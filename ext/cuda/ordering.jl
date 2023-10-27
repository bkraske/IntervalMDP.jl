
struct CuSparseOrdering{T} <: AbstractStateOrdering{T}
    subsets::CuVectorOfVector{T, T}
    rowvals::CuVector{T}
end
# TODO: Add adaptor from SparseOrdering to CuSparseOrdering

function CUDA.unsafe_free!(o::CuSparseOrdering)
    unsafe_free!(o.subsets)
    unsafe_free!(o.rowvals)
    return
end

function Adapt.adapt_structure(to::CUDA.Adaptor, o::CuSparseOrdering)
    return CuSparseDeviceOrdering(adapt(to, o.subsets), adapt(to, o.rowvals))
end

struct CuSparseDeviceOrdering{T, A} <: AbstractStateOrdering{T}
    subsets::CuDeviceVectorOfVector{T, T, A}
    rowvals::CuDeviceVector{T, A}
end

# Permutations are specific to each state
IMDP.perm(order::CuSparseOrdering, state) = order.subsets[state]
IMDP.perm(order::CuSparseDeviceOrdering, state) = order.subsets[state]

function IMDP.sort_states!(order::CuSparseOrdering, V; max = true)
    # populate_value_subsets!(order, V)
    # initialize_perm_subsets!(order)
    sort_subsets!(order, V; max = max)

    return order
end

function populate_value_subsets!(order::CuSparseOrdering, V)
    n = length(order.rowvals)

    threads = 1024
    blocks = ceil(Int32, n / threads)

    @cuda blocks = blocks threads = threads populate_value_subsets_kernel!(order, V)

    return order
end

function populate_value_subsets_kernel!(
    order::CuSparseDeviceOrdering{Ti, A},
    V::CuDeviceVector{Tv, A},
) where {Ti, Tv, A}
    thread_id = (blockIdx().x - T(1)) * blockDim().x + threadIdx().x
    n = length(order.rowvals)

    if thread_id <= n
        value_id = order.rowvals[thread_id]
        order.subsets.value_subsets.val[thread_id] = V[value_id]
    end

    return nothing
end

function initialize_perm_subsets!(order::CuSparseOrdering)
    n = length(order.subsets) * warpsize(device())

    threads = 256
    blocks = ceil(Int32, n / threads)

    @cuda blocks = blocks threads = threads initialize_perm_subsets_kernel!(order)

    return order
end

function initialize_perm_subsets_kernel!(order::CuSparseDeviceOrdering{T, A}) where {T, A}
    assume(warpsize() == 32)

    thread_id = (blockIdx().x - T(1)) * blockDim().x + threadIdx().x
    warp_id, lane = fldmod1(thread_id, warpsize())

    n = length(order.subsets)

    if warp_id <= n
        subset = order.subsets[warp_id]

        i = T(lane)
        while i <= length(subset)
            subset.perm_subset[i] = i
            i += T(warpsize())
        end
    end

    return nothing
end

function sort_subsets!(
    order::CuSparseOrdering{Ti},
    V::CuVector{Tv};
    max = true,
) where {Ti, Tv}
    n = length(order.subsets)

    ml = maxlength(order.subsets)
    ml_ceil = nextpow(Ti(2), ml)

    threads_per_subset = min(256, ispow2(ml) ? ml ÷ Ti(2) : prevpow(Ti(2), ml))

    threads = threads_per_subset
    blocks = min(65536, n)
    shmem = ml_ceil * (sizeof(Ti) + sizeof(Tv))

    @cuda blocks = blocks threads = threads shmem = shmem sort_subsets_kernel!(
        order,
        V,
        max,
    )

    return order
end

function sort_subsets_kernel!(
    order::CuSparseDeviceOrdering{Ti, A},
    V::CuDeviceVector{Tv, A},
    max::Bool,
) where {Ti, Tv, A}
    ml = maxlength(order.subsets)
    ml_ceil = nextpow(Ti(2), ml)

    value = CuDynamicSharedArray(Tv, ml_ceil)
    perm = CuDynamicSharedArray(Ti, ml_ceil, ml_ceil * sizeof(Tv))

    s = blockIdx().x
    while s <= length(order.subsets)  # Grid-stride loop
        subset = order.subsets[s]

        initialize_sorting_shared_memory!(order, subset, V, value, perm)
        bitonic_sort!(subset, value, perm)
        copy_perm_to_global!(subset, perm)

        s += gridDim().x
    end

    return nothing
end

@inline function initialize_sorting_shared_memory!(
    order::CuSparseDeviceOrdering{Ti, A},
    subset,
    V,
    value,
    perm,
) where {Ti, A}
    # Copy into shared memory
    i = threadIdx().x
    while i <= length(subset)
        value_id = order.rowvals[subset.offset + i - one(Ti)]
        value[i] = V[value_id]
        perm[i] = i
        i += blockDim().x
    end

    # Need to synchronize to make sure all agree on the shared memory
    return sync_threads()
end

@inline function bitonic_sort!(
    subset::CuDeviceVectorInstance{Ti, Ti, A},
    value,
    perm,
) where {Ti, A}
    #### Sort the shared memory with bitonic sort
    subset_length = length(subset)
    half_subset_length =
        ispow2(subset_length) ? subset_length ÷ Ti(2) : prevpow(Ti(2), subset_length)

    # Major step
    k = Ti(2)
    while k <= half_subset_length

        # Minor step - Merge
        k_half = k ÷ Ti(2)
        i = threadIdx().x - Ti(1)
        while i < subset_length
            i_block, i_lane = fld(i, k_half), mod(i, k_half)
            i_concrete = i_block * k + i_lane
            l = (i_block + one(Ti)) * k - i_lane

            if l < subset_length # Ensure only one thread in each pair does the swap
                i1 = i_concrete + Ti(1)
                l1 = l + Ti(1)

                if (value[i1] > value[l1]) != max
                    perm[i1], perm[l1] = perm[l1], perm[i1]
                    value[i1], value[l1] = value[l1], value[i1]
                end
            end

            i += blockDim().x
        end

        sync_threads()

        # Minor step - Compare and swap
        j = k ÷ Ti(4)
        while j > Ti(0)

            # Compare and swap
            i = threadIdx().x - Ti(1)
            while i < subset_length
                i_block, i_lane = fld(i, j), mod(i, j)
                i_concrete = i_block * j * Ti(2) + i_lane
                l = i_concrete + j

                if l < subset_length # Ensure only one thread in each pair does the swap
                    i1 = i_concrete + Ti(1)
                    l1 = l + Ti(1)

                    if (value[i1] > value[l1]) != max
                        perm[i1], perm[l1] = perm[l1], perm[i1]
                        value[i1], value[l1] = value[l1], value[i1]
                    end
                end

                i += blockDim().x
            end

            j ÷= Ti(2)

            # Synchronize after minor step to make sure all threads agree on the shared memory
            sync_threads()
        end

        k *= Ti(2)
    end
end

@inline function copy_perm_to_global!(subset, perm)
    i = threadIdx().x
    while i <= length(subset)
        subset[i] = perm[i]
        i += blockDim().x
    end

    # Do I need to synchronize here? Now, we do it for
    # safety's sake.
    return sync_threads()
end

function IMDP.construct_ordering(T, p::CuSparseMatrixCSC)
    # Assume that input/start state is on the columns and output/target state is on the rows
    vecptr = CuVector{T}(p.colPtr)
    perm = CuVector{T}(SparseArrays.rowvals(p))
    maxlength = maximum(p.colPtr[2:end] - p.colPtr[1:(end - 1)])

    subsets = CuVectorOfVector{T, T}(vecptr, perm, maxlength)
    rowvals = CuVector{T}(SparseArrays.rowvals(p))

    order = CuSparseOrdering(subsets, rowvals)
    return order
end
