"""
This module provides utilities to build neural networks with Flux,
along with a library of standard architectures.
"""
module FluxNets

export SimpleNet, SimpleNetHP, ResNet, ResNetHP

using ..Network
using Base: @kwdef
import ..GameInterface, ..Util, ..CyclicSchedule

using CUDAapi

# Import CuArrays only if CUDA is installed
if has_cuda()
  try
    using CuArrays
    @eval const CUARRAYS_IMPORTED = true
  catch ex
    @warn(
      "CUDA is installed, but CuArrays.jl fails to load.",
      exception=(ex,catch_backtrace()))
    @eval const CUARRAYS_IMPORTED = false
  end
else
  @eval const CUARRAYS_IMPORTED = false
end

import Flux

if CUARRAYS_IMPORTED
  @eval begin
    CuArrays.allowscalar(false)
    on_gpu(::Type{<:Array}) = false
    on_gpu(::Type{<:CuArray}) = true
    on_gpu(x) = on_gpu(typeof(x))
  end
else
  @eval begin
    on_gpu(x) = false
  end
end

using Flux: relu, softmax, flatten
using Flux: Chain, Dense, Conv, BatchNorm, SkipConnection
import Zygote

#####
##### Flux Networks
#####

"""
    FluxNetwork{Game} <: AbstractNetwork{Game}

Abstract type for neural networks implemented using the _Flux_ framework.

The `regularized_params_` function must be overrided for all layers containing
parameters that are subject to regularization.

Provided that the above holds, `FluxNetwork` implements the full
network interface with the following exceptions:
[`Network.HyperParams`](@ref), [`Network.hyperparams`](@ref),
[`Network.forward`](@ref) and [`Network.on_gpu`](@ref).
"""
abstract type FluxNetwork{Game} <: AbstractNetwork{Game} end

function Base.copy(nn::Net) where Net <: FluxNetwork
  #new = Net(Network.hyperparams(nn))
  #Flux.loadparams!(new, Flux.params(nn))
  #return new
  return Base.deepcopy(nn)
end

Network.to_cpu(nn::FluxNetwork) = Flux.cpu(nn)

function Network.to_gpu(nn::FluxNetwork)
  CUARRAYS_IMPORTED && CuArrays.allowscalar(false)
  return Flux.gpu(nn)
end

function Network.set_test_mode!(nn::FluxNetwork, mode)
  Flux.testmode!(nn, mode)
end

Network.convert_input(nn::FluxNetwork, x) =
  Network.on_gpu(nn) ? Flux.gpu(x) : x

Network.convert_output(nn::FluxNetwork, x) = Flux.cpu(x)

Network.params(nn::FluxNetwork) = Flux.params(nn)

# This should be included in Flux
function lossgrads(f, args...)
  val, back = Zygote.pullback(f, args...)
  grad = back(Zygote.sensitivity(val))
  return val, grad
end

function Network.train!(callback, nn::FluxNetwork, opt::Adam, loss, data, n)
  optimiser = Flux.ADAM(opt.lr)
  params = Flux.params(nn)
  for (i, d) in enumerate(data)
    l, grads = lossgrads(params) do
      loss(d...)
    end
    Flux.update!(optimiser, params, grads)
    callback(i, l)
  end
end

function Network.train!(
    callback, nn::FluxNetwork, opt::CyclicNesterov, loss, data, n)
  lr = CyclicSchedule(
    opt.lr_base,
    opt.lr_high,
    opt.lr_low, n=n)
  momentum = CyclicSchedule(
    opt.momentum_high,
    opt.momentum_low,
    opt.momentum_high, n=n)
  optimiser = Flux.Nesterov(opt.lr_low, opt.momentum_high)
  params = Flux.params(nn)
  for (i, d) in enumerate(data)
    l, grads = lossgrads(params) do
      loss(d...)
    end
    Flux.update!(optimiser, params, grads)
    optimiser.eta = lr[i]
    optimiser.rho = momentum[i]
    callback(i, l)
  end
end

regularized_params_(l) = []
regularized_params_(l::Flux.Dense) = [l.W]
regularized_params_(l::Flux.Conv) = [l.weight]

# Reimplementation of what used to be Flux.prefor, does not visit leafs
function foreach_flux_node(f::Function, x, seen = IdDict())
  Flux.isleaf(x) && return
  haskey(seen, x) && return
  seen[x] = true
  f(x)
  for child in Flux.trainable(x)
    foreach_flux_node(f, child, seen)
  end
end

function Network.regularized_params(net::FluxNetwork)
  ps = Flux.Params()
  foreach_flux_node(net) do p
    for r in regularized_params_(p)
      any(x -> x === r, ps) || push!(ps, r)
    end
  end
  return ps
end

function Network.gc(::FluxNetwork)
  CUARRAYS_IMPORTED || return
  GC.gc(true)
  # CuArrays.reclaim()
end

#####
##### Common functions between two-head neural networks
#####

"""
    TwoHeadNetwork{Game} <: FluxNetwork{G}

An abstract type for two-head neural networks implemented with Flux.

Subtypes are assumed to have fields
`hyper`, `common`, `vhead` and `phead`. Based on those, an implementation
is provided for [`Network.hyperparams`](@ref), [`Network.forward`](@ref) and
[`Network.on_gpu`](@ref), leaving only [`Network.HyperParams`](@ref) to
be implemented.
"""
abstract type TwoHeadNetwork{G} <: FluxNetwork{G} end

function Network.forward(nn::TwoHeadNetwork, board)
  c = nn.common(board)
  v = nn.vhead(c)
  p = nn.phead(c)
  return (p, v)
end

# Flux.@functor does not work do to Network being parametric
function Flux.functor(nn::Net) where Net <: TwoHeadNetwork
  children = (nn.common, nn.vhead, nn.phead)
  constructor = cs -> Net(nn.hyper, cs...)
  return (children, constructor)
end

Network.hyperparams(nn::TwoHeadNetwork) = nn.hyper

Network.on_gpu(nn::TwoHeadNetwork) = on_gpu(nn.vhead[end].b)

#####
##### Include networks library
#####

include("architectures/simplenet.jl")
include("architectures/resnet.jl")

end
