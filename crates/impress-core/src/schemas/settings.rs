//! The synced settings row (ADR-0036 D5, decision D-R1/D-R12).
//!
//! Settings live in files under `<workspace>/settings/` — one per scope —
//! except the `Synced` scope, which is ONE row of this kind so the sync
//! engine carries it to every device the way it carries a named layout. The
//! registry that declares which keys are synced is `crates/impress-settings`;
//! this row holds only `values`, a key → JSON-value object, and the store-tier
//! backend in `impress-store-service` (`settings_service::StoreSyncedBackend`)
//! is its one writer and reader. A device-scoped setting never enters this
//! row: the daemon and the CLI read a port from the file without opening the
//! store, which is the reason the AI preferences precedent chose a file.

use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The canonical synced-settings ref. **VERSIONED**, spelled exactly like
/// this; copy the constant (or `impress_settings::SYNCED_SCHEMA_REF`, which
/// equals it by test), never a sibling call site.
pub const SETTINGS_SCHEMA_REF: crate::SchemaRef = crate::schema::refs::IMPRESS_SETTINGS;

pub fn settings_schema() -> Schema {
    Schema {
        id: SETTINGS_SCHEMA_REF,
        name: "Synced Settings".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "values".into(),
                field_type: FieldType::Object,
                required: true,
                description: Some(
                    "Registry key → JSON value, for every `Synced`-scope setting that has \
                     a stored value. Keys are `impress_settings::registry()`'s; a key the \
                     reading build does not declare is kept, not dropped."
                        .into(),
                ),
            },
            FieldDef {
                name: "updated_at_ms".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some("Unix milliseconds of the last write.".into()),
            },
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

pub fn register_settings_schema(registry: &mut SchemaRegistry) {
    registry
        .register(settings_schema())
        .expect("settings schema registration");
}
