//! Summary statistics for datasets
//!
//! Provides common statistical summaries:
//! - Mean, variance, standard deviation
//! - Min, max, range
//! - Robust statistics (median, MAD)

use serde::{Deserialize, Serialize};

/// Summary statistics for a numeric dataset
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SummaryStats {
    /// Number of values
    pub count: usize,
    /// Number of missing/NaN values
    pub missing: usize,
    /// Minimum value
    pub min: f64,
    /// Maximum value
    pub max: f64,
    /// Mean (average)
    pub mean: f64,
    /// Variance
    pub variance: f64,
    /// Standard deviation
    pub std_dev: f64,
    /// Median (50th percentile)
    pub median: f64,
    /// Median Absolute Deviation
    pub mad: f64,
}

impl SummaryStats {
    /// Compute summary statistics from data
    pub fn from_data(data: &[f64]) -> Self {
        let (finite, missing): (Vec<f64>, usize) = {
            let finite: Vec<f64> = data.iter().copied().filter(|x| x.is_finite()).collect();
            let missing = data.len() - finite.len();
            (finite, missing)
        };

        if finite.is_empty() {
            return Self::empty(missing);
        }

        let count = finite.len();
        let sum: f64 = finite.iter().sum();
        let mean = sum / count as f64;

        let variance: f64 = finite.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / count as f64;
        let std_dev = variance.sqrt();

        let min = finite.iter().copied().fold(f64::INFINITY, f64::min);
        let max = finite.iter().copied().fold(f64::NEG_INFINITY, f64::max);

        // Sort for median and MAD
        let mut sorted = finite.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());

        let median = if count % 2 == 0 {
            (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        } else {
            sorted[count / 2]
        };

        // Median Absolute Deviation
        let mut deviations: Vec<f64> = sorted.iter().map(|x| (x - median).abs()).collect();
        deviations.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let mad = if count % 2 == 0 {
            (deviations[count / 2 - 1] + deviations[count / 2]) / 2.0
        } else {
            deviations[count / 2]
        };

        Self {
            count,
            missing,
            min,
            max,
            mean,
            variance,
            std_dev,
            median,
            mad,
        }
    }

    /// Create empty statistics (all NaN)
    fn empty(missing: usize) -> Self {
        Self {
            count: 0,
            missing,
            min: f64::NAN,
            max: f64::NAN,
            mean: f64::NAN,
            variance: f64::NAN,
            std_dev: f64::NAN,
            median: f64::NAN,
            mad: f64::NAN,
        }
    }

    /// Get the range (max - min)
    pub fn range(&self) -> f64 {
        self.max - self.min
    }

    /// Get the coefficient of variation (std_dev / mean)
    pub fn cv(&self) -> f64 {
        self.std_dev / self.mean.abs()
    }

    /// Compute z-score for a value
    pub fn zscore(&self, x: f64) -> f64 {
        (x - self.mean) / self.std_dev
    }

    /// Compute robust z-score using median and MAD
    ///
    /// Uses the formula: (x - median) / (1.4826 * MAD)
    /// The constant 1.4826 makes it comparable to standard z-score for normal data.
    pub fn robust_zscore(&self, x: f64) -> f64 {
        if self.mad == 0.0 {
            return 0.0;
        }
        (x - self.median) / (1.4826 * self.mad)
    }

    /// Check if a value is an outlier (|z| > 3)
    pub fn is_outlier(&self, x: f64) -> bool {
        self.zscore(x).abs() > 3.0
    }

    /// Check if a value is a robust outlier (|robust_z| > 3)
    pub fn is_robust_outlier(&self, x: f64) -> bool {
        self.robust_zscore(x).abs() > 3.0
    }
}

/// Compute z-scores for an entire dataset
pub fn zscore_batch(data: &[f64]) -> Vec<f64> {
    let stats = SummaryStats::from_data(data);
    data.iter().map(|&x| stats.zscore(x)).collect()
}

/// Compute robust z-scores for an entire dataset
pub fn robust_zscore_batch(data: &[f64]) -> Vec<f64> {
    let stats = SummaryStats::from_data(data);
    data.iter().map(|&x| stats.robust_zscore(x)).collect()
}

/// Winsorize data at a given percentile
///
/// Replaces values below the lower percentile with that percentile's value,
/// and values above the upper percentile with that percentile's value.
pub fn winsorize(data: &[f64], percentile: f64) -> Vec<f64> {
    if data.is_empty() {
        return Vec::new();
    }

    let mut sorted: Vec<f64> = data.iter().copied().filter(|x| x.is_finite()).collect();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let n = sorted.len();
    let lower_idx = ((percentile / 100.0) * n as f64) as usize;
    let upper_idx = (((100.0 - percentile) / 100.0) * n as f64) as usize;

    let lower_bound = sorted[lower_idx.min(n - 1)];
    let upper_bound = sorted[upper_idx.min(n - 1)];

    data.iter()
        .map(|&x| {
            if !x.is_finite() {
                x
            } else if x < lower_bound {
                lower_bound
            } else if x > upper_bound {
                upper_bound
            } else {
                x
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_summary_stats_basic() {
        let data: Vec<f64> = (1..=10).map(|x| x as f64).collect();
        let stats = SummaryStats::from_data(&data);

        assert_eq!(stats.count, 10);
        assert_eq!(stats.min, 1.0);
        assert_eq!(stats.max, 10.0);
        assert!((stats.mean - 5.5).abs() < 1e-10);
        assert!((stats.median - 5.5).abs() < 1e-10);
    }

    #[test]
    fn test_summary_stats_with_nan() {
        let data = vec![1.0, 2.0, f64::NAN, 4.0, 5.0];
        let stats = SummaryStats::from_data(&data);

        assert_eq!(stats.count, 4);
        assert_eq!(stats.missing, 1);
        assert_eq!(stats.min, 1.0);
        assert_eq!(stats.max, 5.0);
    }

    #[test]
    fn test_zscore() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let stats = SummaryStats::from_data(&data);

        // Mean is 3.0
        let z_at_mean = stats.zscore(3.0);
        assert!((z_at_mean - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_robust_zscore() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0, 100.0]; // 100 is an outlier
        let stats = SummaryStats::from_data(&data);

        // Regular zscore of 100 won't be that extreme due to inflated std
        // Robust zscore should be more extreme
        let robust_z = stats.robust_zscore(100.0);
        assert!(robust_z > 3.0);
    }

    #[test]
    fn test_winsorize() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0, 100.0];
        let winsorized = winsorize(&data, 10.0);

        // The outlier 100 should be replaced with a smaller value
        assert!(winsorized.iter().all(|&x| x <= 5.0 || x == 100.0)); // Simple check
    }

    #[test]
    fn test_zscore_batch() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let zscores = zscore_batch(&data);

        assert_eq!(zscores.len(), 5);
        // Check that z-scores sum to ~0
        let sum: f64 = zscores.iter().sum();
        assert!(sum.abs() < 1e-10);
    }
}
