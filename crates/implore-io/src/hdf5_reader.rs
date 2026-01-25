//! HDF5 file reader for scientific datasets
//!
//! HDF5 is the primary format for large scientific datasets.
//! This reader supports:
//! - Reading datasets by path within the file
//! - Automatic type detection and conversion
//! - Chunked reading for memory efficiency
//! - Attribute extraction for metadata

#[cfg(feature = "hdf5")]
use hdf5::{File as Hdf5File, Dataset as Hdf5Dataset, types::TypeDescriptor};

use crate::reader::{DataReader, IoError, IoResult};
use crate::schema::{ColumnDescriptor, ColumnType, DataColumn, DataSchema, DataSlice};
use std::collections::HashMap;
use std::path::Path;

/// HDF5 file reader
#[cfg(feature = "hdf5")]
pub struct Hdf5Reader {
    path: String,
    dataset_path: String,
    schema: DataSchema,
    metadata: HashMap<String, String>,
}

#[cfg(feature = "hdf5")]
impl Hdf5Reader {
    /// Open an HDF5 file and read a specific dataset
    pub fn open(path: &str, dataset_path: &str) -> IoResult<Self> {
        if !Path::new(path).exists() {
            return Err(IoError::FileNotFound(path.to_string()));
        }

        let file = Hdf5File::open(path).map_err(|e| IoError::OpenFailed(e.to_string()))?;

        let dataset = file
            .dataset(dataset_path)
            .map_err(|e| IoError::DatasetNotFound(format!("{}: {}", dataset_path, e)))?;

        let schema = Self::infer_schema(&dataset, &file, dataset_path)?;

        let mut metadata = HashMap::new();
        metadata.insert("format".to_string(), "HDF5".to_string());
        metadata.insert("dataset_path".to_string(), dataset_path.to_string());

        // Extract file-level attributes
        if let Ok(attrs) = file.attr_names() {
            for attr_name in attrs {
                if let Ok(attr) = file.attr(&attr_name) {
                    if let Ok(value) = attr.read_scalar::<hdf5::types::VarLenUnicode>() {
                        metadata.insert(attr_name.clone(), value.to_string());
                    }
                }
            }
        }

        Ok(Self {
            path: path.to_string(),
            dataset_path: dataset_path.to_string(),
            schema,
            metadata,
        })
    }

    /// List all datasets in an HDF5 file
    pub fn list_datasets(path: &str) -> IoResult<Vec<String>> {
        let file = Hdf5File::open(path).map_err(|e| IoError::OpenFailed(e.to_string()))?;
        let mut datasets = Vec::new();
        Self::collect_datasets(&file, "/", &mut datasets)?;
        Ok(datasets)
    }

    fn collect_datasets(
        group: &hdf5::Group,
        prefix: &str,
        datasets: &mut Vec<String>,
    ) -> IoResult<()> {
        for name in group.member_names().map_err(|e| IoError::ReadFailed(e.to_string()))? {
            let path = if prefix == "/" {
                format!("/{}", name)
            } else {
                format!("{}/{}", prefix, name)
            };

            if group.dataset(&name).is_ok() {
                datasets.push(path);
            } else if let Ok(subgroup) = group.group(&name) {
                Self::collect_datasets(&subgroup, &path, datasets)?;
            }
        }
        Ok(())
    }

    fn infer_schema(
        dataset: &Hdf5Dataset,
        _file: &Hdf5File,
        dataset_path: &str,
    ) -> IoResult<DataSchema> {
        let shape = dataset.shape();
        let dtype = dataset.dtype().map_err(|e| IoError::InvalidFormat(e.to_string()))?;

        // Handle different dataset shapes
        let (num_records, columns) = match shape.len() {
            1 => {
                // 1D array - single column
                let col_type = Self::hdf5_type_to_column_type(&dtype);
                let col = ColumnDescriptor::new(
                    dataset_path.split('/').last().unwrap_or("data"),
                    col_type,
                );
                (shape[0], vec![col])
            }
            2 => {
                // 2D array - multiple columns
                let num_cols = shape[1];
                let col_type = Self::hdf5_type_to_column_type(&dtype);

                let columns: Vec<ColumnDescriptor> = (0..num_cols)
                    .map(|i| ColumnDescriptor::new(format!("col_{}", i), col_type))
                    .collect();

                (shape[0], columns)
            }
            _ => {
                return Err(IoError::InvalidFormat(format!(
                    "Unsupported dataset shape: {:?}",
                    shape
                )));
            }
        };

        // Try to get column names from attributes
        let mut schema = DataSchema::new(columns, num_records);

        // Add dataset attributes to metadata
        if let Ok(attr_names) = dataset.attr_names() {
            for attr_name in attr_names {
                if let Ok(attr) = dataset.attr(&attr_name) {
                    if let Ok(value) = attr.read_scalar::<hdf5::types::VarLenUnicode>() {
                        schema.metadata.insert(attr_name, value.to_string());
                    }
                }
            }
        }

        Ok(schema)
    }

    fn hdf5_type_to_column_type(dtype: &hdf5::Datatype) -> ColumnType {
        match dtype.to_descriptor() {
            Ok(TypeDescriptor::Float(hdf5::types::FloatSize::U4)) => ColumnType::Float32,
            Ok(TypeDescriptor::Float(hdf5::types::FloatSize::U8)) => ColumnType::Float64,
            Ok(TypeDescriptor::Integer(hdf5::types::IntSize::U4)) => ColumnType::Int32,
            Ok(TypeDescriptor::Integer(hdf5::types::IntSize::U8)) => ColumnType::Int64,
            Ok(TypeDescriptor::Boolean) => ColumnType::Bool,
            Ok(TypeDescriptor::VarLenAscii) | Ok(TypeDescriptor::VarLenUnicode) => {
                ColumnType::String
            }
            _ => ColumnType::Unknown,
        }
    }

    fn read_dataset_column(&self, col_index: usize) -> IoResult<DataColumn> {
        let file = Hdf5File::open(&self.path).map_err(|e| IoError::OpenFailed(e.to_string()))?;
        let dataset = file
            .dataset(&self.dataset_path)
            .map_err(|e| IoError::DatasetNotFound(e.to_string()))?;

        let shape = dataset.shape();
        let col_type = self.schema.columns.get(col_index)
            .map(|c| c.dtype)
            .unwrap_or(ColumnType::Float64);

        match shape.len() {
            1 => {
                // 1D dataset
                Self::read_1d_column(&dataset, col_type)
            }
            2 => {
                // 2D dataset - read specific column
                Self::read_2d_column(&dataset, col_index, col_type)
            }
            _ => Err(IoError::InvalidFormat("Unsupported shape".to_string())),
        }
    }

    fn read_1d_column(dataset: &Hdf5Dataset, col_type: ColumnType) -> IoResult<DataColumn> {
        match col_type {
            ColumnType::Float32 => {
                let data: Vec<f32> = dataset
                    .read_1d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?
                    .to_vec();
                Ok(DataColumn::Float32(data))
            }
            ColumnType::Float64 => {
                let data: Vec<f64> = dataset
                    .read_1d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?
                    .to_vec();
                Ok(DataColumn::Float64(data))
            }
            ColumnType::Int32 => {
                let data: Vec<i32> = dataset
                    .read_1d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?
                    .to_vec();
                Ok(DataColumn::Int32(data))
            }
            ColumnType::Int64 => {
                let data: Vec<i64> = dataset
                    .read_1d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?
                    .to_vec();
                Ok(DataColumn::Int64(data))
            }
            _ => {
                // Default to f64
                let data: Vec<f64> = dataset
                    .read_1d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?
                    .to_vec();
                Ok(DataColumn::Float64(data))
            }
        }
    }

    fn read_2d_column(
        dataset: &Hdf5Dataset,
        col_index: usize,
        col_type: ColumnType,
    ) -> IoResult<DataColumn> {
        // Read the entire 2D array and extract the column
        // For large datasets, this should use slicing instead
        match col_type {
            ColumnType::Float64 | ColumnType::Unknown => {
                let data: ndarray::Array2<f64> = dataset
                    .read_2d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?;
                let col_data: Vec<f64> = data.column(col_index).to_vec();
                Ok(DataColumn::Float64(col_data))
            }
            ColumnType::Float32 => {
                let data: ndarray::Array2<f32> = dataset
                    .read_2d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?;
                let col_data: Vec<f32> = data.column(col_index).to_vec();
                Ok(DataColumn::Float32(col_data))
            }
            ColumnType::Int64 => {
                let data: ndarray::Array2<i64> = dataset
                    .read_2d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?;
                let col_data: Vec<i64> = data.column(col_index).to_vec();
                Ok(DataColumn::Int64(col_data))
            }
            ColumnType::Int32 => {
                let data: ndarray::Array2<i32> = dataset
                    .read_2d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?;
                let col_data: Vec<i32> = data.column(col_index).to_vec();
                Ok(DataColumn::Int32(col_data))
            }
            _ => {
                let data: ndarray::Array2<f64> = dataset
                    .read_2d()
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?;
                let col_data: Vec<f64> = data.column(col_index).to_vec();
                Ok(DataColumn::Float64(col_data))
            }
        }
    }
}

#[cfg(feature = "hdf5")]
impl DataReader for Hdf5Reader {
    fn read_schema(&self) -> IoResult<DataSchema> {
        Ok(self.schema.clone())
    }

    fn read_column(&self, name: &str) -> IoResult<DataColumn> {
        let col_index = self
            .schema
            .column_index(name)
            .ok_or_else(|| IoError::ColumnNotFound(name.to_string()))?;

        self.read_dataset_column(col_index)
    }

    fn read_range(&self, start: usize, end: usize) -> IoResult<DataSlice> {
        let file = Hdf5File::open(&self.path).map_err(|e| IoError::OpenFailed(e.to_string()))?;
        let dataset = file
            .dataset(&self.dataset_path)
            .map_err(|e| IoError::DatasetNotFound(e.to_string()))?;

        let shape = dataset.shape();
        let end = end.min(shape[0]);

        let mut slice = DataSlice::new(start);

        // Read each column for the range
        for (i, col_desc) in self.schema.columns.iter().enumerate() {
            let col_data = if shape.len() == 1 {
                // 1D - read slice directly
                match col_desc.dtype {
                    ColumnType::Float64 | ColumnType::Unknown => {
                        let data: Vec<f64> = dataset
                            .read_slice_1d(start..end)
                            .map_err(|e| IoError::ReadFailed(e.to_string()))?
                            .to_vec();
                        DataColumn::Float64(data)
                    }
                    ColumnType::Float32 => {
                        let data: Vec<f32> = dataset
                            .read_slice_1d(start..end)
                            .map_err(|e| IoError::ReadFailed(e.to_string()))?
                            .to_vec();
                        DataColumn::Float32(data)
                    }
                    _ => {
                        let data: Vec<f64> = dataset
                            .read_slice_1d(start..end)
                            .map_err(|e| IoError::ReadFailed(e.to_string()))?
                            .to_vec();
                        DataColumn::Float64(data)
                    }
                }
            } else {
                // 2D - read slice and extract column
                let data: ndarray::Array2<f64> = dataset
                    .read_slice_2d((start..end, ..))
                    .map_err(|e| IoError::ReadFailed(e.to_string()))?;
                DataColumn::Float64(data.column(i).to_vec())
            };

            slice.add_column(&col_desc.name, col_data);
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
        "HDF5"
    }
}

/// Stub implementation when HDF5 feature is not enabled
#[cfg(not(feature = "hdf5"))]
pub struct Hdf5Reader;

#[cfg(not(feature = "hdf5"))]
impl Hdf5Reader {
    pub fn open(_path: &str, _dataset_path: &str) -> IoResult<Self> {
        Err(IoError::UnsupportedFormat(
            "HDF5 support not compiled. Enable the 'hdf5' feature.".to_string(),
        ))
    }

    pub fn list_datasets(_path: &str) -> IoResult<Vec<String>> {
        Err(IoError::UnsupportedFormat(
            "HDF5 support not compiled. Enable the 'hdf5' feature.".to_string(),
        ))
    }
}

#[cfg(all(test, feature = "hdf5"))]
mod tests {
    use super::*;

    // Tests would require actual HDF5 files
    // These are placeholder tests that would run with test fixtures

    #[test]
    fn test_hdf5_type_conversion() {
        // Test type conversion logic
        assert_eq!(
            Hdf5Reader::hdf5_type_to_column_type(&hdf5::Datatype::from_type::<f64>().unwrap()),
            ColumnType::Float64
        );
    }
}
