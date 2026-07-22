//! Integration: generated plot specs actually compile through the suite's
//! persistent Typst engine, and the axis controls (lin/log + min/max) change
//! the output. Emits SVG/PDF samples for eyeballing.
//!
//! Run: cargo test -p impress-plot --test render_typst -- --nocapture

use impress_plot::*;
use imprint_core::render::{PersistentTypstRenderer, RenderOptions};

fn out_dir() -> std::path::PathBuf {
    let d = std::env::var("SPIKE_OUT").unwrap_or_else(|_| {
        "/private/tmp/claude-501/-Users-tabel-Projects-impress-apps/85751f16-1066-417a-8800-4f120e7f2d24/scratchpad/plot_spike".into()
    });
    let p = std::path::PathBuf::from(d);
    std::fs::create_dir_all(&p).ok();
    p
}

fn compile(r: &mut PersistentTypstRenderer, out: &PlotOutput, name: &str) {
    for (path, bytes) in &out.assets {
        r.set_asset(path, bytes.clone());
    }
    let opts = RenderOptions::a4();
    let (svgs, _w, _p, _m) = r.render_svg(&out.typst, &opts).expect("svg compile");
    let (pdf, _m) = r.render_pdf(&out.typst, &opts).expect("pdf compile");
    let dir = out_dir();
    std::fs::write(dir.join(format!("{name}.svg")), svgs[0].as_bytes()).unwrap();
    std::fs::write(dir.join(format!("{name}.pdf")), pdf.as_pdf().unwrap()).unwrap();
    assert!(svgs[0].contains("<svg"));
}

#[test]
fn axis_controls_lin_log_zoom_compile() {
    // A cubic across three decades — the canonical "reach for log-y" case.
    let xs: Vec<f64> = (1..=120).map(|i| i as f64).collect();
    let ys: Vec<f64> = xs.iter().map(|x| x.powi(3)).collect();
    let color = [31, 111, 214];
    let mut r = PersistentTypstRenderer::new();
    let size = PlotSize::new(340.0, 220.0);

    // 1) linear x, linear y
    let linlin = LinePlot::new(
        Axis::linear().with_label("x"),
        Axis::linear().with_label("x³"),
    )
    .title("linear axes")
    .line(xs.clone(), ys.clone(), color)
    .render(size);
    compile(&mut r, &linlin, "axis_lin_lin");

    // 2) linear x, LOG y — same data, one field changed
    let linlog = LinePlot::new(
        Axis::linear().with_label("x"),
        Axis::log().with_label("x³ (log)"),
    )
    .title("log y-axis")
    .line(xs.clone(), ys.clone(), color)
    .render(size);
    compile(&mut r, &linlog, "axis_lin_log");

    // 3) ZOOM: manual x-limits [1,40], log y — min/max control
    let zoom = LinePlot::new(
        Axis::linear()
            .with_limits(1.0, 40.0)
            .with_label("x (zoom 1–40)"),
        Axis::log().with_label("x³ (log)"),
    )
    .title("zoom x + log y")
    .line(xs, ys, color)
    .render(size);
    compile(&mut r, &zoom, "axis_zoom_log");

    // The three renders must differ (axis config actually flows through).
    assert_ne!(linlin.typst, linlog.typst);
    assert_ne!(linlog.typst, zoom.typst);
    println!(
        "wrote axis_lin_lin / axis_lin_log / axis_zoom_log to {}",
        out_dir().display()
    );
}

#[test]
fn hist_figure_compiles_with_asset() {
    // Deterministic two-blob density (mirrors the raster spike, smaller N).
    let n = 60_000usize;
    let mut s: u64 = 0xC0FFEE;
    let mut nrm = || {
        let mut g = || {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1);
            ((s >> 11) as f64) / ((1u64 << 53) as f64)
        };
        let (u1, u2) = (g().max(1e-12), g());
        (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
    };
    let (mut xs, mut ys, mut ws) = (Vec::new(), Vec::new(), Vec::new());
    for i in 0..n {
        if i % 3 == 0 {
            xs.push(2.0 + 0.5 * nrm());
            ys.push(1.6 + 0.5 * nrm());
            ws.push(5.0);
        } else {
            xs.push(-1.0 + 1.0 * nrm());
            ys.push(-0.4 + 0.8 * nrm());
            ws.push(1.0);
        }
    }
    let hist = Hist2D::bin(
        &xs,
        &ys,
        Some(&ws),
        120,
        120,
        Some(((-4.0, 4.0), (-3.0, 4.0))),
    );
    let fig = Hist2DFigure {
        title: "density · viridis · log".into(),
        hist,
        norm: Normalization::Density,
        cmap: Colormap::Viridis,
        scale: ColorScale::Log,
        x: Axis::linear().with_label("x"),
        y: Axis::linear().with_label("y"),
        asset_id: "hist_crate.png".into(),
    };
    let out = fig.render(PlotSize::new(340.0, 240.0).with_colorbar());
    assert_eq!(out.assets.len(), 1);

    let mut r = PersistentTypstRenderer::new();
    compile(&mut r, &out, "hist_crate");
    println!("wrote hist_crate to {}", out_dir().display());
}
