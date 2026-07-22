//! Rendering: declarative plot spec → Typst source (+ raster assets).
//!
//! Two renderers share the same [`Axis`] model, so a lin/log flip or a min/max
//! change re-renders both correctly:
//!   * [`LinePlot`] — vector line/scatter (publication-crisp, matches document).
//!   * [`Hist2DFigure`] — the big-N raster heatmap under vector axes + colorbar.
//!
//! Output is [`PlotOutput`] `{ typst, assets }`: the caller registers each asset
//! with the Typst renderer (`set_asset`) and compiles `typst`. impress-plot
//! itself never links the Typst engine.

use crate::axis::{Axis, Tick};
use crate::colormap::Colormap;
use crate::hist2d::{ColorScale, Hist2D, Normalization};
use std::fmt::Write as _;

/// Figure box size + inner padding (points).
#[derive(Clone, Copy, Debug)]
pub struct PlotSize {
    pub w: f64,
    pub h: f64,
    pub pad_l: f64,
    pub pad_r: f64,
    pub pad_t: f64,
    pub pad_b: f64,
}

impl PlotSize {
    pub fn new(w: f64, h: f64) -> Self {
        Self {
            w,
            h,
            pad_l: 46.0,
            pad_r: 14.0,
            pad_t: 24.0,
            pad_b: 30.0,
        }
    }
    /// Extra right padding for a colorbar.
    pub fn with_colorbar(mut self) -> Self {
        self.pad_r = 58.0;
        self
    }
    fn pw(&self) -> f64 {
        (self.w - self.pad_l - self.pad_r).max(1.0)
    }
    fn ph(&self) -> f64 {
        (self.h - self.pad_t - self.pad_b).max(1.0)
    }
}

/// Generated figure: Typst source plus any binary assets it references.
#[derive(Clone, Debug, Default)]
pub struct PlotOutput {
    pub typst: String,
    pub assets: Vec<(String, Vec<u8>)>,
}

/// One data series.
#[derive(Clone, Debug)]
pub enum Series {
    Line {
        xs: Vec<f64>,
        ys: Vec<f64>,
        color: [u8; 3],
        width: f64,
    },
    Scatter {
        xs: Vec<f64>,
        ys: Vec<f64>,
        color: [u8; 3],
        radius: f64,
    },
}

impl Series {
    fn xs(&self) -> &[f64] {
        match self {
            Series::Line { xs, .. } | Series::Scatter { xs, .. } => xs,
        }
    }
    fn ys(&self) -> &[f64] {
        match self {
            Series::Line { ys, .. } | Series::Scatter { ys, .. } => ys,
        }
    }
}

/// A line/scatter plot with independent x/y axes.
#[derive(Clone, Debug)]
pub struct LinePlot {
    pub title: String,
    pub x: Axis,
    pub y: Axis,
    pub series: Vec<Series>,
}

impl LinePlot {
    pub fn new(x: Axis, y: Axis) -> Self {
        Self {
            title: String::new(),
            x,
            y,
            series: Vec::new(),
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

    pub fn render(&self, size: PlotSize) -> PlotOutput {
        let (pw, ph) = (size.pw(), size.ph());
        let (dxmin, dxmax, dymin, dymax) = self.data_extent();
        let (lox, hix) = self.x.resolved(dxmin, dxmax);
        let (loy, hiy) = self.y.resolved(dymin, dymax);

        let mut b = String::new();
        if !self.title.is_empty() {
            let _ = writeln!(
                b,
                "#place(dx: {}pt, dy: 4pt)[#text(size: 9pt, weight: \"bold\")[{}]]",
                size.pad_l, self.title
            );
        }

        // Series: map through the axes, splitting the polyline wherever a point
        // is out of range (log-invalid or beyond a manual limit) so no segment
        // is drawn across a gap.
        for s in &self.series {
            let (xs, ys) = (s.xs(), s.ys());
            let mut seg: Vec<(f64, f64)> = Vec::new();
            let flush = |b: &mut String, seg: &mut Vec<(f64, f64)>, s: &Series| {
                if seg.is_empty() {
                    return;
                }
                match s {
                    Series::Line { color, width, .. } => {
                        if seg.len() >= 2 {
                            let mut c = format!(
                                "#place(dx: {}pt, dy: {}pt)[#curve(stroke: {}pt + {}, ",
                                size.pad_l,
                                size.pad_t,
                                width,
                                rgb(*color)
                            );
                            let _ =
                                write!(c, "curve.move(({:.2}pt, {:.2}pt)), ", seg[0].0, seg[0].1);
                            for p in &seg[1..] {
                                let _ = write!(c, "curve.line(({:.2}pt, {:.2}pt)), ", p.0, p.1);
                            }
                            c.push_str(")]\n");
                            b.push_str(&c);
                        }
                    }
                    Series::Scatter { color, radius, .. } => {
                        for p in seg.iter() {
                            let _ = writeln!(
                                b,
                                "#place(dx: {:.2}pt, dy: {:.2}pt)[#circle(radius: {}pt, fill: {}, stroke: none)]",
                                size.pad_l + p.0 - radius,
                                size.pad_t + p.1 - radius,
                                radius,
                                rgb(*color)
                            );
                        }
                    }
                }
                seg.clear();
            };

            for i in 0..xs.len() {
                match (self.x.norm(xs[i], lox, hix), self.y.norm(ys[i], loy, hiy)) {
                    (Some(tx), Some(ty))
                        if (0.0..=1.0).contains(&tx) && (0.0..=1.0).contains(&ty) =>
                    {
                        seg.push((tx * pw, (1.0 - ty) * ph));
                    }
                    _ => flush(&mut b, &mut seg, s),
                }
            }
            flush(&mut b, &mut seg, s);
        }

        emit_frame_and_ticks(
            &mut b,
            size,
            pw,
            ph,
            &self.x.ticks(lox, hix, 5),
            &self.y.ticks(loy, hiy, 5),
            self.x.label.as_deref(),
            self.y.label.as_deref(),
        );

        PlotOutput {
            typst: wrap_box(size, &b),
            assets: Vec::new(),
        }
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

/// The big-N raster: a [`Hist2D`] under vector axes + a vector colorbar. The
/// axes here are linear (native to the binning); a log color scale handles
/// dynamic range. (Log *axes* on a histogram = log-spaced bins — a follow-up.)
#[derive(Clone, Debug)]
pub struct Hist2DFigure {
    pub title: String,
    pub hist: Hist2D,
    pub norm: Normalization,
    pub cmap: Colormap,
    pub scale: ColorScale,
    pub x: Axis,
    pub y: Axis,
    /// Stable asset id (becomes `image("/<asset_id>")`).
    pub asset_id: String,
}

impl Hist2DFigure {
    pub fn render(&self, size: PlotSize) -> PlotOutput {
        let (pw, ph) = (size.pw(), size.ph());
        let (png, vmin, vmax) = self.hist.to_png(self.norm, self.cmap, self.scale, 4);
        let asset_path = format!("/{}", self.asset_id);

        let mut b = String::new();
        if !self.title.is_empty() {
            let _ = writeln!(
                b,
                "#place(dx: {}pt, dy: 4pt)[#text(size: 9pt, weight: \"bold\")[{}]]",
                size.pad_l, self.title
            );
        }
        // Heatmap raster stretched to the plot rect.
        let _ = writeln!(
            b,
            "#place(dx: {}pt, dy: {}pt)[#image(\"{}\", width: {}pt, height: {}pt)]",
            size.pad_l, size.pad_t, asset_path, pw, ph
        );

        // Axes honor the histogram range.
        let (lox, hix) = (self.hist.xr.0, self.hist.xr.1);
        let (loy, hiy) = (self.hist.yr.0, self.hist.yr.1);
        emit_frame_and_ticks(
            &mut b,
            size,
            pw,
            ph,
            &self.x.ticks(lox, hix, 5),
            &self.y.ticks(loy, hiy, 5),
            self.x.label.as_deref(),
            self.y.label.as_deref(),
        );

        // Vector colorbar.
        emit_colorbar(&mut b, size, ph, self.cmap, vmin, vmax);

        PlotOutput {
            typst: wrap_box(size, &b),
            assets: vec![(asset_path, png)],
        }
    }
}

// --- shared Typst emission ------------------------------------------------

fn wrap_box(size: PlotSize, body: &str) -> String {
    format!(
        "#box(width: {}pt, height: {}pt, fill: white, stroke: 0.5pt + luma(180))[\n{}]\n",
        size.w, size.h, body
    )
}

fn rgb(c: [u8; 3]) -> String {
    format!("rgb({}, {}, {})", c[0], c[1], c[2])
}

#[allow(clippy::too_many_arguments)]
fn emit_frame_and_ticks(
    b: &mut String,
    size: PlotSize,
    pw: f64,
    ph: f64,
    xticks: &[Tick],
    yticks: &[Tick],
    xlabel: Option<&str>,
    ylabel: Option<&str>,
) {
    let (pl, pt) = (size.pad_l, size.pad_t);
    // Frame.
    let _ = writeln!(
        b,
        "#place(dx: {pl}pt, dy: {pt}pt)[#rect(width: {pw}pt, height: {ph}pt, stroke: 0.8pt, fill: none)]"
    );
    // X ticks + labels.
    for tk in xticks {
        let px = pl + tk.t * pw;
        let _ = writeln!(
            b,
            "#place(dx: {px}pt, dy: {}pt)[#line(end: (0pt, 4pt), stroke: 0.6pt)]",
            pt + ph
        );
        let _ = writeln!(
            b,
            "#place(dx: {}pt, dy: {}pt)[#text(size: 6.5pt)[{}]]",
            px - 11.0,
            pt + ph + 6.0,
            tk.label
        );
    }
    // Y ticks + labels.
    for tk in yticks {
        let py = pt + ph - tk.t * ph;
        let _ = writeln!(
            b,
            "#place(dx: {}pt, dy: {py}pt)[#line(end: (4pt, 0pt), stroke: 0.6pt)]",
            pl - 4.0
        );
        let _ = writeln!(
            b,
            "#place(dx: 3pt, dy: {}pt)[#text(size: 6.5pt)[{}]]",
            py - 4.0,
            tk.label
        );
    }
    if let Some(l) = xlabel {
        let _ = writeln!(
            b,
            "#place(dx: {}pt, dy: {}pt)[#text(size: 7.5pt)[{}]]",
            pl + pw / 2.0 - 20.0,
            pt + ph + 15.0,
            l
        );
    }
    if let Some(l) = ylabel {
        // Rotated y-axis label.
        let _ = writeln!(
            b,
            "#place(dx: 2pt, dy: {}pt)[#rotate(-90deg, reflow: true)[#text(size: 7.5pt)[{}]]]",
            pt + ph / 2.0 + 20.0,
            l
        );
    }
}

fn emit_colorbar(b: &mut String, size: PlotSize, ph: f64, cmap: Colormap, vmin: f64, vmax: f64) {
    let cb_x = size.pad_l + size.pw() + 12.0;
    let cb_w = 10.0;
    let segs = 48usize;
    let seg_h = ph / segs as f64;
    for s in 0..segs {
        let t = s as f64 / (segs - 1) as f64;
        let c = cmap.sample(t);
        let y = size.pad_t + ph - (s as f64 + 1.0) * seg_h;
        let _ = writeln!(
            b,
            "#place(dx: {cb_x}pt, dy: {y}pt)[#rect(width: {cb_w}pt, height: {}pt, fill: {}, stroke: none)]",
            seg_h + 0.5,
            rgb(c)
        );
    }
    let _ = writeln!(
        b,
        "#place(dx: {cb_x}pt, dy: {}pt)[#rect(width: {cb_w}pt, height: {ph}pt, stroke: 0.5pt, fill: none)]",
        size.pad_t
    );
    let _ = writeln!(
        b,
        "#place(dx: {}pt, dy: {}pt)[#text(size: 6pt)[{}]]",
        cb_x + cb_w + 2.0,
        size.pad_t - 3.0,
        fmt_sig(vmax)
    );
    let _ = writeln!(
        b,
        "#place(dx: {}pt, dy: {}pt)[#text(size: 6pt)[{}]]",
        cb_x + cb_w + 2.0,
        size.pad_t + ph - 6.0,
        fmt_sig(vmin)
    );
}

fn fmt_sig(v: f64) -> String {
    if v == 0.0 {
        "0".into()
    } else if v.abs() >= 100.0 || v.abs() < 0.01 {
        format!("{v:.1e}")
    } else if v.abs() >= 1.0 {
        format!("{v:.1}")
    } else {
        format!("{v:.3}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_plot_emits_vector_curve_and_ticks() {
        let xs: Vec<f64> = (0..50).map(|i| i as f64).collect();
        let ys: Vec<f64> = xs.iter().map(|x| x * x).collect();
        let out = LinePlot::new(Axis::linear(), Axis::linear())
            .title("parabola")
            .line(xs, ys, [31, 111, 214])
            .render(PlotSize::new(320.0, 200.0));
        assert!(out.typst.contains("#curve("));
        assert!(out.typst.contains("#rect(")); // frame
        assert!(out.assets.is_empty());
    }

    #[test]
    fn log_y_axis_changes_tick_labels() {
        let xs: Vec<f64> = (1..=100).map(|i| i as f64).collect();
        let ys: Vec<f64> = xs.iter().map(|x| x.powi(3)).collect();
        let lin = LinePlot::new(Axis::linear(), Axis::linear())
            .line(xs.clone(), ys.clone(), [0, 0, 0])
            .render(PlotSize::new(300.0, 200.0));
        let log = LinePlot::new(Axis::linear(), Axis::log())
            .line(xs, ys, [0, 0, 0])
            .render(PlotSize::new(300.0, 200.0));
        // Log y introduces decade labels not present on the linear render.
        assert!(log.typst.contains("[1000]") || log.typst.contains("[1e"));
        assert_ne!(lin.typst, log.typst);
    }

    #[test]
    fn manual_limits_drop_out_of_range_points() {
        // A ramp 0..100; zoom y to [40,60] → only ~1/5 of vertices survive.
        let xs: Vec<f64> = (0..=100).map(|i| i as f64).collect();
        let ys = xs.clone();
        let zoom = LinePlot::new(Axis::linear(), Axis::linear().with_limits(40.0, 60.0))
            .line(xs, ys, [0, 0, 0])
            .render(PlotSize::new(300.0, 200.0));
        // curve.line count reflects clipped-in vertices (~21), not all 101.
        let n = zoom.typst.matches("curve.line").count();
        assert!(n > 0 && n < 40, "expected clipped vertex count, got {n}");
    }
}
