//! Apache Parquet file reader.
//!
//! Real implementation over the `parquet` crate's standalone row API (no
//! arrow dependency): schema from the file metadata, values via row
//! iteration. Row iteration is not the fastest way to read Parquet, but it is
//! simple, allocation-bounded, and plenty for plot-sized datasets; a
//! column-chunk fast path is a later optimization.

use std::collections::HashMap;
use std::fs::File;
use std::path::Path;

use parquet::basic::Type as PhysicalType;
use parquet::file::reader::{FileReader, SerializedFileReader};
use parquet::record::Field;

use crate::reader::{DataReader, IoError, IoResult};
use crate::schema::{ColumnDescriptor, ColumnType, DataColumn, DataSchema, DataSlice};

/// Parquet file reader.
pub struct ParquetReader {
    path: String,
    metadata: HashMap<String, String>,
}

impl ParquetReader {
    /// Open a Parquet file (validates it parses).
    pub fn open(path: impl AsRef<Path>) -> IoResult<Self> {
        let path_str = path.as_ref().to_string_lossy().to_string();
        // Validate up front so open_file() errors early on non-Parquet input.
        let _ = Self::file_reader(&path_str)?;
        let mut metadata = HashMap::new();
        metadata.insert("format".to_string(), "parquet".to_string());
        Ok(Self {
            path: path_str,
            metadata,
        })
    }

    fn file_reader(path: &str) -> IoResult<SerializedFileReader<File>> {
        let file = File::open(path).map_err(|e| IoError::Io(format!("open {path}: {e}")))?;
        SerializedFileReader::new(file)
            .map_err(|e| IoError::InvalidFormat(format!("parquet parse: {e}")))
    }

    fn column_type(physical: PhysicalType) -> ColumnType {
        match physical {
            PhysicalType::FLOAT => ColumnType::Float32,
            PhysicalType::DOUBLE => ColumnType::Float64,
            PhysicalType::INT32 => ColumnType::Int32,
            PhysicalType::INT64 => ColumnType::Int64,
            PhysicalType::BOOLEAN => ColumnType::Bool,
            PhysicalType::BYTE_ARRAY => ColumnType::String,
            _ => ColumnType::Unknown,
        }
    }

    /// Coerce a row Field to f64 (numeric fields only).
    fn field_f64(field: &Field) -> Option<f64> {
        match field {
            Field::Double(v) => Some(*v),
            Field::Float(v) => Some(*v as f64),
            Field::Int(v) => Some(*v as f64),
            Field::Long(v) => Some(*v as f64),
            Field::Short(v) => Some(*v as f64),
            Field::Byte(v) => Some(*v as f64),
            Field::UInt(v) => Some(*v as f64),
            Field::ULong(v) => Some(*v as f64),
            Field::UShort(v) => Some(*v as f64),
            Field::UByte(v) => Some(*v as f64),
            _ => None,
        }
    }
}

impl DataReader for ParquetReader {
    fn read_schema(&self) -> IoResult<DataSchema> {
        let reader = Self::file_reader(&self.path)?;
        let meta = reader.metadata().file_metadata();
        let columns = meta
            .schema_descr()
            .columns()
            .iter()
            .map(|c| ColumnDescriptor::new(c.name(), Self::column_type(c.physical_type())))
            .collect();
        Ok(DataSchema::new(columns, meta.num_rows().max(0) as usize))
    }

    fn read_column(&self, name: &str) -> IoResult<DataColumn> {
        let schema = self.read_schema()?;
        let descriptor = schema
            .columns
            .iter()
            .find(|c| c.name == name)
            .ok_or_else(|| IoError::ColumnNotFound(name.to_string()))?;
        let dtype = descriptor.dtype;

        let reader = Self::file_reader(&self.path)?;
        let rows = reader
            .get_row_iter(None)
            .map_err(|e| IoError::InvalidFormat(format!("parquet rows: {e}")))?;

        // Collect by declared type; numeric values coerce through f64.
        let mut f64s: Vec<f64> = Vec::new();
        let mut bools: Vec<bool> = Vec::new();
        let mut strings: Vec<String> = Vec::new();
        for row in rows {
            let row = row.map_err(|e| IoError::InvalidFormat(format!("parquet row: {e}")))?;
            for (col_name, field) in row.get_column_iter() {
                if col_name != name {
                    continue;
                }
                match dtype {
                    ColumnType::Bool => bools.push(matches!(field, Field::Bool(true))),
                    ColumnType::String => strings.push(match field {
                        Field::Str(s) => s.clone(),
                        other => format!("{other}"),
                    }),
                    _ => f64s.push(Self::field_f64(field).unwrap_or(f64::NAN)),
                }
            }
        }

        Ok(match dtype {
            ColumnType::Bool => DataColumn::Bool(bools),
            ColumnType::String => DataColumn::String(strings),
            ColumnType::Float32 => {
                DataColumn::Float32(f64s.into_iter().map(|v| v as f32).collect())
            }
            ColumnType::Int32 => DataColumn::Int32(f64s.into_iter().map(|v| v as i32).collect()),
            ColumnType::Int64 => DataColumn::Int64(f64s.into_iter().map(|v| v as i64).collect()),
            _ => DataColumn::Float64(f64s),
        })
    }

    fn read_range(&self, start: usize, end: usize) -> IoResult<DataSlice> {
        let schema = self.read_schema()?;
        let mut columns: HashMap<String, DataColumn> = HashMap::new();
        // Simple per-column implementation; fine for plot-sized data.
        for descriptor in &schema.columns {
            let full = self.read_column(&descriptor.name)?;
            let clamped_end = end.min(schema.num_records);
            let clamped_start = start.min(clamped_end);
            let sliced = match full {
                DataColumn::Float32(v) => {
                    DataColumn::Float32(v[clamped_start..clamped_end].to_vec())
                }
                DataColumn::Float64(v) => {
                    DataColumn::Float64(v[clamped_start..clamped_end].to_vec())
                }
                DataColumn::Int32(v) => DataColumn::Int32(v[clamped_start..clamped_end].to_vec()),
                DataColumn::Int64(v) => DataColumn::Int64(v[clamped_start..clamped_end].to_vec()),
                DataColumn::Bool(v) => DataColumn::Bool(v[clamped_start..clamped_end].to_vec()),
                DataColumn::String(v) => DataColumn::String(v[clamped_start..clamped_end].to_vec()),
            };
            columns.insert(descriptor.name.clone(), sliced);
        }
        let num_rows = end.min(schema.num_records).saturating_sub(start);
        Ok(DataSlice {
            columns,
            start,
            num_rows,
        })
    }

    fn metadata(&self) -> &HashMap<String, String> {
        &self.metadata
    }

    fn path(&self) -> Option<&str> {
        Some(&self.path)
    }

    fn format_name(&self) -> &'static str {
        "parquet"
    }
}
