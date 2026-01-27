//! FITS (Flexible Image Transport System) file reader
//!
//! This module provides support for reading FITS files commonly used in astronomy.
//! Currently a placeholder - FITS support is planned for a future release.

use crate::reader::{DataReader, ReaderError};
use crate::schema::DataSchema;

/// FITS file reader (placeholder implementation)
pub struct FitsReader {
    _path: String,
}

impl FitsReader {
    /// Create a new FITS reader for the given file path
    pub fn new(path: impl Into<String>) -> Result<Self, ReaderError> {
        Err(ReaderError::UnsupportedFormat(
            "FITS support is not yet implemented".to_string(),
        ))
    }
}

impl DataReader for FitsReader {
    fn schema(&self) -> Result<DataSchema, ReaderError> {
        Err(ReaderError::UnsupportedFormat(
            "FITS support is not yet implemented".to_string(),
        ))
    }

    fn read_column(&self, _name: &str) -> Result<Vec<f64>, ReaderError> {
        Err(ReaderError::UnsupportedFormat(
            "FITS support is not yet implemented".to_string(),
        ))
    }
}
