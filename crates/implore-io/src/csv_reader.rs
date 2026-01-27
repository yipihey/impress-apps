//! CSV file reader with type inference

use crate::reader::{DataReader, IoError, IoResult};
use crate::schema::{ColumnDescriptor, ColumnType, DataColumn, DataSchema, DataSlice};
use std::collections::HashMap;
use std::fs::File;
use std::io::BufReader;
use std::path::Path;

/// CSV file reader
pub struct CsvReader {
    path: String,
    schema: DataSchema,
    metadata: HashMap<String, String>,
    delimiter: u8,
}

impl CsvReader {
    /// Open a CSV file
    pub fn open(path: &str) -> IoResult<Self> {
        Self::open_with_options(path, b',', true)
    }

    /// Open a CSV file with options
    pub fn open_with_options(path: &str, delimiter: u8, has_header: bool) -> IoResult<Self> {
        if !Path::new(path).exists() {
            return Err(IoError::FileNotFound(path.to_string()));
        }

        let file = File::open(path).map_err(|e| IoError::OpenFailed(e.to_string()))?;
        let mut reader = csv::ReaderBuilder::new()
            .delimiter(delimiter)
            .has_headers(has_header)
            .from_reader(BufReader::new(file));

        // Infer schema from first few rows
        let schema = Self::infer_schema(&mut reader, has_header)?;

        let mut metadata = HashMap::new();
        metadata.insert("format".to_string(), "CSV".to_string());
        metadata.insert("delimiter".to_string(), (delimiter as char).to_string());

        Ok(Self {
            path: path.to_string(),
            schema,
            metadata,
            delimiter,
        })
    }

    fn infer_schema(
        reader: &mut csv::Reader<BufReader<File>>,
        has_header: bool,
    ) -> IoResult<DataSchema> {
        let headers = if has_header {
            reader
                .headers()
                .map_err(|e| IoError::InvalidFormat(e.to_string()))?
                .iter()
                .map(|s| s.to_string())
                .collect::<Vec<_>>()
        } else {
            // Generate column names
            (0..10).map(|i| format!("col_{}", i)).collect()
        };

        // Read a few rows to infer types
        let mut sample_values: Vec<Vec<String>> = vec![Vec::new(); headers.len()];
        let mut num_records = 0;

        for result in reader.records() {
            let record = result.map_err(|e| IoError::InvalidFormat(e.to_string()))?;
            for (i, value) in record.iter().enumerate() {
                if i < sample_values.len() {
                    sample_values[i].push(value.to_string());
                }
            }
            num_records += 1;

            // Sample first 100 rows for type inference
            if num_records >= 100 {
                break;
            }
        }

        // Continue counting records
        for result in reader.records() {
            result.map_err(|e| IoError::InvalidFormat(e.to_string()))?;
            num_records += 1;
        }

        // Infer types
        let columns: Vec<ColumnDescriptor> = headers
            .into_iter()
            .enumerate()
            .map(|(i, name)| {
                let dtype = if i < sample_values.len() {
                    infer_type(&sample_values[i])
                } else {
                    ColumnType::String
                };
                ColumnDescriptor::new(name, dtype)
            })
            .collect();

        Ok(DataSchema::new(columns, num_records))
    }
}

impl DataReader for CsvReader {
    fn read_schema(&self) -> IoResult<DataSchema> {
        Ok(self.schema.clone())
    }

    fn read_column(&self, name: &str) -> IoResult<DataColumn> {
        let col_index = self
            .schema
            .column_index(name)
            .ok_or_else(|| IoError::ColumnNotFound(name.to_string()))?;

        let col_desc = &self.schema.columns[col_index];

        let file = File::open(&self.path).map_err(|e| IoError::OpenFailed(e.to_string()))?;
        let mut reader = csv::ReaderBuilder::new()
            .delimiter(self.delimiter)
            .has_headers(true)
            .from_reader(BufReader::new(file));

        let values: Vec<String> = reader
            .records()
            .filter_map(|r| r.ok())
            .filter_map(|record| record.get(col_index).map(|s| s.to_string()))
            .collect();

        Ok(parse_column(&values, col_desc.dtype))
    }

    fn read_range(&self, start: usize, end: usize) -> IoResult<DataSlice> {
        let file = File::open(&self.path).map_err(|e| IoError::OpenFailed(e.to_string()))?;
        let mut reader = csv::ReaderBuilder::new()
            .delimiter(self.delimiter)
            .has_headers(true)
            .from_reader(BufReader::new(file));

        let mut columns: Vec<Vec<String>> = vec![Vec::new(); self.schema.num_columns()];

        for (i, result) in reader.records().enumerate() {
            if i < start {
                continue;
            }
            if i >= end {
                break;
            }

            let record = result.map_err(|e| IoError::InvalidFormat(e.to_string()))?;
            for (j, value) in record.iter().enumerate() {
                if j < columns.len() {
                    columns[j].push(value.to_string());
                }
            }
        }

        let mut slice = DataSlice::new(start);
        for (i, col_desc) in self.schema.columns.iter().enumerate() {
            let data = parse_column(&columns[i], col_desc.dtype);
            slice.add_column(&col_desc.name, data);
        }

        Ok(slice)
    }

    fn metadata(&self) -> &HashMap<String, String> {
        &self.metadata
    }

    fn path(&self) -> Option<&str> {
        Some(&self.path)
    }

    fn format_name(&self) -> &'static str {
        "CSV"
    }
}

/// Infer column type from sample values
fn infer_type(values: &[String]) -> ColumnType {
    if values.is_empty() {
        return ColumnType::String;
    }

    let non_empty: Vec<&str> = values
        .iter()
        .map(|s| s.as_str())
        .filter(|s| !s.is_empty())
        .collect();
    if non_empty.is_empty() {
        return ColumnType::String;
    }

    // Try parsing as integers
    if non_empty.iter().all(|s| s.parse::<i64>().is_ok()) {
        return ColumnType::Int64;
    }

    // Try parsing as floats
    if non_empty.iter().all(|s| s.parse::<f64>().is_ok()) {
        return ColumnType::Float64;
    }

    // Try parsing as booleans
    if non_empty.iter().all(|s| {
        matches!(
            s.to_lowercase().as_str(),
            "true" | "false" | "yes" | "no" | "1" | "0"
        )
    }) {
        return ColumnType::Bool;
    }

    ColumnType::String
}

/// Parse column values into a DataColumn
fn parse_column(values: &[String], dtype: ColumnType) -> DataColumn {
    match dtype {
        ColumnType::Float32 => DataColumn::Float32(
            values
                .iter()
                .map(|s| s.parse().unwrap_or(f32::NAN))
                .collect(),
        ),
        ColumnType::Float64 => DataColumn::Float64(
            values
                .iter()
                .map(|s| s.parse().unwrap_or(f64::NAN))
                .collect(),
        ),
        ColumnType::Int32 => {
            DataColumn::Int32(values.iter().map(|s| s.parse().unwrap_or(0)).collect())
        }
        ColumnType::Int64 => {
            DataColumn::Int64(values.iter().map(|s| s.parse().unwrap_or(0)).collect())
        }
        ColumnType::Bool => DataColumn::Bool(
            values
                .iter()
                .map(|s| matches!(s.to_lowercase().as_str(), "true" | "yes" | "1"))
                .collect(),
        ),
        ColumnType::String | ColumnType::Unknown => {
            DataColumn::String(values.iter().cloned().collect())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_infer_type_int() {
        let values = vec!["1".to_string(), "2".to_string(), "3".to_string()];
        assert_eq!(infer_type(&values), ColumnType::Int64);
    }

    #[test]
    fn test_infer_type_float() {
        let values = vec!["1.5".to_string(), "2.7".to_string(), "3.14".to_string()];
        assert_eq!(infer_type(&values), ColumnType::Float64);
    }

    #[test]
    fn test_infer_type_bool() {
        let values = vec!["true".to_string(), "false".to_string(), "yes".to_string()];
        assert_eq!(infer_type(&values), ColumnType::Bool);
    }

    #[test]
    fn test_infer_type_string() {
        let values = vec!["hello".to_string(), "world".to_string()];
        assert_eq!(infer_type(&values), ColumnType::String);
    }
}
