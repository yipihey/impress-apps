# ADR-001: Stigmergic Coordination

## Status
Accepted

## Context
Impel needs to coordinate 10-100+ AI agents working on research tasks alongside human researchers. Traditional approaches include:

1. **Central command**: A manager agent assigns tasks to worker agents
2. **Direct communication**: Agents negotiate with each other
3. **Stigmergic coordination**: Agents coordinate through shared state

Central command creates bottlenecks and single points of failure. Direct communication doesn't scale and creates complex interaction patterns.

## Decision
Impel uses **stigmergic coordination** - agents coordinate indirectly through modification of shared state, similar to how ants leave pheromone trails.

Key principles:
1. No agent decides what other agents work on
2. Activity leaves traces visible in coordination state
3. Temperature signals create gradients that guide attention
4. Humans shape the landscape, not individual particles

## Consequences

### Positive
- Scales naturally - no coordination bottleneck
- Robust - no single point of failure
- Emergent behavior - complex coordination arises from simple rules
- Human attention is minimized but impactful when applied

### Negative
- Less predictable than direct control
- Requires careful design of signals and state
- Can produce suboptimal local behavior
- Harder to debug coordination issues

## Implementation
- Coordination state is the shared environment (Layer 2 in architecture)
- Temperature-based attention gradients prioritize work
- Agents use pull-based work selection
- Human steering commands modify the landscape

## References
- Grassé, Pierre-Paul (1959). "La reconstruction du nid et les coordinations interindividuelles"
- Theraulaz, G., & Bonabeau, E. (1999). "A brief history of stigmergy"
