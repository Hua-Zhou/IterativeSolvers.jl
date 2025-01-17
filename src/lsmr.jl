export lsmr, lsmr!

using LinearAlgebra

"""
    lsmr(A, b; kwrags...) -> x, [history]

Same as [`lsmr!`](@ref), but allocates a solution vector `x` initialized with zeros.
"""
lsmr(A, b; kwargs...) = lsmr!(zerox(A, b), A, b; kwargs...)

"""
    lsmr!(x, A, b; kwargs...) -> x, [history]

Minimizes ``\\|Ax - b\\|^2 + \\|λx\\|^2`` in the Euclidean norm. If multiple solutions
exists the minimum norm solution is returned.

The method is based on the Golub-Kahan bidiagonalization process. It is
algebraically equivalent to applying MINRES to the normal equations
``(A^*A + λ^2I)x = A^*b``, but has better numerical properties,
especially if ``A`` is ill-conditioned.

# Arguments
- `x`: Initial guess, will be updated in-place;
- `A`: linear operator;
- `b`: right-hand side.

## Keywords

- `λ::Number = 0`: lambda.
- `atol::Number = 1e-6`, `btol::Number = 1e-6`: stopping tolerances. If both are
  1.0e-9 (say), the final residual norm should be accurate to about 9 digits.
  (The final `x` will usually have fewer correct digits,
  depending on `cond(A)` and the size of damp).
- `conlim::Number = 1e8`: stopping tolerance. `lsmr` terminates if an estimate
  of `cond(A)` exceeds conlim.  For compatible systems Ax = b,
  conlim could be as large as 1.0e+12 (say).  For least-squares
  problems, conlim should be less than 1.0e+8.
  Maximum precision can be obtained by setting
- `atol` = `btol` = `conlim` = zero, but the number of iterations
  may then be excessive.
- `maxiter::Int = maximum(size(A))`: maximum number of iterations.
- `log::Bool`: keep track of the residual norm in each iteration;
- `verbose::Bool`: print convergence information during the iterations.

# Return values

**if `log` is `false`**

- `x`: approximated solution.

**if `log` is `true`**

- `x`: approximated solution.
- `ch`: convergence history.

**ConvergenceHistory keys**

- `:atol` => `::Real`: atol stopping tolerance.
- `:btol` => `::Real`: btol stopping tolerance.
- `:ctol` => `::Real`: ctol stopping tolerance.
- `:anorm` => `::Real`: anorm.
- `:rnorm` => `::Real`: rnorm.
- `:cnorm` => `::Real`: cnorm.
- `:resnom` => `::Vector`: residual norm at each iteration.
"""
function lsmr!(x, A, b;
    maxiter::Int = maximum(size(A)),
    log::Bool=false, kwargs...
    )
    history = ConvergenceHistory(partial=!log)
    reserve!(history,[:anorm,:rnorm,:cnorm],maxiter)

    T = Adivtype(A, b)
    m, n = size(A, 1), size(A, 2)
    btmp = similar(b, T)
    copyto!(btmp, b)
    v, h, hbar = similar(x, T), similar(x, T), similar(x, T)
    lsmr_method!(history, x, A, btmp, v, h, hbar; maxiter=maxiter, kwargs...)
    log && shrink!(history)
    log ? (x, history) : x
end

#########################
# Method Implementation #
#########################

function lsmr_method!(log::ConvergenceHistory, x, A, b, v, h, hbar;
    atol::Number = 1e-6, btol::Number = 1e-6, conlim::Number = 1e8,
    maxiter::Int = maximum(size(A)), λ::Number = 0,
    verbose::Bool=false
    )
    verbose && @printf("=== lsmr ===\n%4s\t%7s\t\t%7s\t\t%7s\n","iter","anorm","cnorm","rnorm")

    # Sanity-checking
    m = size(A, 1)
    n = size(A, 2)
    length(x) == n || error("x has length $(length(x)) but should have length $n")
    length(v) == n || error("v has length $(length(v)) but should have length $n")
    length(h) == n || error("h has length $(length(h)) but should have length $n")
    length(hbar) == n || error("hbar has length $(length(hbar)) but should have length $n")
    length(b) == m || error("b has length $(length(b)) but should have length $m")

    T = Adivtype(A, b)
    Tr = real(T)
    normrs = Tr[]
    normArs = Tr[]
    conlim > 0 ? ctol = convert(Tr, inv(conlim)) : ctol = zero(Tr)
    # form the first vectors u and v (satisfy  β*u = b,  α*v = A'u)
    tmp_u = similar(b)
    tmp_v = similar(v)
    mul!(tmp_u, A, x)
    b .-= tmp_u
    u = b
    β = norm(u)
    u .*= inv(β)
    adjointA = adjoint(A)
    mul!(v, adjointA, u)
    α = norm(v)
    v .*= inv(α)

    log[:atol] = atol
    log[:btol] = btol
    log[:ctol] = ctol

    # Initialize variables for 1st iteration.
    ζbar = α * β
    αbar = α
    ρ = one(Tr)
    ρbar = one(Tr)
    cbar = one(Tr)
    sbar = zero(Tr)

    copyto!(h, v)
    fill!(hbar, zero(Tr))

    # Initialize variables for estimation of ||r||.
    βdd = β
    βd = zero(Tr)
    ρdold = one(Tr)
    τtildeold = zero(Tr)
    θtilde  = zero(Tr)
    ζ = zero(Tr)
    d = zero(Tr)

    # Initialize variables for estimation of ||A|| and cond(A).
    normA, condA, normx = -one(Tr), -one(Tr), -one(Tr)
    normA2 = abs2(α)
    maxrbar = zero(Tr)
    minrbar = 1e100

    # Items for use in stopping rules.
    normb = β
    istop = 0
    normr = β
    normAr = α * β
    iter = 0
    # Exit if b = 0 or A'b = 0.

    log.mvps=1
    log.mtvps=1
    if normAr != 0
        while iter < maxiter
            nextiter!(log,mvps=1)
            iter += 1
            mul!(tmp_u, A, v)
            u .= tmp_u .+ u .* -α
            β = norm(u)
            if β > 0
                log.mtvps+=1
                u .*= inv(β)
                mul!(tmp_v, adjointA, u)
                v .= tmp_v .+ v .* -β
                α = norm(v)
                v .*= inv(α)
            end

            # Construct rotation Qhat_{k,2k+1}.
            αhat = hypot(αbar, λ)
            chat = αbar / αhat
            shat = λ / αhat

            # Use a plane rotation (Q_i) to turn B_i to R_i.
            ρold = ρ
            ρ = hypot(αhat, β)
            c = αhat / ρ
            s = β / ρ
            θnew = s * α
            αbar = c * α

            # Use a plane rotation (Qbar_i) to turn R_i^T to R_i^bar.
            ρbarold = ρbar
            ζold = ζ
            θbar = sbar * ρ
            ρtemp = cbar * ρ
            ρbar = hypot(cbar * ρ, θnew)
            cbar = cbar * ρ / ρbar
            sbar = θnew / ρbar
            ζ = cbar * ζbar
            ζbar = - sbar * ζbar

            # Update h, h_hat, x.
            hbar .= hbar .* (-θbar * ρ / (ρold * ρbarold)) .+ h
            x .+= (ζ / (ρ * ρbar)) .* hbar
            h .= h .* (-θnew / ρ) .+ v

            ##############################################################################
            ##
            ## Estimate of ||r||
            ##
            ##############################################################################

            # Apply rotation Qhat_{k,2k+1}.
            βacute = chat * βdd
            βcheck = - shat * βdd

            # Apply rotation Q_{k,k+1}.
            βhat = c * βacute
            βdd = - s * βacute

            # Apply rotation Qtilde_{k-1}.
            θtildeold = θtilde
            ρtildeold = hypot(ρdold, θbar)
            ctildeold = ρdold / ρtildeold
            stildeold = θbar / ρtildeold
            θtilde = stildeold * ρbar
            ρdold = ctildeold * ρbar
            βd = - stildeold * βd + ctildeold * βhat

            τtildeold = (ζold - θtildeold * τtildeold) / ρtildeold
            τd = (ζ - θtilde * τtildeold) / ρdold
            d += abs2(βcheck)
            normr = sqrt(d + abs2(βd - τd) + abs2(βdd))

            # Estimate ||A||.
            normA2 += abs2(β)
            normA  = sqrt(normA2)
            normA2 += abs2(α)

            # Estimate cond(A).
            maxrbar = max(maxrbar, ρbarold)
            if iter > 1
                minrbar = min(minrbar, ρbarold)
            end
            condA = max(maxrbar, ρtemp) / min(minrbar, ρtemp)

            ##############################################################################
            ##
            ## Test for convergence
            ##
            ##############################################################################

            # Compute norms for convergence testing.
            normAr  = abs(ζbar)
            normx = norm(x)

            # Now use these norms to estimate certain other quantities,
            # some of which will be small near a solution.
            test1 = normr / normb
            test2 = normAr / (normA * normr)
            test3 = inv(condA)
            push!(log, :cnorm, test3)
            push!(log, :anorm, test2)
            push!(log, :rnorm, test1)
            verbose && @printf("%3d\t%1.2e\t%1.2e\t%1.2e\n",iter,test2,test3,test1)

            t1 = test1 / (one(Tr) + normA * normx / normb)
            rtol = btol + atol * normA * normx / normb
            # The following tests guard against extremely small values of
            # atol, btol or ctol.  (The user may have set any or all of
            # the parameters atol, btol, conlim  to 0.)
            # The effect is equivalent to the normAl tests using
            # atol = eps,  btol = eps,  conlim = 1/eps.
            if iter >= maxiter istop = 7; break end
            if 1 + test3 <= 1 istop = 6; break end
            if 1 + test2 <= 1 istop = 5; break end
            if 1 + t1 <= 1 istop = 4; break end
            # Allow for tolerances set by the user.
            if test3 <= ctol istop = 3; break end
            if test2 <= atol istop = 2; break end
            if test1 <= rtol  istop = 1; break end
        end
    end
    verbose && @printf("\n")
    setconv(log, istop ∉ (3, 6, 7))
    x
end
