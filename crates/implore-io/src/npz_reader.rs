//! NPZ file reader for volumetric scientific data
//!
//! Reads `.npz` files (zip archives of `.npy` arrays) as produced by
//! NumPy's `np.savez()`. Used for loading 3D RG turbulence velocity
//! fields and gain factor tensors.

use crate::reader::{IoError, IoResult};
use ndarray::{ArrayD, IxDyn};
use npyz::{DType, NpyFile, TypeChar};
use std::collections::HashMap;
use std::fs::File;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use zip::ZipArchive;

/// An opened `.npz` file providing access to named N-dimensional arrays.
pub struct NpzFile {
    path: PathBuf,
    /// Raw bytes for each array name
    arrays: HashMap<String, Vec<u8>>,
}

impl NpzFile {
    /// Open an `.npz` file and index its contents.
    pub fn open(path: impl AsRef<Path>) -> IoResult<Self> {
        let path = path.as_ref().to_path_buf();
        let file = File::open(&path).map_err(|e| {
            IoError::OpenFailed(format!("{}: {}", path.display(), e))
        })?;

        let mut archive = ZipArchive::new(file).map_err(|e| {
            IoError::InvalidFormat(format!("Not a valid .npz (zip) file: {}", e))
        })?;

        let mut arrays = HashMap::new();
        for i in 0..archive.len() {
            let mut entry = archive.by_index(i).map_err(|e| {
                IoError::ReadFailed(format!("Failed to read zip entry {}: {}", i, e))
            })?;

            let name = entry.name().to_string();
            // .npz entries are named like "array_name.npy"
            let key = name.strip_suffix(".npy").unwrap_or(&name).to_string();

            let mut buf = Vec::new();
            entry.read_to_end(&mut buf).map_err(|e| {
                IoError::ReadFailed(format!("Failed to read '{}': {}", name, e))
            })?;
            arrays.insert(key, buf);
        }

        Ok(Self { path, arrays })
    }

    /// List all array names in the file.
    pub fn array_names(&self) -> Vec<String> {
        let mut names: Vec<_> = self.arrays.keys().cloned().collect();
        names.sort();
        names
    }

    /// Get the shape of a named array without reading the data.
    pub fn peek_shape(&self, name: &str) -> IoResult<Vec<usize>> {
        let buf = self.arrays.get(name).ok_or_else(|| {
            IoError::DatasetNotFound(format!(
                "Array '{}' not found in {}",
                name,
                self.path.display()
            ))
        })?;

        let reader = NpyFile::new(Cursor::new(buf.as_slice())).map_err(|e| {
            IoError::InvalidFormat(format!("Invalid .npy for '{}': {}", name, e))
        })?;

        Ok(reader.shape().iter().map(|&s| s as usize).collect())
    }

    /// Read a 1D array as `Vec<f32>`.
    pub fn read_1d_f32(&self, name: &str) -> IoResult<Vec<f32>> {
        let arr = self.read_f32_array(name)?;
        Ok(arr.into_raw_vec_and_offset().0)
    }

    /// Read a named array as `f32`. Integers and `f64` are cast to `f32`.
    pub fn read_f32_array(&self, name: &str) -> IoResult<ArrayD<f32>> {
        let buf = self.arrays.get(name).ok_or_else(|| {
            IoError::DatasetNotFound(format!(
                "Array '{}' not found in {}",
                name,
                self.path.display()
            ))
        })?;

        let reader = NpyFile::new(Cursor::new(buf.as_slice())).map_err(|e| {
            IoError::InvalidFormat(format!("Invalid .npy for '{}': {}", name, e))
        })?;

        let shape: Vec<usize> = reader.shape().iter().map(|&s| s as usize).collect();
        let dtype = reader.dtype();

        // Extract the TypeStr from a Plain dtype, or fail
        let type_str = match &dtype {
            DType::Plain(ts) => ts.clone(),
            _ => {
                return Err(IoError::InvalidFormat(format!(
                    "Structured/array dtypes not supported for '{}': {:?}",
                    name, dtype
                )));
            }
        };

        let tc = type_str.type_char();
        let nbytes = type_str.num_bytes();

        // Re-open the npy (reader was consumed for dtype inspection)
        let data: Vec<f32> = match tc {
            TypeChar::Float => {
                if nbytes == Some(8) {
                    // f64 → f32
                    let npy = NpyFile::new(Cursor::new(buf.as_slice())).unwrap();
                    npy.into_vec::<f64>()
                        .map_err(|e| {
                            IoError::ReadFailed(format!("f64 read '{}': {}", name, e))
                        })?
                        .into_iter()
                        .map(|v| v as f32)
                        .collect()
                } else {
                    // f32 or f16 (treat as f32)
                    let npy = NpyFile::new(Cursor::new(buf.as_slice())).unwrap();
                    npy.into_vec::<f32>()
                        .map_err(|e| {
                            IoError::ReadFailed(format!("f32 read '{}': {}", name, e))
                        })?
                }
            }
            TypeChar::Int => {
                if nbytes <= Some(4) {
                    let npy = NpyFile::new(Cursor::new(buf.as_slice())).unwrap();
                    npy.into_vec::<i32>()
                        .map_err(|e| {
                            IoError::ReadFailed(format!("i32 read '{}': {}", name, e))
                        })?
                        .into_iter()
                        .map(|v| v as f32)
                        .collect()
                } else {
                    let npy = NpyFile::new(Cursor::new(buf.as_slice())).unwrap();
                    npy.into_vec::<i64>()
                        .map_err(|e| {
                            IoError::ReadFailed(format!("i64 read '{}': {}", name, e))
                        })?
                        .into_iter()
                        .map(|v| v as f32)
                        .collect()
                }
            }
            TypeChar::Uint => {
                if nbytes <= Some(4) {
                    let npy = NpyFile::new(Cursor::new(buf.as_slice())).unwrap();
                    npy.into_vec::<u32>()
                        .map_err(|e| {
                            IoError::ReadFailed(format!("u32 read '{}': {}", name, e))
                        })?
                        .into_iter()
                        .map(|v| v as f32)
                        .collect()
                } else {
                    let npy = NpyFile::new(Cursor::new(buf.as_slice())).unwrap();
                    npy.into_vec::<u64>()
                        .map_err(|e| {
                            IoError::ReadFailed(format!("u64 read '{}': {}", name, e))
                        })?
                        .into_iter()
                        .map(|v| v as f32)
                        .collect()
                }
            }
            TypeChar::Bool => {
                // NumPy bools are 1-byte (0 or 1)
                let npy = NpyFile::new(Cursor::new(buf.as_slice())).unwrap();
                npy.into_vec::<bool>()
                    .map_err(|e| {
                        IoError::ReadFailed(format!("bool read '{}': {}", name, e))
                    })?
                    .into_iter()
                    .map(|v| if v { 1.0f32 } else { 0.0f32 })
                    .collect()
            }
            _ => {
                // Try f64 as a last resort
                let npy = NpyFile::new(Cursor::new(buf.as_slice())).unwrap();
                npy.into_vec::<f64>()
                    .map_err(|e| {
                        IoError::ReadFailed(format!("fallback read '{}': {}", name, e))
                    })?
                    .into_iter()
                    .map(|v| v as f32)
                    .collect()
            }
        };

        let expected_len: usize = shape.iter().product();
        if data.len() != expected_len {
            return Err(IoError::ReadFailed(format!(
                "Shape mismatch for '{}': shape {:?} expects {} elements, got {}",
                name, shape, expected_len, data.len()
            )));
        }

        ArrayD::from_shape_vec(IxDyn(&shape), data).map_err(|e| {
            IoError::ReadFailed(format!("ndarray reshape for '{}': {}", name, e))
        })
    }

    /// Read a scalar `f32` value (a 0-d array or 1-element array).
    pub fn read_scalar_f32(&self, name: &str) -> IoResult<f32> {
        let arr = self.read_f32_array(name)?;
        if arr.len() != 1 {
            return Err(IoError::TypeMismatch {
                expected: "scalar (1 element)".to_string(),
                actual: format!("{} elements, shape {:?}", arr.len(), arr.shape()),
            });
        }
        Ok(arr.iter().next().copied().unwrap())
    }

    /// Read a scalar `i32` value.
    pub fn read_scalar_i32(&self, name: &str) -> IoResult<i32> {
        self.read_scalar_f32(name).map(|v| v as i32)
    }

    /// Check if an array exists.
    pub fn contains(&self, name: &str) -> bool {
        self.arrays.contains_key(name)
    }

    /// Get the file path.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Create a minimal .npz file with a single f32 array for testing.
    fn create_test_npz(shape: &[usize], data: &[f32]) -> Vec<u8> {
        // Build a .npy buffer
        let npy_bytes = {
            let mut buf = Vec::new();
            // Magic: \x93NUMPY
            buf.extend_from_slice(b"\x93NUMPY");
            // Version 1.0
            buf.push(1);
            buf.push(0);
            // Header
            let shape_str: Vec<String> = shape.iter().map(|s| s.to_string()).collect();
            let shape_part = if shape.len() == 1 {
                format!("({},)", shape_str[0])
            } else {
                format!("({})", shape_str.join(", "))
            };
            let header = format!(
                "{{'descr': '<f4', 'fortran_order': False, 'shape': {}, }}",
                shape_part
            );
            // Pad header to multiple of 64
            let header_len = header.len() + 1; // +1 for newline
            let padding = (64 - ((10 + header_len) % 64)) % 64;
            let total_header_len = (header_len + padding) as u16;
            buf.extend_from_slice(&total_header_len.to_le_bytes());
            buf.extend_from_slice(header.as_bytes());
            buf.extend_from_slice(&vec![b' '; padding]);
            buf.push(b'\n');
            // Data
            for &v in data {
                buf.extend_from_slice(&v.to_le_bytes());
            }
            buf
        };

        // Wrap in a zip
        let mut zip_buf = Vec::new();
        {
            let cursor = Cursor::new(&mut zip_buf);
            let mut zip = zip::ZipWriter::new(cursor);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored);
            zip.start_file("test.npy", options).unwrap();
            zip.write_all(&npy_bytes).unwrap();
            zip.finish().unwrap();
        }
        zip_buf
    }

    #[test]
    fn test_npz_open_and_read() {
        let data = vec![1.0f32, 2.0, 3.0, 4.0];
        let npz_bytes = create_test_npz(&[2, 2], &data);

        let tmp = std::env::temp_dir().join("test_implore.npz");
        std::fs::write(&tmp, &npz_bytes).unwrap();

        let npz = NpzFile::open(&tmp).unwrap();
        assert!(npz.array_names().contains(&"test".to_string()));

        let arr = npz.read_f32_array("test").unwrap();
        assert_eq!(arr.shape(), &[2, 2]);
        assert_eq!(arr[[0, 0]], 1.0);
        assert_eq!(arr[[1, 1]], 4.0);

        std::fs::remove_file(&tmp).ok();
    }
}
