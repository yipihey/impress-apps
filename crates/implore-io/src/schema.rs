//! Schema and column types for data representation

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Schema describing the structure of a dataset
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DataSchema {
    /// Column descriptors
    pub columns: Vec<ColumnDescriptor>,

    /// Number of records
    pub num_records: usize,

    /// Additional metadata
    pub metadata: HashMap<String, String>,
}

impl DataSchema {
    /// Create a new schema
    pub fn new(columns: Vec<ColumnDescriptor>, num_records: usize) -> Self {
        Self {
            columns,
            num_records,
            metadata: HashMap::new(),
        }
    }

    /// Get a column by name
    pub fn column(&self, name: &str) -> Option<&ColumnDescriptor> {
        self.columns.iter().find(|c| c.name == name)
    }

    /// Get column index by name
    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|c| c.name == name)
    }

    /// Get column names
    pub fn column_names(&self) -> Vec<&str> {
        self.columns.iter().map(|c| c.name.as_str()).collect()
    }

    /// Number of columns
    pub fn num_columns(&self) -> usize {
        self.columns.len()
    }
}

/// Descriptor for a column
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColumnDescriptor {
    /// Column name
    pub name: String,

    /// Data type
    pub dtype: ColumnType,

    /// Physical units (if known)
    pub unit: Option<String>,

    /// Description
    pub description: Option<String>,

    /// Whether the column can contain nulls
    pub nullable: bool,
}

impl ColumnDescriptor {
    /// Create a new column descriptor
    pub fn new(name: impl Into<String>, dtype: ColumnType) -> Self {
        Self {
            name: name.into(),
            dtype,
            unit: None,
            description: None,
            nullable: true,
        }
    }

    /// Set the unit
    pub fn with_unit(mut self, unit: impl Into<String>) -> Self {
        self.unit = Some(unit.into());
        self
    }

    /// Set the description
    pub fn with_description(mut self, desc: impl Into<String>) -> Self {
        self.description = Some(desc.into());
        self
    }

    /// Set nullable
    pub fn with_nullable(mut self, nullable: bool) -> Self {
        self.nullable = nullable;
        self
    }
}

/// Column data type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ColumnType {
    Float32,
    Float64,
    Int32,
    Int64,
    Bool,
    String,
    Unknown,
}

impl ColumnType {
    /// Size in bytes for fixed-width types
    pub fn byte_size(&self) -> Option<usize> {
        match self {
            ColumnType::Float32 => Some(4),
            ColumnType::Float64 => Some(8),
            ColumnType::Int32 => Some(4),
            ColumnType::Int64 => Some(8),
            ColumnType::Bool => Some(1),
            ColumnType::String | ColumnType::Unknown => None,
        }
    }

    /// Check if this is a numeric type
    pub fn is_numeric(&self) -> bool {
        matches!(
            self,
            ColumnType::Float32 | ColumnType::Float64 | ColumnType::Int32 | ColumnType::Int64
        )
    }
}

/// A column of data
#[derive(Debug, Clone)]
pub enum DataColumn {
    Float32(Vec<f32>),
    Float64(Vec<f64>),
    Int32(Vec<i32>),
    Int64(Vec<i64>),
    Bool(Vec<bool>),
    String(Vec<String>),
}

impl DataColumn {
    /// Get the column type
    pub fn dtype(&self) -> ColumnType {
        match self {
            DataColumn::Float32(_) => ColumnType::Float32,
            DataColumn::Float64(_) => ColumnType::Float64,
            DataColumn::Int32(_) => ColumnType::Int32,
            DataColumn::Int64(_) => ColumnType::Int64,
            DataColumn::Bool(_) => ColumnType::Bool,
            DataColumn::String(_) => ColumnType::String,
        }
    }

    /// Get the number of elements
    pub fn len(&self) -> usize {
        match self {
            DataColumn::Float32(v) => v.len(),
            DataColumn::Float64(v) => v.len(),
            DataColumn::Int32(v) => v.len(),
            DataColumn::Int64(v) => v.len(),
            DataColumn::Bool(v) => v.len(),
            DataColumn::String(v) => v.len(),
        }
    }

    /// Check if the column is empty
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Convert to f64 (for numeric types)
    pub fn to_f64(&self) -> Option<Vec<f64>> {
        match self {
            DataColumn::Float32(v) => Some(v.iter().map(|&x| x as f64).collect()),
            DataColumn::Float64(v) => Some(v.clone()),
            DataColumn::Int32(v) => Some(v.iter().map(|&x| x as f64).collect()),
            DataColumn::Int64(v) => Some(v.iter().map(|&x| x as f64).collect()),
            _ => None,
        }
    }

    /// Get a slice as f64 values
    pub fn slice_f64(&self, start: usize, end: usize) -> Option<Vec<f64>> {
        let end = end.min(self.len());
        if start >= end {
            return Some(Vec::new());
        }

        match self {
            DataColumn::Float32(v) => Some(v[start..end].iter().map(|&x| x as f64).collect()),
            DataColumn::Float64(v) => Some(v[start..end].to_vec()),
            DataColumn::Int32(v) => Some(v[start..end].iter().map(|&x| x as f64).collect()),
            DataColumn::Int64(v) => Some(v[start..end].iter().map(|&x| x as f64).collect()),
            _ => None,
        }
    }
}

/// A slice of rows from a dataset
#[derive(Debug, Clone)]
pub struct DataSlice {
    /// Columns of data
    pub columns: HashMap<String, DataColumn>,

    /// Starting row index
    pub start: usize,

    /// Number of rows
    pub num_rows: usize,
}

impl DataSlice {
    /// Create a new data slice
    pub fn new(start: usize) -> Self {
        Self {
            columns: HashMap::new(),
            start,
            num_rows: 0,
        }
    }

    /// Add a column
    pub fn add_column(&mut self, name: impl Into<String>, data: DataColumn) {
        if self.columns.is_empty() {
            self.num_rows = data.len();
        }
        self.columns.insert(name.into(), data);
    }

    /// Get a column by name
    pub fn column(&self, name: &str) -> Option<&DataColumn> {
        self.columns.get(name)
    }

    /// Get column names
    pub fn column_names(&self) -> Vec<&str> {
        self.columns.keys().map(|s| s.as_str()).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_schema_column_lookup() {
        let schema = DataSchema::new(
            vec![
                ColumnDescriptor::new("x", ColumnType::Float64),
                ColumnDescriptor::new("y", ColumnType::Float64),
            ],
            100,
        );

        assert_eq!(schema.column_index("x"), Some(0));
        assert_eq!(schema.column_index("y"), Some(1));
        assert_eq!(schema.column_index("z"), None);
    }

    #[test]
    fn test_data_column_conversion() {
        let col = DataColumn::Int32(vec![1, 2, 3, 4, 5]);
        let f64_values = col.to_f64().unwrap();
        assert_eq!(f64_values, vec![1.0, 2.0, 3.0, 4.0, 5.0]);
    }

    #[test]
    fn test_column_type_properties() {
        assert!(ColumnType::Float64.is_numeric());
        assert!(ColumnType::Int32.is_numeric());
        assert!(!ColumnType::String.is_numeric());
        assert_eq!(ColumnType::Float64.byte_size(), Some(8));
    }
}
