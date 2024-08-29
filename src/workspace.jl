
function construct_workspace end

##########
# Simple #
##########

"""
    construct_workspace(mp::SimpleIntervalMarkovProcess)

Construct a workspace for computing the Bellman update, given a value function.
If the Bellman update is used in a hot-loop, it is more efficient to use this function
to preallocate the workspace and reuse across iterations.

The workspace type is determined by the type and size of the transition probability matrix,
as well as the number of threads available.
"""
construct_workspace(mp::SimpleIntervalMarkovProcess) =
    construct_workspace(transition_prob(mp, 1), max_actions(mp))

"""
    construct_workspace(prob::IntervalProbabilities)

Construct a workspace for computing the Bellman update, given a value function.
If the Bellman update is used in a hot-loop, it is more efficient to use this function
to preallocate the workspace and reuse across iterations.

The workspace type is determined by the type and size of the transition probability matrix,
as well as the number of threads available.
"""
construct_workspace(prob::IntervalProbabilities, max_actions = 1) =
    construct_workspace(gap(prob), max_actions)

# Dense
struct DenseWorkspace{T <: Real}
    permutation::Vector{Int32}
    actions::Vector{T}
end

function DenseWorkspace(p::AbstractMatrix{T}, max_actions) where {T <: Real}
    n = size(p, 1)
    perm = Vector{Int32}(undef, n)
    actions = Vector{T}(undef, max_actions)
    return DenseWorkspace(perm, actions)
end

struct ThreadedDenseWorkspace{T <: Real}
    permutation::Vector{Int32}
    actions::Vector{Vector{T}}
end

function ThreadedDenseWorkspace(p::AbstractMatrix{T}, max_actions) where {T <: Real}
    n = size(p, 1)
    perm = Vector{Int32}(undef, n)
    actions = [Vector{T}(undef, max_actions) for _ in 1:Threads.nthreads()]
    return ThreadedDenseWorkspace(perm, actions)
end

function construct_workspace(p::AbstractMatrix, max_actions; threshold = 10)
    if Threads.nthreads() == 1 || size(p, 2) <= threshold
        return DenseWorkspace(p, max_actions)
    else
        return ThreadedDenseWorkspace(p, max_actions)
    end
end

# Sparse
struct SparseWorkspace{T <: Real}
    values_gaps::Vector{Tuple{T, T}}
    actions::Vector{T}
end

function SparseWorkspace(p::AbstractSparseMatrix{T}, max_actions) where {T <: Real}
    max_nonzeros = maximum(map(nnz, eachcol(p)))
    values_gaps = Vector{Tuple{T, T}}(undef, max_nonzeros)
    actions = Vector{T}(undef, max_actions)
    return SparseWorkspace(values_gaps, actions)
end

struct ThreadedSparseWorkspace{T}
    thread_workspaces::Vector{SparseWorkspace{T}}
end

function ThreadedSparseWorkspace(p::AbstractSparseMatrix, max_actions)
    nthreads = Threads.nthreads()
    thread_workspaces = [SparseWorkspace(p, max_actions) for _ in 1:nthreads]
    return ThreadedSparseWorkspace(thread_workspaces)
end

function construct_workspace(p::AbstractSparseMatrix, max_actions; threshold = 10)
    if Threads.nthreads() == 1 || size(p, 2) <= threshold
        return SparseWorkspace(p, max_actions)
    else
        return ThreadedSparseWorkspace(p, max_actions)
    end
end

# Product
struct DenseOrthogonalWorkspace{N, T <: Real}
    expectation_cache::NTuple{N, Vector{T}}
    permutation::Vector{Int32}
    actions::Vector{T}
    state_index::Int32
end

function DenseOrthogonalWorkspace(p::OrthogonalIntervalProbabilities{N, <:IntervalProbabilities{R}}, max_actions) where {N, R}
    pns = num_target(p)
    nmax = maximum(pns)

    perm = Vector{Int32}(undef, nmax)
    expectation_cache = NTuple(Vector{R}(undef, n) for n in pns)
    actions = Vector{R}(undef, max_actions)
    return DenseOrthogonalWorkspace(expectation_cache, perm, actions, one(Int32))
end

struct ThreadedDenseOrthogonalWorkspace{N, T}
    thread_workspaces::Vector{DenseOrthogonalWorkspace{N, T}}
end

function ThreadedDenseOrthogonalWorkspace(p::OrthogonalIntervalProbabilities, max_actions)
    nthreads = Threads.nthreads()
    thread_workspaces = [DenseOrthogonalWorkspace(p, max_actions) for _ in 1:nthreads]
    return ThreadedDenseOrthogonalWorkspace(thread_workspaces)
end

function construct_workspace(p::OrthogonalIntervalProbabilities, max_actions)
    if Threads.nthreads() == 1
        return DenseOrthogonalWorkspace(p, max_actions)
    else
        return ThreadedDenseOrthogonalWorkspace(p, max_actions)
    end
end

#############
# Composite #
#############

"""
    construct_workspace(mp::ParallelProduct)

Construct a workspace for computing the Bellman update, given a value function.
If the Bellman update is used in a hot-loop, it is more efficient to use this function
to preallocate the workspace and reuse across iterations.

The workspace composite hierachy is determined by process structure and the type of transition probability matrices,
as well as the number of threads available.
"""
construct_workspace(mp::ParallelProduct) = _construct_workspace(mp)

abstract type CompositeWorkspace end

# Dense - simple
struct DenseParallelWorkspace{T <: Real} <: CompositeWorkspace
    permutation::Vector{Int32}
    actions::Vector{T}
    state_index::Int32
end

function DenseParallelWorkspace(
    ::AbstractMatrix{T},
    ntarget,
    max_actions,
    state_index,
) where {T <: Real}
    perm = Vector{Int32}(undef, ntarget)
    actions = Vector{T}(undef, max_actions)
    return DenseParallelWorkspace(perm, actions, state_index)
end

struct ThreadedDenseParallelWorkspace{T <: Real} <: CompositeWorkspace
    thread_workspaces::Vector{DenseParallelWorkspace{T}}
    state_index::Int32
end

function ThreadedDenseParallelWorkspace(
    p::AbstractMatrix{T},
    ntarget,
    max_actions,
    state_index,
) where {T <: Real}
    thread_workspaces = [
        DenseParallelWorkspace(p, ntarget, max_actions, state_index) for
        _ in 1:Threads.nthreads()
    ]
    return ThreadedDenseParallelWorkspace(thread_workspaces, state_index)
end

function _construct_workspace(
    p::AbstractMatrix,
    mp::SimpleIntervalMarkovProcess,
    state_index,
)
    ntarget = num_states(mp)
    mactions = max_actions(mp)

    if Threads.nthreads() == 1
        return DenseParallelWorkspace(p, ntarget, mactions, state_index),
        state_index + one(Int32)
    else
        return ThreadedDenseParallelWorkspace(p, ntarget, mactions, state_index),
        state_index + one(Int32)
    end
end

# Sparse - simple
struct SparseProductWorkspace{T <: Real} <: CompositeWorkspace
    values_gaps::Vector{Tuple{T, T}}
    actions::Vector{T}
    state_index::Int32
end

function SparseProductWorkspace(
    ::AbstractSparseMatrix{T},
    ntarget,
    max_actions,
    state_index,
) where {T <: Real}
    values_gaps = Vector{Tuple{T, T}}(undef, ntarget)
    actions = Vector{T}(undef, max_actions)
    return SparseProductWorkspace(values_gaps, actions, state_index)
end

struct ThreadedSparseProductWorkspace{T} <: CompositeWorkspace
    thread_workspaces::Vector{SparseProductWorkspace{T}}
    state_index::Int32
end

function ThreadedSparseProductWorkspace(
    p::AbstractSparseMatrix,
    ntarget,
    max_actions,
    state_index,
)
    nthreads = Threads.nthreads()
    thread_workspaces =
        [SparseProductWorkspace(p, ntarget, max_actions, state_index) for _ in 1:nthreads]
    return ThreadedSparseProductWorkspace(thread_workspaces, state_index)
end

function _construct_workspace(
    p::AbstractSparseMatrix,
    mp::SimpleIntervalMarkovProcess,
    state_index,
)
    ntarget = num_states(mp)
    mactions = max_actions(mp)

    if Threads.nthreads() == 1
        return SparseProductWorkspace(p, ntarget, mactions, state_index),
        state_index + one(Int32)
    else
        return ThreadedSparseProductWorkspace(p, ntarget, mactions, state_index),
        state_index + one(Int32)
    end
end

# Parallel product workspace
struct ParallelProductWorkspace <: CompositeWorkspace
    process_workspaces::Vector{CompositeWorkspace}
end
orthogonal_workspaces(workspace::ParallelProductWorkspace) = workspace.process_workspaces

function _construct_workspace(mp::ParallelProduct)
    workspace, _ = _construct_workspace(mp, one(Int32))
    return workspace
end

function _construct_workspace(mp::ParallelProduct, state_index)
    workspaces = CompositeWorkspace[]
    sizehint!(workspaces, length(orthogonal_processes(mp)))

    for orthogonal_process in orthogonal_processes(mp)
        workspace, state_index = _construct_workspace(orthogonal_process, state_index)
        push!(workspaces, workspace)
    end

    return ParallelProductWorkspace(workspaces), state_index
end

_construct_workspace(mp::SimpleIntervalMarkovProcess, state_index) =
    _construct_workspace(gap(transition_prob(mp, 1)), mp, state_index)
