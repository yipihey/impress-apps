//! Unified plot with automatic vector↔raster strategy.
//!
//! [`Plot`] is the one entry point a caller reaches for: give it series + axes,
//! and `render()` picks the cheapest faithful representation — a crisp **vector**
//! line/scatter below the point threshold, a binned **raster** heatmap above it
//! (the `plot_spike` scaling test put the vector ceiling around 10k vertices).
//!
//! The raster path bins in **normalized-axis space**, so per-axis lin/log +
//! min/max flow through identically to the vector path: a log axis simply yields
//! log-spaced bins, and the decade ticks line up with the image for free.

use crate::axis::Axis;
use crate::colormap::Colormap;
use crate::contour::ContourLevels;
use crate::hist2d::{ColorScale, Hist2D, Normalization};
use crate::render::{ContourFigure, Hist2DFigure, LinePlot, PlotOutput, PlotSize, Series};

/// Requested rendering strategy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Strategy {
    /// Pick vector or raster by point count (default).
    Auto,
    /// Always vector (line/scatter).
    Vector,
    /// Always raster (2D-histogram heatmap).
    Raster,
}

/// The concrete strategy `Auto` resolved to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Chosen {
    Vector,
    Raster,
}

/// A plot that renders itself as vector or raster as appropriate.
#[derive(Clone, Debug)]
pub struct Plot {
    pub title: String,
    pub x: Axis,
    pub y: Axis,
    pub series: Vec<Series>,
    pub strategy: Strategy,
    /// Point count above which `Auto` switches to raster.
    pub raster_threshold: usize,
    /// Colormap for the raster path.
    pub cmap: Colormap,
    /// Bin grid for the raster path.
    pub bins: (usize, usize),
    /// Asset id for the raster path.
    pub asset_id: String,
    /// Number of contour levels for contour series (default 7). Log-spaced
    /// automatically since the density color scale is log.
    pub contour_levels: usize,
    /// Draw the heatmap under contour lines (default true — classic look).
    pub contour_underlay: bool,
    /// Gaussian pre-smoothing (bins) for contour extraction; raw binned
    /// densities contour their Poisson noise. Default 2.0; 0 = off.
    pub contour_smooth_sigma: f64,
    /// Inline level labels on contour rings (default true).
    pub contour_labels: bool,
}

impl Plot {
    pub fn new(x: Axis, y: Axis) -> Self {
        Self {
            title: String::new(),
            x,
            y,
            series: Vec::new(),
            strategy: Strategy::Auto,
            raster_threshold: 10_000,
            cmap: Colormap::Viridis,
            bins: (160, 160),
            asset_id: "plot_raster.png".into(),
            contour_levels: 7,
            contour_underlay: true,
            contour_smooth_sigma: 2.0,
            contour_labels: true,
        }
    }
    pub fn title(mut self, t: impl Into<String>) -> Self {
        self.title = t.into();
        self
    }
    pub fn line(mut self, xs: Vec<f64>, ys: Vec<f64>, color: [u8; 3]) -> Self {
        self.series.push(Series::Line {
            xs,
            ys,
            color,
            width: 1.0,
        });
        self
    }
    pub fn scatter(mut self, xs: Vec<f64>, ys: Vec<f64>, color: [u8; 3]) -> Self {
        self.series.push(Series::Scatter {
            xs,
            ys,
            color,
            radius: 1.6,
        });
        self
    }
    pub fn strategy(mut self, s: Strategy) -> Self {
        self.strategy = s;
        self
    }
    /// Density-contour the points (binned, then iso-lined; heatmap underlay
    /// per `contour_underlay`).
    pub fn contour(mut self, xs: Vec<f64>, ys: Vec<f64>) -> Self {
        self.series.push(Series::Contour { xs, ys });
        self
    }

    fn total_points(&self) -> usize {
        self.series.iter().map(|s| s.len()).sum()
    }

    /// The concrete strategy this plot will use.
    pub fn chosen(&self) -> Chosen {
        match self.strategy {
            Strategy::Vector => Chosen::Vector,
            Strategy::Raster => Chosen::Raster,
            Strategy::Auto => {
                if self.total_points() > self.raster_threshold {
                    Chosen::Raster
                } else {
                    Chosen::Vector
                }
            }
        }
    }

    pub fn render(&self, size: PlotSize) -> PlotOutput {
        // Contour series take their own path regardless of point count (the
        // binning cost is the same as the raster path).
        if self
            .series
            .iter()
            .any(|s| matches!(s, Series::Contour { .. }))
        {
            return self.render_contour(size);
        }
        match self.chosen() {
            Chosen::Vector => self.render_vector(size),
            Chosen::Raster => self.render_raster(size),
        }
    }

    fn render_vector(&self, size: PlotSize) -> PlotOutput {
        let mut lp = LinePlot::new(self.x.clone(), self.y.clone());
        lp.title = self.title.clone();
        lp.series = self.series.clone();
        lp.render(size)
    }

    /// Bin all series' points in normalized-axis space (lin/log + limits
    /// honored uniformly). Returns the histogram + the resolved data bounds
    /// used for tick labeling.
    fn bin_normalized(&self) -> (Hist2D, (f64, f64), (f64, f64)) {
        let (dxmin, dxmax, dymin, dymax) = self.data_extent();
        let (lox, hix) = self.x.resolved(dxmin, dxmax);
        let (loy, hiy) = self.y.resolved(dymin, dymax);

        // Every point becomes (tx, ty) ∈ [0,1]² through the axis transform; the
        // heatmap/contours then stretch to the plot rect and the axis ticks
        // (also in t-space) align exactly.
        let (mut txs, mut tys) = (Vec::new(), Vec::new());
        for s in &self.series {
            let (xs, ys) = (s.xs(), s.ys());
            for i in 0..xs.len() {
                if let (Some(tx), Some(ty)) =
                    (self.x.norm(xs[i], lox, hix), self.y.norm(ys[i], loy, hiy))
                {
                    if (0.0..=1.0).contains(&tx) && (0.0..=1.0).contains(&ty) {
                        txs.push(tx);
                        tys.push(ty);
                    }
                }
            }
        }

        let hist = Hist2D::bin(
            &txs,
            &tys,
            None,
            self.bins.0,
            self.bins.1,
            Some(((0.0, 1.0), (0.0, 1.0))),
        );
        (hist, (lox, hix), (loy, hiy))
    }

    fn render_contour(&self, size: PlotSize) -> PlotOutput {
        let (hist, x_range, y_range) = self.bin_normalized();
        let fig = ContourFigure {
            title: self.title.clone(),
            hist,
            norm: Normalization::Count,
            cmap: self.cmap,
            scale: ColorScale::Log, // density spans orders of magnitude
            levels: ContourLevels::Linear(self.contour_levels.max(1)),
            smooth_sigma: self.contour_smooth_sigma,
            underlay: self.contour_underlay,
            labels: self.contour_labels,
            x: self.x.clone(),
            y: self.y.clone(),
            x_range,
            y_range,
            asset_id: self.asset_id.clone(),
        };
        fig.render(size.with_colorbar())
    }

    fn render_raster(&self, size: PlotSize) -> PlotOutput {
        let (hist, (lox, hix), (loy, hiy)) = self.bin_normalized();
        let fig = Hist2DFigure {
            title: self.title.clone(),
            hist,
            norm: Normalization::Count,
            cmap: self.cmap,
            scale: ColorScale::Log, // density spans orders of magnitude
            x: self.x.clone(),
            y: self.y.clone(),
            x_range: (lox, hix),
            y_range: (loy, hiy),
            asset_id: self.asset_id.clone(),
        };
        fig.render(size.with_colorbar())
    }

    fn data_extent(&self) -> (f64, f64, f64, f64) {
        let (mut xmin, mut xmax, mut ymin, mut ymax) = (
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
        );
        for s in &self.series {
            for &x in s.xs() {
                if x.is_finite() {
                    xmin = xmin.min(x);
                    xmax = xmax.max(x);
                }
            }
            for &y in s.ys() {
                if y.is_finite() {
                    ymin = ymin.min(y);
                    ymax = ymax.max(y);
                }
            }
        }
        if !xmin.is_finite() {
            (xmin, xmax, ymin, ymax) = (0.0, 1.0, 0.0, 1.0);
        }
        (xmin, xmax, ymin, ymax)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ramp(n: usize) -> (Vec<f64>, Vec<f64>) {
        let xs: Vec<f64> = (0..n).map(|i| i as f64).collect();
        let ys = xs.clone();
        (xs, ys)
    }

    #[test]
    fn auto_picks_vector_below_threshold() {
        let (xs, ys) = ramp(500);
        let p = Plot::new(Axis::linear(), Axis::linear()).scatter(xs, ys, [0, 0, 0]);
        assert_eq!(p.chosen(), Chosen::Vector);
        let out = p.render(PlotSize::new(300.0, 200.0));
        assert!(out.assets.is_empty());
        assert!(out.typst.contains("#circle(") || out.typst.contains("#curve("));
    }

    #[test]
    fn auto_picks_raster_above_threshold() {
        let (xs, ys) = ramp(40_000);
        let p = Plot::new(Axis::linear(), Axis::linear()).scatter(xs, ys, [0, 0, 0]);
        assert_eq!(p.chosen(), Chosen::Raster);
        let out = p.render(PlotSize::new(300.0, 200.0));
        assert_eq!(out.assets.len(), 1, "raster path emits one PNG asset");
        assert!(out.typst.contains("#image("));
    }

    #[test]
    fn forced_strategy_overrides_count() {
        let (xs, ys) = ramp(50);
        let raster = Plot::new(Axis::linear(), Axis::linear())
            .scatter(xs.clone(), ys.clone(), [0, 0, 0])
            .strategy(Strategy::Raster);
        assert_eq!(raster.chosen(), Chosen::Raster);
        assert_eq!(raster.render(PlotSize::new(200.0, 200.0)).assets.len(), 1);

        let (bx, by) = ramp(100_000);
        let vector = Plot::new(Axis::linear(), Axis::linear())
            .line(bx, by, [0, 0, 0])
            .strategy(Strategy::Vector);
        assert_eq!(vector.chosen(), Chosen::Vector);
        assert!(vector.render(PlotSize::new(200.0, 200.0)).assets.is_empty());
    }

    #[test]
    fn raster_honors_log_axis() {
        // Log-y raster path must still produce a heatmap (log-spaced bins).
        let n = 20_000;
        let xs: Vec<f64> = (0..n).map(|i| i as f64).collect();
        let ys: Vec<f64> = (0..n).map(|i| (i as f64 + 1.0).powi(2)).collect();
        let p = Plot::new(Axis::linear(), Axis::log()).scatter(xs, ys, [0, 0, 0]);
        assert_eq!(p.chosen(), Chosen::Raster);
        let out = p.render(PlotSize::new(300.0, 220.0));
        assert_eq!(out.assets.len(), 1);
        // decade tick labels present (log y over the real range)
        assert!(out.typst.contains("[1") && out.typst.contains("#image("));
    }
}
