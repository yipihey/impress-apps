use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for the `plot-spec@1.0.0` item type.
///
/// A SAVED, backend-neutral plot specification (the declarative spec that
/// `impress-plot` renders): series/grid, axes, colormap, contour settings —
/// stored as the FFI-spec JSON so a plot made in the imbib panel, over HTTP,
/// or by an agent can be reloaded, re-rendered, and re-inserted later from
/// EITHER app. This is the store-backed replacement for what a `.vsz` file
/// was to Veusz: the figure's editable source of truth.
///
/// The payload deliberately stores the spec as one JSON string rather than
/// exploding fields into the schema: the spec shape evolves with the plotting
/// crate (new series kinds, style options), and the store's job here is
/// identity + listing + sync, not queryability of individual plot knobs.
pub fn plot_spec_schema() -> Schema {
    Schema {
        id: "plot-spec".into(),
        name: "Plot Spec".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "name".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Human-readable name shown in saved-plot lists.".into()),
            },
            FieldDef {
                name: "spec_kind".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Which spec shape `spec_json` holds: \"series\" (FfiPlotSpec) or \
                     \"grid\" (FfiGridSpec)."
                        .into(),
                ),
            },
            FieldDef {
                name: "spec_json".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "The full plot spec as JSON (same shape as the HTTP plot API's \
                     `spec`/`gridSpec` bodies)."
                        .into(),
                ),
            },
            FieldDef {
                name: "data_source".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Optional provenance: path or description of the data file/columns \
                     the series were loaded from (informational; series data is inline \
                     in spec_json)."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Register the plot-spec schema.
pub fn register_plot_spec_schema(registry: &mut SchemaRegistry) {
    registry.register(plot_spec_schema());
}
