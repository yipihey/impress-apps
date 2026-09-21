//! Workspace UI records: the layout tree and the presets it comes from
//! (ADR-0019 D1, ADR-0031 D4/D10).
//!
//! Two schemas, registered from [`crate::schemas::register_core_schemas`]
//! exactly as the eight artifact kinds are (ADR-0019 D1 names that pattern
//! explicitly). No core type changes are needed: `schema` is a string and
//! `payload` is open JSON, so the whole layout tree rides in one `Object`
//! field.
//!
//! * [`LAYOUT_SCHEMA_REF`] — a named or live workspace arrangement. Its
//!   `layout` field is the serde JSON of `impress_layout::Layout` (ADR-0031
//!   D4): windows over one tile arena, containers over panes, channel state.
//!   The value is produced and mutated only by the pure verbs in
//!   `crates/impress-layout`; this schema is where it comes to rest.
//! * [`PRESET_SCHEMA_REF`] — "an app preset is a set of named queries, a
//!   default tree, and a role assignment" (ADR-0031 D10). The five binaries
//!   are a distribution decision; a preset is what an app *is*. Shipped
//!   presets (Reading, Triage, Writing, Reviewing, plus each app's default)
//!   are store records the user can edit, which is why they are records at
//!   all rather than Rust constants.
//!
//! # Scope (ADR-0019 D2) — the load-bearing decision
//!
//! Scope is a *policy* over fields the substrate already carries
//! ([`crate::item::Visibility`], [`crate::operation::RetentionTier`]) plus an
//! explicit device tag. There is no new mechanism here, and this schema adds
//! no scope field: the scope of a row is read off the envelope and the
//! `device` payload field.
//!
//! | What | Visibility | Retention | Syncs? | Carries `device`? |
//! |---|---|---|---|---|
//! | A **named** layout (`name` set, `is_live` false) | `Private` | `Durable` | yes | no |
//! | The **live** arrangement (`name` null, `is_live` true) | `Private` | `Durable` | yes, as a row | **yes** |
//! | A **preset** | `Private` | `Durable` | yes | no |
//! | Focus, selection, channel values, in-flight resizes | `Private` | `Ephemeral` | no | n/a |
//!
//! The live arrangement is durable — it must survive a quit — but it is
//! **device-scoped**: one live row per `device`, and the projection (ADR-0019
//! D3, the chassis reader at L6) filters to the current device rather than
//! applying a 27" iMac's arrangement to a laptop. Named layouts carry no
//! `device` and follow the user everywhere.
//!
//! **Geometry is device-scoped even inside a layout that is not.** A window's
//! frame lives at `layout.windows[].geometry`, which is `Option<Geometry>` in
//! the layout value precisely so it can be absent. A named layout that
//! travels must be projected with geometry **filtered out** before it is
//! applied on another device; the logical tree (splits, shares, roles, pane
//! specs) is what ports. This is ADR-0031's "Defaults accepted" resolution of
//! ADR-0019 OQ1: logical tree portable-durable, window geometry
//! device-scoped, focus and selection ephemeral.
//!
//! Churn is bounded by tier and coalescing (ADR-0019 D6): a splitter drag
//! emits `Ephemeral` operations coalesced on release, and only a *commit* —
//! saving a named layout, editing a preset — is `Durable`. Nothing here may
//! be written during the first ~90 s of launch; see the standing startup
//! render-loop guard in the root CLAUDE.md.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The canonical layout ref. **VERSIONED**, and spelled exactly like this.
///
/// Copy this constant, never a sibling call site (root CLAUDE.md, "Definition
/// of done — schema refs"): the store matches `items.schema_ref` by exact
/// equality, so `impress/ui/layout` — the bare spelling — matches no rows
/// forever, silently. The constant exists so L3's `layout-service` and L6's
/// projection never spell the string at all.
pub const LAYOUT_SCHEMA_REF: &str = "impress/ui/layout@1.0.0";

/// The canonical preset ref. **VERSIONED**, for the same reason as
/// [`LAYOUT_SCHEMA_REF`]: the payload shape is the contract every preset
/// reader depends on, and a v2 must be able to coexist with v1 rows in a
/// live store rather than requiring a migration of the user's saved work.
pub const PRESET_SCHEMA_REF: &str = "impress/ui/preset@1.0.0";

/// Schema for [`LAYOUT_SCHEMA_REF`] — a named or live workspace arrangement.
///
/// `layout` is the whole tree, as the serde JSON of `impress_layout::Layout`.
/// It is deliberately ONE `Object` field rather than a flattened set of
/// columns: the tree's shape is owned by `crates/impress-layout` and its
/// normalization invariants (empty containers pruned, single-child containers
/// collapsed, same-direction linears joined), and a second, flattened
/// description of it here would be a second definition to keep in step — the
/// failure mode this repo has a CI workflow about.
///
/// Scope per ADR-0019 D2; see the module docs for the table. In short:
/// named layouts are `Private` + `Durable` and sync to every device; the live
/// arrangement is also `Private` + `Durable` but carries `device`, so it
/// persists locally and never *applies* elsewhere; and the geometry inside
/// `layout.windows[].geometry` is device-scoped in every case and must be
/// filtered out by the projection before a travelled layout is applied.
///
/// Expected edges: `DerivedFrom` (the preset this arrangement started as, so
/// "reset to preset" is a graph walk rather than a remembered string) and
/// `RelatesTo` (the manuscript, library or collection a purpose-labelled
/// layout is *about*).
pub fn layout_schema() -> Schema {
    Schema {
        id: LAYOUT_SCHEMA_REF.into(),
        name: "Workspace Layout".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "name".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Display name of a saved layout (\"Triage\", \"Two-up reading\"). \
                     NULL/absent for the live arrangement — the one the window is \
                     currently in — which is distinguished by `is_live`, not by a \
                     reserved name. ADR-0019 D1: `SavedPaneLayout`'s name becomes a \
                     payload field."
                        .into(),
                ),
            },
            FieldDef {
                name: "purpose".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Free-text task label the user may set (\"Reading\", \"Revising \
                     the methods section\"). Optional, uninterpreted, and NOT a \
                     closed vocabulary: it exists so a layout can say what it is for \
                     in the user's words, and so an agent can be asked for \"the \
                     layout I read in\" without the chassis owning a taxonomy."
                        .into(),
                ),
            },
            FieldDef {
                name: "layout".into(),
                field_type: FieldType::Object,
                required: true,
                description: Some(
                    "The layout tree: the serde JSON of `impress_layout::Layout` \
                     (ADR-0031 D4) — `windows`, the `tiles` arena, `channels`, \
                     `next_tile`. Written and mutated only by the pure verbs in \
                     crates/impress-layout; stored here verbatim. Note that \
                     `windows[].geometry` inside this object is DEVICE-SCOPED \
                     (ADR-0019 D2) and must be filtered by the projection before a \
                     synced layout is applied on another device."
                        .into(),
                ),
            },
            FieldDef {
                name: "device".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Device tag for a device-scoped variant (ADR-0019 D2). Set on \
                     the live arrangement — one live row per device, and the \
                     projection filters to the current device so a 27\" iMac's \
                     arrangement never overwrites the laptop. NULL/absent on a named \
                     layout, which is portable-durable and follows the user."
                        .into(),
                ),
            },
            FieldDef {
                name: "app_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Which preset family this arrangement belongs to (\"imbib\", \
                     \"imprint\", \"impress\", …), matching `app_id` on the preset \
                     it derives from. NULL for a layout that is not tied to one — \
                     the five binaries are a distribution decision, not a chassis \
                     one (ADR-0031 D10)."
                        .into(),
                ),
            },
            FieldDef {
                name: "is_live".into(),
                field_type: FieldType::Bool,
                required: true,
                description: Some(
                    "True for THE distinguished live arrangement of its scope — the \
                     (app_id, device) pair — and false for every saved layout. \
                     Required rather than defaulted: a writer that omits it is \
                     ambiguous about which row the chassis restores at launch, and \
                     two rows claiming to be live for one scope is the bug this \
                     field exists to make visible. Readers should still treat absent \
                     as false rather than erroring on a hand-edited row."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![EdgeType::DerivedFrom, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Schema for [`PRESET_SCHEMA_REF`] — a shipped or user-edited preset
/// (ADR-0031 D10).
///
/// "imbib is the publication queries with the triage layout; imprint is the
/// manuscript queries with the writing layout." A preset is therefore three
/// things and a name: `queries` (name → `PaneQuery` JSON), `layout` (the
/// default tree), and `roles` (role → pane path or tile id). `version` is the
/// shipped revision, so an app can tell "the user edited Triage" from "we
/// shipped a newer Triage" without a second record kind.
///
/// Only `name` and `app_id` are required. The other three are optional
/// because a **user-edited** preset legitimately overrides one facet and
/// inherits the rest from the shipped preset it `DerivedFrom` — a preset that
/// only reassigns roles is a real thing a user makes, and requiring it to
/// carry a copy of the tree would be a second definition that drifts.
/// Shipped presets carry all four.
///
/// `roles` is a map rather than a field per role on purpose: ADR-0031 D5 is
/// explicit that no pane kind is privileged, so the role set (`navigator`,
/// `list`, `detail`, `preview`, `console`, …) must be extensible without a
/// schema version bump.
pub fn preset_schema() -> Schema {
    Schema {
        id: PRESET_SCHEMA_REF.into(),
        name: "Workspace Preset".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "name".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Display name of the preset (\"Triage\", \"Reading\", \
                     \"Writing\", \"Reviewing\", or an app's default). Recalled by \
                     ⌃⌘1–9 (ADR-0031 D10)."
                        .into(),
                ),
            },
            FieldDef {
                name: "app_id".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "The preset family: \"imbib\", \"imprint\", \"implore\", \
                     \"impel\", \"impart\", \"impress\". An app preset is what the \
                     app IS (ADR-0031 D10), so this is required — a preset that \
                     belongs to nothing cannot be offered anywhere."
                        .into(),
                ),
            },
            FieldDef {
                name: "queries".into(),
                field_type: FieldType::Object,
                required: false,
                description: Some(
                    "Map of query name → `impress_core::pane_query::PaneQuery` JSON \
                     (ADR-0031 D2). These are the named queries the preset's panes \
                     refer to. Absent on a user-edited preset that overrides only \
                     the tree or the roles and inherits the queries from the shipped \
                     preset it DerivedFrom."
                        .into(),
                ),
            },
            FieldDef {
                name: "layout".into(),
                field_type: FieldType::Object,
                required: false,
                description: Some(
                    "The default tree: the serde JSON of `impress_layout::Layout`, \
                     same shape as the layout record's `layout` field. Absent on a \
                     preset that overrides only queries or roles."
                        .into(),
                ),
            },
            FieldDef {
                name: "roles".into(),
                field_type: FieldType::Object,
                required: false,
                description: Some(
                    "Map of role → pane path or tile id, assigning `navigator`, \
                     `list`, `detail`, `preview`, `console` (and any later role) to \
                     tiles of `layout`. A MAP, not a field per role: no pane kind is \
                     privileged (ADR-0031 D5) and the universal chords act on \
                     whichever pane holds the role, so the set must grow without a \
                     schema version bump."
                        .into(),
                ),
            },
            FieldDef {
                name: "version".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some(
                    "Revision of the SHIPPED preset this row represents. Lets an app \
                     distinguish \"the user edited Triage\" from \"we shipped a newer \
                     Triage\" and offer the update, instead of silently overwriting \
                     the user's arrangement — which is the behaviour \
                     `PaneLayoutStore`'s own header objects to."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![EdgeType::DerivedFrom, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Every UI schema ref, in registration order — the ONE list a caller
/// enumerates workspace record kinds from. Hardcoding these spellings
/// anywhere else is the schema-refs drift class; the parity test below pins
/// this array to what [`register_ui_schemas`] actually registers.
pub const UI_SCHEMA_REFS: [&str; 2] = [LAYOUT_SCHEMA_REF, PRESET_SCHEMA_REF];

/// Register the workspace UI schemas (ADR-0019 D1).
///
/// Order is presentation only: neither inherits from the other, and neither
/// depends on any other core schema. A layout's relation to its preset is a
/// `DerivedFrom` edge, not an inherits edge — the payloads are different
/// shapes, and a preset is not a layout with extra fields.
pub fn register_ui_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(layout_schema())
        .expect("ui/layout schema registration");
    registry
        .register(preset_schema())
        .expect("ui/preset schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ui_schemas_register_under_the_canonical_refs() {
        let mut reg = SchemaRegistry::new();
        register_ui_schemas(&mut reg);
        assert!(
            reg.get(LAYOUT_SCHEMA_REF).is_some(),
            "layout not registered under {LAYOUT_SCHEMA_REF}"
        );
        assert!(
            reg.get(PRESET_SCHEMA_REF).is_some(),
            "preset not registered under {PRESET_SCHEMA_REF}"
        );
    }

    /// The versioned spelling is the ONLY one. A bare `impress/ui/layout`
    /// registration would let a writer and a reader each pick one, pass the
    /// lint, and never meet — the `manuscript-section@1.0.0` incident.
    #[test]
    fn the_bare_spellings_are_not_registered() {
        let mut reg = SchemaRegistry::new();
        register_ui_schemas(&mut reg);
        // schema-ref-lint:allow — negative assertion: these are the WRONG
        // spellings, named here so the test can prove nothing answers to them.
        for bare in ["impress/ui/layout", "impress/ui/preset"] {
            assert!(
                reg.get(bare).is_none(),
                "{bare:?} must not be registered: one canonical spelling per kind"
            );
        }
    }

    #[test]
    fn ui_schema_refs_const_matches_the_registry() {
        let mut reg = SchemaRegistry::new();
        register_ui_schemas(&mut reg);
        for id in UI_SCHEMA_REFS {
            assert!(
                reg.get(id).is_some(),
                "UI_SCHEMA_REFS names {id:?}, which register_ui_schemas does not register"
            );
        }
        assert_eq!(
            UI_SCHEMA_REFS.len(),
            reg.list()
                .iter()
                .filter(|s| s.id.starts_with("impress/ui/"))
                .count(),
            "a ui schema exists that UI_SCHEMA_REFS does not name"
        );
    }

    #[test]
    fn layout_required_fields() {
        let s = layout_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(required, vec!["layout", "is_live"]);
    }

    #[test]
    fn layout_tree_is_one_open_object_field() {
        let s = layout_schema();
        let layout = s
            .fields
            .iter()
            .find(|f| f.name == "layout")
            .expect("layout field");
        assert_eq!(layout.field_type, FieldType::Object);
        // The tree is owned by crates/impress-layout. Flattening any part of
        // it into sibling columns here would be a second definition of the
        // same value.
        for flattened in ["windows", "tiles", "channels", "root", "focused"] {
            assert!(
                !s.fields.iter().any(|f| f.name == flattened),
                "{flattened:?} belongs INSIDE the `layout` object, not beside it"
            );
        }
    }

    /// ADR-0019 D2: the live arrangement is device-scoped, so the device tag
    /// must be a field the projection can filter on.
    #[test]
    fn layout_carries_the_device_tag_and_the_live_flag() {
        let s = layout_schema();
        let device = s
            .fields
            .iter()
            .find(|f| f.name == "device")
            .expect("device field");
        assert_eq!(device.field_type, FieldType::String);
        assert!(!device.required, "a named layout carries no device");

        let is_live = s
            .fields
            .iter()
            .find(|f| f.name == "is_live")
            .expect("is_live field");
        assert_eq!(is_live.field_type, FieldType::Bool);
    }

    #[test]
    fn preset_required_fields() {
        let s = preset_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(required, vec!["name", "app_id"]);
    }

    #[test]
    fn preset_carries_queries_layout_and_roles_as_open_maps() {
        let s = preset_schema();
        for name in ["queries", "layout", "roles"] {
            let f = s
                .fields
                .iter()
                .find(|f| f.name == name)
                .unwrap_or_else(|| panic!("field {name:?} should exist"));
            assert_eq!(
                f.field_type,
                FieldType::Object,
                "{name:?} must be an open object"
            );
        }
        let version = s
            .fields
            .iter()
            .find(|f| f.name == "version")
            .expect("version field");
        assert_eq!(version.field_type, FieldType::Int);
    }

    #[test]
    fn ui_schemas_do_not_inherit() {
        assert_eq!(layout_schema().inherits, None);
        assert_eq!(preset_schema().inherits, None);
    }

    #[test]
    fn ui_schemas_expect_derived_from_edges() {
        for s in [layout_schema(), preset_schema()] {
            assert!(
                s.expected_edges.contains(&EdgeType::DerivedFrom),
                "{} should expect DerivedFrom (layout ← preset)",
                s.id
            );
        }
    }

    #[test]
    fn ui_schemas_serde_round_trip() {
        for s in [layout_schema(), preset_schema()] {
            let json = serde_json::to_string_pretty(&s).unwrap();
            let back: Schema = serde_json::from_str(&json).unwrap();
            assert_eq!(s, back);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Store-backed: a real layout tree written and read back by exact ref
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(all(test, feature = "sqlite"))]
mod store_tests {
    use super::*;
    use crate::item::{Item, Priority, Value, Visibility};
    use crate::query::ItemQuery;
    use crate::schemas::register_core_schemas;
    use crate::sqlite_store::SqliteItemStore;
    use crate::store::ItemStore;
    use std::collections::BTreeMap;

    /// A real `impress_layout::Layout` — today's three-column chassis as a
    /// value — as produced by `impress_layout::preset::three_column(...)`.
    ///
    /// Embedded as the committed golden file rather than constructed by
    /// calling `three_column()` directly: `impress-layout` depends on
    /// `impress-core`, so taking it as a dev-dependency here would be a
    /// dev-dependency cycle *and* an edit to the workspace manifest, which is
    /// owned elsewhere right now (see the L2 report). The golden is the same
    /// bytes `crates/impress-layout/tests` asserts against, so it cannot
    /// silently stop being a real layout: if the layout value's serde shape
    /// changes, that crate's golden test fails first.
    const THREE_COLUMN_GOLDEN: &str =
        include_str!("../../../impress-layout/tests/golden/three_column.json");

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    fn item(store: &SqliteItemStore, schema: &str, payload: BTreeMap<String, Value>) -> Item {
        let now = chrono::Utc::now();
        Item {
            id: uuid::Uuid::new_v4(),
            schema: schema.into(),
            payload,
            created: now,
            modified: now,
            author: store.default_author.clone(),
            author_kind: store.default_author_kind,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::None,
            // ADR-0019 D2: every UI item is Private. The scope distinction is
            // retention plus the device tag, not visibility.
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        }
    }

    /// The golden bytes as a payload value, via the same open-JSON path a
    /// real writer would take.
    fn golden_layout_value() -> Value {
        serde_json::from_str::<Value>(THREE_COLUMN_GOLDEN).expect("golden layout parses as a Value")
    }

    fn named_layout_payload() -> BTreeMap<String, Value> {
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        payload.insert("name".into(), Value::String("Triage".into()));
        payload.insert("purpose".into(), Value::String("Reading".into()));
        payload.insert("layout".into(), golden_layout_value());
        payload.insert("app_id".into(), Value::String("imbib".into()));
        payload.insert("is_live".into(), Value::Bool(false));
        payload
    }

    fn query_for(schema: &str) -> ItemQuery {
        ItemQuery {
            schema: Some(schema.to_string()),
            ..Default::default()
        }
    }

    /// Write a layout whose payload is a real `Layout`, read it back by the
    /// exact canonical ref, and prove the tree survives the round trip.
    #[test]
    fn layout_round_trips_through_the_store() {
        let store = open();
        let id = store
            .insert(item(&store, LAYOUT_SCHEMA_REF, named_layout_payload()))
            .expect("insert layout");

        let rows = store
            .query(&query_for(LAYOUT_SCHEMA_REF))
            .expect("query runs");
        assert_eq!(rows.len(), 1, "exactly one layout row");
        assert_eq!(rows[0].id, id);
        assert_eq!(rows[0].schema, LAYOUT_SCHEMA_REF);

        let Some(Value::Object(_)) = rows[0].payload.get("layout") else {
            panic!("the `layout` field must come back as an object");
        };

        // The payload deserializes: re-serialize the stored value and compare
        // it to the golden JSON it was written from. Structural equality of
        // the whole tree, not a spot check — this is the assertion that would
        // fail if the store coerced, truncated or reordered the value.
        let stored: serde_json::Value =
            serde_json::to_value(rows[0].payload.get("layout").unwrap())
                .expect("stored layout re-serializes");
        let golden: serde_json::Value =
            serde_json::from_str(THREE_COLUMN_GOLDEN).expect("golden parses");
        assert_eq!(stored, golden, "the layout tree survived the round trip");

        // And it really is a three-column layout: one window, four tiles, the
        // three ADR-0031 D5 roles. (Asserted on the JSON rather than on
        // `impress_layout::Layout` only because of the dependency direction
        // noted on THREE_COLUMN_GOLDEN.)
        assert_eq!(stored["windows"].as_array().expect("windows").len(), 1);
        let tiles = stored["tiles"].as_object().expect("tiles arena");
        assert_eq!(tiles.len(), 4, "navigator, list, detail, and the container");
        let roles: Vec<&str> = tiles
            .values()
            .filter_map(|t| t.get("pane")?.get("role")?.as_str())
            .collect();
        for role in ["navigator", "list", "detail"] {
            assert!(roles.contains(&role), "expected a pane with role {role:?}");
        }
    }

    /// The invariant, documented as a test rather than a comment: the store
    /// matches `schema_ref` by EXACT EQUALITY. A reader that drops the
    /// version suffix gets zero rows — no error, no log line, forever. That
    /// is indistinguishable from "the user has no saved layouts yet", which
    /// is why this bug class has shipped five times.
    #[test]
    fn a_misspelled_ref_returns_zero_rows_rather_than_erroring() {
        let store = open();
        store
            .insert(item(&store, LAYOUT_SCHEMA_REF, named_layout_payload()))
            .expect("insert layout");

        assert_eq!(
            store
                .query(&query_for(LAYOUT_SCHEMA_REF))
                .expect("canonical query runs")
                .len(),
            1
        );

        // schema-ref-lint:allow — negative fixture: the bare spelling is the
        // WRONG ref, named here to prove it silently matches nothing.
        for wrong in ["impress/ui/layout", "impress/ui/layout@1.0", "ui/layout"] {
            let rows = store
                .query(&query_for(wrong))
                .unwrap_or_else(|e| panic!("query for {wrong:?} should run, not error: {e}"));
            assert!(
                rows.is_empty(),
                "{wrong:?} returned {} rows — the store is supposed to match by \
                 exact equality, so this spelling must match nothing",
                rows.len()
            );
        }
    }

    /// Presets are records the user can edit (ADR-0031 D10), so they round
    /// trip too — and they do not answer to the layout ref.
    #[test]
    fn preset_round_trips_and_does_not_collide_with_layout() {
        let store = open();
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        payload.insert("name".into(), Value::String("Triage".into()));
        payload.insert("app_id".into(), Value::String("imbib".into()));
        payload.insert("layout".into(), golden_layout_value());
        payload.insert(
            "roles".into(),
            Value::Object(BTreeMap::from([
                ("navigator".into(), Value::String("1".into())),
                ("list".into(), Value::String("2".into())),
                ("detail".into(), Value::String("3".into())),
            ])),
        );
        payload.insert("version".into(), Value::Int(1));
        store
            .insert(item(&store, PRESET_SCHEMA_REF, payload))
            .expect("insert preset");

        let presets = store
            .query(&query_for(PRESET_SCHEMA_REF))
            .expect("preset query runs");
        assert_eq!(presets.len(), 1);
        assert_eq!(presets[0].schema, PRESET_SCHEMA_REF);

        assert!(
            store
                .query(&query_for(LAYOUT_SCHEMA_REF))
                .expect("layout query runs")
                .is_empty(),
            "a preset is not a layout: the two refs are separate kinds"
        );
    }

    /// Both rows validate against the registry `register_core_schemas`
    /// builds — the other direction of "registered" from the parity test.
    #[test]
    fn stored_rows_validate_against_the_core_registry() {
        let store = open();
        let mut registry = crate::registry::SchemaRegistry::new();
        register_core_schemas(&mut registry);

        let layout = item(&store, LAYOUT_SCHEMA_REF, named_layout_payload());
        registry
            .validate(&layout)
            .expect("a well-formed layout row validates");

        // `layout` and `is_live` are the two required fields; dropping either
        // must be caught here rather than at read time.
        let mut missing = layout.clone();
        missing.payload.remove("layout");
        let errs = registry
            .validate(&missing)
            .expect_err("a layout row without its tree must not validate");
        assert!(errs.iter().any(|e| e.field == "layout"));
    }
}
