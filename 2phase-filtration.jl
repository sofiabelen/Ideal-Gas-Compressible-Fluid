## Physics:
##
## We simulate 2d flow of ideal gas through a porous medium
## with the help of Darcy's law.
## 
## v⃗ = -μ⁻¹ K̂ ⋅∇P,
##
## where K̂, a second-order tensor in the general case, is
## the specific permeability. It depends only on the
## geometry of the mediumm. Here we assume isotropy
## of space, so K is a scalar. μ is the dynamic viscocity.
##
## Continuity equation:
##
## φ ⋅∂ρ / ∂t + div(ρv⃗) = 0
##
## where φ is the porosity.
##
## So, the equations used are the continuity equation and
## Darcy's equation, which replaces the momentum equation,
## used in our last program.
##
## Another change with respect to the ideal gas program
## is that we will set the boundary conditions using ghost cells.
## This way, we can make use of the central difference scheme for
## boundary conditions which consist of partial derivatives,
## which is second-order.
##
## The boundary conditions consist of walls on the top
## and bottom, and constant pressure on either side.
##
## For now, our velocities will be equal to 0 at the beginning.
##
## ---------
## ->     ->
## ->     ->
## ---------
##
## Initial conditions:
## v⃗ = (u, v) = 0⃗ everywhere
## P = P0 everywhere else
##
## Boundary conditions:
## u = 0 at x = 0, 2 (walls)
## P = Pin at y = 0 and x ∈ [0, 1]
## v = 0 at y = 0 and x ∈ [1, 2]
## P = Pout, dv / dy = 0 at y = 2
## ∂P / ∂y = 0 at y = 0, 2

using DelimitedFiles, PyPlot

## Change index -> [i, j, k]
mutable struct System{T<:AbstractFloat}
    ## index [k, i, j], where k=1,2 is the component: 1 - gas,
    ## 2 - liquid; i, j are x and y spatial coordinates.
    u::Array{T, 3}
    v::Array{T, 3}
    ρ::Array{T, 3}
    ## [i, j] -> x, y
    P::Array{T, 2}
    s::Array{T, 2}
end

Base.copy(sys::System) = System(copy.((sys.u, sys.v, sys.ρ,
                                       sys.P, sys.s))... )

function binarySearch(; f, left, right, niter=50, eps=1e-6)
    mid = left
    for i = 1 : niter
        mid = left + (right - left) / 2

        if abs((right - left) / mid) < eps
            return mid
        elseif f(mid) < 0
            left = mid
        elseif f(mid) > 0
            right = mid
        else
            return mid
        end
    end
    return mid
end

function findPressure(; ρ̂₁::T, ρ̂₂::T, V::T,
        left=1e4, right=1e7, niter=50,
        eps=1e-6) where T<:AbstractFloat
    function f(P::Float64)
        ρ₁ = 0.029 / 8.314 / 298 * P
        s = ρ̂₁ / ρ₁
        ρ₂ = ρ̂₂ / (1 - s)
        ρ₀ = 616.18
        P₀ = 1e5
        return (ρ₂ - ρ₀) / ρ₂ - 0.2105 *
            log10((35e6 + P) / (35e6 + P₀))
    end

    P = binarySearch(; f, left, right, eps)
    ρ₁ = 0.029 / 8.314 / 298 * P
    s = ρ̂₁ / ρ₁
    return P, s
end

function densityofLiquid(P::Float64, s::Float64)
    ρ₀ = 616.18
    P₀ = 1e5
    ρ₂ = ρ₀ / (1 - 0.2105 * log10((35e6 + P) / (35e6 + P₀)))
    ρ̂₂ = (1 - s) * ρ₂
    return ρ̂₂
end

## Avoid typos when working with partial derivatives
##
## NW--N--NE
##     |
## W---C---E
##     |
## SW--S--SE
function cnswe(arr::AbstractArray{T, 2},
        i::Int, j::Int) where T<:AbstractFloat
    c = arr[i, j]
    n = arr[i, j + 1]
    s = arr[i, j - 1]
    w = arr[i - 1, j]
    e = arr[i + 1, j]
    return c, n, s, w, e
end

## Continuity equation to calculate ρᵢ
## φ ⋅∂ρᵢ / ∂t + div(ρᵢv⃗ᵢ) = 0, where ρᵢ = mᵢ / V
## We will add a right side to this where we inject matter.
function continuity_equation!(; Δt::T, Δx::T, Δy::T, φ::T,
        ρnext::AbstractArray{T, 2},
        ρwork::AbstractArray{T, 2},
        uwork::AbstractArray{T, 2},
        vwork::AbstractArray{T, 2}) where T<:AbstractFloat
    nx, ny = size(ρnext)
    for j = 2 : ny - 1
        for i = 2 : nx - 1
            ρc, ρn, ρs, ρw, ρe = cnswe(ρwork, i, j)
            uc, un, us, uw, ue = cnswe(uwork, i, j)
            vc, vn, vs, vw, ve = cnswe(vwork, i, j)
    
            ρnext[i, j] = ρc - Δt / φ *
                (uc * (ρe - ρw) / (2 * Δx) +
                 vc * (ρn - ρs) / (2 * Δy) +
                 ρc * (ue - uw) / (2 * Δx) +
                 ρc * (vn - vs) / (2 * Δy))
        end
    end
end

## Fix: change μ for different components
## Darcy's law
## v⃗ = -μ⁻¹ K̂⋅f(s) ⋅∇P
function darcy!(; f::Function,
        unext::AbstractArray{T, 2},
        vnext::AbstractArray{T, 2},
        Pnext::AbstractArray{T, 2},
            s::AbstractArray{T, 2},
        K::T, μ::T, Δx::T, Δy::T) where T<:AbstractFloat
    nx, ny = size(unext)
    for j = 2 : ny - 1
        for i = 2 : nx - 1
            ## можно через (ρwork + ρnext) / 2
            Pc, Pn, Ps, Pw, Pe = cnswe(Pnext, i, j)

            unext[i, j] = -K / μ * f(s[i, j]) *
                (Pe - Pw) / (2 * Δx)
            vnext[i, j] = -K / μ * f(s[i, j]) *
                (Pn - Ps) / (2 * Δy)
        end
    end
end

## Question: Is it necessry to write these explicitly
# function boundaryDensity!(ρnext::AbstractArray{Float64, 2})
#     nx, ny = size(ρnext)
#     ## Question
#     ## ρ = 0 'behind walls'
#     # @. @views ρnext[1, :] = 0
#     # @. @views ρnext[nx, :] = 0
#     # @. @views ρnext[nx ÷ 2 + 1: nx, 1] = 0
#     ## Or ρ = 0 at walls ??
#     # @. @views ρnext[1, :] = -ρnext[2, :]
#     # @. @views ρnext[nx, :] = -ρnext[nx - 1, :]
#     # @. @views ρnext[nx ÷ 2 + 1: nx, 1] = 
#     #     -ρnext[nx ÷ 2 + 1: nx, 2]
#     ## ∂ρ / ∂n = 0
# 
#     ## ∂ρ / ∂y = 0 at entrance and exit
#     @. @views ρnext[:, ny] = ρnext[:, ny - 1]
#     @. @views ρnext[1: nx ÷ 2, 1] = ρnext[1: nx ÷ 2, 2]
# end

function boundaryPressure!(Pnext::Array{T, 2},
        Pin::T, Pout::T) where T<:AbstractFloat
    nx, ny = size(Pnext)
    ## P = Pin at y = 0 and x ∈ [0, 1]
    @. @views Pnext[1: nx ÷ 2, 1] =
        2 * Pin - Pnext[1: nx ÷ 2, 2]

    ## P = Pout at y = 2
    @. @views Pnext[:, ny] = 2 * Pout - Pnext[:, ny - 1]

    ## ∂P / ∂x = 0 at x = 0, 2
    @. @views Pnext[nx, :] = Pnext[nx - 1, :]
    @. @views Pnext[1, :] = Pnext[2, :]

    ## ∂P / ∂y = 0 at y = 0 x ∈ [1, 2]
    @. @views Pnext[nx ÷ 2 + 1: nx, 1] =
        Pnext[nx ÷ 2 + 1: nx, 2]
end

function boundaryVelocity!(unext::AbstractArray{T, 2},
        vnext::AbstractArray{T, 2}) where T<:AbstractFloat
    nx, ny = size(unext)
    ## u = 0 at x = 0, 2 (walls)
    @. @views unext[1, :] = -unext[2, :]
    @. @views unext[nx, :] = -unext[nx - 1, :]

    ## v = 0 at y = 0 and x ∈ [1, 2]
    @. @views vnext[1, nx ÷ 2 + 1: nx] =
        -vnext[2, nx ÷ 2 + 1: nx]

    ## ∂v / ∂y = 0 at y = 2
    @views vnext[:, ny] = vnext[:, ny - 1]

    ## ∂v / ∂y = 0 at y = 0 and x ∈ [0, 1]
    @views vnext[1: nx ÷ 2, 1] =  vnext[1: nx ÷ 2, 2]
end

function update!(; ρnext, unext, vnext, Pnext, snext,
        ρwork, uwork, vwork,
        Δt, Δx, Δy, Pin, Pout, φ, K, μ)
    nx, ny = size(ρnext)
    coeff = 8.314 * 298 / 0.029

    for k = 1 : 2
        @views continuity_equation!(Δt=Δt, Δx=Δx, Δy=Δy, φ=φ,
            ρnext=ρnext[k, :, :], ρwork=ρwork[k, :, :],
            uwork=uwork[k, :, :], vwork=vwork[k, :, :])
    end
    # for k = 1 : 2
    #     @views boundaryDensity!(ρnext[k, :, :])
    # end
    for index in CartesianIndices(Pnext)
        i, j = Tuple(index)
        Pnext[i, j], snext[i, j] =
            findPressure(ρ̂₁=ρnext[1, i, j],
                         ρ̂₂=ρnext[2, i, j], V=Δx * Δy)
    end
    boundaryPressure!(Pnext, Pin, Pout)
    
    f1(s) = s^2
    f2(s) = (1 - s)^2
    f = [f1, f2]
    for k = 1 : 2
        @views darcy!(f=f[k],  unext=unext[k, :, :],
               vnext=vnext[k, :, :], Pnext=Pnext,
               s=(k == 1 ? snext : snext.-1), K=K,
               μ=μ, Δx=Δx, Δy=Δy)
    end
    for k = 1 : 2
        @views boundaryVelocity!(unext[k, :, :],
                                 vnext[k, :, :])
    end
end

function filtration!(; Δx, Δy, Δt, nsteps, K, φ, μ,
        Pin, Pout, sys)
    syswork = sys
    sysnext = copy(sys)
    
    for t = 1 : nsteps
        Parameters = (
                      ρnext = sysnext.ρ,
                      unext = sysnext.u,
                      vnext = sysnext.v,
                      Pnext = sysnext.P,
                      snext = sysnext.s,
                      ρwork = syswork.ρ,
                      uwork = syswork.u,
                      vwork = syswork.v,
                      Δt = Δt,
                      Δx = Δx,
                      Δy = Δy,
                      Pin = Pin,
                      Pout = Pout,
                      φ = φ,
                      K = K,
                      μ = μ
                     )
        update!(; Parameters...)

        ## Swap next and work and continue iteration
        sysnext, syswork = syswork, sysnext
    end

    ## If in the end syswork is not the original sys,
    ## copy the most recent data into sys
    if syswork !== sys
        sys = syswork
    end
end

function plot(u::Array{T, 3}, v::Array{T, 3},
        P::Array{T, 2}) where T<:AbstractFloat
    nx, ny = size(u[1, :, :])

    fig = PyPlot.figure(figsize=(10, 10))
    ax = PyPlot.axes()
    ax.set_xlabel("x")
    ax.set_ylabel("y")
    
    rgx = range(0, 2, length=nx)
    rgy = range(0, 2, length=ny)
    x = [rgx;]'
    y = [rgy;]'
    X = repeat([rgx;]', length(x))
    Y = repeat([rgy;],1, length(y))
    
    ## Velocity vector field
    ## scale = 100.0
    quiver(x, y, u[1, :, :]', v[1, :, :]', color="r")
    quiver(x, y, u[2, :, :]', v[2, :, :]', color="b")
    
    ## Pressure contour map
    pos = ax.contourf(X, Y, P', alpha=0.5,
        cmap=matplotlib.cm.viridis)
    fig.colorbar(pos, ax=ax)
    cp = contour(X, Y, P', cmap=matplotlib.cm.viridis)

    PyPlot.title("2 Phase Filtration: Liquid and Ideal Gas")
    
    savefig("img/2phase-filtration.png", dpi=200)
    savefig("img/2phase-filtration.svg")
end

let
    duration = 2000
    Δt = 0.001
    nsteps = round(Int64, duration / Δt)
    nsteps = 100
    
    ## Space grid [0, 2] × [0, 2]
    Δx = 0.05
    Δy = Δx
    nx = round(Int64, 2 / Δx)
    ny = round(Int64, 2 / Δy)
    
    ## Porosity
    φ = 0.7
    
    ## Specific permeability
    K = 1e-12
    
    ## Dynamic viscocity (for air)
    μ = 18e-6
    
    ## Pressures at top and bottom, and initial pressure
    Pin = 1e6
    Pout = 1e5
    P0 = Pout

    ## Initial saturation
    s0 = 0.75

    coeff = 8.314 * 298 / 0.029

    u = zeros(2, nx, ny)
    v = zeros(2, nx, ny)
    P = fill(P0, nx, ny)
    boundaryPressure!(P, Pin, Pout)
    s = fill(s0, nx, ny)
    ρ = fill(P0 / coeff, 2, nx, ny)
    @. ρ[2, :, :] = densityofLiquid(P, s)

    sys = System(u, v, ρ, P, s)

    Parameters = (
                  Δt = Δt,
                  nsteps = nsteps,
                  Δx = Δx,
                  Δy = Δy,
                  φ = φ,
                  K = K,
                  μ = μ,
                  Pin = Pin,
                  Pout = Pout,
                  sys = sys
                 )

    filtration!(; Parameters...)
    plot(sys.u, sys.v, sys.P)
    writedlm("pressure.txt", sys.P, ' ')
    writedlm("u1.txt", sys.u[1, :, :], ' ')
    writedlm("u2.txt", sys.u[2, :, :], ' ')
    writedlm("density1.txt", sys.ρ[1, :, :], ' ')
    writedlm("density2.txt", sys.ρ[2, :, :], ' ')
    writedlm("s.txt", sys.s, ' ')
end
