abstract type TerminationCriteria end
function termination_criteria(spec::Specification)
    prop = system_property(spec)
    return termination_criteria(prop, Val(isfinitetime(prop)))
end

struct FixedIterationsCriteria{T <: Integer} <: TerminationCriteria
    n::T
end
(f::FixedIterationsCriteria)(V, k, u) = k >= f.n
termination_criteria(prop, finitetime::Val{true}) =
    FixedIterationsCriteria(time_horizon(prop))

struct CovergenceCriteria{T <: AbstractFloat} <: TerminationCriteria
    tol::T
end
(f::CovergenceCriteria)(V, k, u) = maximum(u) < f.tol
termination_criteria(prop, finitetime::Val{false}) =
    CovergenceCriteria(convergence_eps(prop))

"""
    value_iteration(problem::Problem)

Solve minimizes/mazimizes optimistic/pessimistic specification problems using value iteration for interval Markov processes. 

### Examples

```jldoctest
prob1 = IntervalProbabilities(;
    lower = [
        0.0 0.5
        0.1 0.3
        0.2 0.1
    ],
    upper = [
        0.5 0.7
        0.6 0.5
        0.7 0.3
    ],
)

prob2 = IntervalProbabilities(;
    lower = [
        0.1 0.2
        0.2 0.3
        0.3 0.4
    ],
    upper = [
        0.6 0.6
        0.5 0.5
        0.4 0.4
    ],
)

prob3 = IntervalProbabilities(;
    lower = [0.0; 0.0; 1.0],
    upper = [0.0; 0.0; 1.0]
)

transition_probs = [["a1", "a2"] => prob1, ["a1", "a2"] => prob2, ["sinking"] => prob3]
initial_state = 1
mdp = IntervalMarkovDecisionProcess(transition_probs, initial_state)

terminal_states = [3]
time_horizon = 10
prop = FiniteTimeReachability(terminal_states, time_horizon)
spec = Specification(prop, Pessimistic, Maximize)
problem = Problem(mdp, spec)
V, k, residual = value_iteration(problem)
```

"""
function value_iteration(
    problem::Problem,
)
    no_policy_cache = NoPolicyCache()
    V, k, res, _ = _value_iteration!(no_policy_cache, problem)

    return V, k, res
end

function _value_iteration!(
    policy_cache::AbstractPolicyCache,
    problem::Problem,
)
    mp = system(problem)
    spec = specification(problem)
    term_criteria = termination_criteria(spec)
    upper_bound = satisfaction_mode(spec) == Optimistic
    maximize = strategy_mode(spec) == Maximize

    # It is more efficient to use allocate first and reuse across iterations
    workspace = construct_workspace(mp, policy_cache)

    value_function = ValueFunction(problem)
    initialize!(value_function, spec)

    step!(workspace, value_function, 0, mp; upper_bound = upper_bound, maximize = maximize)
    postprocess_value_function!(value_function, spec)
    postprocess_policy_cache!(workspace.policy_cache)
    k = 1

    while !term_criteria(value_function.current, k, lastdiff!(value_function))
        nextiteration!(value_function)

        step!(workspace, value_function, k, mp; upper_bound = upper_bound, maximize = maximize)
        postprocess_value_function!(value_function, spec)
        postprocess_policy_cache!(workspace.policy_cache)
        k += 1
    end

    # lastdiff! uses previous to store the latest difference
    # and it is already computed from the condition in the loop
    return value_function.current, k, value_function.previous, policy_cache
end

mutable struct ValueFunction{R, A <: AbstractArray{R}}
    previous::A
    current::A
end

function ValueFunction(
    problem::Problem{<:SimpleIntervalMarkovProcess},
)
    mp = system(problem)

    previous = construct_value_function(gap(transition_prob(mp, 1)), num_states(mp))
    current = copy(previous)

    return ValueFunction(previous, current)
end


function ValueFunction(
    problem::Problem{<:ProductIntervalMarkovProcess},
)
    mp = system(problem)

    pns = product_num_states(mp) |> recursiveflatten |> collect
    # Just need any one of the transition probabilities to dispatch
    # to the correct method (based on the type).
    previous = construct_value_function(gap(first_transition_prob(mp)), pns)
    current = copy(previous)

    return ValueFunction(previous, current)
end

function construct_value_function(::MR, num_states) where {R, MR <: AbstractMatrix{R}}
    V = zeros(R, num_states)
    return V
end

function lastdiff!(V)
    # Reuse prev to store the latest difference
    V.previous .-= V.current
    rmul!(V.previous, -1.0)

    return V.previous
end

function nextiteration!(V)
    copyto!(V.previous, V.current)

    return V
end

function step!(workspace, value_function, k, mp::StationaryIntervalMarkovProcess; upper_bound, maximize)
    prob = transition_prob(mp)
    bellman!(
        workspace,
        value_function.current,
        value_function.previous,
        prob,
        stateptr(mp);
        upper_bound = upper_bound,
        maximize = maximize,
    )
end

function step!(workspace, value_function, k, mp::TimeVaryingIntervalMarkovProcess; upper_bound, maximize)
    prob = transition_prob(mp, time_length(mp) - k)
    bellman!(
        workspace,
        value_function.current,
        value_function.previous,
        prob,
        stateptr(mp);
        upper_bound = upper_bound,
        maximize = maximize,
    )
end

function step!(workspace, value_function, k, mp::ParallelProduct; upper_bound, maximize)
    d = 0

    for orthogonal_process in orthogonal_processes(mp)
        process_dims = dims(orthogonal_process)
        process_dim_indices = collect(1:process_dims) .+ d

        paxis_indices = permuted_axis_indices(process_dim_indices, ndims(value_function.current))

        permuted_current = PermutedDimsArray(value_function.current, paxis_indices)
        permuted_previous = PermutedDimsArray(value_function.previous, paxis_indices)
        permuted_value_function = ValueFunction(permuted_previous, permuted_current)

        step!(workspace, permuted_value_function, k, orthogonal_process; upper_bound = upper_bound, maximize = maximize)
        d += process_dims
    end
end

function permuted_axis_indices(axis_dims, ndims)
    axis_indices = copy(axis_dims)
    sizehint!(axis_indices, ndims)
    for i in 1:ndims
        if i ∉ axis_dims
            push!(axis_indices, i)
        end
    end
end