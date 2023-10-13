
struct StateIntervalProbabilities{R, VR <: AbstractVector{R}}
    lower::VR
    gap::VR

    sum_lower::R
end

function StateIntervalProbabilities(lower::VR, gap::VR) where {R, VR <: AbstractVector{R}}
    joint_lower_bound = sum(lower)
    @assert joint_lower_bound <= 1 "The joint lower bound transition probability (is $joint_lower_bound) should be less than or equal to 1."

    joint_upper_bound = joint_lower_bound + sum(gap)
    @assert joint_upper_bound >= 1 "The joint upper bound transition probability (is $joint_upper_bound) should be greater than or equal to 1."

    return new{R, VR}(lower, gap, joint_lower_bound)
end

# Keyword constructor
function StateIntervalProbabilities(; lower::VR, upper::VR) where {VR <: AbstractVector}
    gap = upper - lower
    return StateIntervalProbabilities(lower, gap)
end

gap(s::StateIntervalProbabilities) = s.gap
lower(s::StateIntervalProbabilities) = s.lower
sum_lower(s::StateIntervalProbabilities) = s.sum_lower

struct MatrixIntervalProbabilities{R, MR <: AbstractMatrix{R}}
    lower::MR
    gap::MR

    sum_lower::Vector{R}
end

function MatrixIntervalProbabilities(lower::MR, gap::MR) where {R, MR <: AbstractMatrix{R}}
    sum_lower = sum(lower; dims = 1)

    max_lower_bound = max(sum_lower)
    @assert max_lower_bound <= 1 "The joint lower bound transition probability per column (max is $max_lower_bound) should be less than or equal to 1."

    sum_gap = sum(gap; dims = 1)
    max_upper_bound = maximum(sum_lower + sum_gap)
    @assert max_upper_bound >= 1 "The joint upper bound transition probability per column (max is $max_upper_bound) should be greater than or equal to 1."

    return new{R, MR}(lower, gap, sum_lower)
end

# Keyword constructor
function MatrixIntervalProbabilities(;
    lower::MR,
    upper::MR,
) where {R, MR <: AbstractMatrix{R}}
    gap = upper - lower
    return MatrixIntervalProbabilities(lower, gap)
end

gap(s::MatrixIntervalProbabilities) = s.gap
lower(s::MatrixIntervalProbabilities) = s.lower
sum_lower(s::MatrixIntervalProbabilities) = s.sum_lower
