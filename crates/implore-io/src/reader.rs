//! Data reader trait and common types
//!
//! The `DataReader` trait provides a uniform interface for reading
//! scientific data from various file formats.

use crate::schema::{DataColumn, DataSchema, DataSlice};
use std::collections::HashMap;
use thiserror::Error;

/// Errors that can occur during I/O operations
#[derive(Debug, Error)]
pub enum IoError {
    #[error("File not found: {0}")]
    FileNotFound(String),

    #[error("Failed to open file: {0}")]
    OpenFailed(String),

    #[error("Invalid format: {0}")]
    InvalidFormat(String),

    #[error("Column not found: {0}")]
    ColumnNotFound(String),

    #[error("Type mismatch: expected {expected}, got {actual}")]
    TypeMismatch { expected: String, actual: String },

    #[error("Out of bounds: index {index}, size {size}")]
    OutOfBounds { index: usize, size: usize },

    #[error("I/O error: {0}")]
    Io(String),
}

/// Result type for I/O operations
pub type IoResult<T> = Result<T, IoError>;

/// Trait for reading scientific data from various formats
///
/// Implementations should provide lazy loading where possible,
/// reading data only when requested.
pub trait DataReader: Send + Sync {
    /// Read the schema (column names, types, record count)
    fn read_schema(&self) -> IoResult<DataSchema>;

    /// Read a single column by name
    fn read_column(&self, name: &str) -> IoResult<DataColumn>;

    /// Read a range of records (all columns)
    fn read_range(&self, start: usize, end: usize) -> IoResult<DataSlice>;

    /// Get metadata as key-value pairs
    fn metadata(&self) -> &HashMap<String, String>;

    /// Get the file path (if applicable)
    fn path(&self) -> Option<&str> {
        None
    }

    /// Get the format name
    fn format_name(&self) -> &'static str;

    /// Check if the reader supports lazy loading
    fn supports_lazy_loading(&self) -> bool {
        false
    }

    /// Estimate memory usage for the full dataset
    fn estimated_memory_bytes(&self) -> Option<usize> {
        None
    }
}

/// A boxed reader for dynamic dispatch
pub type BoxedReader = Box<dyn DataReader>;

/// Open a file and return an appropriate reader
///
/// The format is auto-detected from the file extension.
pub fn open_file(path: &str) -> IoResult<BoxedReader> {
    let extension = path
        .rsplit('.')
        .next()
        .map(|s| s.to_lowercase())
        .unwrap_or_default();

    match extension.as_str() {
        #[cfg(feature = "csv")]
        "csv" | "tsv" => {
            use crate::csv_reader::CsvReader;
            Ok(Box::new(CsvReader::open(path)?))
        }

        #[cfg(feature = "hdf5")]
        "h5" | "hdf5" | "hdf" => {
            use crate::hdf5_reader::Hdf5Reader;
            Ok(Box::new(Hdf5Reader::open(path)?))
        }

        #[cfg(feature = "fits")]
        "fits" | "fit" | "fts" => {
            use crate::fits_reader::FitsReader;
            Ok(Box::new(FitsReader::open(path)?))
        }

        #[cfg(feature = "parquet")]
        "parquet" | "pq" => {
            use crate::parquet_reader::ParquetReader;
            Ok(Box::new(ParquetReader::open(path)?))
        }

        _ => Err(IoError::InvalidFormat(format!(
            "Unknown file extension: {}",
            extension
        ))),
    }
}

/// List supported file extensions
pub fn supported_extensions() -> Vec<&'static str> {
    let mut extensions = Vec::new();

    #[cfg(feature = "csv")]
    {
        extensions.push("csv");
        extensions.push("tsv");
    }

    #[cfg(feature = "hdf5")]
    {
        extensions.push("h5");
        extensions.push("hdf5");
        extensions.push("hdf");
    }

    #[cfg(feature = "fits")]
    {
        extensions.push("fits");
        extensions.push("fit");
        extensions.push("fts");
    }

    #[cfg(feature = "parquet")]
    {
        extensions.push("parquet");
        extensions.push("pq");
    }

    extensions
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_supported_extensions() {
        let extensions = supported_extensions();
        // At least csv should be supported by default
        #[cfg(feature = "csv")]
        assert!(extensions.contains(&"csv"));
    }
}
