# ADR-001: Trait-Based Data Generator Plugins

## Status
Accepted

## Context
implore needs to generate synthetic data for testing, demonstrations, and procedural visualization. Use cases include:

1. **Testing**: Generate known patterns to verify rendering
2. **Demonstrations**: Show capabilities without requiring real data files
3. **Procedural art**: Create noise fields, fractals, mathematical functions
4. **Benchmarking**: Generate large datasets for performance testing

Traditional approaches:
- **Hardcoded generators**: Inflexible, clutters core code
- **Dynamic plugins (dylib)**: Complex loading, platform-specific issues
- **Script-based**: Performance overhead, dependency on interpreter

## Decision
implore uses a **trait-based plugin architecture** where generators implement the `DataGenerator` trait and are registered at compile time.

```rust
/// The core trait all data generators implement.
pub trait DataGenerator: Send + Sync {
    /// Unique identifier for this generator
    fn id(&self) -> &'static str;

    /// Human-readable metadata
    fn metadata(&self) -> GeneratorMetadata;

    /// Parameter specifications for UI generation
    fn parameters(&self) -> Vec<ParameterSpec>;

    /// Generate data with given parameters
    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError>;

    /// Expected output schema
    fn output_schema(&self) -> DataSchema;
}

pub struct GeneratorMetadata {
    pub name: String,
    pub description: String,
    pub category: GeneratorCategory,
    pub author: Option<String>,
    pub version: String,
}

pub enum GeneratorCategory {
    Noise,        // Perlin, Simplex, Worley
    Fractal,      // Mandelbrot, Julia
    Statistical,  // Gaussian clusters, uniform random
    Mathematical, // Functions, parametric curves
    Astronomical, // Mock catalogs, power spectra
}
```

### Built-in Generators

| Generator | Category | Description |
|-----------|----------|-------------|
| `PerlinNoise2D` | Noise | Classic Perlin noise field |
| `SimplexNoise2D` | Noise | Improved simplex noise |
| `WorleyNoise2D` | Noise | Cellular/Voronoi noise |
| `MandelbrotSet` | Fractal | Classic Mandelbrot zoom |
| `JuliaSet` | Fractal | Julia set with configurable c |
| `GaussianClusters` | Statistical | N-cluster Gaussian mixture |
| `UniformRandom` | Statistical | Uniform random points |
| `FunctionPlotter2D` | Mathematical | Plot f(x,y) surfaces |
| `PowerSpectrumNoise` | Astronomical | Power-law noise fields |

## Consequences

### Positive
- Type-safe: Compiler catches interface mismatches
- Zero overhead: No dynamic dispatch in hot paths
- Discoverable: UI can enumerate generators and their parameters
- Testable: Each generator independently unit-testable
- Extensible: New generators without modifying core

### Negative
- Compile-time only: Can't add generators at runtime
- Binary size: All generators included in binary
- Rust-only: Can't write generators in other languages
- Registration: Must manually register each generator

## Implementation
- Generators in `implore-core/src/plugin/generators/`
- Registry in `implore-core/src/plugin/registry.rs`
- FFI wrapper in `implore-core/src/plugin/ffi.rs`
- Parameters use `GeneratorParams` HashMap for flexibility
