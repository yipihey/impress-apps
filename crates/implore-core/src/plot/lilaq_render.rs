//! lilaq backend — translates `PlotSpec` → Typst source with lilaq → SVG/PDF.
//!
//! Requires the `lilaq` feature flag.  Generates Typst markup using the
//! `@preview/lilaq:0.6.0` package (the version vendored for imprint's engine)
//! for publication-quality figures.

use super::types::*;

/// Convert a `PlotSpec` to lilaq Typst source code.
///
/// The output can be compiled with a Typst engine to produce SVG or PDF.
/// This always works (no feature gate) since it's pure string generation.
/// The lilaq package the generated source imports — the version vendored in
/// `vendor/typst-packages` (imprint's engine resolves it offline).
pub const LILAQ_PACKAGE: &str = "@preview/lilaq:0.6.0";

/// A number list as Typst reads it: `(1, 2.5, 3)`.
fn typst_array(values: &[f64]) -> String {
    let items: Vec<String> = values.iter().map(|v| format_f64(*v)).collect();
    if items.len() == 1 {
        format!("({},)", items[0])
    } else {
        format!("({})", items.join(", "))
    }
}

pub fn plot_spec_to_typst(spec: &PlotSpec) -> String {
    let mut lines = Vec::new();
    lines.push(format!("#import \"{LILAQ_PACKAGE}\" as lq"));
    // A figure is its own page, hugging the diagram.
    lines.push("#set page(width: auto, height: auto, margin: 2pt)".to_string());
    lines.push(String::new());

    // Diagram arguments (lilaq 0.6: `lq.diagram(width:, height:, title:,
    // xlabel:, ylabel:, xlim:, ylim:, xscale:, yscale:, legend:, ...plots)`).
    let mut diagram_args = Vec::new();
    diagram_args.push(format!(
        "  width: {}pt, height: {}pt",
        format_f64(spec.width.max(32.0)),
        format_f64(spec.height.max(32.0))
    ));
    if let Some(title) = &spec.title {
        if !title.is_empty() {
            diagram_args.push(format!("  title: [{}]", escape_typst(title)));
        }
    }
    if let Some(label) = &spec.x_axis.label {
        diagram_args.push(format!("  xlabel: [{}]", escape_typst(label)));
    }
    if let Some(label) = &spec.y_axis.label {
        diagram_args.push(format!("  ylabel: [{}]", escape_typst(label)));
    }
    if let (Some(min), Some(max)) = (spec.x_axis.min, spec.x_axis.max) {
        diagram_args.push(format!(
            "  xlim: ({}, {})",
            format_f64(min),
            format_f64(max)
        ));
    }
    if let (Some(min), Some(max)) = (spec.y_axis.min, spec.y_axis.max) {
        diagram_args.push(format!(
            "  ylim: ({}, {})",
            format_f64(min),
            format_f64(max)
        ));
    }
    if spec.x_axis.log_scale {
        diagram_args.push("  xscale: \"log\"".to_string());
    }
    if spec.y_axis.log_scale {
        diagram_args.push("  yscale: \"log\"".to_string());
    }
    if !spec.legend.visible {
        diagram_args.push("  legend: none".to_string());
    }

    // Data series as lilaq plot objects.
    let mut plot_calls = Vec::new();
    for series in &spec.series {
        let n = series.x.len().min(series.y.len());
        if n == 0 {
            continue;
        }
        let mut xs = Vec::with_capacity(n);
        let mut ys = Vec::with_capacity(n);
        let mut lows = Vec::with_capacity(n);
        let mut highs = Vec::with_capacity(n);
        for i in 0..n {
            if series.x[i].is_finite() && series.y[i].is_finite() {
                xs.push(series.x[i]);
                ys.push(series.y[i]);
                lows.push(
                    series
                        .error_low
                        .as_ref()
                        .and_then(|e| e.get(i).copied())
                        .unwrap_or(0.0),
                );
                highs.push(
                    series
                        .error_high
                        .as_ref()
                        .and_then(|e| e.get(i).copied())
                        .unwrap_or(0.0),
                );
            }
        }
        if xs.is_empty() {
            continue;
        }
        let color = typst_color(&series.color);
        let label =
            (!series.label.is_empty()).then(|| format!("label: [{}]", escape_typst(&series.label)));
        let yerr = (series.error_low.is_some() || series.error_high.is_some()).then(|| {
            format!(
                "yerr: (p: {}, m: {})",
                typst_array(&highs),
                typst_array(&lows)
            )
        });
        let data = format!("{}, {}", typst_array(&xs), typst_array(&ys));
        let mut args: Vec<String> = vec![data];
        match series.style {
            SeriesStyle::Line | SeriesStyle::Step => {
                args.push(format!("color: {color}"));
                args.push("mark: none".into());
                args.push(format!(
                    "stroke: {}pt",
                    format_f64(series.line_width.max(0.1))
                ));
                args.extend(yerr);
                args.extend(label);
                plot_calls.push(format!("  lq.plot({})", args.join(", ")));
            }
            SeriesStyle::Scatter => {
                args.push(format!("color: {color}"));
                args.push(format!(
                    "size: {}pt",
                    format_f64((series.point_radius * 2.0).max(1.0))
                ));
                args.extend(label);
                plot_calls.push(format!("  lq.scatter({})", args.join(", ")));
            }
            SeriesStyle::LineScatter => {
                args.push(format!("color: {color}"));
                args.push("mark: \"o\"".into());
                args.push(format!(
                    "stroke: {}pt",
                    format_f64(series.line_width.max(0.1))
                ));
                args.extend(yerr);
                args.extend(label);
                plot_calls.push(format!("  lq.plot({})", args.join(", ")));
            }
            SeriesStyle::Bar => {
                args.push(format!("fill: {color}"));
                args.extend(label);
                plot_calls.push(format!("  lq.bar({})", args.join(", ")));
            }
        }
    }

    lines.push("#lq.diagram(".to_string());
    for arg in &diagram_args {
        lines.push(format!("{arg},"));
    }
    for call in &plot_calls {
        lines.push(format!("{call},"));
    }
    lines.push(")".to_string());
    lines.join("\n")
}

/// Render a PlotSpec to SVG via Typst + lilaq compilation.
///
/// Requires the `lilaq` feature. Returns `None` if not available.
#[cfg(feature = "lilaq")]
pub fn render_lilaq_svg(spec: &PlotSpec) -> Option<String> {
    let source = plot_spec_to_typst(spec);
    compile_typst_to_svg(&source)
}

#[cfg(not(feature = "lilaq"))]
pub fn render_lilaq_svg(_spec: &PlotSpec) -> Option<String> {
    None
}

/// Render a PlotSpec to PDF via Typst + lilaq compilation.
///
/// Requires the `lilaq` feature. Returns `None` if not available.
#[cfg(feature = "lilaq")]
pub fn render_lilaq_pdf(spec: &PlotSpec) -> Option<Vec<u8>> {
    let source = plot_spec_to_typst(spec);
    compile_typst_to_pdf(&source)
}

#[cfg(not(feature = "lilaq"))]
pub fn render_lilaq_pdf(_spec: &PlotSpec) -> Option<Vec<u8>> {
    None
}

// ── Typst compilation ───────────────────────────────────────────────

#[cfg(feature = "lilaq")]
fn compile_typst_to_svg(source: &str) -> Option<String> {
    use typst::foundations::Smart;
    use typst_as_lib::TypstEngine;

    let engine = TypstEngine::default();
    let doc = engine.compile(source).ok()?;
    let pages = typst_svg::svg(&doc);
    // Return first page SVG
    if pages.is_empty() {
        None
    } else {
        Some(pages)
    }
}

#[cfg(feature = "lilaq")]
fn compile_typst_to_pdf(source: &str) -> Option<Vec<u8>> {
    use typst_as_lib::TypstEngine;

    let engine = TypstEngine::default();
    let doc = engine.compile(source).ok()?;
    typst_pdf::pdf(&doc, &typst_pdf::PdfOptions::default()).ok()
}

// ── Helpers ─────────────────────────────────────────────────────────

fn typst_color(color: &PlotColor) -> String {
    match color {
        PlotColor::Blue => "blue".to_string(),
        PlotColor::Red => "red".to_string(),
        PlotColor::Green => "green".to_string(),
        PlotColor::Orange => "orange".to_string(),
        PlotColor::Purple => "purple".to_string(),
        PlotColor::Cyan => "aqua".to_string(),
        PlotColor::Black => "black".to_string(),
        PlotColor::Gray => "gray".to_string(),
        PlotColor::Rgb(r, g, b) => format!("rgb(\"#{:02X}{:02X}{:02X}\")", r, g, b),
    }
}

fn escape_typst(s: &str) -> String {
    s.replace('#', "\\#")
        .replace('$', "\\$")
        .replace('@', "\\@")
}

fn format_f64(v: f64) -> String {
    if v == v.floor() && v.abs() < 1e15 {
        format!("{:.0}", v)
    } else {
        format!("{}", v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_typst_source_generation() {
        let spec = PlotSpec::new()
            .with_title("Test")
            .with_x_label("x")
            .with_y_label("y")
            .line(vec![0.0, 1.0, 2.0], vec![0.0, 1.0, 4.0], "data");

        let typst = plot_spec_to_typst(&spec);
        assert!(typst.contains("lilaq"));
        assert!(typst.contains("xlabel: [x]"));
        assert!(typst.contains("ylabel: [y]"));
        assert!(typst.contains("lq.plot("));
        assert!(typst.contains("mark: none"));
        assert!(typst.contains("label: [data]"));
    }

    #[test]
    fn test_typst_scatter() {
        let spec = PlotSpec::new().scatter(vec![1.0, 2.0], vec![3.0, 4.0], "pts");
        let typst = plot_spec_to_typst(&spec);
        assert!(typst.contains("lq.scatter((1, 2), (3, 4)"), "{typst}");
    }

    #[test]
    fn test_typst_multi_series() {
        let spec =
            PlotSpec::new()
                .line(vec![0.0], vec![0.0], "a")
                .scatter(vec![1.0], vec![1.0], "b");
        let typst = plot_spec_to_typst(&spec);
        assert!(typst.contains("lq.plot((0,), (0,)"), "{typst}");
        assert!(typst.contains("lq.scatter((1,), (1,)"), "{typst}");
    }

    #[test]
    fn test_typst_color_mapping() {
        assert_eq!(typst_color(&PlotColor::Blue), "blue");
        assert_eq!(
            typst_color(&PlotColor::Rgb(255, 128, 0)),
            "rgb(\"#FF8000\")"
        );
    }

    #[test]
    fn test_escape_typst() {
        assert_eq!(escape_typst("a # b"), "a \\# b");
    }
}
