module IMDP

include("interval_probabilities.jl")
export StateIntervalProbabilities, MatrixIntervalProbabilities
export gap

include("ordering.jl")
export construct_ordering, sort_states!, perm
export AbstractStateOrdering, DenseOrdering, SparseOrdering, PermutationSubset

include("ominmax.jl")
export ominmax, ominmax!, probability_assignment!, probability_assignment_from!

end
