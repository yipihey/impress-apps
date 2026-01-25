//! Error types for implore-core
//!
//! Provides comprehensive error handling for:
//! - Dataset operations
//! - Rendering errors
//! - Export failures
//! - Session management

use std::path::PathBuf;
use thiserror::Error;

/// Main error type for implore operations
#[derive(Error, Debug)]
pub enum ImploreError {
    /// Dataset loading errors
    #[error("Failed to load dataset: {0}")]
    DatasetLoad(#[from] DatasetError),

    /// Rendering errors
    #[error("Rendering failed: {0}")]
    Render(#[from] RenderError),

    /// Export errors
    #[error("Export failed: {0}")]
    Export(#[from] ExportError),

    /// Session errors
    #[error("Session error: {0}")]
    Session(#[from] SessionError),

    /// Selection parsing errors
    #[error("Selection error: {0}")]
    Selection(String),

    /// Invalid configuration
    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),

    /// I/O errors
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

/// Errors related to dataset operations
#[derive(Error, Debug)]
pub enum DatasetError {
    /// File not found
    #[error("Dataset file not found: {path}")]
    NotFound { path: PathBuf },

    /// Unsupported format
    #[error("Unsupported dataset format: {format}")]
    UnsupportedFormat { format: String },

    /// Invalid schema
    #[error("Invalid dataset schema: {message}")]
    InvalidSchema { message: String },

    /// Field not found
    #[error("Field '{field}' not found in dataset")]
    FieldNotFound { field: String },

    /// Type mismatch
    #[error("Type mismatch for field '{field}': expected {expected}, got {actual}")]
    TypeMismatch {
        field: String,
        expected: String,
        actual: String,
    },

    /// Dataset too large
    #[error("Dataset exceeds size limit: {size} points (max: {max})")]
    TooLarge { size: usize, max: usize },

    /// Corrupted data
    #[error("Dataset appears corrupted: {message}")]
    Corrupted { message: String },

    /// HDF5-specific error
    #[error("HDF5 error: {message}")]
    Hdf5Error { message: String },

    /// FITS-specific error
    #[error("FITS error: {message}")]
    FitsError { message: String },

    /// CSV parsing error
    #[error("CSV parsing error at line {line}: {message}")]
    CsvError { line: usize, message: String },
}

/// Errors related to rendering
#[derive(Error, Debug)]
pub enum RenderError {
    /// GPU device not available
    #[error("GPU device not available")]
    NoDevice,

    /// Shader compilation failed
    #[error("Shader compilation failed: {message}")]
    ShaderCompilation { message: String },

    /// Pipeline creation failed
    #[error("Pipeline creation failed: {message}")]
    PipelineCreation { message: String },

    /// Buffer allocation failed
    #[error("Buffer allocation failed: {size} bytes requested")]
    BufferAllocation { size: usize },

    /// Texture creation failed
    #[error("Texture creation failed: {width}x{height}")]
    TextureCreation { width: u32, height: u32 },

    /// Invalid render mode
    #[error("Invalid render mode: {mode}")]
    InvalidMode { mode: String },

    /// Frame timing error
    #[error("Frame timing error: {message}")]
    FrameTiming { message: String },
}

/// Errors related to export
#[derive(Error, Debug)]
pub enum ExportError {
    /// Invalid output path
    #[error("Invalid output path: {path}")]
    InvalidPath { path: PathBuf },

    /// Write permission denied
    #[error("Permission denied: cannot write to {path}")]
    PermissionDenied { path: PathBuf },

    /// Unsupported format for operation
    #[error("Format {format} does not support {operation}")]
    UnsupportedOperation { format: String, operation: String },

    /// Invalid dimensions
    #[error("Invalid dimensions: {width}x{height} (must be positive and within limits)")]
    InvalidDimensions { width: u32, height: u32 },

    /// Export cancelled
    #[error("Export cancelled by user")]
    Cancelled,

    /// PNG encoding error
    #[error("PNG encoding failed: {message}")]
    PngEncoding { message: String },

    /// PDF generation error
    #[error("PDF generation failed: {message}")]
    PdfGeneration { message: String },

    /// SVG generation error
    #[error("SVG generation failed: {message}")]
    SvgGeneration { message: String },
}

/// Errors related to sessions
#[derive(Error, Debug)]
pub enum SessionError {
    /// Session not found
    #[error("Session not found: {id}")]
    NotFound { id: String },

    /// Permission denied
    #[error("Permission denied for session: {id}")]
    PermissionDenied { id: String },

    /// Session expired
    #[error("Session has expired: {id}")]
    Expired { id: String },

    /// Invalid session state
    #[error("Invalid session state: {message}")]
    InvalidState { message: String },

    /// Sync conflict
    #[error("Sync conflict: {message}")]
    SyncConflict { message: String },

    /// Network error
    #[error("Network error: {message}")]
    NetworkError { message: String },
}

/// Result type alias for implore operations
pub type ImploreResult<T> = Result<T, ImploreError>;

/// Result type alias for dataset operations
pub type DatasetResult<T> = Result<T, DatasetError>;

/// Result type alias for render operations
pub type RenderResult<T> = Result<T, RenderError>;

/// Result type alias for export operations
pub type ExportResult<T> = Result<T, ExportError>;

/// Result type alias for session operations
pub type SessionResult<T> = Result<T, SessionError>;

/// Validation utilities
pub mod validation {
    use super::*;

    /// Validate export dimensions
    pub fn validate_dimensions(width: u32, height: u32) -> ExportResult<()> {
        const MAX_DIMENSION: u32 = 16384;
        const MIN_DIMENSION: u32 = 1;

        if width < MIN_DIMENSION
            || height < MIN_DIMENSION
            || width > MAX_DIMENSION
            || height > MAX_DIMENSION
        {
            return Err(ExportError::InvalidDimensions { width, height });
        }
        Ok(())
    }

    /// Validate dataset size
    pub fn validate_dataset_size(size: usize, max: usize) -> DatasetResult<()> {
        if size > max {
            return Err(DatasetError::TooLarge { size, max });
        }
        Ok(())
    }

    /// Validate field exists
    pub fn validate_field_exists(field: &str, available: &[String]) -> DatasetResult<()> {
        if !available.iter().any(|f| f == field) {
            return Err(DatasetError::FieldNotFound {
                field: field.to_string(),
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_implore_error_display() {
        let err = ImploreError::InvalidConfig("test error".to_string());
        assert!(err.to_string().contains("test error"));
    }

    #[test]
    fn test_dataset_error_display() {
        let err = DatasetError::FieldNotFound {
            field: "x".to_string(),
        };
        assert!(err.to_string().contains("x"));
    }

    #[test]
    fn test_render_error_display() {
        let err = RenderError::BufferAllocation { size: 1024 };
        assert!(err.to_string().contains("1024"));
    }

    #[test]
    fn test_export_error_display() {
        let err = ExportError::InvalidDimensions {
            width: 0,
            height: 100,
        };
        assert!(err.to_string().contains("0x100"));
    }

    #[test]
    fn test_validate_dimensions() {
        assert!(validation::validate_dimensions(1920, 1080).is_ok());
        assert!(validation::validate_dimensions(0, 100).is_err());
        assert!(validation::validate_dimensions(20000, 1000).is_err());
    }

    #[test]
    fn test_validate_dataset_size() {
        assert!(validation::validate_dataset_size(1000, 10000).is_ok());
        assert!(validation::validate_dataset_size(20000, 10000).is_err());
    }

    #[test]
    fn test_validate_field_exists() {
        let fields = vec!["x".to_string(), "y".to_string(), "z".to_string()];
        assert!(validation::validate_field_exists("x", &fields).is_ok());
        assert!(validation::validate_field_exists("w", &fields).is_err());
    }
}
