# ADR-005: Column-Major FFI Serialization

## Status
Accepted

## Context
implore's Rust core must pass large numerical arrays to Swift/Metal for GPU rendering. The FFI boundary presents challenges:

1. **Memory layout**: Row-major vs column-major affects GPU access patterns
2. **Copying overhead**: Large datasets expensive to copy
3. **Type safety**: Rust and Swift have different type systems
4. **Alignment**: GPU requires specific memory alignment

GPU rendering typically processes all X coordinates, then all Y coordinates (column-major), while scientists often think in rows (row-major).

## Decision
implore uses **column-major serialization** at the FFI boundary, optimized for GPU access patterns.

```rust
/// FFI-friendly data structure for generated data
pub struct GeneratedDataFfi {
    /// Flattened column data: [x₀,x₁,...,xₙ, y₀,y₁,...,yₙ, z₀,z₁,...,zₙ]
    pub data: Vec<f32>,

    /// Number of points
    pub point_count: u32,

    /// Number of dimensions (columns)
    pub dimension_count: u32,

    /// Column names in order
    pub column_names: Vec<String>,

    /// Metadata key-value pairs
    pub metadata: Vec<MetadataEntry>,
}

pub struct MetadataEntry {
    pub key: String,
    pub value: String,
}
```

### Memory Layout

For N points with columns (x, y, color):

```
Row-major (not used):
[x₀,y₀,c₀, x₁,y₁,c₁, x₂,y₂,c₂, ...]
Stride: 3 elements per point

Column-major (used):
[x₀,x₁,x₂,...,xₙ, y₀,y₁,y₂,...,yₙ, c₀,c₁,c₂,...,cₙ]
Stride: N elements per column
```

### Swift Consumption

```swift
func uploadToGPU(data: GeneratedDataFfi) {
    // Column offsets
    let xOffset = 0
    let yOffset = Int(data.pointCount)
    let colorOffset = Int(data.pointCount) * 2

    // Create Metal buffers directly from column slices
    let xBuffer = device.makeBuffer(
        bytes: data.data + xOffset,
        length: Int(data.pointCount) * MemoryLayout<Float>.stride
    )
    // ... similar for y, color
}
```

### Conversion from Internal Format

```rust
impl From<GeneratedData> for GeneratedDataFfi {
    fn from(data: GeneratedData) -> Self {
        let point_count = data.points.len() as u32;
        let dim_count = data.dimensions.len() as u32;

        // Transpose to column-major
        let mut flat = Vec::with_capacity(point_count as usize * dim_count as usize);
        for dim in 0..dim_count as usize {
            for point in &data.points {
                flat.push(point.coords[dim]);
            }
        }

        Self {
            data: flat,
            point_count,
            dimension_count: dim_count,
            column_names: data.dimensions.iter().map(|d| d.name.clone()).collect(),
            metadata: data.metadata.into_iter().map(|(k, v)| MetadataEntry { key: k, value: v }).collect(),
        }
    }
}
```

## Consequences

### Positive
- GPU-optimal: Column-major matches shader access patterns
- Single copy: Data ready for Metal buffer upload
- Cache-friendly: Sequential access in shaders
- Aligned: Natural f32 alignment for GPU

### Negative
- Transpose cost: Row-major sources require conversion
- API mismatch: Scientists expect row-major
- Memory peak: May briefly hold both layouts during conversion
- Debugging harder: Column-major less intuitive to inspect

## Implementation
- FFI types in `implore-core/src/plugin/ffi.rs`
- Conversion in `From<GeneratedData> for GeneratedDataFfi`
- Swift bindings via UniFFI
- Metal shaders assume column-major input
