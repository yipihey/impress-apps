//! `histogram`'s `plot` field is a koine `plot-spec@1.0.0` payload, and
//! imprint draws it: the spec parses as `koine_plot::PlotSpec` and renders
//! through koine-plot's Typst backend and this crate's engine
//! (`plot_ffi::render_koine_plot_svg`; docs/plan-koine-kit-moves.md KM13).
//! The demo crate builds the spec with koine-plot; nothing here converts it.
//!
//! `imprint-core`'s `typst-render` feature is what exposes the renderer.

#![cfg(feature = "typst-render")]

use impress_service_core::{runtime, McpToolDescriptor};
use imprint_core::plot_ffi::render_koine_plot_svg;
use serde_json::json;
use surface_demo_service::{DefaultSurfaceDemoService, SurfaceDemoService};

#[test]
fn histogram_plot_is_a_koine_spec_imprint_renders() {
    let service = DefaultSurfaceDemoService::new();
    let result = runtime::block_on(service.histogram(vec![1.0, 2.0, 2.0, 3.0, 3.0, 3.0], 3));
    assert!(result.error.is_none());

    let spec: koine_plot::PlotSpec =
        serde_json::from_value(result.plot.clone()).unwrap_or_else(|e| {
            panic!(
                "plot did not parse as a koine PlotSpec: {e}\n{}",
                result.plot
            )
        });
    assert_eq!(spec.title.as_deref(), Some("Histogram"));
    assert_eq!(spec.series.len(), 1);
    assert_eq!(spec.series[0].x.len(), 3);
    assert_eq!(spec.x_axis.label.as_deref(), Some("value"));
    assert_eq!(spec.y_axis.label.as_deref(), Some("count"));

    let rendered = render_koine_plot_svg(&spec);
    assert!(rendered.error.is_none(), "{:?}", rendered.error);
    assert!(rendered.svg.contains("<svg"), "imprint drew no SVG");
}

#[test]
fn histogram_plot_reached_through_the_inventory_renders_too() {
    // The same check through the linked-inventory call path (MCP/CLI's
    // actual dispatch), to catch a macro-wiring mistake a direct call would
    // miss.
    let tool = McpToolDescriptor::iter()
        .find(|t| t.name == "surface-demo-service_histogram")
        .expect("surface-demo-service_histogram should be registered");
    let result = impress_service_core::pipeline::invoke_blocking(
        tool.verb,
        impress_service_core::pipeline::Call::agent(
            "test",
            json!({ "values": [0.0, 1.0, 2.0, 3.0, 4.0], "bins": 5 }),
        ),
    )
    .expect("histogram should succeed");

    let plot = result.get("plot").expect("result has a plot field").clone();
    let spec: koine_plot::PlotSpec = serde_json::from_value(plot)
        .expect("the inventory's plot should parse as a koine PlotSpec");
    assert_eq!(spec.series[0].x.len(), 5);
    let rendered = render_koine_plot_svg(&spec);
    assert!(rendered.error.is_none(), "{:?}", rendered.error);
}
