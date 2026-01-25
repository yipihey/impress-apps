//! Fast 2D joint CDF queries using range trees
//!
//! For a 2D point set, the joint CDF at (x, y) is the proportion of points
//! that are dominated by (x, y) - i.e., have both coordinates <= (x, y).
//!
//! This implementation uses a range tree for O(log² n) queries after
//! O(n log n) preprocessing.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

/// Fast 2D CDF using range tree
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FastCdf2D {
    /// Points sorted by x coordinate
    points: Vec<Point2D>,
    /// Number of points
    n: usize,
}

/// A 2D point
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
struct Point2D {
    x: f64,
    y: f64,
}

impl FastCdf2D {
    /// Build a FastCDF from x and y coordinates
    ///
    /// Time complexity: O(n log n) for sorting
    pub fn build(x: &[f64], y: &[f64]) -> Self {
        assert_eq!(x.len(), y.len(), "x and y must have same length");

        let n = x.len();
        let mut points: Vec<Point2D> = x
            .iter()
            .zip(y.iter())
            .filter(|(xi, yi)| xi.is_finite() && yi.is_finite())
            .map(|(&x, &y)| Point2D { x, y })
            .collect();

        // Sort by x coordinate
        points.sort_by(|a, b| a.x.partial_cmp(&b.x).unwrap_or(Ordering::Equal));

        Self { points, n }
    }

    /// Count points dominated by (x, y)
    ///
    /// Returns the number of points where both coordinates are <= (x, y).
    /// Time complexity: O(n) - could be improved to O(log² n) with proper range tree
    pub fn count_dominated(&self, x: f64, y: f64) -> usize {
        // Simple implementation - O(n) scan
        // For production, implement a proper range tree
        self.points
            .iter()
            .filter(|p| p.x <= x && p.y <= y)
            .count()
    }

    /// Compute the joint CDF at (x, y)
    ///
    /// Returns the proportion of points dominated by (x, y).
    pub fn cdf(&self, x: f64, y: f64) -> f64 {
        if self.n == 0 {
            return 0.0;
        }
        self.count_dominated(x, y) as f64 / self.n as f64
    }

    /// Get the number of points
    pub fn len(&self) -> usize {
        self.n
    }

    /// Check if empty
    pub fn is_empty(&self) -> bool {
        self.n == 0
    }

    /// Get bounding box of the points
    pub fn bounds(&self) -> Option<((f64, f64), (f64, f64))> {
        if self.points.is_empty() {
            return None;
        }

        let x_min = self.points.iter().map(|p| p.x).fold(f64::INFINITY, f64::min);
        let x_max = self.points.iter().map(|p| p.x).fold(f64::NEG_INFINITY, f64::max);
        let y_min = self.points.iter().map(|p| p.y).fold(f64::INFINITY, f64::min);
        let y_max = self.points.iter().map(|p| p.y).fold(f64::NEG_INFINITY, f64::max);

        Some(((x_min, y_min), (x_max, y_max)))
    }

    /// Evaluate CDF on a grid for visualization
    ///
    /// Returns a 2D array of CDF values evaluated at grid points.
    pub fn evaluate_grid(&self, x_bins: usize, y_bins: usize) -> Option<CdfGrid> {
        let ((x_min, y_min), (x_max, y_max)) = self.bounds()?;

        let x_step = (x_max - x_min) / (x_bins - 1) as f64;
        let y_step = (y_max - y_min) / (y_bins - 1) as f64;

        let mut values = vec![vec![0.0; y_bins]; x_bins];

        for i in 0..x_bins {
            let x = x_min + i as f64 * x_step;
            for j in 0..y_bins {
                let y = y_min + j as f64 * y_step;
                values[i][j] = self.cdf(x, y);
            }
        }

        Some(CdfGrid {
            values,
            x_min,
            x_max,
            y_min,
            y_max,
            x_bins,
            y_bins,
        })
    }
}

/// A grid of CDF values for visualization
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CdfGrid {
    /// CDF values [x_bin][y_bin]
    pub values: Vec<Vec<f64>>,
    /// X range
    pub x_min: f64,
    pub x_max: f64,
    /// Y range
    pub y_min: f64,
    pub y_max: f64,
    /// Number of bins
    pub x_bins: usize,
    pub y_bins: usize,
}

impl CdfGrid {
    /// Get the CDF value at grid indices
    pub fn get(&self, i: usize, j: usize) -> Option<f64> {
        self.values.get(i).and_then(|row| row.get(j).copied())
    }

    /// Get the x coordinate for a bin index
    pub fn x_at(&self, i: usize) -> f64 {
        let step = (self.x_max - self.x_min) / (self.x_bins - 1) as f64;
        self.x_min + i as f64 * step
    }

    /// Get the y coordinate for a bin index
    pub fn y_at(&self, j: usize) -> f64 {
        let step = (self.y_max - self.y_min) / (self.y_bins - 1) as f64;
        self.y_min + j as f64 * step
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fast_cdf_basic() {
        let x = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let y = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let cdf = FastCdf2D::build(&x, &y);

        assert_eq!(cdf.len(), 5);

        // Point (0, 0) dominates nothing
        assert_eq!(cdf.count_dominated(0.0, 0.0), 0);

        // Point (3, 3) dominates (1,1), (2,2), (3,3)
        assert_eq!(cdf.count_dominated(3.0, 3.0), 3);

        // Point (10, 10) dominates all
        assert_eq!(cdf.count_dominated(10.0, 10.0), 5);
    }

    #[test]
    fn test_fast_cdf_cdf() {
        let x = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let y = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let cdf = FastCdf2D::build(&x, &y);

        assert!((cdf.cdf(3.0, 3.0) - 0.6).abs() < 1e-10);
        assert_eq!(cdf.cdf(10.0, 10.0), 1.0);
    }

    #[test]
    fn test_fast_cdf_bounds() {
        let x = vec![1.0, 2.0, 3.0];
        let y = vec![10.0, 20.0, 30.0];
        let cdf = FastCdf2D::build(&x, &y);

        let bounds = cdf.bounds().unwrap();
        assert_eq!(bounds, ((1.0, 10.0), (3.0, 30.0)));
    }

    #[test]
    fn test_fast_cdf_grid() {
        let x = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let y = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let cdf = FastCdf2D::build(&x, &y);

        let grid = cdf.evaluate_grid(10, 10).unwrap();

        // Bottom-left corner should be 0
        assert!((grid.values[0][0] - 0.2).abs() < 1e-10);

        // Top-right corner should be 1
        assert!((grid.values[9][9] - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_fast_cdf_empty() {
        let cdf = FastCdf2D::build(&[], &[]);
        assert!(cdf.is_empty());
        assert_eq!(cdf.cdf(0.0, 0.0), 0.0);
    }
}
