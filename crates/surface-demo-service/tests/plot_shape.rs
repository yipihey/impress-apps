//! `histogram`'s `plot` field really is a `plot-spec@1.0.0` payload: it
//! deserializes into `imprint_core::plot_ffi::FfiPlotSpec`, the type the
//! suite's `plot` widget renders through
//! (ADR-0033 "Defaults": "the widget renders through imprint-core's existing
//! `render_plot_svg`").
//!
//! `imprint-core` (with its heavy `typst-render` feature) is a dev-dependency
//! only — see `src/plot.rs`'s module docs for why the crate itself never
//! needs it: it builds this JSON from a local mirror struct.

use impress_service_core::{runtime, McpToolDescriptor};
use imprint_core::plot_ffi::{FfiColormap, FfiPlotSpec, FfiSeriesKind, FfiStrategy};
use serde_json::json;
use surface_demo_service::{DefaultSurfaceDemoService, SurfaceDemoService};

#[test]
fn histogram_plot_deserializes_as_ffi_plot_spec() {
    let service = DefaultSurfaceDemoService::new();
    let result = runtime::block_on(service.histogram(vec![1.0, 2.0, 2.0, 3.0, 3.0, 3.0], 3));
    assert!(result.error.is_none());

    let spec: FfiPlotSpec = serde_json::from_value(result.plot.clone())
        .unwrap_or_else(|e| panic!("plot did not parse as FfiPlotSpec: {e}\n{}", result.plot));

    assert_eq!(spec.title, "Histogram");
    assert!(matches!(spec.strategy, FfiStrategy::Auto));
    assert!(matches!(spec.colormap, FfiColormap::Viridis));
    assert_eq!(spec.series.len(), 1);
    assert!(matches!(spec.series[0].kind, FfiSeriesKind::Line));
    assert_eq!(spec.series[0].xs.len(), 3);
    assert_eq!(spec.series[0].ys.len(), 3);
    assert_eq!(spec.x.label.as_deref(), Some("value"));
    assert_eq!(spec.y.label.as_deref(), Some("count"));
}

#[test]
fn histogram_plot_also_deserializes_reached_through_the_inventory() {
    // The same check, but through the linked-inventory call path (MCP/CLI's
    // actual dispatch), to catch a macro-wiring mistake a direct call would
    // miss — same discipline as the scaffold's own inventory test.
    let tool = McpToolDescriptor::iter()
        .find(|t| t.name == "surface-demo-service_histogram")
        .expect("surface-demo-service_histogram should be registered");
    let result = runtime::block_on((tool.handler)(json!({
        "values": [0.0, 1.0, 2.0, 3.0, 4.0],
        "bins": 5
    })))
    .expect("histogram should succeed");

    let plot = result.get("plot").expect("result has a plot field").clone();
    let spec: FfiPlotSpec = serde_json::from_value(plot)
        .expect("plot returned through the inventory should parse as FfiPlotSpec");
    assert_eq!(spec.series[0].xs.len(), 5);
}
