//! Probability-integral-transform CDF (PCDF)
//!
//! The PCDF transforms data via the probability integral transform,
//! mapping values to the interval [0, 1] based on their rank in the sample.
//!
//! This is useful for:
//! - Comparing distributions visually
//! - Detecting departures from uniformity
//! - Creating normalized color mappings

use crate::ecdf::Ecdf;
use serde::{Deserialize, Serialize};

/// Probability-integral-transform CDF
///
/// Maps values to [0, 1] based on their empirical rank.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pcdf {
    ecdf: Ecdf,
}

impl Pcdf {
    /// Build a PCDF from data
    pub fn from_data(data: &[f64]) -> Self {
        Self {
            ecdf: Ecdf::from_data(data),
        }
    }

    /// Transform a value to its probability
    ///
    /// Returns a value in [0, 1] representing the proportion of
    /// data values <= x.
    pub fn transform(&self, x: f64) -> f64 {
        self.ecdf.evaluate(x)
    }

    /// Transform multiple values
    pub fn transform_batch(&self, values: &[f64]) -> Vec<f64> {
        values.iter().map(|&x| self.transform(x)).collect()
    }

    /// Inverse transform (quantile function)
    ///
    /// Given a probability p in [0, 1], returns the value x such that
    /// approximately p proportion of data values are <= x.
    pub fn inverse_transform(&self, p: f64) -> Option<f64> {
        self.ecdf.quantile(p)
    }

    /// Get the underlying ECDF
    pub fn ecdf(&self) -> &Ecdf {
        &self.ecdf
    }

    /// Check if the PCDF is empty
    pub fn is_empty(&self) -> bool {
        self.ecdf.is_empty()
    }

    /// Get the number of samples
    pub fn len(&self) -> usize {
        self.ecdf.len()
    }
}

/// Normalize a dataset to [0, 1] using the PCDF transform
///
/// This is useful for colormap normalization that respects the
/// actual data distribution.
pub fn normalize_to_uniform(data: &[f64]) -> Vec<f64> {
    let pcdf = Pcdf::from_data(data);
    pcdf.transform_batch(data)
}

/// Check if a dataset is approximately uniform
///
/// Uses the Kolmogorov-Smirnov test statistic (D) against uniform.
pub fn uniformity_test_statistic(data: &[f64]) -> f64 {
    let pcdf = Pcdf::from_data(data);
    let transformed = pcdf.transform_batch(data);

    // Sort the transformed values
    let mut sorted = transformed;
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let n = sorted.len() as f64;
    let mut d_max = 0.0_f64;

    for (i, &value) in sorted.iter().enumerate() {
        let expected = (i as f64 + 0.5) / n;
        let d = (value - expected).abs();
        d_max = d_max.max(d);
    }

    d_max
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pcdf_transform() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let pcdf = Pcdf::from_data(&data);

        // Min should map to 0.2 (1/5)
        assert!((pcdf.transform(1.0) - 0.2).abs() < 1e-10);
        // Max should map to 1.0
        assert!((pcdf.transform(5.0) - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_pcdf_inverse() {
        let data: Vec<f64> = (1..=100).map(|x| x as f64).collect();
        let pcdf = Pcdf::from_data(&data);

        assert_eq!(pcdf.inverse_transform(0.5), Some(50.0));
    }

    #[test]
    fn test_normalize_to_uniform() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let normalized = normalize_to_uniform(&data);

        // All values should be in [0, 1]
        assert!(normalized.iter().all(|&x| (0.0..=1.0).contains(&x)));
    }

    #[test]
    fn test_uniformity_statistic() {
        // Uniform data should have small D statistic
        let uniform: Vec<f64> = (0..100).map(|i| i as f64 / 99.0).collect();
        let d = uniformity_test_statistic(&uniform);
        assert!(d < 0.1);
    }
}
