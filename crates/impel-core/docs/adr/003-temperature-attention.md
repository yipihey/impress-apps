# ADR-003: Temperature-Based Attention

## Status
Accepted

## Context
With many threads competing for agent attention, we need a mechanism to:
- Prioritize important work
- Allow human steering without micromanagement
- Naturally decay stale work
- Reward progress and breakthroughs

Options considered:
1. **Fixed priority**: Human-assigned static priorities
2. **FIFO queue**: First-in-first-out processing
3. **Temperature/heat**: Dynamic attention gradients

## Decision
Use a **temperature-based attention system** where each thread has a computed temperature value (0.0-1.0) that guides agent work selection.

### Formula
```
temperature = base_priority
            + α × recent_activity
            + β × breakthrough_signals
            - γ × time_since_progress
            + δ × human_boost
```

### Parameters (tunable)
| Parameter | Default | Description |
|-----------|---------|-------------|
| α (alpha) | 0.2 | Weight for recent activity |
| β (beta) | 0.3 | Weight for breakthrough signals |
| γ (gamma) | 0.1 | Decay rate for staleness |
| δ (delta) | 0.5 | Weight for human boost |

### Decay
- Half-life: 24 hours
- Temperature naturally cools without activity
- Prevents abandoned threads from blocking work

## Consequences

### Positive
- Human attention is multiplicative, not additive
- Hot threads attract more agents naturally
- Cold threads can be identified for review/kill
- Breakthroughs get immediate attention
- Self-regulating without central scheduling

### Negative
- Non-intuitive for users at first
- Requires tuning of parameters
- Can create feedback loops (hot gets hotter)
- Temperature alone doesn't capture all priority factors

## Implementation

```rust
pub struct Temperature {
    value: f64,
    base_priority: f64,
    last_updated: DateTime<Utc>,
    human_boost: f64,
    breakthrough_signal: f64,
}

impl Temperature {
    pub fn recalculate(&mut self, recent_activity: f64, coefficients: &TemperatureCoefficients) {
        let elapsed = Utc::now() - self.last_updated;
        let hours_since_progress = elapsed.num_hours() as f64;

        self.value = self.base_priority
            + coefficients.alpha * recent_activity
            + coefficients.beta * self.breakthrough_signal
            - coefficients.gamma * (hours_since_progress / DECAY_HALF_LIFE_HOURS as f64)
            + coefficients.delta * self.human_boost;

        self.value = self.value.clamp(0.0, 1.0);
    }
}
```

## Thresholds
- Hot (≥0.7): High priority, multiple agents may work
- Warm (0.3-0.7): Normal priority
- Cold (<0.3): Low priority, candidate for review/kill

## References
- Simulated annealing in optimization
- Ant colony optimization temperature mechanisms
