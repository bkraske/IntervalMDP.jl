# Default ordering type
construct_ordering(p) = construct_ordering(Int32, p)

abstract type AbstractStateOrdering{T} end

##################
# Dense ordering #
##################
struct DenseOrdering{T <: Integer, VT <: AbstractVector{T}} <: AbstractStateOrdering{T}
    perm::VT
end

function DenseOrdering{T}(n) where {T}
    return DenseOrdering(collect(UnitRange{T}(1, n)))
end

# Permutations are shared for all states
perm(order::DenseOrdering, state) = order.perm

# Vector of dense vectors
function construct_ordering(T, p::VV) where {VV <: AbstractVector{<:AbstractVector}}
    # Assume that each vector corresponds to a start state
    n = length(first(p))
    return DenseOrdering{T}(n)
end

# Dense matrix
function construct_ordering(T, p::AbstractMatrix)
    # Assume that input/start state is on the columns and output/target state is on the rows
    n = size(p, 1)
    return DenseOrdering{T}(n)
end

function sort_states!(order::DenseOrdering, V; max = true)
    sortperm!(order.perm, V; rev = max)  # rev=true for maximization

    return order
end

###################
# Sparse ordering #
###################
mutable struct PermutationSubset{T <: Integer, VT <: AbstractVector{T}}
    ptr::T
    items::VT
end
Base.length(subset::PermutationSubset) = length(subset.items)

struct SparseOrdering{T <: Integer, VT <: AbstractVector{T}} <: AbstractStateOrdering{T}
    perm::VT
    state_to_subset::Vector{Vector{Tuple{T, T}}}
    subsets::Vector{PermutationSubset{T, VT}}
end

# Permutations are specific to each state
perm(order::SparseOrdering, state) = order.subsets[state].items

function Base.empty!(subset::PermutationSubset{T, VT}) where {T, VT}
    return subset.ptr = 1
end

function Base.push!(subset::PermutationSubset{T, VT}, item::T) where {T, VT}
    @inbounds subset.items[subset.ptr] = item
    return subset.ptr += 1
end

function reset_subsets!(subsets::Vector{PermutationSubset{T, VT}}) where {T, VT}
    @inbounds for subset in subsets
        empty!(subset)
    end
end

function populate_subsets!(order::SparseOrdering{T, VT}) where {T, VT}
    reset_subsets!(order.subsets)

    @inbounds for i in order.perm
        @inbounds for (j, sparse_ind) in order.state_to_subset[i]
            push!(order.subsets[j], sparse_ind)
        end
    end

    return order
end

function sort_states!(order::SparseOrdering{T, VT}, V::VR; max = true) where {T, VT, VR}
    sortperm!(order.perm, V; rev = max)  # rev=true for maximization
    populate_subsets!(order)

    return order
end
