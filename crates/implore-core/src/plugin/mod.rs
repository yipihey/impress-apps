//! Plugin system for data generation in implore.
//!
//! This module provides a trait-based plugin architecture for generating synthetic data,
//! enabling exploratory data analysis, algorithm development, and educational use.
//!
//! # Key Components
//!
//! - [`DataGenerator`]: The core trait all generators implement
//! - [`GeneratorMetadata`]: Static metadata describing a generator
//! - [`GeneratorParams`]: Runtime parameters for generation
//! - [`GeneratedData`]: Output from a generator
//! - [`GeneratorRegistry`]: Registry of all available generators
//!
//! # Example
//!
//! ```ignore
//! let registry = GeneratorRegistry::new();
//! let generator = registry.get("noise-perlin-2d").unwrap();
//!
//! let mut params = GeneratorParams::new();
//! params.set_int("resolution", 256);
//! params.set_float("frequency", 4.0);
//!
//! let data = generator.generate(&params)?;
//! ```

pub mod ffi;
pub mod generators;
pub mod params;
pub mod registry;

pub use ffi::{GeneratedDataFfi, GeneratorErrorFfi, GeneratorRegistryHandle, MetadataEntry};
pub use params::{GeneratorParams, ParameterConstraints, ParameterSpec, ParameterType, ParameterValue};
pub use registry::GeneratorRegistry;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

/// Error type for generator operations
#[derive(Error, Debug)]
pub enum GeneratorError {
    #[error("Generator not found: {0}")]
    NotFound(String),

    #[error("Invalid parameter '{name}': {reason}")]
    InvalidParameter { name: String, reason: String },

    #[error("Missing required parameter: {0}")]
    MissingParameter(String),

    #[error("Parameter type mismatch for '{name}': expected {expected}")]
    TypeMismatch { name: String, expected: String },

    #[error("Generation failed: {0}")]
    GenerationFailed(String),

    #[error("Expression parse error: {0}")]
    ExpressionError(String),

    #[error("Dataset is not from a generator")]
    NotGenerated,
}

/// Category of data generator
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum GeneratorCategory {
    /// Noise generators (Perlin, Simplex, Worley, etc.)
    Noise,

    /// Fractal generators (Mandelbrot, Julia, etc.)
    Fractal,

    /// Statistical distributions (Gaussian clusters, power-law, etc.)
    Statistical,

    /// Mathematical functions (sin, cos, parametric, etc.)
    Function,

    /// Physics simulations (N-body, fluid, etc.)
    Simulation,
}

impl GeneratorCategory {
    /// Get a human-readable display name for this category
    pub fn display_name(&self) -> &'static str {
        match self {
            GeneratorCategory::Noise => "Noise",
            GeneratorCategory::Fractal => "Fractals",
            GeneratorCategory::Statistical => "Statistical",
            GeneratorCategory::Function => "Functions",
            GeneratorCategory::Simulation => "Simulations",
        }
    }

    /// Get an SF Symbol icon name for this category
    pub fn icon(&self) -> &'static str {
        match self {
            GeneratorCategory::Noise => "waveform",
            GeneratorCategory::Fractal => "sparkles",
            GeneratorCategory::Statistical => "chart.bar",
            GeneratorCategory::Function => "function",
            GeneratorCategory::Simulation => "atom",
        }
    }
}

/// Metadata describing a data generator plugin
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct GeneratorMetadata {
    /// Unique identifier (e.g., "noise-perlin-2d")
    pub id: String,

    /// Human-readable name (e.g., "Perlin Noise (2D)")
    pub name: String,

    /// Category for organization
    pub category: GeneratorCategory,

    /// Description of what this generator produces
    pub description: String,

    /// SF Symbol icon name
    pub icon: String,

    /// Parameter specifications
    pub parameters: Vec<ParameterSpec>,

    /// Output dimensionality (1, 2, or 3)
    pub output_dimensions: u8,

    /// Whether this generator supports time-based animation
    pub supports_animation: bool,
}

/// Output from a generator
#[derive(Clone, Debug)]
pub struct GeneratedData {
    /// Column data keyed by field name
    pub columns: HashMap<String, Vec<f64>>,

    /// Number of points/samples generated
    pub point_count: usize,

    /// Optional bounding box of the data
    pub bounds: Option<BoundingBox>,

    /// Additional metadata about the generation
    pub metadata: HashMap<String, String>,
}

/// 3D bounding box for generated data
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct BoundingBox {
    pub min: [f64; 3],
    pub max: [f64; 3],
}

impl BoundingBox {
    pub fn new(min: [f64; 3], max: [f64; 3]) -> Self {
        Self { min, max }
    }

    pub fn unit_cube() -> Self {
        Self::new([0.0, 0.0, 0.0], [1.0, 1.0, 1.0])
    }

    pub fn symmetric(half_extent: f64) -> Self {
        Self::new(
            [-half_extent, -half_extent, -half_extent],
            [half_extent, half_extent, half_extent],
        )
    }
}

/// Schema describing the output fields of a generator
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DataSchema {
    pub fields: Vec<FieldDescriptor>,
}

/// Description of a single output field
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FieldDescriptor {
    /// Field name (e.g., "x", "y", "value")
    pub name: String,

    /// Data type
    pub data_type: DataType,

    /// Unit of measurement (empty string if unitless)
    pub unit: String,

    /// Expected range if known
    pub range: Option<(f64, f64)>,

    /// Human-readable description
    pub description: Option<String>,
}

/// Data types for schema fields
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DataType {
    Float32,
    Float64,
    Int32,
    Int64,
    Bool,
}

impl DataSchema {
    pub fn new(fields: Vec<FieldDescriptor>) -> Self {
        Self { fields }
    }
}

impl FieldDescriptor {
    pub fn new(name: impl Into<String>, data_type: DataType) -> Self {
        Self {
            name: name.into(),
            data_type,
            unit: String::new(),
            range: None,
            description: None,
        }
    }

    pub fn with_unit(mut self, unit: impl Into<String>) -> Self {
        self.unit = unit.into();
        self
    }

    pub fn with_range(mut self, min: f64, max: f64) -> Self {
        self.range = Some((min, max));
        self
    }

    pub fn with_description(mut self, desc: impl Into<String>) -> Self {
        self.description = Some(desc.into());
        self
    }
}

impl GeneratedData {
    /// Create new generated data with the given columns
    pub fn new(columns: HashMap<String, Vec<f64>>) -> Self {
        let point_count = columns.values().next().map(|v| v.len()).unwrap_or(0);
        Self {
            columns,
            point_count,
            bounds: None,
            metadata: HashMap::new(),
        }
    }

    /// Set the bounding box
    pub fn with_bounds(mut self, bounds: BoundingBox) -> Self {
        self.bounds = Some(bounds);
        self
    }

    /// Add metadata
    pub fn with_metadata(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.metadata.insert(key.into(), value.into());
        self
    }

    /// Get a column by name
    pub fn get_column(&self, name: &str) -> Option<&Vec<f64>> {
        self.columns.get(name)
    }

    /// Get column names
    pub fn column_names(&self) -> impl Iterator<Item = &String> {
        self.columns.keys()
    }
}

/// The core trait all data generators implement.
///
/// Generators are stateless - all configuration is passed via parameters.
/// This enables reproducible generation when parameters are recorded.
pub trait DataGenerator: Send + Sync {
    /// Get static metadata describing this generator
    fn metadata(&self) -> &GeneratorMetadata;

    /// Generate data with the given parameters
    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError>;

    /// Get the output schema for this generator
    fn schema(&self) -> DataSchema;

    /// Generate a frame for animation (default: ignore time)
    fn generate_frame(
        &self,
        params: &GeneratorParams,
        _time: f64,
    ) -> Result<GeneratedData, GeneratorError> {
        self.generate(params)
    }

    /// Validate parameters before generation
    fn validate_params(&self, params: &GeneratorParams) -> Result<(), GeneratorError> {
        let meta = self.metadata();
        for spec in &meta.parameters {
            // Check if required parameters are present
            // (all parameters have defaults, so this is mainly for type checking)
            if let Some(value) = params.get(&spec.name) {
                if !spec.param_type.is_compatible_with(value) {
                    return Err(GeneratorError::TypeMismatch {
                        name: spec.name.clone(),
                        expected: spec.param_type.type_name().to_string(),
                    });
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generator_category() {
        assert_eq!(GeneratorCategory::Noise.display_name(), "Noise");
        assert_eq!(GeneratorCategory::Fractal.icon(), "sparkles");
    }

    #[test]
    fn test_bounding_box() {
        let bbox = BoundingBox::symmetric(1.0);
        assert_eq!(bbox.min, [-1.0, -1.0, -1.0]);
        assert_eq!(bbox.max, [1.0, 1.0, 1.0]);
    }

    #[test]
    fn test_field_descriptor() {
        let field = FieldDescriptor::new("x", DataType::Float64)
            .with_unit("meters")
            .with_range(0.0, 100.0)
            .with_description("X coordinate");

        assert_eq!(field.name, "x");
        assert_eq!(field.unit, "meters");
        assert_eq!(field.range, Some((0.0, 100.0)));
    }

    #[test]
    fn test_generated_data() {
        let mut columns = HashMap::new();
        columns.insert("x".to_string(), vec![1.0, 2.0, 3.0]);
        columns.insert("y".to_string(), vec![4.0, 5.0, 6.0]);

        let data = GeneratedData::new(columns)
            .with_bounds(BoundingBox::unit_cube())
            .with_metadata("generator", "test");

        assert_eq!(data.point_count, 3);
        assert!(data.bounds.is_some());
        assert_eq!(data.metadata.get("generator"), Some(&"test".to_string()));
    }
}
