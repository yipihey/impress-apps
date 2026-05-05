//! kuva backend — translates `PlotSpec` → kuva API → SVG/PNG/PDF.
//!
//! Requires the `kuva` feature flag.  Falls back to hand-written SVG
//! when kuva is not available.

#[cfg(feature = "kuva")]
use kuva::prelude::*;

use super::types::*;

/// Render a `PlotSpec` to SVG using kuva.
///
/// Returns `None` if the kuva feature is not enabled.
#[cfg(feature = "kuva")]
pub fn render_kuva_svg(spec: &PlotSpec) -> Option<String> {
    let mut plots: Vec<Plot> = Vec::new();

    for series in &spec.series {
        let color = series.color.css();
        let n = series.x.len().min(series.y.len());
        if n == 0 {
            continue;
        }

        match series.style {
            SeriesStyle::Line | SeriesStyle::LineScatter => {
                let data: Vec<(f64, f64)> = (0..n)
                    .filter(|&i| series.x[i].is_finite() && series.y[i].is_finite())
                    .map(|i| (series.x[i], series.y[i]))
                    .collect();

                let mut line = LinePlot::new()
                    .with_data(data.clone())
                    .with_color(&color)
                    .with_legend(&series.label);

                plots.push(line.into());

                if series.style == SeriesStyle::LineScatter {
                    let scatter = ScatterPlot::new()
                        .with_data(data)
                        .with_color(&color)
                        .with_size(series.point_radius as f32);
                    plots.push(scatter.into());
                }
            }
            SeriesStyle::Scatter => {
                let data: Vec<(f64, f64)> = (0..n)
                    .filter(|&i| series.x[i].is_finite() && series.y[i].is_finite())
                    .map(|i| (series.x[i], series.y[i]))
                    .collect();

                let scatter = ScatterPlot::new()
                    .with_data(data)
                    .with_color(&color)
                    .with_size(series.point_radius as f32)
                    .with_legend(&series.label);
                plots.push(scatter.into());
            }
            SeriesStyle::Bar => {
                let data: Vec<(f64, f64)> = (0..n)
                    .filter(|&i| series.x[i].is_finite() && series.y[i].is_finite())
                    .map(|i| (series.x[i], series.y[i]))
                    .collect();

                let bar = BarPlot::new()
                    .with_data(data)
                    .with_color(&color)
                    .with_legend(&series.label);
                plots.push(bar.into());
            }
            SeriesStyle::Step => {
                // kuva may not have a step plot — use line with step data
                let mut step_data: Vec<(f64, f64)> = Vec::new();
                for i in 0..n {
                    if !series.x[i].is_finite() || !series.y[i].is_finite() {
                        continue;
                    }
                    if i > 0 && !step_data.is_empty() {
                        // Horizontal segment to new x
                        step_data.push((series.x[i], step_data.last().unwrap().1));
                    }
                    step_data.push((series.x[i], series.y[i]));
                }

                let line = LinePlot::new()
                    .with_data(step_data)
                    .with_color(&color)
                    .with_legend(&series.label);
                plots.push(line.into());
            }
        }
    }

    if plots.is_empty() {
        return None;
    }

    let mut layout = Layout::auto_from_plots(&plots);
    layout.width = spec.width as u32;
    layout.height = spec.height as u32;

    if let Some(title) = &spec.title {
        layout.title = Some(title.clone());
    }
    if let Some(label) = &spec.x_axis.label {
        layout.x_label = Some(label.clone());
    }
    if let Some(label) = &spec.y_axis.label {
        layout.y_label = Some(label.clone());
    }

    Some(render_to_svg(&plots, &layout))
}

#[cfg(not(feature = "kuva"))]
pub fn render_kuva_svg(_spec: &PlotSpec) -> Option<String> {
    None
}

#[cfg(test)]
#[cfg(feature = "kuva")]
mod tests {
    use super::*;

    #[test]
    fn test_kuva_line_plot() {
        let spec = PlotSpec::new()
            .with_title("kuva test")
            .line(vec![0.0, 1.0, 2.0], vec![0.0, 1.0, 4.0], "y=x^2");
        let svg = render_kuva_svg(&spec);
        assert!(svg.is_some());
        let svg = svg.unwrap();
        assert!(svg.contains("<svg"));
    }

    #[test]
    fn test_kuva_empty() {
        let spec = PlotSpec::new();
        assert!(render_kuva_svg(&spec).is_none());
    }
}
