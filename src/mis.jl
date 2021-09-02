"""
    is_independent_set(graph::AbstractGraph, config)

Return `true` if `config` is an independent set of graph.
`config` can be a `BitStr`, a vector, or any iterable.
"""
function is_independent_set(graph::AbstractGraph, config)
    for i in 1:nv(graph)
        for j in i+1:nv(graph)
            config[i] == 1 && config[j] == 1 && has_edge(graph, i, j) && return false
        end
    end
    return true
end

"""
    to_independent_set!(graph::AbstractGraph, config::AbstractVector)

Eliminate vertices in `config` so that remaining vertices do not have connected edges.
This algorithm is a naive vertex elimination that does not nesesarily give the maximum possible vertex set.

```@example
# run the following code in Atom/VSCode
atoms = RydAtom.([(0.0, 1.0), (1.0, 0.), (2.0, 0.0),
    (1.0, 1.0), (1.0, 2.0), (2.0, 2.0)])
graph = unit_disk_graph(atoms, 1.5)

config = [1, 1, 1, 0, 1, 1]
viz_config(atoms, graph, config)

to_independent_set!(graph, config)
viz_config(atoms, graph, config)
```
"""
function to_independent_set!(graph::AbstractGraph, config::AbstractVector)
    N = length(config)
    n = typemax(Int)
    while true
        n, loc = findmax(map(i->num_mis_violation(config, graph, i), 1:N))
        if n == 0
            break
        else
            config[loc] = 0
        end
    end
    return config
end

function to_independent_set(graph::AbstractGraph, config::Integer)
    return to_independent_set!(graph, bitarray(config, nv(graph)))
end

"""
    num_mis_violation(config, graph::AbstractGraph, i::Int)

Calculate the number of MIS violations for `i`-th vertex in `graph`
and configuration `config`. The `config` should be a subtype of
`AbstractVector`.
"""
Base.@propagate_inbounds function num_mis_violation(config, graph::AbstractGraph, i::Int)
    ci = config[i]
    ci == 1 || return 0

    return count(1:length(config)) do j
        config[j] == 1 && has_edge(graph, i, j)
    end
end

"""
    exact_solve_mis(g::AbstractGraph)

Return the exact MIS size of a graph `g`.
"""
exact_solve_mis(g::AbstractGraph) = mis2(EliminateGraph(adjacency_matrix(g)))

"""
    add_random_vertices!([rng=GLOBAL_RNG], config::AbstractVector, graph::AbstractGraph, ntrials::Int = 10)

Add vertices randomly to given configuration for `ntrials` times and
pick the one that has largest [`count_vertices`](@ref).

# Arguments

- `rng`: optional, Random Number Generator.
- `config`: configuration to tweak.
- `graph`: problem graph.
- `ntrials`: number of trials to use, default is `10`.
"""
function add_random_vertices!(
    config::AbstractVector,
    graph::AbstractGraph,
    ntrials::Int = 10)

    return add_random_vertices!(
        Random.GLOBAL_RNG,
        config,
        graph,
        ntrials
    )
end

function add_random_vertices!(
        rng::AbstractRNG,
        config::AbstractVector,
        graph::AbstractGraph,
        ntrials::Int = 10
    )
    perm = collect(1:nv(graph))
    nvertices = count_vertices(config)
    config_candidate = copy(config)

    for _ in 1:ntrials
        randperm!(rng, perm)
        copyto!(config_candidate, config)
        add_vertices!(config_candidate, graph, perm)
        nvertices_config = count_vertices(config)
        if nvertices_config > nvertices
            copyto!(config, config_candidate)
            nvertices = nvertices_config
        end
    end
    return config
end

add_vertices(config::AbstractVector, graph::AbstractGraph, perm=eachindex(config)) =
    add_vertices!(copy(config), graph, perm)

function add_vertices!(config::AbstractVector, graph::AbstractGraph, perm=eachindex(config))
    for (k, c) in zip(perm, config)
        if iszero(c)
            config[k] = 1
            if is_independent_set(graph, config)
                continue
            else
                config[k] = 0
            end
        end
    end
    return config
end

"""
    independent_set_probabilities(reg::RydbergReg, graph::AbstractGraph, mis::Int = exact_solve_mis(graph); add_vertices::Bool = false)

Return a `Vector` of the probabilities of all independent set size.
An optional argument `mis` can be applied to use pre-calculated mis size.

The probability of each size can be queried via `prob[size+1]`, e.g

```julia
prob = independent_set_probabilities(r, graph)
prob[end]   # the probability of mis
prob[end-1] # the probability of mis - 1
```
"""
function independent_set_probabilities(reg::RydbergReg, graph::AbstractGraph, mis::Int = exact_solve_mis(graph); add_vertices::Bool = false)
    probs = zeros(real(eltype(reg.state)), mis+1)

    @progress name="IS probabilities (add_vertices=$add_vertices)" for (c, amp) in zip(vec(reg.subspace), vec(reg.state))
        new_c_array = to_independent_set!(graph, bitarray(c, nv(graph)))
        add_vertices && add_vertices!(new_c_array, graph)
        new_c = packbits(new_c_array)

        nvertices = count_vertices(new_c)
        probs[nvertices+1] += abs2(amp)
    end
    return probs
end

"""
    independent_set_probabilities([f], reg::Yao.AbstractRegister, graph_or_mis)

Calculate the probabilities of independent sets with given postprocessing function
`f(config) -> config`. The default postprocessing function `f` will only reduce all
configurations to independent set.

# Arguments

- `f`: optional, postprocessing function, default is [`to_independent_set`](@ref).
- `reg`: required, the register object.
- `graph_or_mis`: a problem graph or the MIS size of the problem
    graph (can be calculated via [`exact_solve_mis`](@ref)).
"""
function independent_set_probabilities end

function independent_set_probabilities(reg::Yao.AbstractRegister, graph::AbstractGraph)
    independent_set_probabilities(reg, graph) do config
        to_independent_set(graph, config)
    end
end

function independent_set_probabilities(f, reg::Yao.AbstractRegister, graph::AbstractGraph)
    return independent_set_probabilities(f, reg, exact_solve_mis(graph))
end

function independent_set_probabilities(f, reg::Yao.AbstractRegister, mis::Int)
    probs = zeros(real(eltype(reg.state)), mis+1)
    for (c, amp) in _config_amplitude(reg)
        nvertices = count_vertices(f(c))
        @inbounds probs[nvertices+1] += abs2(amp)
    end
    return probs
end

"""
    mis_postprocessing(config, graph::AbstractGraph; ntrials::Int=10)

The postprocessing protocal used in Harvard.

# Arguments

- `config`: configuration to postprocess.
- `graph`: the problem graph.

# Keyword Arguments

- `ntrials`: number of trials to use.
"""
function mis_postprocessing(config, graph::AbstractGraph; ntrials::Int=10)
    config = to_independent_set(graph, config)
    add_random_vertices!(config, graph, ntrials)
    return config
end

"""
    mis_postprocessing(graph::AbstractGraph; ntrials::Int = 10)

Curried version of [`mis_postprocessing`](@ref).

# Example

to calculate `mean_rydberg` loss with postprocessing used in
Harvard experiment.

```julia
mean_rydberg(mis_postprocessing(graph), reg)
```
"""
function mis_postprocessing(graph::AbstractGraph; ntrials::Int = 10)
    return function postprocessing(config)
        mis_postprocessing(config, graph; ntrials)
    end
end
