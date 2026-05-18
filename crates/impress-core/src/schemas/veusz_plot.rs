use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for the `veusz-plot@1.0.0` item type.
///
/// A Veusz plot is a `.vsz` source file plus its rendered output (SVG, PDF,
/// or PNG) that lives inside a manuscript's working directory. The plot's
/// rendered file is referenced from the manuscript body via
/// `\includegraphics{...}` (LaTeX) or `image(...)` (Typst).
///
/// Plots are inbound targets of the manuscript's `Visualizes` edge; the plot
/// itself emits no outbound edges by default but may be annotated.
pub fn veusz_plot_schema() -> Schema {
    Schema {
        id: "veusz-plot".into(),
        name: "Veusz Plot".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "display_name".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Human-readable name used in the Plots panel and inserted citations."
                        .into(),
                ),
            },
            FieldDef {
                name: "source_file_rel_path".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Path to the .vsz source file, relative to the parent manuscript's \
                     working directory (e.g. `figures/pulse.vsz`)."
                        .into(),
                ),
            },
            FieldDef {
                name: "rendered_file_rel_path".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Path to the rendered output, relative to the parent manuscript's \
                     working directory (e.g. `figures/pulse.svg`). Absent until the first \
                     successful render."
                        .into(),
                ),
            },
            FieldDef {
                name: "export_format".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Target render format: svg | pdf | png. Driven by host document \
                     format (SVG for Typst, PDF for LaTeX)."
                        .into(),
                ),
            },
            FieldDef {
                name: "source_modified_at".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ISO 8601 timestamp of the .vsz source's last on-disk mtime as \
                     observed by the watcher. Used to decide whether the rendered output \
                     is stale."
                        .into(),
                ),
            },
            FieldDef {
                name: "last_rendered_at".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ISO 8601 timestamp of the most recent successful render. Null when \
                     `render_status` is `error` or `rendering` and no prior success exists."
                        .into(),
                ),
            },
            FieldDef {
                name: "render_status".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Latest render state: idle | rendering | error. Defaults to `idle` \
                     when absent."
                        .into(),
                ),
            },
            FieldDef {
                name: "last_render_error".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Stderr/diagnostic text from the most recent failed render, if any. \
                     Cleared on the next successful render."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Register the `veusz-plot@1.0.0` schema.
pub fn register_veusz_plot_schema(registry: &mut SchemaRegistry) {
    registry
        .register(veusz_plot_schema())
        .expect("veusz-plot schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn veusz_plot_schema_registers() {
        let mut reg = SchemaRegistry::new();
        register_veusz_plot_schema(&mut reg);
        assert!(reg.get("veusz-plot").is_some());
    }

    #[test]
    fn veusz_plot_required_fields() {
        let s = veusz_plot_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"display_name"));
        assert!(required.contains(&"source_file_rel_path"));
        assert!(required.contains(&"export_format"));
    }

    #[test]
    fn veusz_plot_serde_round_trip() {
        let s = veusz_plot_schema();
        let json = serde_json::to_string_pretty(&s).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }
}
