module AutoGPs

using Reexport

@reexport using AbstractGPs
@reexport using ApproximateGPs
@reexport using GPLikelihoods

import Optimization, OptimizationOptimJL
import ParameterHandling
import Enzyme, Zygote

export with_gaussian_noise
export SVA, SVGP

"""
    fit(something, data; kwargs...)

Fit `something` to `data`. Returns another instance of `typeof(something)` with optimized
parameters. For possible keyword arguments see `optimize`.
"""
function fit(something, data; kwargs...)
    model, θ0 = parameterize(something)
    θ = optimize(model, θ0, data; kwargs...)
    return model(θ)
end

"""
    fit(something, x, y; kwargs...)

A shorthand for `fit(something, (; x, y); kwargs...)` for when the only data is `x` and `y`.
"""
fit(gp, x, y; kwargs...) = fit(gp, (; x, y); kwargs...)

struct Parameterized{T}
    thing::T
end

function (p::Parameterized)(θ)
    return apply_parameters(p.thing, ParameterHandling.value(θ))
end

"""
    parameterize(something) -> model, θ

Turn `something` into a callable parameterized version of something and a parameter `θ`.
After assigning `model, θ = parameterize(something)`, calling `model(θ)` will yield the same
`something` back. 
"""
parameterize(thing) = Parameterized(thing), extract_parameters(thing)

"""
    optimize(model, θ0, data; kwargs...) -> θ_opt

Takes a callable `model` and returns the optimal parameter, starting with initial parameters
`θ0`. In order to work, there needs to be an implementation of `AutoGPs.costfunction` taking
two arguments, the first of which is of type `typeof(model(θ0))`.
"""
function optimize(model, θ0, data; kwargs...)
    par0, unflatten = ParameterHandling.flatten(θ0)
    optf = Optimization.OptimizationFunction(
        (par, data) -> costfunction(model(unflatten(par)), data),
        Optimization.AutoZygote()
    )
    prob = Optimization.OptimizationProblem(optf, par0, data)
    sol = Optimization.solve(prob, OptimizationOptimJL.BFGS(); maxiters = 1000)
    return unflatten(sol.u)
end

"""
    _isequal(something, something_else)

Check whether two things are equal for the purposes of this library.
"""
_isequal(::T1, ::T2) where {T1, T2} = false



# Mean functions
extract_parameters(::ZeroMean) = nothing
apply_parameters(m::ZeroMean, θ) = m
_isequal(::ZeroMean, ::ZeroMean) = true

extract_parameters(m::ConstMean) = m.c
apply_parameters(::ConstMean, θ) = ConstMean(θ)
_isequal(m1::ConstMean, m2::ConstMean) = isapprox(m1.c, m2.c)



# Simple kernels
extract_parameters(::SEKernel) = nothing
apply_parameters(m::SEKernel, θ) = m
_isequal(::SEKernel, ::SEKernel) = true

extract_parameters(::Matern32Kernel) = nothing
apply_parameters(m::Matern32Kernel, θ) = m
_isequal(::Matern32Kernel, ::Matern32Kernel) = true

extract_parameters(::Matern52Kernel) = nothing
apply_parameters(m::Matern52Kernel, θ) = m
_isequal(::Matern52Kernel, ::Matern52Kernel) = true



# Composite kernels
extract_parameters(k::KernelSum) = map(extract_parameters, k.kernels)
apply_parameters(k::KernelSum, θ) = KernelSum(map(apply_parameters, k.kernels, θ))
_isequal(k1::KernelSum, k2::KernelSum) = mapreduce(_isequal, &, k1.kernels, k2.kernels)

extract_parameters(k::KernelProduct) = map(extract_parameters, k.kernels)
apply_parameters(k::KernelProduct, θ) = KernelProduct(map(apply_parameters, k.kernels, θ))
_isequal(k1::KernelProduct, k2::KernelProduct) = mapreduce(_isequal, &, k1.kernels, k2.kernels)

function extract_parameters(k::TransformedKernel)
    return (extract_parameters(k.kernel), extract_parameters(k.transform))
end

function apply_parameters(k::TransformedKernel, θ)
    return TransformedKernel(
        apply_parameters(k.kernel, θ[1]),
        apply_parameters(k.transform, θ[2])
    )
end

function _isequal(k1::TransformedKernel, k2::TransformedKernel)
    return _isequal(k1.kernel, k2.kernel) && _isequal(k1.transform, k2.transform)
end

function extract_parameters(k::ScaledKernel)
    return (extract_parameters(k.kernel), ParameterHandling.positive(only(k.σ²)))
end

function apply_parameters(k::ScaledKernel, θ)
    return ScaledKernel(
        apply_parameters(k.kernel, θ[1]),
        θ[2]
    )
end

function _isequal(k1::ScaledKernel, k2::ScaledKernel)
    return _isequal(k1.kernel, k2.kernel) && isapprox(k1.σ², k2.σ²)
end



# Transforms
extract_parameters(t::ScaleTransform) = ParameterHandling.positive(only(t.s))
apply_parameters(::ScaleTransform, θ) = ScaleTransform(θ)
_isequal(t1::ScaleTransform, t2::ScaleTransform) = isapprox(t1.s, t2.s)



# Likelihoods
extract_parameters(::BernoulliLikelihood) = nothing
apply_parameters(l::BernoulliLikelihood, θ) = l



# GPs
extract_parameters(f::GP) = (extract_parameters(f.mean), extract_parameters(f.kernel))
apply_parameters(f::GP, θ) = GP(apply_parameters(f.mean, θ[1]), apply_parameters(f.kernel, θ[2]))
_isequal(f1::GP, f2::GP) = _isequal(f1.mean, f2.mean) && _isequal(f1.kernel, f2.kernel)

extract_parameters(f::LatentGP) = (extract_parameters(f.f), extract_parameters(f.lik))
apply_parameters(f::LatentGP, θ) = GP(apply_parameters(f.f, θ[1]), apply_parameters(f.lik, θ[2]), f.Σy)



# Approximations
const SVA = SparseVariationalApproximation

function extract_parameters(sva::SVA, fixed_inducing_points::Bool)
    fz_par = fixed_inducing_points ? nothing : collect(fz.x)
    q_par = extract_parameters(sva.q)
    return (fz_par, q_par)
end

function apply_parameters(sva::SVA, θ)
    fz = isnothing(θ[1]) ? sva.fz : sva.fz.f(θ[1])
    q = apply_parameters(sva.q, θ[2])
    return SVA(fz, q)
end



# Custom wrappers
struct NoisyGP{T <: GP, Tn <: Real}
    gp::T
    obs_noise::Tn
end

with_gaussian_noise(gp::GP, obs_noise::Real) = NoisyGP(gp, obs_noise)

extract_parameters(f::NoisyGP) = (extract_parameters(f.gp), ParameterHandling.positive(f.obs_noise))
apply_parameters(f::NoisyGP, θ) = NoisyGP(apply_parameters(f.gp, θ[1]), θ[2])
costfunction(f::NoisyGP, data) = -logpdf(f.gp(data.x, f.obs_noise), data.y)
_isequal(f1::NoisyGP, f2::NoisyGP) = _isequal(f1.gp, f2.gp) && isapprox(f1.obs_noise, f2.obs_noise)

struct SVGP{T <: LatentGP, Ts <: SVA}
    lgp::T
    sva::Ts
    fixed_inducing_points::Bool
end

SVGP(lgp, sva; fixed_induxing_points) = SVGP(lgp, sva, fixed_induxing_points)

function extract_parameters(f::SVGP)
    return (
        extract_parameters(f.lgp),
        extract_parameters(f.sva, f.fixed_inducing_points),
    )
end

function apply_parameters(f::SVGP, θ)
    return SVGP(
        apply_parameters(f.lgp, θ[1]),
        apply_parameters(f.sva, θ[2]),
        f.fixed_inducing_points
    )
end

costfunction(svgp::SVGP, data) = -elbo(svgp.lgp(data.x), svgp.sva, data.y)

end # module AutoGPs
