//! Core data types for RG turbulence visualization.

use ndarray::{Array3, Array4, Array5};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::RwLock;

use implore_io::npz_reader::NpzFile;
use implore_io::IoError;

/// Axis along which to take a 2D slice through the 3D volume.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SliceAxis {
    X,
    Y,
    Z,
}

impl SliceAxis {
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "x" => Some(Self::X),
            "y" => Some(Self::Y),
            "z" => Some(Self::Z),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::X => "x",
            Self::Y => "y",
            Self::Z => "z",
        }
    }
}

/// Derived scalar quantities that can be computed from the velocity and gain fields.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DerivedQuantity {
    /// Raw gain factor from file (scalar per grid point)
    GainFactor,
    /// log10 of gain factor
    LogGainFactor,
    /// |u| = sqrt(u_x^2 + u_y^2 + u_z^2)
    VelocityMagnitude,
    /// Individual velocity components
    VelocityX,
    VelocityY,
    VelocityZ,
    /// |omega| = |curl(u)|
    VorticityMagnitude,
    /// |S| where S_ij = (du_i/dx_j + du_j/dx_i) / 2
    StrainMagnitude,
    /// I2 = tr(A^2)
    I2,
    /// I3 = tr(A^3)
    I3,
    /// Q = (|Omega|^2 - |S|^2) / 2
    QCriterion,
    /// det(G) — determinant of gain tensor
    DetG,
    /// Max eigenvalue of Cauchy-Green tensor F^T F where F = G^{-1}
    LambdaMax,
}

impl DerivedQuantity {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "gain_factor" => Some(Self::GainFactor),
            "log_gain_factor" => Some(Self::LogGainFactor),
            "velocity_magnitude" => Some(Self::VelocityMagnitude),
            "velocity_x" => Some(Self::VelocityX),
            "velocity_y" => Some(Self::VelocityY),
            "velocity_z" => Some(Self::VelocityZ),
            "vorticity_magnitude" => Some(Self::VorticityMagnitude),
            "strain_magnitude" => Some(Self::StrainMagnitude),
            "i2" => Some(Self::I2),
            "i3" => Some(Self::I3),
            "q_criterion" => Some(Self::QCriterion),
            "det_g" => Some(Self::DetG),
            "lambda_max" => Some(Self::LambdaMax),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::GainFactor => "gain_factor",
            Self::LogGainFactor => "log_gain_factor",
            Self::VelocityMagnitude => "velocity_magnitude",
            Self::VelocityX => "velocity_x",
            Self::VelocityY => "velocity_y",
            Self::VelocityZ => "velocity_z",
            Self::VorticityMagnitude => "vorticity_magnitude",
            Self::StrainMagnitude => "strain_magnitude",
            Self::I2 => "i2",
            Self::I3 => "i3",
            Self::QCriterion => "q_criterion",
            Self::DetG => "det_g",
            Self::LambdaMax => "lambda_max",
        }
    }

    /// Quantities available for the first milestone.
    pub fn available() -> Vec<Self> {
        vec![
            Self::GainFactor,
            Self::LogGainFactor,
            Self::VelocityMagnitude,
            Self::VelocityX,
            Self::VelocityY,
            Self::VelocityZ,
            Self::VorticityMagnitude,
        ]
    }
}

/// Data for a single RG level (one cascade step).
pub struct RgLevel {
    /// Velocity field: shape (3, n, n, n) — u[component][z][y][x]
    pub u: Array4<f32>,
    /// Gain tensor: shape (3, 3, n, n, n) — g[i][j][z][y][x]
    pub g: Option<Array5<f32>>,
    /// Scalar gain factor: shape (n, n, n)
    pub gain_factor: Option<Array3<f32>>,
    /// Grid size (n)
    pub n: usize,
    /// Domain size L
    pub domain_size: f32,
    /// Viscosity
    pub viscosity: f32,
    /// Simulation time
    pub time: f32,
    /// Grid spacing
    pub h: f32,
}

/// RG cascade statistics extracted from an .npz file.
///
/// These are pre-computed statistics from the RG turbulence simulation,
/// including per-level intermittency measures, structure function exponents,
/// and per-sample diagnostics.
#[derive(Clone, Debug, Default)]
pub struct RgCascadeStats {
    /// Intermittency parameter mu = Var(ln f)/ln(2) per cascade level.
    pub mu_per_level: Vec<f32>,
    /// Mean log gain factor <ln(enstrophy_after/enstrophy_before)> per level.
    pub ln_f_mean_per_level: Vec<f32>,
    /// Variance of log gain factor per level.
    pub ln_f_var_per_level: Vec<f32>,
    /// Ratio of <ln f> between adjacent levels (expect ~2 for self-similar cascade).
    pub ln_f_ratios: Vec<f32>,
    /// Structure function exponents zeta_p for p=1..8.
    pub zeta_p: Vec<f32>,
    /// Number of cascade levels detected.
    pub num_levels: u32,
    /// Number of statistical samples (if per-sample data is available).
    pub num_samples: u32,
    /// Spectral radius rho(DT) from power iteration. NaN if not available.
    pub sigma_max: f32,
    /// Whether the power iteration converged.
    pub power_converged: bool,
    /// Per-sample kinetic energy values.
    pub sample_energy: Vec<f32>,
    /// Per-sample velocity derivative skewness values.
    pub sample_skewness: Vec<f32>,
    /// Per-sample velocity derivative flatness values.
    pub sample_flatness: Vec<f32>,
}

/// A named 1D data series from an .npz file (for per-level or per-sample stats).
#[derive(Clone, Debug)]
pub struct RgDataSeries {
    pub name: String,
    pub values: Vec<f32>,
}

/// Information about an array in the .npz file.
#[derive(Clone, Debug)]
pub struct RgArrayInfo {
    pub name: String,
    pub shape: Vec<u32>,
}

/// A complete RG dataset, potentially with multiple cascade levels.
pub struct RgDataset {
    /// Levels keyed by level index (0 = finest, positive = coarser)
    pub levels: BTreeMap<i32, RgLevel>,
    /// Current active level
    pub active_level: i32,
    /// Computed field cache: (level, quantity) → 3D array
    cache: RwLock<HashMap<(i32, DerivedQuantity), Array3<f32>>>,
    /// Pre-computed cascade statistics from the file.
    pub cascade_stats: Option<RgCascadeStats>,
    /// All named data series (per-level, per-sample, time series) from the file.
    /// Key format: "I2_mean_L0", "skewness_L3", "energy", "history", etc.
    pub data_series: HashMap<String, Vec<f32>>,
    /// Shape info for all arrays in the source file.
    pub array_info: Vec<RgArrayInfo>,
    /// Whether this file has volume data (velocity fields) or is stats-only.
    pub has_volume_data: bool,
    /// Number of velocity snapshots loaded as levels.
    pub num_snapshots: u32,
}

/// Velocity key names to try, in order of priority.
const VELOCITY_KEYS: &[&str] = &["u", "velocity", "velocity_final"];

impl RgDataset {
    /// Load an RG dataset from a `.npz` file.
    ///
    /// Supports multiple data formats from rg-map:
    /// - Volume data: `u`, `velocity`, or `velocity_final` (3, n, n, n)
    /// - Velocity snapshots: `velocity_snapshots` (N, 3, n, n, n) → multiple levels
    /// - Gain fields: `g`/`gain_tensor` (3,3,n,n,n), `gain_factor` (n,n,n)
    /// - Cascade statistics: `mu_per_level`, `ln_f_*`, `zeta_p`, etc.
    /// - Spinup diagnostics: `energy`, `enstrophy`, `skewness`, etc.
    /// - Power iteration: `sigma_max`, `history`, `converged`
    /// - Summary files: aggregate scalars without velocity fields
    pub fn load(path: impl AsRef<Path>) -> Result<Self, IoError> {
        let npz = NpzFile::open(path)?;
        let names = npz.array_names();

        // Collect array info for all arrays in the file
        let mut array_info = Vec::new();
        for name in &names {
            if let Ok(shape) = npz.peek_shape(name) {
                array_info.push(RgArrayInfo {
                    name: name.clone(),
                    shape: shape.iter().map(|&s| s as u32).collect(),
                });
            }
        }

        // Find velocity field (try multiple key names)
        let u_name = VELOCITY_KEYS
            .iter()
            .find(|&&k| names.contains(&k.to_string()))
            .copied();

        let mut levels = BTreeMap::new();
        let mut has_volume_data = false;
        let mut num_snapshots: u32 = 0;

        // Metadata scalars (used for all levels)
        let domain_size =
            read_scalar_with_fallback(&npz, &["L", "domain_size"], std::f32::consts::TAU);
        let viscosity = read_scalar_with_fallback(&npz, &["nu", "viscosity"], 1e-3);
        let time = read_scalar_with_fallback(&npz, &["t", "time"], 0.0);

        if let Some(u_key) = u_name {
            // Load primary velocity field
            let u_raw = npz.read_f32_array(u_key)?;
            let u_shape = u_raw.shape().to_vec();
            if u_shape.len() != 4 || u_shape[0] != 3 {
                return Err(IoError::InvalidFormat(format!(
                    "Velocity field must have shape (3, n, n, n), got {:?}",
                    u_shape
                )));
            }
            let n = u_shape[1];
            if u_shape[2] != n || u_shape[3] != n {
                return Err(IoError::InvalidFormat(format!(
                    "Velocity field must be cubic: got shape {:?}",
                    u_shape
                )));
            }

            let u = u_raw
                .into_shape_with_order(ndarray::Ix4(3, n, n, n))
                .map_err(|e| IoError::ReadFailed(format!("Failed to reshape velocity: {}", e)))?;

            // Gain tensor (optional)
            let g = load_gain_tensor(&npz, &names, n)?;

            // Scalar gain factor (optional)
            let gain_factor = load_gain_factor(&npz, &names, n)?;

            let level_idx = read_scalar_with_fallback(&npz, &["level"], 0.0) as i32;
            let h = domain_size / n as f32;

            levels.insert(
                level_idx,
                RgLevel {
                    u,
                    g,
                    gain_factor,
                    n,
                    domain_size,
                    viscosity,
                    time,
                    h,
                },
            );
            has_volume_data = true;
        }

        // Load velocity snapshots as additional levels
        if names.contains(&"velocity_snapshots".to_string()) {
            if let Ok(snap_shape) = npz.peek_shape("velocity_snapshots") {
                // Expected shape: (N, 3, n, n, n)
                if snap_shape.len() == 5 && snap_shape[1] == 3 {
                    let n_snap = snap_shape[0];
                    let n = snap_shape[2];
                    if snap_shape[3] == n && snap_shape[4] == n {
                        let snap_raw = npz.read_f32_array("velocity_snapshots")?;
                        let h = domain_size / n as f32;

                        for i in 0..n_snap {
                            // Extract snapshot i: slice along first axis
                            let start = i * 3 * n * n * n;
                            let end = start + 3 * n * n * n;
                            let snap_data: Vec<f32> =
                                snap_raw.as_slice().unwrap()[start..end].to_vec();

                            if let Ok(u_snap) = ndarray::Array4::from_shape_vec(
                                ndarray::Ix4(3, n, n, n),
                                snap_data,
                            ) {
                                // Use negative level indices for snapshots to avoid
                                // collision with the primary level 0.
                                // snapshot 0 → level -1, snapshot 1 → level -2, etc.
                                let level_idx = -(i as i32) - 1;
                                levels.insert(
                                    level_idx,
                                    RgLevel {
                                        u: u_snap,
                                        g: None,
                                        gain_factor: None,
                                        n,
                                        domain_size,
                                        viscosity,
                                        time: 0.0,
                                        h,
                                    },
                                );
                            }
                        }
                        num_snapshots = n_snap as u32;
                        has_volume_data = true;
                    }
                }
            }
        }

        // Parse cascade statistics from the file
        let cascade_stats = parse_cascade_stats(&npz, &names);

        // Collect all 0D and 1D arrays as data series
        let data_series = collect_data_series(&npz, &names);

        let active_level = if levels.contains_key(&0) {
            0
        } else {
            levels.keys().next().copied().unwrap_or(0)
        };

        Ok(Self {
            active_level,
            levels,
            cache: RwLock::new(HashMap::new()),
            cascade_stats,
            data_series,
            array_info,
            has_volume_data,
            num_snapshots,
        })
    }

    /// Get the active level.
    pub fn active(&self) -> Option<&RgLevel> {
        self.levels.get(&self.active_level)
    }

    /// Grid size of the active level.
    pub fn grid_size(&self) -> usize {
        self.active().map(|l| l.n).unwrap_or(0)
    }

    /// Get or compute a derived quantity for the active level.
    pub fn get_field(&self, quantity: DerivedQuantity) -> Result<Array3<f32>, IoError> {
        let level_key = self.active_level;
        let cache_key = (level_key, quantity);

        // Check cache first
        {
            let cache = self.cache.read().map_err(|e| {
                IoError::ReadFailed(format!("Cache lock poisoned: {}", e))
            })?;
            if let Some(field) = cache.get(&cache_key) {
                return Ok(field.clone());
            }
        }

        // Compute
        let level = self.active().ok_or_else(|| {
            IoError::DatasetNotFound(format!("No active level {}", level_key))
        })?;

        let field = super::compute::compute_quantity(level, quantity)?;

        // Store in cache
        {
            let mut cache = self.cache.write().map_err(|e| {
                IoError::ReadFailed(format!("Cache lock poisoned: {}", e))
            })?;
            cache.insert(cache_key, field.clone());
        }

        Ok(field)
    }

    /// Available quantity names for FFI.
    pub fn available_quantities(&self) -> Vec<String> {
        if !self.has_volume_data {
            return Vec::new();
        }

        let mut quantities: Vec<String> = DerivedQuantity::available()
            .iter()
            .map(|q| q.as_str().to_string())
            .collect();

        // Only include gain-tensor-dependent quantities if we have the tensor
        if let Some(level) = self.active() {
            if level.g.is_none() {
                quantities.retain(|q| !matches!(q.as_str(), "det_g" | "lambda_max"));
            }
            if level.gain_factor.is_none() {
                quantities.retain(|q| !matches!(q.as_str(), "gain_factor" | "log_gain_factor"));
            }
        }

        quantities
    }
}

/// Load gain tensor from NPZ if present and shape matches.
fn load_gain_tensor(
    npz: &NpzFile,
    names: &[String],
    n: usize,
) -> Result<Option<Array5<f32>>, IoError> {
    let g_name = if names.contains(&"g".to_string()) {
        Some("g")
    } else if names.contains(&"gain_tensor".to_string()) {
        Some("gain_tensor")
    } else {
        None
    };
    if let Some(name) = g_name {
        let g_raw = npz.read_f32_array(name)?;
        let g_shape = g_raw.shape().to_vec();
        if g_shape == [3, 3, n, n, n] {
            Ok(Some(
                g_raw
                    .into_shape_with_order(ndarray::Ix5(3, 3, n, n, n))
                    .map_err(|e| {
                        IoError::ReadFailed(format!("Failed to reshape gain tensor: {}", e))
                    })?,
            ))
        } else {
            Ok(None)
        }
    } else {
        Ok(None)
    }
}

/// Load scalar gain factor from NPZ if present and shape matches.
fn load_gain_factor(
    npz: &NpzFile,
    names: &[String],
    n: usize,
) -> Result<Option<Array3<f32>>, IoError> {
    if names.contains(&"gain_factor".to_string()) {
        let gf_raw = npz.read_f32_array("gain_factor")?;
        if gf_raw.shape() == [n, n, n] {
            Ok(Some(
                gf_raw
                    .into_shape_with_order(ndarray::Ix3(n, n, n))
                    .map_err(|e| {
                        IoError::ReadFailed(format!("Failed to reshape gain_factor: {}", e))
                    })?,
            ))
        } else {
            Ok(None)
        }
    } else {
        Ok(None)
    }
}

/// Parse well-known RG cascade statistics from an NPZ file.
fn parse_cascade_stats(npz: &NpzFile, names: &[String]) -> Option<RgCascadeStats> {
    // Need at least one recognizable stat to create the struct
    let has_mu = names.contains(&"mu_per_level".to_string());
    let has_sigma = names.contains(&"sigma_max".to_string());
    let has_zeta = names.contains(&"zeta_p".to_string());
    let has_energy = names.contains(&"energy".to_string());
    let has_spinup = names.contains(&"enstrophy".to_string());

    if !has_mu && !has_sigma && !has_zeta && !has_energy && !has_spinup {
        return None;
    }

    let mut stats = RgCascadeStats::default();
    stats.sigma_max = f32::NAN;

    if has_mu {
        stats.mu_per_level = read_1d_or_empty(npz, "mu_per_level");
        stats.num_levels = stats.mu_per_level.len() as u32;
    }
    if names.contains(&"ln_f_mean_per_level".to_string()) {
        stats.ln_f_mean_per_level = read_1d_or_empty(npz, "ln_f_mean_per_level");
    }
    if names.contains(&"ln_f_var_per_level".to_string()) {
        stats.ln_f_var_per_level = read_1d_or_empty(npz, "ln_f_var_per_level");
    }
    if names.contains(&"ln_f_ratios".to_string()) {
        stats.ln_f_ratios = read_1d_or_empty(npz, "ln_f_ratios");
    }
    if has_zeta {
        stats.zeta_p = read_1d_or_empty(npz, "zeta_p");
    }
    if has_sigma {
        stats.sigma_max = npz.read_scalar_f32("sigma_max").unwrap_or(f32::NAN);
    }
    if names.contains(&"converged".to_string()) {
        stats.power_converged = npz.read_scalar_f32("converged").unwrap_or(0.0) != 0.0;
    }
    if has_energy {
        stats.sample_energy = read_1d_or_empty(npz, "energy");
        stats.num_samples = stats.sample_energy.len() as u32;
    }
    if names.contains(&"skewness".to_string()) {
        stats.sample_skewness = read_1d_or_empty(npz, "skewness");
        if stats.num_samples == 0 {
            stats.num_samples = stats.sample_skewness.len() as u32;
        }
    }
    if names.contains(&"flatness".to_string()) {
        stats.sample_flatness = read_1d_or_empty(npz, "flatness");
    }

    // Detect num_levels from per-level arrays if not set via mu_per_level
    if stats.num_levels == 0 {
        let max_level = names
            .iter()
            .filter_map(|n| {
                n.rsplit_once("_L")
                    .and_then(|(_, suffix)| suffix.parse::<u32>().ok())
            })
            .max();
        if let Some(max_l) = max_level {
            stats.num_levels = max_l + 1;
        }
    }

    Some(stats)
}

/// Collect all 0D/1D arrays as named data series.
/// Skips arrays that are clearly volume data (3D+).
fn collect_data_series(npz: &NpzFile, names: &[String]) -> HashMap<String, Vec<f32>> {
    let mut series = HashMap::new();

    // Skip known volume array names
    let skip = [
        "u",
        "velocity",
        "velocity_final",
        "velocity_snapshots",
        "g",
        "gain_tensor",
        "gain_factor",
    ];

    for name in names {
        if skip.contains(&name.as_str()) {
            continue;
        }

        // Only collect scalar (0D) and 1D arrays.
        // 2D arrays (like struct_fns_L0 with shape (N, 8)) are flattened.
        if let Ok(shape) = npz.peek_shape(name) {
            if shape.len() <= 2 {
                if let Ok(data) = npz.read_1d_f32(name) {
                    series.insert(name.clone(), data);
                }
            }
        }
    }

    series
}

/// Read a 1D array from NPZ, returning empty vec on failure.
fn read_1d_or_empty(npz: &NpzFile, name: &str) -> Vec<f32> {
    npz.read_1d_f32(name).unwrap_or_default()
}

/// Try multiple key names for a scalar, falling back to a default.
fn read_scalar_with_fallback(npz: &NpzFile, names: &[&str], default: f32) -> f32 {
    for name in names {
        if npz.contains(name) {
            if let Ok(v) = npz.read_scalar_f32(name) {
                return v;
            }
        }
    }
    default
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_slice_axis_roundtrip() {
        for axis in [SliceAxis::X, SliceAxis::Y, SliceAxis::Z] {
            assert_eq!(SliceAxis::from_str(axis.as_str()), Some(axis));
        }
    }

    #[test]
    fn test_derived_quantity_roundtrip() {
        for q in DerivedQuantity::available() {
            assert_eq!(DerivedQuantity::from_str(q.as_str()), Some(q));
        }
    }

    /// Integration test: load real rg-map data files.
    /// Run with: cargo test -p implore-core -- --ignored test_load_rg_map_data --nocapture
    #[test]
    #[ignore]
    fn test_load_rg_map_data() {
        let data_dir = std::path::Path::new("/Users/tabel/Projects/rg-map/data");
        if !data_dir.exists() {
            eprintln!("Skipping: rg-map data directory not found");
            return;
        }

        // Test volume file with velocity_final + velocity_snapshots
        let ds = RgDataset::load(data_dir.join("phase2_64.npz")).unwrap();
        assert!(ds.has_volume_data);
        assert_eq!(ds.grid_size(), 64);
        assert!(ds.cascade_stats.is_some());
        let stats = ds.cascade_stats.as_ref().unwrap();
        assert_eq!(stats.mu_per_level.len(), 5);
        assert_eq!(stats.num_samples, 200);
        assert_eq!(stats.sample_energy.len(), 200);
        println!("phase2_64: OK, mu={:?}", stats.mu_per_level);

        // Test phase_a with snapshots
        let ds = RgDataset::load(data_dir.join("phase_a_64.npz")).unwrap();
        assert!(ds.has_volume_data);
        assert_eq!(ds.grid_size(), 64);
        assert_eq!(ds.num_snapshots, 20);
        assert!(ds.levels.len() >= 21); // 1 velocity_final + 20 snapshots
        assert!(ds.cascade_stats.is_some());
        let stats = ds.cascade_stats.as_ref().unwrap();
        assert_eq!(stats.zeta_p.len(), 8);
        // Per-level series should be present
        assert!(ds.data_series.contains_key("I2_mean_L0"));
        assert!(ds.data_series.contains_key("ln_f_mean_L4"));
        assert!(ds.data_series.contains_key("lagr_det_G_mean_L0"));
        println!(
            "phase_a_64: OK, snapshots={}, levels={}, series={}",
            ds.num_snapshots,
            ds.levels.len(),
            ds.data_series.len()
        );

        // Test stats-only files
        let ds = RgDataset::load(data_dir.join("summary.npz")).unwrap();
        assert!(!ds.has_volume_data);
        assert!(ds.cascade_stats.is_some());
        let stats = ds.cascade_stats.as_ref().unwrap();
        assert!(stats.sigma_max.is_finite());
        println!("summary: OK, sigma_max={}", stats.sigma_max);

        let ds = RgDataset::load(data_dir.join("spinup_history_64.npz")).unwrap();
        assert!(!ds.has_volume_data);
        assert!(ds.data_series.contains_key("energy"));
        assert!(ds.data_series.contains_key("enstrophy"));
        println!(
            "spinup_history_64: OK, series={:?}",
            ds.data_series.keys().collect::<Vec<_>>()
        );

        let ds = RgDataset::load(data_dir.join("phase_c_power.npz")).unwrap();
        assert!(!ds.has_volume_data);
        assert!(ds.cascade_stats.is_some());
        let stats = ds.cascade_stats.as_ref().unwrap();
        assert!(stats.power_converged);
        assert!(stats.sigma_max.is_finite());
        println!(
            "phase_c_power: OK, sigma_max={}, converged={}",
            stats.sigma_max, stats.power_converged
        );
    }
}
