"""
Covariance Matrix Adaptation Evolution Strategy Implementation: (μ/μ_{I,W},λ)-CMA-ES

The constructor takes following keyword arguments:

- `μ`/`mu` is the number of parents
- `λ`/`lambda` is the number of offspring
- `c_1` is a learning rate for the rank-one update of the covariance matrix update
- `c_c` is a learning rate for cumulation for the rank-one update of the covariance matrix
- `c_mu` is a learning rate for the rank-``\\mu`` update of the covariance matrix update
- `c_sigma` is a learning rate for the cumulation for the step-size control
- `c_m` is the learning rate for the mean update, ``c_m \\leq 1``
- `σ0`/`sigma0` is the initial step size `σ`
- `weights` are recombination weights, if the weights are set to ```1/\\mu`` then the *intermediate* recombination is activated.
"""
struct CMAES{T} <: AbstractOptimizer
    μ::Int
    λ::Int
    c_1::T
    c_c::T
    c_μ::T
    c_σ::T
    σ₀::T
    cₘ::T
    wᵢ::Vector{T}

    function CMAES(; μ::Int=15, λ::Int=2μ, mu::Int=μ, lambda::Int=λ, weights::Vector{T}=zeros(lambda),
                     c_1::Real=NaN, c_c::Real=NaN, c_mu::Real=NaN, c_sigma::Real=NaN,
                     sigma0::Real=1, c_m::Real=1) where {T}
        @assert c_m ≤ 1 "cₘ > 1"
        @assert length(weights) == lambda "Number of weights must be $lambda"
        new{T}(mu, lambda, c_1, c_c, c_mu, c_sigma, sigma0, c_m, weights)
    end
end

population_size(method::CMAES) = method.μ
default_options(method::CMAES) = (iterations=1500, abstol=1e-15)

mutable struct CMAESState{T,TI} <: AbstractOptimizerState
    N::Int
    μ_eff::T
    c_1::T
    c_c::T
    c_μ::T
    c_σ::T
    fitpop::Vector{T}
    C::Matrix{T}
    s::Vector{T}
    s_σ::Vector{T}
    σ::T
    wᵢ::Vector{T}
    d_σ::T
    parent::TI
    fittest::TI
end
value(s::CMAESState) = first(s.fitpop)
minimizer(s::CMAESState) = s.fittest

"""Initialization of CMA-ES algorithm state"""
function initial_state(method::CMAES, options, objfun, population)
    @unpack μ,λ,c_1,c_c,c_μ,c_σ,σ₀,cₘ,wᵢ = method
    @assert μ < λ "Offspring population must be larger then parent population"

    T = typeof(value(objfun))
    individual = first(population)
    TI = typeof(individual)
    n = length(individual)
    α_cov = 2

    # set parameters
    μ_eff = 1/sum(w->w^2,wᵢ[1:μ])
    if !(1 ≤ μ_eff ≤ μ)
        # default parameters for weighted recombination
        w′ᵢ = T[log((λ+1)/2)-log(i) for i in 1:λ]
        w′⁺ = sum(w′ᵢ[w′ᵢ .≥ 0])
        μ_eff = sum(w′ᵢ[1:μ])^2/sum(w->w^2,w′ᵢ[1:μ])
        μ⁻_eff = sum(w′ᵢ[μ+1:end])^2/sum(w->w^2,w′ᵢ[μ+1:end])
        α⁻ = -sum(w′ᵢ[w′ᵢ .< 0])
        α⁻_eff = 1 + (2*μ⁻_eff)/(μ_eff+2)
        c_1 = isnan(c_1) ? α_cov/((n+1.3)^2+μ_eff) : c_1
        c_μ = isnan(c_μ) ? min(1 - c_1, α_cov*(μ_eff-2+1/μ_eff)/((n+2)^2+α_cov*μ_eff/2)) : c_μ
        c_c = isnan(c_c) ? (4 + μ_eff/n)/(n + 4 + 2*μ_eff/n) : c_c
        c_σ = isnan(c_σ) ? (μ_eff+2)/(n+μ_eff+5) : c_σ
        α⁻_pd =  (1 - c_1 - c_μ)/(n*c_μ)
        wᵢ = [ifelse(w≥ 0, w/w′⁺, min(α⁻,α⁻_eff, α⁻_pd)*w/α⁻) for w in w′ᵢ]
    else
        c_c = isnan(c_c) ? 1/sqrt(n) : c_c
        c_σ = isnan(c_σ) ? 1/sqrt(n) : c_σ
        c_μ = isnan(c_μ) ? min(μ_eff/n^2, 1-c_1) : c_μ
        c_1 = isnan(c_1) ?  min(2/n^2, 1-c_μ) : c_1
    end

    @assert 1 ≤ μ_eff ≤ μ "μ_eff ∉ [1, μ]"
    @assert c_1 + c_μ ≤ 1 "c_1 + c_μ > 1"
    @assert c_σ < 1 "c_σ ≥ 1"
    @assert c_c ≤ 1 "c_c > 1"

    d_σ = 1 + 2 * max(0, sqrt((μ_eff-1)/(n+1))-1) + c_σ

    # setup initial state
    return CMAESState{T,TI}(n, μ_eff, c_1, c_c, c_μ, c_σ,
            fill(convert(T, Inf), μ),
            diagm(0=>ones(T,n)),
            zeros(T, n), zeros(T, n), method.σ₀, wᵢ, d_σ,
            copy(individual), copy(individual) )
end

function update_state!(objfun, constraints, state::CMAESState{T,TI}, population::AbstractVector{TI},
                       method::CMAES, itr) where {T, TI}
    μ, λ, cₘ = method.μ, method.λ, method.cₘ
    N,μ_eff,σ,w,d_σ = state.N, state.μ_eff, state.σ, state.wᵢ, state.d_σ
    c_1,c_c,c_μ,c_σ = state.c_1, state.c_c, state.c_μ, state.c_σ
    weights = view(w, 1:μ)
    E_NormN = sqrt(N)*(1-1/(4*N)+1/(21*N*N))

    parent = reshape(state.parent,N)
    parentshape = size(state.parent)

    z = zeros(T, N, λ)
    # y = zeros(T, N, λ)
    ȳ = zeros(T, N)
    offspring = Array{Vector{T}}(undef, λ)
    fitoff = fill(Inf, λ)

    B, D = try
        C = Symmetric(state.C)
        F = eigen!(Symmetric(state.C))
        F.vectors, Diagonal(sqrt.(max.(0,F.values)))
    catch ex
        @error "Break on eigen decomposition: $ex: $(state.C)"
        return true
    end

    # SqrtC = try
    #     cholesky(Symmetric(state.C)).U
    # catch ex
    #     @error "Break on Cholesky: $ex: $(state.C)"
    #     return true
    # end

    for i in 1:λ
        # offspring are generated by transforming standard normally distributed random vectors using a transformation matrix
        z[:,i] = randn(N)
        # y[:,i] =  B * D * z[:,i]
        # y[:,i] =  SqrtC * z[:,i]
        # offspring[i] = state.parent + σ * y[:,i]
        offspring[i] = value(constraints, parent + σ * B * D * z[:,i])
        fitoff[i] = value(constraints, objfun, reshape(offspring[i],parentshape...)) # Evaluate fitness
    end

    # Select new parent population
    idx = sortperm(fitoff)
    for i in 1:μ
        o = offspring[idx[i]]
        population[i] = reshape(o,parentshape...)
        ȳ .+=(o.-parent).*(w[i]/σ)
        state.fitpop[i] = fitoff[idx[i]]
    end

    # y_λ = view(y,:,idx)
    z_λ = view(z,:,idx)
    z̄ = vec(sum(z_λ[:,1:μ].*weights', dims=2))
    parent += (cₘ*σ).*ȳ  #  forming recombinant perent for next generation
    state.s_σ = (1 - c_σ)*state.s_σ + sqrt(μ_eff*c_σ*(2 - c_σ))*(B*z̄)
    # state.s_σ = (1 - c_σ)*state.s_σ + sqrt(μ_eff*c_σ*(2 - c_σ))*(SqrtC*ȳ)
    state.σ = σ * exp((c_σ/d_σ)*(norm(state.s_σ)/E_NormN - 1))
    h_σ = norm(state.s_σ)/sqrt(1 - (1-c_σ)^(2*(itr+1))) < (1.4+2/(N+1))*E_NormN
    state.s = (1 - c_c)*state.s + (h_σ*sqrt(μ_eff*c_c*(2 - c_c)))*ȳ
    # perform rank-one update
    rank_1 = c_1.*state.s*state.s'
    if !h_σ # correction
        rank_1 += (c_1*c_c*(2 - c_c)).*state.C
    end
    # perform rank-μ update
    rank_μ = c_μ*sum( (w ≥ 0 ? 1 : N/norm(B*zi)^2)*w*(zi*zi') for (w,zi) in zip(w, eachcol(z_λ)) )
    # rank_μ = c_μ*sum( (w ≥ 0 ? 1 : N/norm(SqrtC*yi)^2)*w*(yi*yi') for (w,yi) in zip(w, eachcol(y_λ)) )
    # update covariance
    state.C = (1 - c_1 - c_μ*sum(w)).*state.C + rank_1 + rank_μ

    state.fittest = population[1]
    state.parent = reshape(parent,parentshape...)

    return false
end