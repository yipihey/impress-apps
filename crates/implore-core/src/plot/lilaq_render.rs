//! lilaq backend — translates `PlotSpec` → Typst source with lilaq → SVG/PDF.
//!
//! Requires the `lilaq` feature flag.  Generates Typst markup using the
//! `@preview/lilaq:0.2.0` package for publication-quality figures.

use super::types::*;

/// Convert a `PlotSpec` to lilaq Typst source code.
///
/// The output can be compiled with a Typst engine to produce SVG or PDF.
/// This always works (no feature gate) since it's pure string generation.
pub fn plot_spec_to_typst(spec: &PlotSpec) -> String {
    let mut lines = Vec::new();

    lines.push(r#"#import "@preview/lilaq:0.2.0": *"#.to_string());
    lines.push(String::new());

    // Build diagram arguments
    let mut diagram_args = Vec::new();

    if let Some(label) = &spec.x_axis.label {
        diagram_args.push(format!("  xlabel: [{}]", escape_typst(label)));
    }
    if let Some(label) = &spec.y_axis.label {
        diagram_args.push(format!("  ylabel: [{}]", escape_typst(label)));
    }

    // Axis bounds
    if let Some(min) = spec.x_axis.min {
        if let Some(max) = spec.x_axis.max {
            diagram_args.push(format!("  xlim: ({}, {})", format_f64(min), format_f64(max)));
        }
    }
    if let Some(min) = spec.y_axis.min {
        if let Some(max) = spec.y_axis.max {
            diagram_args.push(format!("  ylim: ({}, {})", format_f64(min), format_f64(max)));
        }
    }

    // Data series as plot commands
    let mut plot_calls = Vec::new();

    for series in &spec.series {
        let n = series.x.len().min(series.y.len());
        if n == 0 {
            continue;
        }

        // Build data array: ((x0, y0), (x1, y1), ...)
        let mut data_items = Vec::new();
        for i in 0..n {
            if series.x[i].is_finite() && series.y[i].is_finite() {
                data_items.push(format!(
                    "({}, {})",
                    format_f64(series.x[i]),
                    format_f64(series.y[i])
                ));
            }
        }
        let data_str = format!("({})", data_items.join(", "));

        let color = typst_color(&series.color);

        match series.style {
            SeriesStyle::Line | SeriesStyle::Step => {
                let mut args = vec![data_str];
                args.push(format!("stroke: {}", color));
                if !series.label.is_empty() {
                    args.push(format!("label: [{}]", escape_typst(&series.label)));
                }
                plot_calls.push(format!("  plot.line({})", args.join(", ")));
            }
            SeriesStyle::Scatter => {
                let mut args = vec![data_str];
                args.push(format!("fill: {}", color));
                if !series.label.is_empty() {
                    args.push(format!("label: [{}]", escape_typst(&series.label)));
                }
                plot_calls.push(format!("  plot.scatter({})", args.join(", ")));
            }
            SeriesStyle::LineScatter => {
                let mut line_args = vec![data_str.clone()];
                line_args.push(format!("stroke: {}", color));
                if !series.label.is_empty() {
                    line_args.push(format!("label: [{}]", escape_typst(&series.label)));
                }
                plot_calls.push(format!("  plot.line({})", line_args.join(", ")));

                let mut scatter_args = vec![data_str];
                scatter_args.push(format!("fill: {}", color));
                plot_calls.push(format!("  plot.scatter({})", scatter_args.join(", ")));
            }
            SeriesStyle::Bar => {
                let mut args = vec![data_str];
                args.push(format!("fill: {}", color));
                if !series.label.is_empty() {
                    args.push(format!("label: [{}]", escape_typst(&series.label)));
                }
                plot_calls.push(format!("  plot.bar({})", args.join(", ")));
            }
        }
    }

    // Title
    if let Some(title) = &spec.title {
        lines.push(format!("= {}", escape_typst(title)));
        lines.push(String::new());
    }

    // Assemble diagram call
    lines.push("#diagram(".to_string());
    for arg in &diagram_args {
        lines.push(format!("{},", arg));
    }
    for call in &plot_calls {
        lines.push(format!("{},", call));
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
    if pages.is_empty() { None } else { Some(pages) }
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
        assert!(typst.contains("plot.line"));
        assert!(typst.contains("label: [data]"));
    }

    #[test]
    fn test_typst_scatter() {
        let spec = PlotSpec::new()
            .scatter(vec![1.0, 2.0], vec![3.0, 4.0], "pts");
        let typst = plot_spec_to_typst(&spec);
        assert!(typst.contains("plot.scatter"));
    }

    #[test]
    fn test_typst_multi_series() {
        let spec = PlotSpec::new()
            .line(vec![0.0], vec![0.0], "a")
            .scatter(vec![1.0], vec![1.0], "b");
        let typst = plot_spec_to_typst(&spec);
        assert!(typst.contains("plot.line"));
        assert!(typst.contains("plot.scatter"));
    }

    #[test]
    fn test_typst_color_mapping() {
        assert_eq!(typst_color(&PlotColor::Blue), "blue");
        assert_eq!(typst_color(&PlotColor::Rgb(255, 128, 0)), "rgb(\"#FF8000\")");
    }

    #[test]
    fn test_escape_typst() {
        assert_eq!(escape_typst("a # b"), "a \\# b");
    }
}
