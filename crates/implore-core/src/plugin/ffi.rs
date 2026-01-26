//! FFI bindings for the generator plugin system.
//!
//! This module provides UniFFI-compatible wrappers around the generator
//! registry and related types for use from Swift.

use std::sync::{Arc, RwLock};

use super::{
    GeneratedData, GeneratorCategory, GeneratorError, GeneratorMetadata, GeneratorParams,
    GeneratorRegistry,
};

/// FFI-safe representation of generated data.
///
/// Unlike `GeneratedData`, this uses column-major flattened arrays
/// which are more efficient for FFI transfer.
#[derive(Clone, Debug)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct GeneratedDataFfi {
    /// Names of the data columns in order
    pub column_names: Vec<String>,

    /// Flattened column-major data (all values for column 0, then column 1, etc.)
    pub data: Vec<f64>,

    /// Number of rows in the dataset
    pub row_count: u64,

    /// Minimum bounds for each dimension (if available)
    pub bounds_min: Option<Vec<f64>>,

    /// Maximum bounds for each dimension (if available)
    pub bounds_max: Option<Vec<f64>>,

    /// Additional metadata key-value pairs
    pub metadata: Vec<MetadataEntry>,
}

/// A key-value metadata entry for FFI.
#[derive(Clone, Debug)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct MetadataEntry {
    pub key: String,
    pub value: String,
}

impl From<GeneratedData> for GeneratedDataFfi {
    fn from(data: GeneratedData) -> Self {
        // Get column names in a deterministic order
        let mut column_names: Vec<String> = data.columns.keys().cloned().collect();
        column_names.sort();

        // Flatten data in column-major order
        let row_count = data.point_count as u64;
        let mut flat_data = Vec::with_capacity(column_names.len() * data.point_count);

        for name in &column_names {
            if let Some(col) = data.columns.get(name) {
                flat_data.extend(col.iter());
            }
        }

        // Convert bounds
        let (bounds_min, bounds_max) = if let Some(bounds) = data.bounds {
            (Some(bounds.min.to_vec()), Some(bounds.max.to_vec()))
        } else {
            (None, None)
        };

        // Convert metadata
        let metadata: Vec<MetadataEntry> = data
            .metadata
            .into_iter()
            .map(|(key, value)| MetadataEntry { key, value })
            .collect();

        GeneratedDataFfi {
            column_names,
            data: flat_data,
            row_count,
            bounds_min,
            bounds_max,
            metadata,
        }
    }
}

/// FFI-safe error type for generator operations.
#[derive(Clone, Debug)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum GeneratorErrorFfi {
    /// Generator with the given ID was not found
    NotFound { generator_id: String },

    /// A parameter was invalid
    InvalidParameter { name: String, reason: String },

    /// A required parameter was missing
    MissingParameter { name: String },

    /// Parameter type did not match expected type
    TypeMismatch { name: String, expected: String },

    /// Generation failed with an error message
    GenerationFailed { message: String },

    /// Expression parsing failed
    ExpressionError { message: String },

    /// The dataset is not from a generator
    NotGenerated,

    /// JSON serialization/deserialization error
    JsonError { message: String },

    /// Internal lock error (registry was poisoned)
    LockError { message: String },
}

impl std::fmt::Display for GeneratorErrorFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GeneratorErrorFfi::NotFound { generator_id } => {
                write!(f, "Generator not found: {}", generator_id)
            }
            GeneratorErrorFfi::InvalidParameter { name, reason } => {
                write!(f, "Invalid parameter '{}': {}", name, reason)
            }
            GeneratorErrorFfi::MissingParameter { name } => {
                write!(f, "Missing required parameter: {}", name)
            }
            GeneratorErrorFfi::TypeMismatch { name, expected } => {
                write!(f, "Type mismatch for '{}': expected {}", name, expected)
            }
            GeneratorErrorFfi::GenerationFailed { message } => {
                write!(f, "Generation failed: {}", message)
            }
            GeneratorErrorFfi::ExpressionError { message } => {
                write!(f, "Expression error: {}", message)
            }
            GeneratorErrorFfi::NotGenerated => {
                write!(f, "Dataset is not from a generator")
            }
            GeneratorErrorFfi::JsonError { message } => {
                write!(f, "JSON error: {}", message)
            }
            GeneratorErrorFfi::LockError { message } => {
                write!(f, "Lock error: {}", message)
            }
        }
    }
}

impl std::error::Error for GeneratorErrorFfi {}

impl From<GeneratorError> for GeneratorErrorFfi {
    fn from(err: GeneratorError) -> Self {
        match err {
            GeneratorError::NotFound(id) => GeneratorErrorFfi::NotFound { generator_id: id },
            GeneratorError::InvalidParameter { name, reason } => {
                GeneratorErrorFfi::InvalidParameter { name, reason }
            }
            GeneratorError::MissingParameter(name) => GeneratorErrorFfi::MissingParameter { name },
            GeneratorError::TypeMismatch { name, expected } => {
                GeneratorErrorFfi::TypeMismatch { name, expected }
            }
            GeneratorError::GenerationFailed(msg) => {
                GeneratorErrorFfi::GenerationFailed { message: msg }
            }
            GeneratorError::ExpressionError(msg) => {
                GeneratorErrorFfi::ExpressionError { message: msg }
            }
            GeneratorError::NotGenerated => GeneratorErrorFfi::NotGenerated,
        }
    }
}

/// Thread-safe handle to the generator registry.
///
/// This is the main entry point for Swift code to interact with
/// the data generator system.
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct GeneratorRegistryHandle {
    registry: Arc<RwLock<GeneratorRegistry>>,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl GeneratorRegistryHandle {
    /// Create a new registry handle with all built-in generators.
    #[cfg_attr(feature = "uniffi", uniffi::constructor)]
    pub fn new() -> Self {
        Self {
            registry: Arc::new(RwLock::new(GeneratorRegistry::new())),
        }
    }

    /// List all available generators.
    pub fn list_all(&self) -> Vec<GeneratorMetadata> {
        let registry = self
            .registry
            .read()
            .expect("generator registry lock poisoned");
        registry.list_all().into_iter().cloned().collect()
    }

    /// List generators in a specific category.
    pub fn list_by_category(&self, category: GeneratorCategory) -> Vec<GeneratorMetadata> {
        let registry = self
            .registry
            .read()
            .expect("generator registry lock poisoned");
        registry
            .list_by_category(category)
            .into_iter()
            .cloned()
            .collect()
    }

    /// Get all categories that have at least one generator.
    pub fn categories(&self) -> Vec<GeneratorCategory> {
        let registry = self
            .registry
            .read()
            .expect("generator registry lock poisoned");
        registry.categories()
    }

    /// Get metadata for a specific generator.
    pub fn get_metadata(&self, generator_id: String) -> Option<GeneratorMetadata> {
        let registry = self
            .registry
            .read()
            .expect("generator registry lock poisoned");
        registry.get(&generator_id).map(|g| g.metadata().clone())
    }

    /// Generate data using the specified generator and parameters.
    ///
    /// Parameters are passed as a JSON string for FFI simplicity.
    /// Returns the generated data or an error.
    pub fn generate(
        &self,
        generator_id: String,
        params_json: String,
    ) -> Result<GeneratedDataFfi, GeneratorErrorFfi> {
        let registry = self.registry.read().map_err(|e| GeneratorErrorFfi::LockError {
            message: format!("Failed to acquire registry lock: {}", e),
        })?;

        // Get the generator
        let generator = registry
            .get(&generator_id)
            .ok_or_else(|| GeneratorErrorFfi::NotFound {
                generator_id: generator_id.clone(),
            })?;

        // Parse parameters from JSON
        let mut params = if params_json.is_empty() || params_json == "{}" {
            GeneratorParams::new()
        } else {
            GeneratorParams::from_json(&params_json).map_err(|e| GeneratorErrorFfi::JsonError {
                message: e.to_string(),
            })?
        };

        // Fill in defaults for any missing parameters
        params.fill_defaults(&generator.metadata().parameters);

        // Validate parameters
        generator
            .validate_params(&params)
            .map_err(GeneratorErrorFfi::from)?;

        // Generate the data
        let data = generator
            .generate(&params)
            .map_err(GeneratorErrorFfi::from)?;

        Ok(data.into())
    }

    /// Get the default parameters for a generator as JSON.
    pub fn default_params_json(&self, generator_id: String) -> Result<String, GeneratorErrorFfi> {
        let registry = self.registry.read().map_err(|e| GeneratorErrorFfi::LockError {
            message: format!("Failed to acquire registry lock: {}", e),
        })?;

        let generator = registry
            .get(&generator_id)
            .ok_or_else(|| GeneratorErrorFfi::NotFound {
                generator_id: generator_id.clone(),
            })?;

        // Build params with all defaults
        let mut params = GeneratorParams::new();
        params.fill_defaults(&generator.metadata().parameters);

        params.to_json().map_err(|e| GeneratorErrorFfi::JsonError {
            message: e.to_string(),
        })
    }

    /// Search generators by name or description.
    pub fn search(&self, query: String) -> Vec<GeneratorMetadata> {
        let registry = self
            .registry
            .read()
            .expect("generator registry lock poisoned");
        registry.search(&query).into_iter().cloned().collect()
    }

    /// Get the total number of registered generators.
    pub fn count(&self) -> u32 {
        let registry = self
            .registry
            .read()
            .expect("generator registry lock poisoned");
        registry.len() as u32
    }
}

impl Default for GeneratorRegistryHandle {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_registry_handle_creation() {
        let handle = GeneratorRegistryHandle::new();
        assert!(handle.count() > 0);
    }

    #[test]
    fn test_list_all() {
        let handle = GeneratorRegistryHandle::new();
        let generators = handle.list_all();
        assert!(!generators.is_empty());
    }

    #[test]
    fn test_list_by_category() {
        let handle = GeneratorRegistryHandle::new();
        let noise_generators = handle.list_by_category(GeneratorCategory::Noise);
        assert!(!noise_generators.is_empty());

        for gen in noise_generators {
            assert_eq!(gen.category, GeneratorCategory::Noise);
        }
    }

    #[test]
    fn test_get_metadata() {
        let handle = GeneratorRegistryHandle::new();
        let metadata = handle.get_metadata("noise-perlin-2d".to_string());
        assert!(metadata.is_some());

        let meta = metadata.unwrap();
        assert_eq!(meta.id, "noise-perlin-2d");
        assert_eq!(meta.category, GeneratorCategory::Noise);
    }

    #[test]
    fn test_generate_with_defaults() {
        let handle = GeneratorRegistryHandle::new();

        // Generate with empty params (use all defaults)
        let result = handle.generate("noise-perlin-2d".to_string(), "{}".to_string());
        assert!(result.is_ok());

        let data = result.unwrap();
        assert!(!data.column_names.is_empty());
        assert!(data.row_count > 0);
    }

    #[test]
    fn test_generate_with_params() {
        let handle = GeneratorRegistryHandle::new();

        // Generate with custom resolution
        let params = r#"{"resolution":{"Int":64},"frequency":{"Float":2.0}}"#;
        let result = handle.generate("noise-perlin-2d".to_string(), params.to_string());
        assert!(result.is_ok());

        let data = result.unwrap();
        assert_eq!(data.row_count, 64 * 64); // 64x64 grid
    }

    #[test]
    fn test_default_params_json() {
        let handle = GeneratorRegistryHandle::new();

        let result = handle.default_params_json("noise-perlin-2d".to_string());
        assert!(result.is_ok());

        let json = result.unwrap();
        assert!(!json.is_empty());
        assert!(json.contains("resolution"));
    }

    #[test]
    fn test_search() {
        let handle = GeneratorRegistryHandle::new();

        let results = handle.search("perlin".to_string());
        assert!(!results.is_empty());

        let results = handle.search("mandelbrot".to_string());
        assert!(!results.is_empty());
    }

    #[test]
    fn test_generator_not_found() {
        let handle = GeneratorRegistryHandle::new();

        let result = handle.generate("nonexistent-generator".to_string(), "{}".to_string());
        assert!(result.is_err());

        match result.unwrap_err() {
            GeneratorErrorFfi::NotFound { generator_id } => {
                assert_eq!(generator_id, "nonexistent-generator");
            }
            _ => panic!("Expected NotFound error"),
        }
    }
}
