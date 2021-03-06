module OpenMDAO
using PyCall

include("utils.jl")

export VarData, PartialsData, make_component, AbstractExplicitComp, AbstractImplicitComp
export om  # direct access to Python module: openmdao.api

# Path to this module.
const module_path = splitdir(@__FILE__)[1]

# load python api
const om = PyNULL()
path_to_julia_comps = module_path
const julia_comps = PyNULL()

function __init__()
    copy!(om, pyimport_conda("openmdao.api", "openmdao"))
    # copy!(julia_comps, pyimport("omjl.julia_comps"))

    # https://stackoverflow.com/questions/35288021/what-is-the-equivalent-of-imp-find-module-in-importlib
    importlib = PyCall.pyimport("importlib")
	loader_details = (
		importlib.machinery.SourceFileLoader,
		importlib.machinery.SOURCE_SUFFIXES)
    finder = importlib.machinery.FileFinder(path_to_julia_comps, loader_details)
	specs = finder.find_spec("julia_comps")
	julia_comps_mod = importlib.util.module_from_spec(specs)
	specs.loader.exec_module(julia_comps_mod)
	copy!(julia_comps, julia_comps_mod)

end

abstract type AbstractComp end
abstract type AbstractExplicitComp <: AbstractComp end
abstract type AbstractImplicitComp <: AbstractComp end

# The component_registry is a dict that stores each OpenMDAO.jl component struct
# that is created with the make_component methods. The idea is to avoid having
# to pass the <:AbstractComp structs from Python to Julia, because that requires
# copying the data, which is slow when the struct is large.
const CompIdType = BigInt
const component_registry = Dict{CompIdType, AbstractComp}()

function make_component(self::T) where {T<:AbstractExplicitComp}
    comp_id = BigInt(objectid(self))
    component_registry[comp_id] = self
    comp = julia_comps.JuliaExplicitComp(jl_id=comp_id)
    return comp
end

function make_component(self::T) where {T<:AbstractImplicitComp}
    comp_id = BigInt(objectid(self))
    component_registry[comp_id] = self
    comp = julia_comps.JuliaImplicitComp(jl_id=comp_id)
    return comp
end

function remove_component(comp_id::Integer)
    delete!(component_registry, BigInt(comp_id))
    # Not returning "nothing" breaks things. Why?
    return nothing
end

# This is just needed for testing the component registry garbage collection from
# Python. For some reason I'm not able to import the component_registry Dict and
# check its size, keys, etc. from Python.
component_registry_length() = length(component_registry)

detect_compute_partials(::Type{<:AbstractExplicitComp}) = true
detect_linearize(::Type{<:AbstractImplicitComp}) = true
detect_apply_nonlinear(::Type{<:AbstractImplicitComp}) = true
detect_guess_nonlinear(::Type{<:AbstractImplicitComp}) = true
detect_solve_nonlinear(::Type{<:AbstractImplicitComp}) = true
detect_apply_linear(::Type{<:AbstractImplicitComp}) = true

function setup(comp_id::Integer)
    comp = component_registry[comp_id]
    return setup(comp)
end

function compute!(comp_id::Integer, inputs, outputs)
    comp = component_registry[comp_id]
    compute!(comp, inputs, outputs)
end

function compute_partials!(comp_id::Integer, inputs, partials)
    comp = component_registry[comp_id]
    compute_partials!(comp, inputs, partials)
end

function apply_nonlinear!(comp_id::Integer, inputs, outputs, residuals)
    comp = component_registry[comp_id]
    apply_nonlinear!(comp, inputs, outputs, residuals)
end

function linearize!(comp_id::Integer, inputs, outputs, partials)
    comp = component_registry[comp_id]
    linearize!(comp, inputs, outputs, partials)
end

function guess_nonlinear!(comp_id::Integer, inputs, outputs, residuals)
    comp = component_registry[comp_id]
    guess_nonlinear!(comp, inputs, outputs, residuals)
end

function solve_nonlinear!(comp_id::Integer, inputs, outputs)
    comp = component_registry[comp_id]
    solve_nonlinear!(comp, inputs, outputs)
end

function apply_linear!(comp_id::Integer, inputs, outputs, d_inputs, d_outputs, d_residuals, mode)
    comp = component_registry[comp_id]
    apply_linear!(comp, inputs, outputs, d_inputs, d_outputs, d_residuals, mode)
end

# TODO: parameterize the `VarData` struct. `name` and `units` should be
# `AbstractString` or something similar. `val` could be a scalar float
# (`AbstractFloat`?) or an array. Shape could be a scalar integer or array or
# tuple.
struct VarData
    name
    val
    shape
    units
end

VarData(name; val=1.0, shape=1, units=nothing) = VarData(name, val, shape, units)

# TODO: parameterize the `PartialsData` struct?
struct PartialsData
    of
    wrt
    rows
    cols
    val
end

PartialsData(of, wrt; rows=nothing, cols=nothing, val=nothing) = PartialsData(of, wrt, rows, cols, val)

function get_py2jl_setup(comp_id::Integer)
    comp = component_registry[comp_id]
    T = typeof(comp)

    args = (T,)  # self
    method = which(setup, args)

    # Now get the wrapped version, which will always be the same for every
    # component... 
    args = (Integer,)  # self
    ret = Tuple{Vector{VarData},       # input metadata
                Vector{VarData},       # output metadata
                Vector{PartialsData}}  # partials metadata

    return pyfunctionret(setup, ret, args...)
end

function get_py2jl_compute(comp_id::Integer)
    comp = component_registry[comp_id]
    T = typeof(comp)

    args = (T, PyDict{String, PyArray}, PyDict{String, PyArray})
    method = which(compute!, args)  # self

    # Now get the wrapped version, which will always be the same for every
    # component... 
    args = (Integer,  # self
            PyDict{String, PyArray},  # inputs
            PyDict{String, PyArray})  # outputs

    return pyfunction(compute!, args...)
end

function get_py2jl_compute_partials(comp_id::Integer)
    comp = component_registry[comp_id]
    T = typeof(comp)
    if detect_compute_partials(T)
        try
            # Look for the method for type T.
            method = which(compute_partials!, (T,  # self
                                               PyDict{String, PyArray},  # inputs
                                               PyDict{Tuple{String, String}, PyArray}))  # partials)

            # Create a Python wrapper for the method.
            args = (Integer,  # component ID
                    PyDict{String, PyArray},  # inputs
                    PyDict{Tuple{String, String}, PyArray})  # partials
            return pyfunction(compute_partials!, args...)
        catch err
            @warn "No compute_partials! method found for $(T)" 
            return nothing
        end
    else
        return nothing
    end
end

function get_py2jl_apply_nonlinear(comp_id::Integer)
    comp = component_registry[comp_id]
    T = typeof(comp)
    if detect_apply_nonlinear(T)
        try
            # Look for the method for type T.
            method = which(apply_nonlinear!, (T,
                                              PyDict{String, PyArray},
                                              PyDict{String, PyArray},
                                              PyDict{String, PyArray}))

            # Create a Python wrapper for the method.
            args = (Integer,  # self
                    PyDict{String, PyArray},  # inputs
                    PyDict{String, PyArray},  # outputs
                    PyDict{String, PyArray})  # residuals
            return pyfunction(apply_nonlinear!, args...)
        catch err
            @warn "No apply_nonlinear! method found for $(T)" 
            return nothing
        end
    else
        return nothing
    end
end

function get_py2jl_linearize(comp_id::Integer)
    comp = component_registry[comp_id]
    T = typeof(comp)
    if detect_linearize(T)
        try
            # Look for the method for type T.
            method = which(linearize!, (T, 
                                        PyDict{String, PyArray}, # inputs
                                        PyDict{String, PyArray}, # outputs
                                        PyDict{Tuple{String, String}, PyArray})) # partials

            # Create a Python wrapper for the method.
            args = (Integer, 
                    PyDict{String, PyArray}, # inputs
                    PyDict{String, PyArray}, # outputs
                    PyDict{Tuple{String, String}, PyArray})
            return pyfunction(linearize!, args...)
        catch err
            @warn "No linearize! method found for $(T)" 
            return nothing
        end
    else
        return nothing
    end
end

function get_py2jl_guess_nonlinear(comp_id::Integer)
    comp = component_registry[comp_id]
    T = typeof(comp)
    if detect_guess_nonlinear(T)
        try
            # Look for the method for type T.
            method = which(guess_nonlinear!, (T, 
                                              PyDict{String, PyArray}, 
                                              PyDict{String, PyArray},
                                              PyDict{String, PyArray}))

            # Create a Python wrapper for the method.
            args = (Integer,  # self
                    PyDict{String, PyArray},  # inputs
                    PyDict{String, PyArray},  # outputs
                    PyDict{String, PyArray})  # residuals
            return pyfunction(guess_nonlinear!, args...)
        catch err
            @warn "No guess_nonlinear! method found for $(T)" 
            return nothing
        end
    else
        return nothing
    end
end

function get_py2jl_solve_nonlinear(comp_id::Integer)
    comp = component_registry[comp_id]
    T = typeof(comp)
    if detect_solve_nonlinear(T)
        try
            # Look for the method for type T.
            method = which(solve_nonlinear!, (T, 
                                              PyDict{String, PyArray}, 
                                              PyDict{String, PyArray}))

            # Create a Python wrapper for the method.
            args = (Integer,  # self
                    PyDict{String, PyArray},  # inputs
                    PyDict{String, PyArray})  # outputs
            return pyfunction(solve_nonlinear!, args...)
        catch err
            @warn "No solve_nonlinear! method found for $(T)" 
            return nothing
        end
    else
        return nothing
    end
end

function get_py2jl_apply_linear(comp_id::Integer)
    comp = component_registry[comp_id]
    T = typeof(comp)
    if detect_apply_linear(T)
        try
            # Look for the method for type T.
            method = which(apply_linear!, (T, 
                                           PyDict{String, PyArray}, 
                                           PyDict{String, PyArray},
                                           PyDict{String, PyArray},
                                           PyDict{String, PyArray},
                                           PyDict{String, PyArray},
                                           String))

            # Create a Python wrapper for the method.
            args = (Integer,  # self
                    PyDict{String, PyArray},  # inputs
                    PyDict{String, PyArray},  # outputs
                    PyDict{String, PyArray},  # d_inputs
                    PyDict{String, PyArray},  # d_outputs
                    PyDict{String, PyArray},  # d_residuals
                    String)                   # mode
            return pyfunction(apply_linear!, args...)
        catch err
            @warn "No apply_linear! method found for $(T)" 
            return nothing
        end
    else
        return nothing
    end
end

end # module
