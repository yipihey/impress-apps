//! implore-io - Data I/O for scientific datasets
//!
//! This crate provides readers for common scientific data formats:
//!
//! - **HDF5**: Hierarchical Data Format (primary scientific format)
//! - **FITS**: Flexible Image Transport System (astronomy)
//! - **CSV**: Comma-separated values with type inference
//! - **Parquet**: Apache Parquet columnar format
//!
//! # Design
//!
//! All readers implement the `DataReader` trait for uniform access.
//! Data is accessed lazily with memory-mapped I/O where possible.

pub mod reader;
pub mod schema;

#[cfg(feature = "csv")]
pub mod csv_reader;

#[cfg(feature = "hdf5")]
pub mod hdf5_reader;

#[cfg(feature = "fits")]
pub mod fits_reader;

#[cfg(feature = "parquet")]
pub mod parquet_reader;

pub use reader::*;
pub use schema::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
