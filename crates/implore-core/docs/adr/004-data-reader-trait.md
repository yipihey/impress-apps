# ADR-004: Format-Agnostic Data Reader Trait

## Status
Accepted

## Context
Scientific data comes in many formats:

| Format | Use Case | Characteristics |
|--------|----------|-----------------|
| HDF5 | Simulations, large arrays | Hierarchical, chunked, compressed |
| FITS | Astronomy images/tables | Headers + data, WCS coordinates |
| Parquet | Analytics, columnar storage | Efficient columnar queries |
| CSV | Simple tabular data | Human-readable, universally supported |
| NumPy | Python interop | Simple binary arrays |

Supporting all formats without code duplication requires abstraction. Traditional approaches:
- **Format-specific APIs**: No code reuse, format lock-in
- **DataFrame libraries**: Heavy dependencies (Polars, Arrow)
- **Common intermediate format**: Conversion overhead

## Decision
implore uses a **`DataReader` trait** that provides a uniform interface across all supported formats.

```rust
pub trait DataReader: Send + Sync {
    /// Get schema without reading all data
    fn schema(&self) -> Result<DataSchema, ReaderError>;

    /// Read a specific column by name
    fn read_column(&self, name: &str) -> Result<ColumnData, ReaderError>;

    /// Read multiple columns efficiently
    fn read_columns(&self, names: &[&str]) -> Result<Vec<ColumnData>, ReaderError>;

    /// Get row count without reading data
    fn row_count(&self) -> Result<usize, ReaderError>;

    /// Stream rows in chunks for large datasets
    fn read_chunks(&self, chunk_size: usize) -> Box<dyn Iterator<Item = Result<Chunk, ReaderError>>>;

    /// Get format-specific metadata
    fn metadata(&self) -> HashMap<String, MetadataValue>;
}

pub enum ColumnData {
    Float32(Vec<f32>),
    Float64(Vec<f64>),
    Int32(Vec<i32>),
    Int64(Vec<i64>),
    String(Vec<String>),
    Boolean(Vec<bool>),
}

pub struct DataSchema {
    pub fields: Vec<FieldDescriptor>,
}

pub struct FieldDescriptor {
    pub name: String,
    pub dtype: DataType,
    pub nullable: bool,
    pub description: Option<String>,
    pub unit: Option<String>,
}
```

### Format Implementations

```rust
// implore-io/src/hdf5_reader.rs
pub struct Hdf5Reader { ... }
impl DataReader for Hdf5Reader { ... }

// implore-io/src/csv_reader.rs
pub struct CsvReader { ... }
impl DataReader for CsvReader { ... }

// Future: FitsReader, ParquetReader, NumpyReader
```

### Factory Pattern

```rust
pub fn open_dataset(path: &Path) -> Result<Box<dyn DataReader>, ReaderError> {
    let ext = path.extension().and_then(|e| e.to_str());
    match ext {
        Some("h5") | Some("hdf5") => Ok(Box::new(Hdf5Reader::open(path)?)),
        Some("csv") => Ok(Box::new(CsvReader::open(path)?)),
        Some("fits") => Ok(Box::new(FitsReader::open(path)?)),
        _ => Err(ReaderError::UnsupportedFormat(ext.unwrap_or("").to_string())),
    }
}
```

## Consequences

### Positive
- Format agnostic: Core code works with any format
- Lazy loading: Schema inspection without reading all data
- Streaming: Handle datasets larger than memory
- Extensible: New formats don't change consuming code
- Testable: Mock readers for testing

### Negative
- Lowest common denominator: Can't expose format-specific features
- Type erasure: Runtime type checks for column data
- Memory copies: Some formats may require conversion
- Incomplete metadata: Generic interface loses format-specific metadata

## Implementation
- Trait in `implore-io/src/reader.rs`
- Schema types in `implore-io/src/schema.rs`
- HDF5 reader in `implore-io/src/hdf5_reader.rs`
- CSV reader in `implore-io/src/csv_reader.rs`
