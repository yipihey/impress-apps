//! Empirical Cumulative Distribution Function (ECDF)
//!
//! The ECDF is a step function that estimates the underlying CDF of a sample.
//! For a sample of n values, ECDF(x) = (number of values <= x) / n.
//!
//! # Advantages over Histograms
//!
//! - No bin width to choose
//! - Preserves all information
//! - Consistent visual comparison across datasets
//! - O(log n) quantile queries

use serde::{Deserialize, Serialize};

/// Empirical Cumulative Distribution Function
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Ecdf {
    /// Sorted values
    values: Vec<f64>,
    /// CDF values (0 to 1) at each point
    cdf: Vec<f64>,
    /// Number of samples
    n: usize,
}

impl Ecdf {
    /// Build an ECDF from data
    ///
    /// Time complexity: O(n log n) for sorting
    pub fn from_data(data: &[f64]) -> Self {
        let n = data.len();
        if n == 0 {
            return Self {
                values: Vec::new(),
                cdf: Vec::new(),
                n: 0,
            };
        }

        // Sort the data
        let mut values: Vec<f64> = data.iter().copied().filter(|x| x.is_finite()).collect();
        values.sort_by(|a, b| a.partial_cmp(b).unwrap());

        // Compute CDF values
        let cdf: Vec<f64> = (1..=values.len())
            .map(|i| i as f64 / values.len() as f64)
            .collect();

        Self {
            values,
            cdf,
            n,
        }
    }

    /// Evaluate the ECDF at a point
    ///
    /// Returns the proportion of values <= x
    /// Time complexity: O(log n)
    pub fn evaluate(&self, x: f64) -> f64 {
        if self.values.is_empty() {
            return 0.0;
        }

        // Binary search for the insertion point
        match self.values.binary_search_by(|v| v.partial_cmp(&x).unwrap()) {
            Ok(idx) => {
                // Exact match - find the last occurrence
                let mut last = idx;
                while last + 1 < self.values.len() && self.values[last + 1] == x {
                    last += 1;
                }
                self.cdf[last]
            }
            Err(idx) => {
                if idx == 0 {
                    0.0
                } else {
                    self.cdf[idx - 1]
                }
            }
        }
    }

    /// Get the quantile (inverse CDF)
    ///
    /// Returns the smallest value x such that ECDF(x) >= p
    /// Time complexity: O(log n)
    pub fn quantile(&self, p: f64) -> Option<f64> {
        if self.values.is_empty() || p < 0.0 || p > 1.0 {
            return None;
        }

        if p == 0.0 {
            return Some(self.values[0]);
        }

        // Binary search for the quantile
        match self.cdf.binary_search_by(|v| v.partial_cmp(&p).unwrap()) {
            Ok(idx) => Some(self.values[idx]),
            Err(idx) => {
                if idx < self.values.len() {
                    Some(self.values[idx])
                } else {
                    Some(self.values[self.values.len() - 1])
                }
            }
        }
    }

    /// Get common quantiles (min, 25%, median, 75%, max)
    pub fn five_number_summary(&self) -> Option<FiveNumberSummary> {
        if self.values.is_empty() {
            return None;
        }

        Some(FiveNumberSummary {
            min: self.values[0],
            q1: self.quantile(0.25)?,
            median: self.quantile(0.5)?,
            q3: self.quantile(0.75)?,
            max: self.values[self.values.len() - 1],
        })
    }

    /// Get the median
    pub fn median(&self) -> Option<f64> {
        self.quantile(0.5)
    }

    /// Get the interquartile range (IQR)
    pub fn iqr(&self) -> Option<f64> {
        let q1 = self.quantile(0.25)?;
        let q3 = self.quantile(0.75)?;
        Some(q3 - q1)
    }

    /// Get the range (max - min)
    pub fn range(&self) -> Option<f64> {
        if self.values.is_empty() {
            return None;
        }
        Some(self.values[self.values.len() - 1] - self.values[0])
    }

    /// Get the number of samples
    pub fn len(&self) -> usize {
        self.n
    }

    /// Check if the ECDF is empty
    pub fn is_empty(&self) -> bool {
        self.n == 0
    }

    /// Get the sorted values for plotting
    pub fn values(&self) -> &[f64] {
        &self.values
    }

    /// Get the CDF values for plotting
    pub fn cdf_values(&self) -> &[f64] {
        &self.cdf
    }

    /// Get points for step-function plotting (x, y pairs)
    ///
    /// Returns coordinates suitable for plotting as a step function
    pub fn plot_points(&self) -> Vec<(f64, f64)> {
        if self.values.is_empty() {
            return Vec::new();
        }

        let mut points = Vec::with_capacity(self.values.len() * 2 + 2);

        // Start at (min, 0)
        points.push((self.values[0], 0.0));

        for i in 0..self.values.len() {
            // Horizontal line to this point
            if i > 0 {
                points.push((self.values[i], self.cdf[i - 1]));
            }
            // Vertical step up
            points.push((self.values[i], self.cdf[i]));
        }

        points
    }
}

/// Five number summary statistics
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct FiveNumberSummary {
    pub min: f64,
    pub q1: f64,
    pub median: f64,
    pub q3: f64,
    pub max: f64,
}

impl FiveNumberSummary {
    /// Get the interquartile range
    pub fn iqr(&self) -> f64 {
        self.q3 - self.q1
    }

    /// Get the range
    pub fn range(&self) -> f64 {
        self.max - self.min
    }

    /// Lower fence for outlier detection (Q1 - 1.5 * IQR)
    pub fn lower_fence(&self) -> f64 {
        self.q1 - 1.5 * self.iqr()
    }

    /// Upper fence for outlier detection (Q3 + 1.5 * IQR)
    pub fn upper_fence(&self) -> f64 {
        self.q3 + 1.5 * self.iqr()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ecdf_basic() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let ecdf = Ecdf::from_data(&data);

        assert_eq!(ecdf.len(), 5);
        assert_eq!(ecdf.evaluate(0.0), 0.0);
        assert_eq!(ecdf.evaluate(1.0), 0.2);
        assert_eq!(ecdf.evaluate(3.0), 0.6);
        assert_eq!(ecdf.evaluate(5.0), 1.0);
        assert_eq!(ecdf.evaluate(6.0), 1.0);
    }

    #[test]
    fn test_ecdf_quantiles() {
        let data: Vec<f64> = (1..=100).map(|x| x as f64).collect();
        let ecdf = Ecdf::from_data(&data);

        assert_eq!(ecdf.quantile(0.0), Some(1.0));
        assert_eq!(ecdf.quantile(0.5), Some(50.0));
        assert_eq!(ecdf.quantile(1.0), Some(100.0));
    }

    #[test]
    fn test_ecdf_five_number_summary() {
        let data: Vec<f64> = (1..=100).map(|x| x as f64).collect();
        let ecdf = Ecdf::from_data(&data);
        let summary = ecdf.five_number_summary().unwrap();

        assert_eq!(summary.min, 1.0);
        assert_eq!(summary.max, 100.0);
        assert_eq!(summary.median, 50.0);
    }

    #[test]
    fn test_ecdf_empty() {
        let ecdf = Ecdf::from_data(&[]);
        assert!(ecdf.is_empty());
        assert_eq!(ecdf.evaluate(0.0), 0.0);
        assert!(ecdf.quantile(0.5).is_none());
    }

    #[test]
    fn test_ecdf_duplicates() {
        let data = vec![1.0, 1.0, 2.0, 2.0, 2.0, 3.0];
        let ecdf = Ecdf::from_data(&data);

        // With 6 values, after sorting: [1,1,2,2,2,3]
        // CDF: [1/6, 2/6, 3/6, 4/6, 5/6, 6/6]
        assert!((ecdf.evaluate(1.0) - 2.0 / 6.0).abs() < 1e-10);
        assert!((ecdf.evaluate(2.0) - 5.0 / 6.0).abs() < 1e-10);
    }

    #[test]
    fn test_ecdf_plot_points() {
        let data = vec![1.0, 2.0, 3.0];
        let ecdf = Ecdf::from_data(&data);
        let points = ecdf.plot_points();

        // Should start at (1, 0)
        assert_eq!(points[0], (1.0, 0.0));
        // Should end at (3, 1)
        assert!(points.last().unwrap().1 > 0.99);
    }
}
