//! UniFFI exports for RG turbulence visualization.
//!
//! Provides FFI-safe types and an opaque handle for Swift to interact
//! with `RgDataset` — load files, query metadata, and request colormapped
//! 2D slices for Metal texture upload.

use super::slice;
use super::types::{DerivedQuantity, RgDataset, SliceAxis};
use std::sync::{Arc, RwLock};

/// Error type exposed to Swift via UniFFI.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RgError {
    /// File could not be opened or parsed.
    #[error("Load failed: {message}")]
    LoadFailed { message: String },
    /// Requested quantity is not available.
    #[error("Quantity not available: {message}")]
    QuantityNotAvailable { message: String },
    /// Slice position is out of bounds.
    #[error("Out of bounds: {message}")]
    OutOfBounds { message: String },
    /// Internal computation error.
    #[error("Compute failed: {message}")]
    ComputeFailed { message: String },
}

impl From<implore_io::IoError> for RgError {
    fn from(e: implore_io::IoError) -> Self {
        RgError::LoadFailed {
            message: e.to_string(),
        }
    }
}

/// A colormapped 2D slice ready for texture upload.
#[derive(uniffi::Record)]
pub struct SliceData {
    /// RGBA pixel bytes, row-major, 4 bytes per pixel.
    pub rgba_bytes: Vec<u8>,
    /// Width of the slice in pixels.
    pub width: u32,
    /// Height of the slice in pixels.
    pub height: u32,
    /// Minimum scalar value in this slice (before colormap).
    pub min_value: f32,
    /// Maximum scalar value in this slice (before colormap).
    pub max_value: f32,
    /// Name of the quantity visualized.
    pub quantity: String,
    /// Slice axis ("x", "y", or "z").
    pub axis: String,
    /// Slice position along the axis.
    pub position: u32,
    /// Maximum valid position (grid_size - 1).
    pub max_position: u32,
}

/// Metadata about an RG dataset.
#[derive(uniffi::Record)]
pub struct RgDatasetInfo {
    /// Grid dimension (n for an n x n x n cube). 0 for stats-only files.
    pub grid_size: u32,
    /// Cascade level indices present.
    pub levels: Vec<i32>,
    /// Simulation time.
    pub time: f32,
    /// Domain size (L).
    pub domain_size: f32,
    /// Viscosity (nu).
    pub viscosity: f32,
    /// Names of available derived quantities.
    pub available_quantities: Vec<String>,
    /// Whether volume data (velocity fields) is present.
    pub has_volume_data: bool,
    /// Number of velocity snapshots loaded as levels.
    pub num_snapshots: u32,
    /// Whether cascade statistics are available.
    pub has_cascade_stats: bool,
    /// Names of all data series in the file.
    pub data_series_names: Vec<String>,
}

/// A raw 2D slice with f32 values and summary statistics.
#[derive(uniffi::Record)]
pub struct RawSliceData {
    /// Row-major f32 values.
    pub values: Vec<f32>,
    /// Width of the slice in pixels.
    pub width: u32,
    /// Height of the slice in pixels.
    pub height: u32,
    /// Minimum finite value in the slice.
    pub min_value: f32,
    /// Maximum finite value in the slice.
    pub max_value: f32,
    /// Mean of finite values.
    pub mean_value: f32,
    /// Standard deviation of finite values.
    pub std_value: f32,
    /// Quantity name.
    pub quantity: String,
    /// Slice axis ("x", "y", or "z").
    pub axis: String,
    /// Slice position along the axis.
    pub position: u32,
}

/// Statistics for an entire 3D field volume.
#[derive(uniffi::Record)]
pub struct FieldStatistics {
    /// Quantity name.
    pub quantity: String,
    /// Minimum finite value across the volume.
    pub min_value: f32,
    /// Maximum finite value across the volume.
    pub max_value: f32,
    /// Mean of finite values.
    pub mean_value: f32,
    /// Standard deviation of finite values.
    pub std_value: f32,
    /// Number of NaN values.
    pub nan_count: u64,
    /// Number of Inf values.
    pub inf_count: u64,
    /// Total number of values.
    pub total_count: u64,
}

/// RG cascade statistics exposed to Swift.
#[derive(uniffi::Record)]
pub struct RgCascadeStatsFfi {
    /// Intermittency parameter mu = Var(ln f)/ln(2) per cascade level.
    pub mu_per_level: Vec<f32>,
    /// Mean log gain factor per level.
    pub ln_f_mean_per_level: Vec<f32>,
    /// Variance of log gain factor per level.
    pub ln_f_var_per_level: Vec<f32>,
    /// Ratio of <ln f> between adjacent levels.
    pub ln_f_ratios: Vec<f32>,
    /// Structure function exponents zeta_p for p=1..8.
    pub zeta_p: Vec<f32>,
    /// Number of cascade levels.
    pub num_levels: u32,
    /// Number of statistical samples.
    pub num_samples: u32,
    /// Spectral radius rho(DT). NaN if not available.
    pub sigma_max: f32,
    /// Whether power iteration converged.
    pub power_converged: bool,
    /// Per-sample energy values.
    pub sample_energy: Vec<f32>,
    /// Per-sample skewness values.
    pub sample_skewness: Vec<f32>,
    /// Per-sample flatness values.
    pub sample_flatness: Vec<f32>,
}

/// Info about a named array in the .npz file.
#[derive(uniffi::Record)]
pub struct RgArrayInfoFfi {
    /// Array name.
    pub name: String,
    /// Shape dimensions.
    pub shape: Vec<u32>,
}

/// A named 1D data series from the .npz file.
#[derive(uniffi::Record)]
pub struct RgDataSeriesFfi {
    /// Series name (e.g. "I2_mean_L0", "energy", "history").
    pub name: String,
    /// Data values.
    pub values: Vec<f32>,
}

/// Opaque handle to an RG dataset, exposed to Swift.
#[derive(uniffi::Object)]
pub struct RgDatasetHandle {
    inner: RwLock<RgDataset>,
}

#[uniffi::export]
impl RgDatasetHandle {
    /// Load an RG dataset from an `.npz` file path.
    #[uniffi::constructor]
    pub fn load(path: String) -> Result<Arc<Self>, RgError> {
        let dataset = RgDataset::load(&path)?;
        Ok(Arc::new(Self {
            inner: RwLock::new(dataset),
        }))
    }

    /// Get dataset metadata.
    pub fn info(&self) -> RgDatasetInfo {
        let ds = self.inner.read().expect("RgDataset lock poisoned");
        let level = ds.active();

        let mut data_series_names: Vec<String> = ds.data_series.keys().cloned().collect();
        data_series_names.sort();

        RgDatasetInfo {
            grid_size: ds.grid_size() as u32,
            levels: ds.levels.keys().copied().collect(),
            time: level.map(|l| l.time).unwrap_or(0.0),
            domain_size: level.map(|l| l.domain_size).unwrap_or(0.0),
            viscosity: level.map(|l| l.viscosity).unwrap_or(0.0),
            available_quantities: ds.available_quantities(),
            has_volume_data: ds.has_volume_data,
            num_snapshots: ds.num_snapshots,
            has_cascade_stats: ds.cascade_stats.is_some(),
            data_series_names,
        }
    }

    /// Get a colormapped 2D slice.
    ///
    /// - `quantity`: one of the names from `info().available_quantities`
    /// - `axis`: "x", "y", or "z"
    /// - `position`: slice index along the axis (0 to grid_size-1)
    /// - `colormap`: colormap name (e.g., "coolwarm", "viridis")
    pub fn get_slice(
        &self,
        quantity: String,
        axis: String,
        position: u32,
        colormap: String,
    ) -> Result<SliceData, RgError> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");

        let dq = DerivedQuantity::from_str(&quantity).ok_or_else(|| RgError::QuantityNotAvailable {
            message: format!("Unknown quantity: '{}'", quantity),
        })?;

        let sa = SliceAxis::from_str(&axis).ok_or_else(|| RgError::OutOfBounds {
            message: format!("Unknown axis: '{}' (expected x, y, or z)", axis),
        })?;

        let n = ds.grid_size();
        if n == 0 {
            return Err(RgError::ComputeFailed {
                message: "No active level".to_string(),
            });
        }
        if position as usize >= n {
            return Err(RgError::OutOfBounds {
                message: format!("Position {} >= grid size {}", position, n),
            });
        }

        // Get or compute the 3D field
        let field = ds.get_field(dq).map_err(|e| RgError::ComputeFailed {
            message: e.to_string(),
        })?;

        // Extract 2D slice
        let slice_2d = slice::extract_slice(&field, sa, position as usize);
        let (vmin, vmax) = slice::finite_min_max(&slice_2d);

        // Apply colormap
        let cmap = slice::get_colormap_or_default(&colormap);
        let rgba = slice::apply_colormap(&slice_2d, &cmap, vmin, vmax);

        let (h, w) = (slice_2d.shape()[0], slice_2d.shape()[1]);

        Ok(SliceData {
            rgba_bytes: rgba,
            width: w as u32,
            height: h as u32,
            min_value: vmin,
            max_value: vmax,
            quantity,
            axis,
            position,
            max_position: (n - 1) as u32,
        })
    }

    /// Set the active cascade level.
    pub fn set_level(&self, level: i32) -> Result<(), RgError> {
        let mut ds = self.inner.write().expect("RgDataset lock poisoned");
        if !ds.levels.contains_key(&level) {
            return Err(RgError::OutOfBounds {
                message: format!("Level {} not found", level),
            });
        }
        ds.active_level = level;
        Ok(())
    }

    /// Get a raw 2D slice as f32 values with summary statistics.
    pub fn get_raw_slice(
        &self,
        quantity: String,
        axis: String,
        position: u32,
    ) -> Result<RawSliceData, RgError> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");

        let dq = DerivedQuantity::from_str(&quantity).ok_or_else(|| RgError::QuantityNotAvailable {
            message: format!("Unknown quantity: '{}'", quantity),
        })?;

        let sa = SliceAxis::from_str(&axis).ok_or_else(|| RgError::OutOfBounds {
            message: format!("Unknown axis: '{}' (expected x, y, or z)", axis),
        })?;

        let n = ds.grid_size();
        if n == 0 {
            return Err(RgError::ComputeFailed {
                message: "No active level".to_string(),
            });
        }
        if position as usize >= n {
            return Err(RgError::OutOfBounds {
                message: format!("Position {} >= grid size {}", position, n),
            });
        }

        let field = ds.get_field(dq).map_err(|e| RgError::ComputeFailed {
            message: e.to_string(),
        })?;

        let slice_2d = slice::extract_slice(&field, sa, position as usize);
        let (h, w) = (slice_2d.shape()[0], slice_2d.shape()[1]);

        let (min_val, max_val, mean_val, std_val) = compute_slice_stats(&slice_2d);

        let (values, _offset) = slice_2d.into_raw_vec_and_offset();

        Ok(RawSliceData {
            values,
            width: w as u32,
            height: h as u32,
            min_value: min_val,
            max_value: max_val,
            mean_value: mean_val,
            std_value: std_val,
            quantity,
            axis,
            position,
        })
    }

    /// Get statistics for an entire 3D field volume.
    pub fn get_field_statistics(&self, quantity: String) -> Result<FieldStatistics, RgError> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");

        let dq = DerivedQuantity::from_str(&quantity).ok_or_else(|| RgError::QuantityNotAvailable {
            message: format!("Unknown quantity: '{}'", quantity),
        })?;

        let field = ds.get_field(dq).map_err(|e| RgError::ComputeFailed {
            message: e.to_string(),
        })?;

        let mut min_val = f32::INFINITY;
        let mut max_val = f32::NEG_INFINITY;
        let mut sum: f64 = 0.0;
        let mut sum_sq: f64 = 0.0;
        let mut finite_count: u64 = 0;
        let mut nan_count: u64 = 0;
        let mut inf_count: u64 = 0;
        let total_count = field.len() as u64;

        for &v in field.iter() {
            if v.is_nan() {
                nan_count += 1;
            } else if v.is_infinite() {
                inf_count += 1;
            } else {
                if v < min_val { min_val = v; }
                if v > max_val { max_val = v; }
                let vd = v as f64;
                sum += vd;
                sum_sq += vd * vd;
                finite_count += 1;
            }
        }

        let mean_val = if finite_count > 0 { (sum / finite_count as f64) as f32 } else { 0.0 };
        let std_val = if finite_count > 1 {
            let variance = (sum_sq / finite_count as f64) - (mean_val as f64).powi(2);
            (variance.max(0.0).sqrt()) as f32
        } else {
            0.0
        };

        if !min_val.is_finite() { min_val = 0.0; }
        if !max_val.is_finite() { max_val = 0.0; }

        Ok(FieldStatistics {
            quantity,
            min_value: min_val,
            max_value: max_val,
            mean_value: mean_val,
            std_value: std_val,
            nan_count,
            inf_count,
            total_count,
        })
    }

    /// Get pre-computed cascade statistics, if present in the file.
    pub fn get_cascade_stats(&self) -> Option<RgCascadeStatsFfi> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");
        ds.cascade_stats.as_ref().map(|s| RgCascadeStatsFfi {
            mu_per_level: s.mu_per_level.clone(),
            ln_f_mean_per_level: s.ln_f_mean_per_level.clone(),
            ln_f_var_per_level: s.ln_f_var_per_level.clone(),
            ln_f_ratios: s.ln_f_ratios.clone(),
            zeta_p: s.zeta_p.clone(),
            num_levels: s.num_levels,
            num_samples: s.num_samples,
            sigma_max: s.sigma_max,
            power_converged: s.power_converged,
            sample_energy: s.sample_energy.clone(),
            sample_skewness: s.sample_skewness.clone(),
            sample_flatness: s.sample_flatness.clone(),
        })
    }

    /// List all data series available in the file.
    pub fn list_data_series(&self) -> Vec<RgDataSeriesFfi> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");
        let mut result: Vec<RgDataSeriesFfi> = ds
            .data_series
            .iter()
            .map(|(name, values)| RgDataSeriesFfi {
                name: name.clone(),
                values: values.clone(),
            })
            .collect();
        result.sort_by(|a, b| a.name.cmp(&b.name));
        result
    }

    /// Get a specific named data series by name.
    pub fn get_data_series(&self, name: String) -> Option<Vec<f32>> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");
        ds.data_series.get(&name).cloned()
    }

    /// List all arrays in the source .npz file with their shapes.
    pub fn list_arrays(&self) -> Vec<RgArrayInfoFfi> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");
        ds.array_info
            .iter()
            .map(|a| RgArrayInfoFfi {
                name: a.name.clone(),
                shape: a.shape.clone(),
            })
            .collect()
    }

    /// Whether this file has volume data (velocity fields).
    pub fn has_volume_data(&self) -> bool {
        let ds = self.inner.read().expect("RgDataset lock poisoned");
        ds.has_volume_data
    }

    /// Number of velocity snapshots loaded.
    pub fn num_snapshots(&self) -> u32 {
        let ds = self.inner.read().expect("RgDataset lock poisoned");
        ds.num_snapshots
    }

    /// Plot one or more named data series overlaid as a line chart, returning SVG.
    ///
    /// - `names`: series names to include (from `list_data_series()`).
    /// - `title`: plot title.
    pub fn plot_data_series(&self, names: Vec<String>, title: String) -> Result<String, RgError> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");

        let mut spec = crate::plot::types::PlotSpec::new().with_title(&title);

        for name in &names {
            let values = ds.data_series.get(name).ok_or_else(|| RgError::QuantityNotAvailable {
                message: format!("Data series '{}' not found", name),
            })?;
            let x: Vec<f64> = (0..values.len()).map(|i| i as f64).collect();
            let y: Vec<f64> = values.iter().map(|&v| v as f64).collect();
            spec = spec.line(x, y, name.clone());
        }

        spec = spec.with_x_label("Index");

        Ok(crate::plot::svg_render::render_svg(&spec))
    }

    /// Plot cascade statistics (mu per level), returning SVG.
    ///
    /// Returns `None` if no cascade stats are available.
    pub fn plot_cascade_stats(&self) -> Option<String> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");
        let stats = ds.cascade_stats.as_ref()?;

        if stats.mu_per_level.is_empty() {
            return None;
        }

        let x: Vec<f64> = (0..stats.mu_per_level.len()).map(|i| i as f64).collect();
        let y: Vec<f64> = stats.mu_per_level.iter().map(|&v| v as f64).collect();

        let spec = crate::plot::types::PlotSpec::new()
            .with_title("Intermittency: \u{03BC} vs cascade level")
            .with_x_label("Cascade level")
            .with_y_label("\u{03BC}")
            .add_series(
                crate::plot::types::PlotSeries::line(x, y, "\u{03BC}(level)")
                    .with_style(crate::plot::types::SeriesStyle::LineScatter)
                    .with_color(crate::plot::types::PlotColor::Blue),
            );

        Some(crate::plot::svg_render::render_svg(&spec))
    }

    /// Plot a histogram of a 3D field's values, returning SVG.
    ///
    /// - `quantity`: derived quantity name
    /// - `num_bins`: number of bins (0 = auto)
    pub fn plot_field_histogram(
        &self,
        quantity: String,
        num_bins: u32,
    ) -> Result<String, RgError> {
        let ds = self.inner.read().expect("RgDataset lock poisoned");

        let dq = super::types::DerivedQuantity::from_str(&quantity).ok_or_else(|| {
            RgError::QuantityNotAvailable {
                message: format!("Unknown quantity: '{}'", quantity),
            }
        })?;

        let field = ds.get_field(dq).map_err(|e| RgError::ComputeFailed {
            message: e.to_string(),
        })?;

        let data: Vec<f64> = field.iter().filter(|v| v.is_finite()).map(|&v| v as f64).collect();

        let config = crate::render::Histogram1DConfig {
            field: quantity,
            num_bins: if num_bins > 0 { Some(num_bins) } else { None },
            ..Default::default()
        };

        let result = crate::plot::histogram::compute_histogram(&data, &config);
        let spec = crate::plot::histogram::histogram_to_plot_spec(&result, &config);

        Ok(crate::plot::svg_render::render_svg(&spec))
    }
}

/// Compute min, max, mean, std for a 2D slice, skipping NaN/Inf.
fn compute_slice_stats(slice: &ndarray::Array2<f32>) -> (f32, f32, f32, f32) {
    let mut min_val = f32::INFINITY;
    let mut max_val = f32::NEG_INFINITY;
    let mut sum: f64 = 0.0;
    let mut sum_sq: f64 = 0.0;
    let mut count: u64 = 0;

    for &v in slice.iter() {
        if v.is_finite() {
            if v < min_val { min_val = v; }
            if v > max_val { max_val = v; }
            let vd = v as f64;
            sum += vd;
            sum_sq += vd * vd;
            count += 1;
        }
    }

    let mean = if count > 0 { (sum / count as f64) as f32 } else { 0.0 };
    let std = if count > 1 {
        let variance = (sum_sq / count as f64) - (mean as f64).powi(2);
        (variance.max(0.0).sqrt()) as f32
    } else {
        0.0
    };

    if !min_val.is_finite() { min_val = 0.0; }
    if !max_val.is_finite() { max_val = 0.0; }

    (min_val, max_val, mean, std)
}
