//! Histogram computation with automatic binning, KDE overlay, and statistics.
//!
//! Implements the `Histogram1DConfig` scaffolded in `render.rs` using the
//! `PlotSpec` rendering pipeline.

use super::types::*;
use crate::render::{BinEdgeMode, Histogram1DConfig};

/// Result of histogram computation.
#[derive(Clone, Debug)]
pub struct HistogramResult {
    /// Bin edges (len = num_bins + 1).
    pub bin_edges: Vec<f64>,
    /// Counts per bin (len = num_bins).
    pub counts: Vec<f64>,
    /// Normalized density per bin (counts / (total * bin_width)).
    pub density: Vec<f64>,
    /// KDE x coordinates (denser sampling for smooth curve).
    pub kde_x: Vec<f64>,
    /// KDE y values.
    pub kde_y: Vec<f64>,
    /// Summary statistics.
    pub stats: HistogramStats,
}

/// Summary statistics for the histogram data.
#[derive(Clone, Debug)]
pub struct HistogramStats {
    pub count: usize,
    pub mean: f64,
    pub std_dev: f64,
    pub median: f64,
    pub min: f64,
    pub max: f64,
    pub q1: f64,
    pub q3: f64,
}

/// Compute a histogram from raw data.
pub fn compute_histogram(data: &[f64], config: &Histogram1DConfig) -> HistogramResult {
    // Filter finite values
    let mut values: Vec<f64> = data.iter().copied().filter(|v| v.is_finite()).collect();
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let n = values.len();
    if n == 0 {
        return empty_result();
    }

    let stats = compute_stats(&values);

    // Determine bin edges
    let bin_edges = match &config.bin_edges {
        BinEdgeMode::Custom(edges) => edges.clone(),
        BinEdgeMode::Linear => {
            let num_bins = config.num_bins.map(|b| b as usize).unwrap_or_else(|| auto_bin_count(&values));
            linear_bin_edges(stats.min, stats.max, num_bins)
        }
        BinEdgeMode::Logarithmic => {
            let num_bins = config.num_bins.map(|b| b as usize).unwrap_or_else(|| auto_bin_count(&values));
            if stats.min <= 0.0 {
                // Fall back to linear if data has non-positive values
                linear_bin_edges(stats.min, stats.max, num_bins)
            } else {
                log_bin_edges(stats.min, stats.max, num_bins)
            }
        }
    };

    let num_bins = if bin_edges.len() > 1 { bin_edges.len() - 1 } else { 1 };

    // Count values in each bin
    let mut counts = vec![0.0; num_bins];
    for &v in &values {
        // Binary search for bin
        let bin = match bin_edges[1..].binary_search_by(|edge| edge.partial_cmp(&v).unwrap()) {
            Ok(i) => i.min(num_bins - 1),
            Err(i) => i.min(num_bins - 1),
        };
        counts[bin] += 1.0;
    }

    // Density normalization
    let density: Vec<f64> = counts
        .iter()
        .enumerate()
        .map(|(i, &c)| {
            let width = bin_edges[i + 1] - bin_edges[i];
            if width > 0.0 { c / (n as f64 * width) } else { 0.0 }
        })
        .collect();

    // KDE
    let (kde_x, kde_y) = if config.show_kde {
        let bandwidth = config.kde_bandwidth.unwrap_or_else(|| scott_bandwidth(&values));
        compute_kde(&values, stats.min, stats.max, bandwidth)
    } else {
        (vec![], vec![])
    };

    HistogramResult {
        bin_edges,
        counts,
        density,
        kde_x,
        kde_y,
        stats,
    }
}

/// Convert a HistogramResult into a PlotSpec.
pub fn histogram_to_plot_spec(result: &HistogramResult, config: &Histogram1DConfig) -> PlotSpec {
    let num_bins = result.counts.len();
    if num_bins == 0 {
        return PlotSpec::new().with_title(&config.field);
    }

    // Bar centers and widths
    let mut bar_x = Vec::with_capacity(num_bins);
    let bar_y = if config.log_scale_y {
        result.counts.iter().map(|&c| if c > 0.0 { c } else { 0.5 }).collect::<Vec<_>>()
    } else {
        result.counts.clone()
    };

    for i in 0..num_bins {
        bar_x.push((result.bin_edges[i] + result.bin_edges[i + 1]) / 2.0);
    }

    let mut spec = PlotSpec::new()
        .with_title(format!("Histogram: {}", config.field))
        .with_x_label(&config.field)
        .with_y_label("Count");

    if config.log_scale_x {
        spec = spec.with_log_x();
    }
    if config.log_scale_y {
        spec = spec.with_log_y();
    }

    // Bar series
    let bar_series = PlotSeries {
        label: config.field.clone(),
        x: bar_x,
        y: bar_y,
        error_low: None,
        error_high: None,
        style: SeriesStyle::Bar,
        color: PlotColor::Blue,
        point_radius: 3.0,
        line_width: 1.0,
    };
    spec = spec.add_series(bar_series);

    // KDE overlay (uses density normalization)
    if config.show_kde && !result.kde_x.is_empty() {
        // Scale KDE to match count scale
        let total = result.counts.iter().sum::<f64>();
        let avg_width = if num_bins > 0 {
            (result.bin_edges.last().unwrap() - result.bin_edges[0]) / num_bins as f64
        } else {
            1.0
        };
        let scale = total * avg_width;

        let kde_y_scaled: Vec<f64> = result.kde_y.iter().map(|&y| y * scale).collect();

        let kde_series = PlotSeries {
            label: "KDE".to_string(),
            x: result.kde_x.clone(),
            y: kde_y_scaled,
            error_low: None,
            error_high: None,
            style: SeriesStyle::Line,
            color: PlotColor::Red,
            point_radius: 0.0,
            line_width: 2.0,
        };
        spec = spec.add_series(kde_series);
    }

    // Statistics annotation via subtitle
    if config.show_statistics {
        let s = &result.stats;
        spec.title = Some(format!(
            "Histogram: {} (n={}, mean={:.3}, std={:.3}, median={:.3})",
            config.field, s.count, s.mean, s.std_dev, s.median
        ));
    }

    spec
}

// ── Auto bin count ──────────────────────────────────────────────────

/// Freedman-Diaconis rule for automatic bin width.
fn auto_bin_count(sorted: &[f64]) -> usize {
    let n = sorted.len();
    if n < 2 {
        return 1;
    }

    let iqr = percentile(sorted, 0.75) - percentile(sorted, 0.25);
    let range = sorted[n - 1] - sorted[0];

    if iqr == 0.0 || range == 0.0 {
        // Scott's rule fallback
        return scott_bin_count(sorted);
    }

    let bin_width = 2.0 * iqr * (n as f64).powf(-1.0 / 3.0);
    let num_bins = (range / bin_width).ceil() as usize;

    num_bins.clamp(5, 200)
}

/// Scott's rule for bin width.
fn scott_bin_count(sorted: &[f64]) -> usize {
    let n = sorted.len();
    if n < 2 {
        return 1;
    }

    let mean = sorted.iter().sum::<f64>() / n as f64;
    let variance = sorted.iter().map(|&v| (v - mean).powi(2)).sum::<f64>() / n as f64;
    let std_dev = variance.sqrt();
    let range = sorted[n - 1] - sorted[0];

    if std_dev == 0.0 || range == 0.0 {
        return 10;
    }

    let bin_width = 3.49 * std_dev * (n as f64).powf(-1.0 / 3.0);
    let num_bins = (range / bin_width).ceil() as usize;

    num_bins.clamp(5, 200)
}

// ── Bin edges ───────────────────────────────────────────────────────

fn linear_bin_edges(min: f64, max: f64, num_bins: usize) -> Vec<f64> {
    let num_bins = num_bins.max(1);
    let step = (max - min) / num_bins as f64;
    (0..=num_bins).map(|i| min + i as f64 * step).collect()
}

fn log_bin_edges(min: f64, max: f64, num_bins: usize) -> Vec<f64> {
    let num_bins = num_bins.max(1);
    let log_min = min.max(1e-30).ln();
    let log_max = max.max(min + 1e-30).ln();
    let step = (log_max - log_min) / num_bins as f64;
    (0..=num_bins).map(|i| (log_min + i as f64 * step).exp()).collect()
}

// ── KDE ─────────────────────────────────────────────────────────────

/// Scott's rule for KDE bandwidth.
fn scott_bandwidth(sorted: &[f64]) -> f64 {
    let n = sorted.len();
    if n < 2 {
        return 1.0;
    }

    let mean = sorted.iter().sum::<f64>() / n as f64;
    let variance = sorted.iter().map(|&v| (v - mean).powi(2)).sum::<f64>() / (n - 1) as f64;
    let std_dev = variance.sqrt();

    if std_dev == 0.0 {
        return 1.0;
    }

    // Silverman's rule of thumb
    let iqr = percentile(sorted, 0.75) - percentile(sorted, 0.25);
    let a = std_dev.min(iqr / 1.34);
    0.9 * a * (n as f64).powf(-0.2)
}

/// Compute Gaussian KDE.
fn compute_kde(sorted: &[f64], min: f64, max: f64, bandwidth: f64) -> (Vec<f64>, Vec<f64>) {
    let n_points = 200;
    let range = max - min;
    let pad = range * 0.1;
    let x_min = min - pad;
    let x_max = max + pad;
    let step = (x_max - x_min) / (n_points - 1) as f64;

    let n = sorted.len() as f64;
    let inv_bw = 1.0 / bandwidth;
    let norm = inv_bw / (n * (2.0 * std::f64::consts::PI).sqrt());

    let mut xs = Vec::with_capacity(n_points);
    let mut ys = Vec::with_capacity(n_points);

    for i in 0..n_points {
        let x = x_min + i as f64 * step;
        let mut density = 0.0;
        for &v in sorted {
            let u = (x - v) * inv_bw;
            density += (-0.5 * u * u).exp();
        }
        xs.push(x);
        ys.push(density * norm);
    }

    (xs, ys)
}

// ── Statistics ──────────────────────────────────────────────────────

fn compute_stats(sorted: &[f64]) -> HistogramStats {
    let n = sorted.len();
    if n == 0 {
        return HistogramStats {
            count: 0,
            mean: 0.0,
            std_dev: 0.0,
            median: 0.0,
            min: 0.0,
            max: 0.0,
            q1: 0.0,
            q3: 0.0,
        };
    }

    let mean = sorted.iter().sum::<f64>() / n as f64;
    let variance = sorted.iter().map(|&v| (v - mean).powi(2)).sum::<f64>() / n as f64;

    HistogramStats {
        count: n,
        mean,
        std_dev: variance.sqrt(),
        median: percentile(sorted, 0.5),
        min: sorted[0],
        max: sorted[n - 1],
        q1: percentile(sorted, 0.25),
        q3: percentile(sorted, 0.75),
    }
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    if n == 1 {
        return sorted[0];
    }

    let idx = p * (n - 1) as f64;
    let lo = idx.floor() as usize;
    let hi = (lo + 1).min(n - 1);
    let frac = idx - lo as f64;

    sorted[lo] * (1.0 - frac) + sorted[hi] * frac
}

fn empty_result() -> HistogramResult {
    HistogramResult {
        bin_edges: vec![0.0, 1.0],
        counts: vec![0.0],
        density: vec![0.0],
        kde_x: vec![],
        kde_y: vec![],
        stats: HistogramStats {
            count: 0,
            mean: 0.0,
            std_dev: 0.0,
            median: 0.0,
            min: 0.0,
            max: 0.0,
            q1: 0.0,
            q3: 0.0,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_auto_bin_count() {
        let data: Vec<f64> = (0..1000).map(|i| i as f64 / 100.0).collect();
        let bins = auto_bin_count(&data);
        assert!(bins >= 5 && bins <= 200);
    }

    #[test]
    fn test_compute_histogram() {
        let data: Vec<f64> = (0..100).map(|i| i as f64).collect();
        let config = Histogram1DConfig::default();
        let result = compute_histogram(&data, &config);

        assert!(result.counts.len() > 1);
        assert_eq!(result.stats.count, 100);
        assert!((result.stats.mean - 49.5).abs() < 0.01);
        assert!((result.stats.median - 49.5).abs() < 0.5);
    }

    #[test]
    fn test_compute_stats() {
        let mut data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let stats = compute_stats(&data);
        assert_eq!(stats.count, 5);
        assert!((stats.mean - 3.0).abs() < 1e-10);
        assert!((stats.median - 3.0).abs() < 1e-10);
        assert_eq!(stats.min, 1.0);
        assert_eq!(stats.max, 5.0);
    }

    #[test]
    fn test_kde() {
        let data: Vec<f64> = (0..100).map(|i| i as f64).collect();
        let bw = scott_bandwidth(&data);
        assert!(bw > 0.0);

        let (xs, ys) = compute_kde(&data, 0.0, 99.0, bw);
        assert_eq!(xs.len(), 200);
        assert_eq!(ys.len(), 200);
        // KDE density should be positive
        assert!(ys.iter().all(|&y| y >= 0.0));
    }

    #[test]
    fn test_histogram_to_plot_spec() {
        let data: Vec<f64> = (0..100).map(|i| i as f64).collect();
        let config = Histogram1DConfig::default();
        let result = compute_histogram(&data, &config);
        let spec = histogram_to_plot_spec(&result, &config);

        assert!(spec.series.len() >= 1);
        assert_eq!(spec.series[0].style, SeriesStyle::Bar);
    }

    #[test]
    fn test_empty_histogram() {
        let data: Vec<f64> = vec![];
        let config = Histogram1DConfig::default();
        let result = compute_histogram(&data, &config);
        assert_eq!(result.stats.count, 0);
    }

    #[test]
    fn test_log_bins() {
        let edges = log_bin_edges(1.0, 1000.0, 3);
        assert_eq!(edges.len(), 4);
        assert!((edges[0] - 1.0).abs() < 0.01);
        assert!((edges[3] - 1000.0).abs() < 1.0);
    }

    #[test]
    fn test_percentile() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        assert!((percentile(&data, 0.0) - 1.0).abs() < 1e-10);
        assert!((percentile(&data, 0.5) - 3.0).abs() < 1e-10);
        assert!((percentile(&data, 1.0) - 5.0).abs() < 1e-10);
        assert!((percentile(&data, 0.25) - 2.0).abs() < 1e-10);
    }
}
