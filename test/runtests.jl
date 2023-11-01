using Test
using Random, StatsBase
using IMDP, SparseArrays, CUDA, Adapt

@testset "IMDP.jl" begin
    test_files = ["ominmax.jl", "partial.jl", "ivi.jl", "imdp.jl"]
    for f in test_files
        @testset "$f" begin
            include(f)
        end
    end
end

@testset "sparse" include("sparse/sparse.jl")

if CUDA.functional()
    @info "Running tests with CUDA"
    @testset "IMDPCudaExt.jl" include("cuda/cuda.jl")
end
