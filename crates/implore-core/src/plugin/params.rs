//! Parameter types for data generator configuration.
//!
//! This module defines the parameter specification system that allows generators
//! to declare their configurable parameters with types, defaults, and constraints.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use super::GeneratorError;

/// Specification for a generator parameter
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ParameterSpec {
    /// Internal parameter name (e.g., "resolution")
    pub name: String,

    /// Display label (e.g., "Resolution")
    pub label: String,

    /// Parameter type
    pub param_type: ParameterType,

    /// Default value
    pub default_value: ParameterValue,

    /// Optional constraints
    pub constraints: Option<ParameterConstraints>,

    /// Optional description/tooltip
    pub description: Option<String>,
}

/// Type of a parameter
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ParameterType {
    /// 64-bit floating point
    Float,

    /// 64-bit signed integer
    Int,

    /// Boolean
    Bool,

    /// String (for expressions, file paths, etc.)
    String,

    /// 2D vector [x, y]
    Vec2,

    /// 3D vector [x, y, z]
    Vec3,

    /// Range with min and max
    Range { min: f64, max: f64 },

    /// Choice from a list of options
    Choice { options: Vec<String> },

    /// Color (RGBA)
    Color,

    /// Polynomial coefficients for power spectrum
    Polynomial,
}

impl ParameterType {
    /// Get a human-readable type name
    pub fn type_name(&self) -> &'static str {
        match self {
            ParameterType::Float => "float",
            ParameterType::Int => "int",
            ParameterType::Bool => "bool",
            ParameterType::String => "string",
            ParameterType::Vec2 => "vec2",
            ParameterType::Vec3 => "vec3",
            ParameterType::Range { .. } => "range",
            ParameterType::Choice { .. } => "choice",
            ParameterType::Color => "color",
            ParameterType::Polynomial => "polynomial",
        }
    }

    /// Check if a value is compatible with this type
    pub fn is_compatible_with(&self, value: &ParameterValue) -> bool {
        match (self, value) {
            (ParameterType::Float, ParameterValue::Float(_)) => true,
            (ParameterType::Int, ParameterValue::Int(_)) => true,
            (ParameterType::Bool, ParameterValue::Bool(_)) => true,
            (ParameterType::String, ParameterValue::String(_)) => true,
            (ParameterType::Vec2, ParameterValue::Vec(v)) => v.len() == 2,
            (ParameterType::Vec3, ParameterValue::Vec(v)) => v.len() == 3,
            (ParameterType::Range { .. }, ParameterValue::Vec(v)) => v.len() == 2,
            (ParameterType::Choice { options }, ParameterValue::String(s)) => options.contains(s),
            (ParameterType::Color, ParameterValue::Vec(v)) => v.len() == 4,
            (ParameterType::Polynomial, ParameterValue::Vec(_)) => true,
            _ => false,
        }
    }
}

/// Runtime parameter value
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ParameterValue {
    Float(f64),
    Int(i64),
    Bool(bool),
    String(String),
    Vec(Vec<f64>),
}

impl ParameterValue {
    /// Try to extract as f64
    pub fn as_float(&self) -> Option<f64> {
        match self {
            ParameterValue::Float(v) => Some(*v),
            ParameterValue::Int(v) => Some(*v as f64),
            _ => None,
        }
    }

    /// Try to extract as i64
    pub fn as_int(&self) -> Option<i64> {
        match self {
            ParameterValue::Int(v) => Some(*v),
            ParameterValue::Float(v) => Some(*v as i64),
            _ => None,
        }
    }

    /// Try to extract as bool
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            ParameterValue::Bool(v) => Some(*v),
            _ => None,
        }
    }

    /// Try to extract as string
    pub fn as_string(&self) -> Option<&str> {
        match self {
            ParameterValue::String(v) => Some(v),
            _ => None,
        }
    }

    /// Try to extract as vec
    pub fn as_vec(&self) -> Option<&[f64]> {
        match self {
            ParameterValue::Vec(v) => Some(v),
            _ => None,
        }
    }
}

/// Constraints on parameter values
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ParameterConstraints {
    /// Minimum value (for numeric types)
    pub min: Option<f64>,

    /// Maximum value (for numeric types)
    pub max: Option<f64>,

    /// Step size for UI sliders
    pub step: Option<f64>,

    /// Whether the parameter must be a positive integer
    pub positive: bool,

    /// Whether the parameter must be a power of 2
    pub power_of_two: bool,
}

impl ParameterConstraints {
    pub fn none() -> Self {
        Self {
            min: None,
            max: None,
            step: None,
            positive: false,
            power_of_two: false,
        }
    }

    pub fn range(min: f64, max: f64) -> Self {
        Self {
            min: Some(min),
            max: Some(max),
            step: None,
            positive: false,
            power_of_two: false,
        }
    }

    pub fn positive() -> Self {
        Self {
            min: Some(0.0),
            max: None,
            step: None,
            positive: true,
            power_of_two: false,
        }
    }

    pub fn with_step(mut self, step: f64) -> Self {
        self.step = Some(step);
        self
    }

    pub fn power_of_two(mut self) -> Self {
        self.power_of_two = true;
        self
    }

    /// Validate a value against these constraints
    pub fn validate(&self, value: &ParameterValue) -> Result<(), String> {
        if let Some(v) = value.as_float() {
            if let Some(min) = self.min {
                if v < min {
                    return Err(format!("Value {} is below minimum {}", v, min));
                }
            }
            if let Some(max) = self.max {
                if v > max {
                    return Err(format!("Value {} is above maximum {}", v, max));
                }
            }
            if self.positive && v <= 0.0 {
                return Err("Value must be positive".to_string());
            }
        }

        if self.power_of_two {
            if let Some(v) = value.as_int() {
                if v <= 0 || (v & (v - 1)) != 0 {
                    return Err(format!("{} is not a power of 2", v));
                }
            }
        }

        Ok(())
    }
}

/// Container for runtime parameter values
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct GeneratorParams {
    values: HashMap<String, ParameterValue>,
}

impl GeneratorParams {
    pub fn new() -> Self {
        Self {
            values: HashMap::new(),
        }
    }

    /// Set a float parameter
    pub fn set_float(&mut self, name: impl Into<String>, value: f64) {
        self.values
            .insert(name.into(), ParameterValue::Float(value));
    }

    /// Set an integer parameter
    pub fn set_int(&mut self, name: impl Into<String>, value: i64) {
        self.values.insert(name.into(), ParameterValue::Int(value));
    }

    /// Set a boolean parameter
    pub fn set_bool(&mut self, name: impl Into<String>, value: bool) {
        self.values.insert(name.into(), ParameterValue::Bool(value));
    }

    /// Set a string parameter
    pub fn set_string(&mut self, name: impl Into<String>, value: impl Into<String>) {
        self.values
            .insert(name.into(), ParameterValue::String(value.into()));
    }

    /// Set a vector parameter
    pub fn set_vec(&mut self, name: impl Into<String>, value: Vec<f64>) {
        self.values.insert(name.into(), ParameterValue::Vec(value));
    }

    /// Get a parameter value by name
    pub fn get(&self, name: &str) -> Option<&ParameterValue> {
        self.values.get(name)
    }

    /// Get a float parameter with optional default
    pub fn get_float(&self, name: &str) -> Option<f64> {
        self.values.get(name).and_then(|v| v.as_float())
    }

    /// Get a float parameter or return a default
    pub fn get_float_or(&self, name: &str, default: f64) -> f64 {
        self.get_float(name).unwrap_or(default)
    }

    /// Get an integer parameter with optional default
    pub fn get_int(&self, name: &str) -> Option<i64> {
        self.values.get(name).and_then(|v| v.as_int())
    }

    /// Get an integer parameter or return a default
    pub fn get_int_or(&self, name: &str, default: i64) -> i64 {
        self.get_int(name).unwrap_or(default)
    }

    /// Get a boolean parameter
    pub fn get_bool(&self, name: &str) -> Option<bool> {
        self.values.get(name).and_then(|v| v.as_bool())
    }

    /// Get a boolean parameter or return a default
    pub fn get_bool_or(&self, name: &str, default: bool) -> bool {
        self.get_bool(name).unwrap_or(default)
    }

    /// Get a string parameter
    pub fn get_string(&self, name: &str) -> Option<&str> {
        self.values.get(name).and_then(|v| v.as_string())
    }

    /// Get a string parameter or return a default
    pub fn get_string_or<'a>(&'a self, name: &str, default: &'a str) -> &'a str {
        self.get_string(name).unwrap_or(default)
    }

    /// Get a vector parameter
    pub fn get_vec(&self, name: &str) -> Option<&[f64]> {
        self.values.get(name).and_then(|v| v.as_vec())
    }

    /// Fill in missing parameters with defaults from specs
    pub fn fill_defaults(&mut self, specs: &[ParameterSpec]) {
        for spec in specs {
            if !self.values.contains_key(&spec.name) {
                self.values
                    .insert(spec.name.clone(), spec.default_value.clone());
            }
        }
    }

    /// Validate parameters against specs
    pub fn validate(&self, specs: &[ParameterSpec]) -> Result<(), GeneratorError> {
        for spec in specs {
            if let Some(value) = self.values.get(&spec.name) {
                // Check type compatibility
                if !spec.param_type.is_compatible_with(value) {
                    return Err(GeneratorError::TypeMismatch {
                        name: spec.name.clone(),
                        expected: spec.param_type.type_name().to_string(),
                    });
                }

                // Check constraints
                if let Some(constraints) = &spec.constraints {
                    constraints
                        .validate(value)
                        .map_err(|reason| GeneratorError::InvalidParameter {
                            name: spec.name.clone(),
                            reason,
                        })?;
                }
            }
        }
        Ok(())
    }

    /// Serialize to JSON
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(&self.values)
    }

    /// Deserialize from JSON
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        let values = serde_json::from_str(json)?;
        Ok(Self { values })
    }
}

impl ParameterSpec {
    /// Create a new float parameter spec
    pub fn float(
        name: impl Into<String>,
        label: impl Into<String>,
        default: f64,
    ) -> Self {
        Self {
            name: name.into(),
            label: label.into(),
            param_type: ParameterType::Float,
            default_value: ParameterValue::Float(default),
            constraints: None,
            description: None,
        }
    }

    /// Create a new integer parameter spec
    pub fn int(name: impl Into<String>, label: impl Into<String>, default: i64) -> Self {
        Self {
            name: name.into(),
            label: label.into(),
            param_type: ParameterType::Int,
            default_value: ParameterValue::Int(default),
            constraints: None,
            description: None,
        }
    }

    /// Create a new boolean parameter spec
    pub fn bool(name: impl Into<String>, label: impl Into<String>, default: bool) -> Self {
        Self {
            name: name.into(),
            label: label.into(),
            param_type: ParameterType::Bool,
            default_value: ParameterValue::Bool(default),
            constraints: None,
            description: None,
        }
    }

    /// Create a new string parameter spec
    pub fn string(
        name: impl Into<String>,
        label: impl Into<String>,
        default: impl Into<String>,
    ) -> Self {
        Self {
            name: name.into(),
            label: label.into(),
            param_type: ParameterType::String,
            default_value: ParameterValue::String(default.into()),
            constraints: None,
            description: None,
        }
    }

    /// Create a new choice parameter spec
    pub fn choice(
        name: impl Into<String>,
        label: impl Into<String>,
        options: Vec<String>,
        default: impl Into<String>,
    ) -> Self {
        Self {
            name: name.into(),
            label: label.into(),
            param_type: ParameterType::Choice { options },
            default_value: ParameterValue::String(default.into()),
            constraints: None,
            description: None,
        }
    }

    /// Add constraints to this parameter spec
    pub fn with_constraints(mut self, constraints: ParameterConstraints) -> Self {
        self.constraints = Some(constraints);
        self
    }

    /// Add a description to this parameter spec
    pub fn with_description(mut self, description: impl Into<String>) -> Self {
        self.description = Some(description.into());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parameter_value_conversions() {
        assert_eq!(ParameterValue::Float(3.14).as_float(), Some(3.14));
        assert_eq!(ParameterValue::Int(42).as_int(), Some(42));
        assert_eq!(ParameterValue::Int(42).as_float(), Some(42.0));
        assert_eq!(ParameterValue::Bool(true).as_bool(), Some(true));
        assert_eq!(
            ParameterValue::String("test".to_string()).as_string(),
            Some("test")
        );
    }

    #[test]
    fn test_generator_params() {
        let mut params = GeneratorParams::new();
        params.set_float("frequency", 4.0);
        params.set_int("resolution", 256);
        params.set_bool("animate", true);

        assert_eq!(params.get_float("frequency"), Some(4.0));
        assert_eq!(params.get_int("resolution"), Some(256));
        assert_eq!(params.get_bool("animate"), Some(true));
        assert_eq!(params.get_float_or("missing", 1.0), 1.0);
    }

    #[test]
    fn test_constraints_validation() {
        let constraints = ParameterConstraints::range(0.0, 100.0);

        assert!(constraints.validate(&ParameterValue::Float(50.0)).is_ok());
        assert!(constraints.validate(&ParameterValue::Float(-1.0)).is_err());
        assert!(constraints.validate(&ParameterValue::Float(101.0)).is_err());
    }

    #[test]
    fn test_power_of_two_constraint() {
        let constraints = ParameterConstraints::positive().power_of_two();

        assert!(constraints.validate(&ParameterValue::Int(256)).is_ok());
        assert!(constraints.validate(&ParameterValue::Int(128)).is_ok());
        assert!(constraints.validate(&ParameterValue::Int(100)).is_err());
        assert!(constraints.validate(&ParameterValue::Int(0)).is_err());
    }

    #[test]
    fn test_type_compatibility() {
        assert!(ParameterType::Float.is_compatible_with(&ParameterValue::Float(1.0)));
        assert!(ParameterType::Int.is_compatible_with(&ParameterValue::Int(1)));
        assert!(!ParameterType::Float.is_compatible_with(&ParameterValue::Int(1)));
        assert!(ParameterType::Vec2.is_compatible_with(&ParameterValue::Vec(vec![1.0, 2.0])));
        assert!(!ParameterType::Vec2.is_compatible_with(&ParameterValue::Vec(vec![1.0])));
    }

    #[test]
    fn test_fill_defaults() {
        let specs = vec![
            ParameterSpec::float("frequency", "Frequency", 4.0),
            ParameterSpec::int("resolution", "Resolution", 256),
        ];

        let mut params = GeneratorParams::new();
        params.set_float("frequency", 8.0);
        params.fill_defaults(&specs);

        assert_eq!(params.get_float("frequency"), Some(8.0)); // Keep existing
        assert_eq!(params.get_int("resolution"), Some(256)); // Fill default
    }

    #[test]
    fn test_json_serialization() {
        let mut params = GeneratorParams::new();
        params.set_float("frequency", 4.0);
        params.set_int("resolution", 256);

        let json = params.to_json().unwrap();
        let restored = GeneratorParams::from_json(&json).unwrap();

        assert_eq!(restored.get_float("frequency"), Some(4.0));
        assert_eq!(restored.get_int("resolution"), Some(256));
    }
}
