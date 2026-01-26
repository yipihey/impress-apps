# ADR-003: ECDF/PCDF Preferred Over Histograms

## Status
Accepted

## Context
Visualizing distributions is fundamental to scientific data analysis. Traditional histograms have well-known problems:

1. **Bin sensitivity**: Results depend on bin width and edge placement
2. **Information loss**: Exact values collapsed into bins
3. **Comparison difficulty**: Hard to compare distributions with different binning
4. **Small sample issues**: Noisy with limited data

Alternatives exist:
- **Kernel Density Estimation (KDE)**: Smooth but requires bandwidth selection
- **Empirical CDF (ECDF)**: Non-parametric, shows exact distribution
- **Percentile CDF (PCDF)**: ECDF variant better for comparisons

## Decision
implore **prefers ECDF and PCDF over histograms** as the default distribution visualization.

### ECDF (Empirical Cumulative Distribution Function)

For data points x₁, x₂, ..., xₙ:

```
ECDF(x) = (1/n) × |{xᵢ : xᵢ ≤ x}|
```

Properties:
- Step function with jumps at data points
- Always monotonically increasing from 0 to 1
- No binning parameters required
- Shows exact quantiles

### PCDF (Percentile CDF)

Swap axes: plot percentile on X, value on Y:

```
PCDF(p) = value at percentile p
```

Properties:
- More intuitive for "what value is at the 90th percentile?"
- Easier to compare distributions (common X axis)
- Natural for showing quartiles, medians

### When to Use Each

| Visualization | Use Case |
|---------------|----------|
| ECDF | "What fraction of data is below X?" |
| PCDF | "What is the value at the Nth percentile?" |
| Histogram | When bin counts themselves are meaningful |

```rust
pub struct EcdfResult {
    /// Sorted unique values
    pub x: Vec<f64>,
    /// Cumulative probabilities [0, 1]
    pub y: Vec<f64>,
}

pub struct PcdfResult {
    /// Percentiles [0, 100]
    pub percentiles: Vec<f64>,
    /// Values at each percentile
    pub values: Vec<f64>,
}
```

## Consequences

### Positive
- No binning artifacts
- Preserves all information in the data
- Robust with small samples
- Easy to read quantiles (median, quartiles)
- Facilitates distribution comparison

### Negative
- Less familiar to some users
- Harder to see "modes" (peaks in distribution)
- Step function can look jagged with few points
- Density interpretation less intuitive than histogram

## Implementation
- `implore-stats/src/ecdf.rs`: ECDF computation
- `implore-stats/src/pcdf.rs`: PCDF computation
- `implore-stats/src/fast_cdf.rs`: Optimized for large datasets
- Histograms still available when explicitly requested
