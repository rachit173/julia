# This file is a part of Julia. License is MIT: https://julialang.org/license

module Random

using Base.dSFMT
using Base.GMP: Limb, MPZ
import Base: copymutable, copy, copy!, ==, hash

export srand,
       rand, rand!,
       randn, randn!,
       randexp, randexp!,
       bitrand,
       randstring,
       randsubseq, randsubseq!,
       shuffle, shuffle!,
       randperm, randperm!,
       randcycle, randcycle!,
       AbstractRNG, MersenneTwister, RandomDevice,
       GLOBAL_RNG, randjump,
       Distributions, Uniform, Sampler


## general definitions

abstract type AbstractRNG end

### Distributions

abstract type Distribution{T} end

Base.eltype(::Type{Distribution{T}}) where {T} = T

struct Distribution0{T} <: Distribution{T} end

Distribution(::Type{T}) where {T} = Distribution0{T}()

struct Distribution1{T,X} <: Distribution{T}
    x::X
end

Distribution(::Type{T}, x::X) where {T,X} = Distribution1{T,X}(x)
Distribution(::Type{T}, ::Type{X}) where {T,X} = Distribution1{T,Type{X}}(X)

struct Distribution2{T,X,Y} <: Distribution{T}
    x::X
    y::Y
end

Distribution(::Type{T}, x::X, y::Y) where {T,X,Y} = Distribution2{deduce_type(T,X,Y),X,Y}(x, y)
Distribution(::Type{T}, ::Type{X}, y::Y) where {T,X,Y} = Distribution2{deduce_type(T,X,Y),Type{X},Y}(X, y)
Distribution(::Type{T}, x::X, ::Type{Y}) where {T,X,Y} = Distribution2{deduce_type(T,X,Y),X,Type{Y}}(x, Y)
Distribution(::Type{T}, ::Type{X}, ::Type{Y}) where {T,X,Y} = Distribution2{deduce_type(T,X,Y),Type{X},Type{Y}}(X, Y)

deduce_type(::Type{T}, ::Type{X}, ::Type{Y}) where {T,X,Y} = _deduce_type(T, Val(isconcrete(T)), eltype(X), eltype(Y))
deduce_type(::Type{T}, ::Type{X}) where {T,X} = _deduce_type(T, Val(isconcrete(T)), eltype(X))

_deduce_type(::Type{T}, ::Val{true},  ::Type{X}, ::Type{Y}) where {T,X,Y} = T
_deduce_type(::Type{T}, ::Val{false}, ::Type{X}, ::Type{Y}) where {T,X,Y} = deduce_type(T{X}, Y)

_deduce_type(::Type{T}, ::Val{true},  ::Type{X}) where {T,X} = T
_deduce_type(::Type{T}, ::Val{false}, ::Type{X}) where {T,X} = T{X}


#### Uniform

abstract type Uniform{T} <: Distribution{T} end

#### Normal & Exponential

struct Normal{T} <: Distribution{T} end

Normal(::Type{T}=Float64) where {T} = Normal{T}()

struct Exponential{T} <: Distribution{T} end

Exponential(::Type{T}=Float64) where {T<:AbstractFloat} = Exponential{T}()

### floats

abstract type FloatInterval{T<:AbstractFloat} <: Uniform{T} end

struct CloseOpen{  T<:AbstractFloat} <: FloatInterval{T} end # interval [0,1)
struct Close1Open2{T<:AbstractFloat} <: FloatInterval{T} end # interval [1,2)

const FloatInterval_64 = FloatInterval{Float64}
const CloseOpen_64     = CloseOpen{Float64}
const Close1Open2_64   = Close1Open2{Float64}

CloseOpen(  ::Type{T}=Float64) where {T<:AbstractFloat} = CloseOpen{T}()
Close1Open2(::Type{T}=Float64) where {T<:AbstractFloat} = Close1Open2{T}()

Base.eltype(::Type{<:FloatInterval{T}}) where {T<:AbstractFloat} = T

const BitFloatType = Union{Type{Float16},Type{Float32},Type{Float64}}

### Sampler

abstract type Sampler{E} end

Base.eltype(::Sampler{E}) where {E} = E

# temporarily for BaseBenchmarks
RangeGenerator(x) = Sampler(GLOBAL_RNG, x)

# In some cases, when only 1 random value is to be generated,
# the optimal sampler can be different than if multiple values
# have to be generated. Hence a `Repetition` parameter is used
# to choose the best one depending on the need.
const Repetition = Union{Val{1},Val{Inf}}

# these default fall-back for all RNGs would be nice,
# but generate difficult-to-solve ambiguities
# Sampler(::AbstractRNG, X, ::Val{Inf}) = Sampler(X)
# Sampler(::AbstractRNG, ::Type{X}, ::Val{Inf}) where {X} = Sampler(X)

Sampler(rng::AbstractRNG, sp::Sampler, ::Repetition) =
    throw(ArgumentError("Sampler for this object is not defined"))

# default shortcut for the general case
Sampler(rng::AbstractRNG, X) = Sampler(rng, X, Val(Inf))
Sampler(rng::AbstractRNG, ::Type{X}) where {X} = Sampler(rng, X, Val(Inf))

#### pre-defined useful Sampler subtypes

# default fall-back for types
struct SamplerType{T} <: Sampler{T} end

Sampler(::AbstractRNG, ::Type{T}, ::Repetition) where {T} = SamplerType{T}()

Base.getindex(::SamplerType{T}) where {T} = T

# default fall-back for values
struct SamplerTrivial{T,E} <: Sampler{E}
    self::T
end

SamplerTrivial(x::T) where {T} = SamplerTrivial{T,eltype(T)}(x)

Sampler(::AbstractRNG, x, ::Repetition) = SamplerTrivial(x)

Base.getindex(sp::SamplerTrivial) = sp.self

# simple sampler carrying data (which can be anything)
struct SamplerSimple{T,S,E} <: Sampler{E}
    self::T
    data::S
end

SamplerSimple(x::T, data::S) where {T,S} = SamplerSimple{T,S,eltype(T)}(x, data)

Base.getindex(sp::SamplerSimple) = sp.self

# simple sampler carrying a (type) tag T and data
struct SamplerTag{T,S,E} <: Sampler{E}
    data::S
    SamplerTag{T}(s::S) where {T,S} = new{T,S,eltype(T)}(s)
end

# a dummy container type to take advangage of SamplerTag constructor

struct Cont{T} end

Base.eltype(::Type{Cont{T}}) where {T} = T

### machinery for generation with Sampler

# This describes how to generate random scalars or arrays, by generating a Sampler
# and calling rand on it (which should be defined in "generation.jl").
# NOTE: this section could be moved into a separate file when more containers are supported.

#### scalars

rand(rng::AbstractRNG, X) = rand(rng, Sampler(rng, X, Val(1)))
rand(rng::AbstractRNG=GLOBAL_RNG, ::Type{X}=Float64) where {X} =
    rand(rng, Sampler(rng, X, Val(1)))

rand(X) = rand(GLOBAL_RNG, X)
rand(::Type{X}) where {X} = rand(GLOBAL_RNG, X)

#### arrays

rand!(A::AbstractArray{T}, X) where {T} = rand!(GLOBAL_RNG, A, X)
rand!(A::AbstractArray{T}, ::Type{X}=T) where {T,X} = rand!(GLOBAL_RNG, A, X)

rand!(rng::AbstractRNG, A::AbstractArray{T}, X) where {T} = rand!(rng, A, Sampler(rng, X))
rand!(rng::AbstractRNG, A::AbstractArray{T}, ::Type{X}=T) where {T,X} = rand!(rng, A, Sampler(rng, X))

function rand!(rng::AbstractRNG, A::AbstractArray{T}, sp::Sampler) where T
    for i in eachindex(A)
        @inbounds A[i] = rand(rng, sp)
    end
    A
end

rand(r::AbstractRNG, dims::Dims)       = rand(r, Float64, dims)
rand(                dims::Dims)       = rand(GLOBAL_RNG, dims)
rand(r::AbstractRNG, dims::Integer...) = rand(r, Dims(dims))
rand(                dims::Integer...) = rand(Dims(dims))

rand(r::AbstractRNG, X, dims::Dims)  = rand!(r, Array{eltype(X)}(uninitialized, dims), X)
rand(                X, dims::Dims)  = rand(GLOBAL_RNG, X, dims)

rand(r::AbstractRNG, X, d::Integer, dims::Integer...) = rand(r, X, Dims((d, dims...)))
rand(                X, d::Integer, dims::Integer...) = rand(X, Dims((d, dims...)))
# note: the above methods would trigger an ambiguity warning if d was not separated out:
# rand(r, ()) would match both this method and rand(r, dims::Dims)
# moreover, a call like rand(r, NotImplementedType()) would be an infinite loop

rand(r::AbstractRNG, ::Type{X}, dims::Dims) where {X} = rand!(r, Array{eltype(X)}(uninitialized, dims), X)
rand(                ::Type{X}, dims::Dims) where {X} = rand(GLOBAL_RNG, X, dims)

rand(r::AbstractRNG, ::Type{X}, d::Integer, dims::Integer...) where {X} = rand(r, X, Dims((d, dims...)))
rand(                ::Type{X}, d::Integer, dims::Integer...) where {X} = rand(X, Dims((d, dims...)))


#### dicts

rand!(A::Associative{K,V}, dist::Distribution{Pair} = Distribution(Pair, K, V)) where {K,V} =
    rand!(GLOBAL_RNG, A, dist)

rand!(rng::AbstractRNG, A::Associative{K,V},
      dist::Distribution{Pair} = Distribution(Pair, K, V)) where {K,V} =
          rand!(GLOBAL_RNG, A, Sampler(rng, dist))

function _rand!(rng::AbstractRNG, A::Associative{K,V}, n::Integer, sp::Sampler) where {K,V}
    empty!(A)
    while length(A) < n
        push!(A, rand(rng, sp))
    end
    A
end

rand!(rng::AbstractRNG, A::Associative{K,V}, sp::Sampler) where {K,V} = _rand!(rng, A, length(A), sp)

# TODO: what to do when e.g. T==Dict ? we could infer the K,V types from u, instead
# of creating Dict(), i.e. Dict{Any,Any}()
rand(rng::AbstractRNG, dist::Distribution{<:Pair}, ::Type{T}, n::Integer) where {T<:Associative} =
    _rand!(rng, deduce_type(T, eltype(dist).parameters...)(), n, Sampler(rng, dist))

rand(u::Distribution{<:Pair}, ::Type{T}, n::Integer) where {T<:Associative} = rand(GLOBAL_RNG, u, T, n)


#### sets

rand!(A::AbstractSet{T}, X) where {T} = rand!(GLOBAL_RNG, A, X)
rand!(A::AbstractSet{T}, ::Type{X}=T) where {T,X} = rand!(GLOBAL_RNG, A, X)

rand!(rng::AbstractRNG, A::AbstractSet, X) = rand!(rng, A, Sampler(rng, X))
rand!(rng::AbstractRNG, A::AbstractSet{T}, ::Type{X}=T) where {T,X} = rand!(rng, A, Sampler(rng, X))

_rand!(rng::AbstractRNG, A::AbstractSet, n::Integer, X) = _rand!(rng, A, n, Sampler(rng, X))

function _rand!(rng::AbstractRNG, A::AbstractSet{T}, n::Integer, sp::Sampler) where T
    empty!(A)
    while length(A) < n
        push!(A, rand(rng, sp))
    end
    A
end

rand!(rng::AbstractRNG, A::AbstractSet, sp::Sampler) = _rand!(rng, A, length(A), sp)


rand(r::AbstractRNG, ::Type{T}, n::Integer) where {T<:AbstractSet} = rand(r, Float64, T, n)
rand(                ::Type{T}, n::Integer) where {T<:AbstractSet} = rand(GLOBAL_RNG, T, n)

rand(r::AbstractRNG, X, ::Type{T}, n::Integer) where {T<:AbstractSet} = _rand!(r, deduce_type(T, eltype(X))(), n, X)
rand(                X, ::Type{T}, n::Integer) where {T<:AbstractSet} = rand(GLOBAL_RNG, X, T, n)

rand(r::AbstractRNG, ::Type{X}, ::Type{T}, n::Integer) where {X,T<:AbstractSet} = _rand!(r, deduce_type(T, X)(), n, X)
rand(                ::Type{X}, ::Type{T}, n::Integer) where {X,T<:AbstractSet} = rand(GLOBAL_RNG, X, T, n)


#### sparse vectors & matrices

# sprand([rng],[type],m,[n],p::AbstractFloat,[rfn])

rand(r::AbstractRNG, p::AbstractFloat, m::Integer) = sprand(r, m, p)
rand(                p::AbstractFloat, m::Integer) = sprand(GLOBAL_RNG, m, p)
rand(r::AbstractRNG, p::AbstractFloat, m::Integer, n::Integer) = sprand(r, m, n, p)
rand(                p::AbstractFloat, m::Integer, n::Integer) = sprand(GLOBAL_RNG, m, n, p)

rand(r::AbstractRNG, X::Sampler, p::AbstractFloat, m::Integer) =
    sprand(r, m, p, (r, n)->rand(r, X, n))

rand(r::AbstractRNG, X, p::AbstractFloat, m::Integer) =
    rand(r, Sampler(r, X), p, m)

rand(r::AbstractRNG, ::Type{X}, p::AbstractFloat, m::Integer) where {X} =
    rand(r, Sampler(r, X), p, m)

rand(X, p::AbstractFloat, m::Integer) = rand(GLOBAL_RNG, X, p, m)

rand(r::AbstractRNG, X::Sampler, p::AbstractFloat, m::Integer, n::Integer) =
    sprand(r, m, n, p, (r, n)->rand(r, sp, n), eltype(X))

rand(r::AbstractRNG, X, p::AbstractFloat, m::Integer, n::Integer) =
    rand(r, Sampler(r, X), p, m, n)

rand(r::AbstractRNG, ::Type{X}, p::AbstractFloat, m::Integer, n::Integer) where {X} =
    rand(r, Sampler(r, X), p, m, n)

rand(X, p::AbstractFloat, m::Integer, n::Integer) = rand(GLOBAL_RNG, X, p, m, n)

#### String

let b = UInt8['0':'9';'A':'Z';'a':'z']
    global rand
    rand(rng::AbstractRNG, chars, ::Type{String}, n::Integer=8) = String(rand(rng, chars, n))
    rand(                  chars, ::Type{String}, n::Integer=8) = rand(GLOBAL_RNG, chars, String, n)
    rand(rng::AbstractRNG, ::Type{String}, n::Integer=8) = rand(rng, b, String, n)
    rand(                  ::Type{String}, n::Integer=8) = rand(GLOBAL_RNG, b, String, n)
end


#### BitArray

rand(r::AbstractRNG, ::Type{BitArray}, dims::Dims)   = rand!(r, BitArray(uninitialized, dims))
rand(r::AbstractRNG, ::Type{BitArray}, dims::Integer...) = rand!(r, BitArray(uninitialized, convert(Dims, dims)))

rand(::Type{BitArray}, dims::Dims)   = rand!(BitArray(uninitialized, dims))
rand(::Type{BitArray}, dims::Integer...) = rand!(BitArray(uninitialized, convert(Dims, dims)))


## __init__ & include

function __init__()
    try
        srand()
    catch ex
        Base.showerror_nostdio(ex,
            "WARNING: Error during initialization of module Random")
    end
end

include("RNGs.jl")
include("generation.jl")
include("normal.jl")
include("misc.jl")


## rand & rand! & srand docstrings

"""
    rand([rng=GLOBAL_RNG], [S], [dims...])

Pick a random element or array of random elements from the set of values specified by `S`;
`S` can be

* an indexable collection (for example `1:n` or `['x','y','z']`),
* an `Associative` or `AbstractSet` object,
* a string (considered as a collection of characters), or
* a type: the set of values to pick from is then equivalent to `typemin(S):typemax(S)` for
  integers (this is not applicable to [`BigInt`](@ref)), and to ``[0, 1)`` for floating
  point numbers;

`S` defaults to [`Float64`](@ref).

# Examples
```julia-repl
julia> rand(Int, 2)
2-element Array{Int64,1}:
 1339893410598768192
 1575814717733606317

julia> rand(MersenneTwister(0), Dict(1=>2, 3=>4))
1=>2
```

!!! note
    The complexity of `rand(rng, s::Union{Associative,AbstractSet})`
    is linear in the length of `s`, unless an optimized method with
    constant complexity is available, which is the case for `Dict`,
    `Set` and `BitSet`. For more than a few calls, use `rand(rng,
    collect(s))` instead, or either `rand(rng, Dict(s))` or `rand(rng,
    Set(s))` as appropriate.
"""
rand

"""
    rand!([rng=GLOBAL_RNG], A, [S=eltype(A)])

Populate the array `A` with random values. If `S` is specified
(`S` can be a type or a collection, cf. [`rand`](@ref) for details),
the values are picked randomly from `S`.
This is equivalent to `copy!(A, rand(rng, S, size(A)))`
but without allocating a new array.

# Examples
```jldoctest
julia> rng = MersenneTwister(1234);

julia> rand!(rng, zeros(5))
5-element Array{Float64,1}:
 0.5908446386657102
 0.7667970365022592
 0.5662374165061859
 0.4600853424625171
 0.7940257103317943
```
"""
rand!

"""
    srand([rng=GLOBAL_RNG], seed) -> rng
    srand([rng=GLOBAL_RNG]) -> rng

Reseed the random number generator: `rng` will give a reproducible
sequence of numbers if and only if a `seed` is provided. Some RNGs
don't accept a seed, like `RandomDevice`.
After the call to `srand`, `rng` is equivalent to a newly created
object initialized with the same seed.

# Examples
```julia-repl
julia> srand(1234);

julia> x1 = rand(2)
2-element Array{Float64,1}:
 0.590845
 0.766797

julia> srand(1234);

julia> x2 = rand(2)
2-element Array{Float64,1}:
 0.590845
 0.766797

julia> x1 == x2
true

julia> rng = MersenneTwister(1234); rand(rng, 2) == x1
true

julia> MersenneTwister(1) == srand(rng, 1)
true

julia> rand(srand(rng), Bool) # not reproducible
true

julia> rand(srand(rng), Bool)
false

julia> rand(MersenneTwister(), Bool) # not reproducible either
true
```
"""
srand(rng::AbstractRNG, ::Void) = srand(rng)

end # module
