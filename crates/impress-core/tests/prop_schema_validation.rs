//! Property tests for schema validation (ADR-0005 section 1) and the
//! hand-written `Value` serde implementation that everything else rides on.
//!
//! These tests run without the `sqlite` feature; store-level properties
//! live in `prop_store_graph.rs`.

use std::collections::BTreeMap;

use chrono::Utc;
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::registry::SchemaRegistry;
use impress_core::schema::FieldType;
use impress_core::schemas::task::{register_task_schemas, task_schema, TASK_SCHEMA};
use proptest::prelude::*;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_item(schema: &str, payload: BTreeMap<String, Value>) -> Item {
    Item {
        id: Uuid::new_v4(),
        schema: schema.into(),
        payload,
        created: Utc::now(),
        modified: Utc::now(),
        author: "prop-test".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    }
}

fn task_registry() -> SchemaRegistry {
    let mut reg = SchemaRegistry::new();
    register_task_schemas(&mut reg);
    reg
}

/// Recursive strategy for arbitrary payload values.
/// Floats are restricted to finite values: JSON has no NaN/Inf representation
/// and `serde_json::to_string` rejects them by design.
fn arb_value_with(floats: bool) -> impl Strategy<Value = Value> {
    let mut leaves = vec![
        Just(Value::Null).boxed(),
        any::<bool>().prop_map(Value::Bool).boxed(),
        any::<i64>().prop_map(Value::Int).boxed(),
        ".{0,12}".prop_map(Value::String).boxed(),
    ];
    if floats {
        leaves.push(
            any::<f64>()
                .prop_filter("finite", |f| f.is_finite())
                .prop_map(Value::Float)
                .boxed(),
        );
    }
    prop::strategy::Union::new(leaves).prop_recursive(3, 24, 6, |inner| {
        prop_oneof![
            prop::collection::vec(inner.clone(), 0..4).prop_map(Value::Array),
            prop::collection::btree_map("[a-z_]{1,8}", inner, 0..4).prop_map(Value::Object),
        ]
    })
}

fn arb_value() -> impl Strategy<Value = Value> {
    arb_value_with(true)
}

/// Arbitrary payload map: mixes known task-schema field names with junk keys,
/// each carrying an arbitrary value.
fn arb_task_payload() -> impl Strategy<Value = BTreeMap<String, Value>> {
    let key = prop_oneof![
        Just("title".to_string()),
        Just("state".to_string()),
        Just("description".to_string()),
        Just("assigned_to".to_string()),
        Just("due_at".to_string()),
        Just("output_schema".to_string()),
        Just("error".to_string()),
        "[a-z_]{1,10}".prop_map(|s| s),
    ];
    prop::collection::btree_map(key, arb_value(), 0..8)
}

/// Independent oracle for task@1.0.0 validation, written directly from the
/// ADR-0005 section 1 field table (NOT from the registry implementation).
///
/// A payload is valid iff:
///  - every required field (title, state) is present, and
///  - every schema-declared field that is present with a non-null value
///    has the declared type (String for all except due_at: Int).
///
/// Note: the registry deliberately skips type-checking of explicit Nulls on
/// OPTIONAL fields; an explicit Null on a REQUIRED field is rejected just
/// like absence (see `required_field_explicit_null_is_rejected` below).
fn oracle_is_valid(payload: &BTreeMap<String, Value>) -> bool {
    let declared: &[(&str, FieldType, bool)] = &[
        ("title", FieldType::String, true),
        ("state", FieldType::String, true),
        ("description", FieldType::String, false),
        ("assigned_to", FieldType::String, false),
        ("due_at", FieldType::Int, false),
        ("output_schema", FieldType::String, false),
        ("error", FieldType::String, false),
    ];
    for (name, ftype, required) in declared {
        match payload.get(*name) {
            None => {
                if *required {
                    return false;
                }
            }
            Some(Value::Null) => {
                // Null is only legal on optional fields; on required fields
                // it is as unusable as absence.
                if *required {
                    return false;
                }
            }
            Some(v) => {
                let matches = match ftype {
                    FieldType::String => matches!(v, Value::String(_)),
                    FieldType::Int => matches!(v, Value::Int(_)),
                    _ => unreachable!("task schema only declares String/Int"),
                };
                if !matches {
                    return false;
                }
            }
        }
    }
    true
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

proptest! {
    /// Property 3a: validation is total — arbitrary payloads (junk keys,
    /// deeply nested values, any scalar types) never panic the registry.
    #[test]
    fn validation_never_panics_on_arbitrary_payload(payload in arb_task_payload()) {
        let reg = task_registry();
        let item = make_item(TASK_SCHEMA, payload);
        let _ = reg.validate(&item); // must not panic
    }

    /// Property 3b: validation agrees with an independent oracle derived
    /// from the ADR-0005 field table. In particular, task items missing
    /// required `title` or `state` are rejected; unknown extra fields
    /// never cause rejection.
    #[test]
    fn validation_matches_adr_oracle(payload in arb_task_payload()) {
        let reg = task_registry();
        let item = make_item(TASK_SCHEMA, payload.clone());
        let got = reg.validate(&item).is_ok();
        let want = oracle_is_valid(&payload);
        prop_assert_eq!(
            got, want,
            "validate disagrees with ADR oracle for payload {:?}", payload
        );
    }

    /// Property 3c: dropping any single required field from an otherwise
    /// valid task payload flips validation from Ok to Err, and the error
    /// names exactly the dropped field.
    #[test]
    fn dropping_required_field_is_rejected(
        title in "[a-zA-Z0-9 ]{1,20}",
        state in prop::sample::select(vec!["pending", "running", "done", "failed", "cancelled"]),
        drop_title in any::<bool>(),
    ) {
        let reg = task_registry();
        let mut payload = BTreeMap::new();
        payload.insert("title".to_string(), Value::String(title));
        payload.insert("state".to_string(), Value::String(state.to_string()));
        prop_assert!(reg.validate(&make_item(TASK_SCHEMA, payload.clone())).is_ok());

        let dropped = if drop_title { "title" } else { "state" };
        payload.remove(dropped);
        let errs = reg.validate(&make_item(TASK_SCHEMA, payload)).unwrap_err();
        prop_assert_eq!(errs.len(), 1);
        prop_assert_eq!(errs[0].field.as_str(), dropped);
    }

    /// Property: the hand-rolled `Value` Deserialize impl round-trips every
    /// value — floats included — through JSON text exactly. Exact float
    /// round-tripping requires serde_json's `float_roundtrip` feature (see
    /// the regression tripwire `float_value_json_round_trip_is_exact` below).
    #[test]
    fn value_json_round_trip(v in arb_value()) {
        let json = serde_json::to_string(&v).expect("serialize");
        let back: Value = serde_json::from_str(&json).expect("deserialize");
        prop_assert_eq!(v, back);
    }

    /// Property: an item with an unregistered schema ref is always rejected
    /// (never panics, never silently passes).
    #[test]
    /// The generator cannot produce a registered id: since WP C4 both
    /// registered ids carry an `@1.0.0` suffix and this alphabet has no `@`,
    /// so the `prop_assume!(schema != "task" && …)` this test used to need is
    /// gone — the versioned spelling made the exclusion structural.
    fn unknown_schema_always_rejected(schema in "[a-z-]{1,16}", payload in arb_task_payload()) {
        let reg = task_registry();
        let errs = reg.validate(&make_item(&schema, payload)).unwrap_err();
        prop_assert_eq!(errs.len(), 1);
        prop_assert_eq!(errs[0].field.as_str(), "schema");
    }
}

// ---------------------------------------------------------------------------
// Deterministic tripwires
// ---------------------------------------------------------------------------

/// REGRESSION TRIPWIRE (found by proptest, counterexample minimized by
/// hand): without serde_json's `float_roundtrip` feature its fast float
/// parser can be off by 1 ULP: 1.7938901934754837e174 serializes to
/// "1.7938901934754837e+174" but parses back as 1.7938901934754835e174,
/// silently drifting every payload float persisted through the store's JSON
/// columns (or synced as JSON). The workspace serde_json dependency now
/// enables `float_roundtrip`; this test guards against losing it.
#[test]
fn float_value_json_round_trip_is_exact() {
    let v = Value::Float(1.7938901934754837e174);
    let json = serde_json::to_string(&v).expect("serialize");
    let back: Value = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(
        v, back,
        "float changed value through JSON round-trip (json text: {})",
        json
    );
}

/// REGRESSION TRIPWIRE: ADR-0005 declares `title` and `state` as *required*
/// fields of task@1.0.0. `SchemaRegistry::validate` rejects an explicit
/// `Value::Null` on a required field the same way it rejects absence — a
/// task with `state: null` has no usable state for the ADR-0005 section 2
/// state machine. (Null on OPTIONAL fields remains legal.)
#[test]
fn required_field_explicit_null_is_rejected() {
    let reg = task_registry();
    let mut payload = BTreeMap::new();
    payload.insert("title".to_string(), Value::String("t".into()));
    payload.insert("state".to_string(), Value::Null);
    let result = reg.validate(&make_item(TASK_SCHEMA, payload));
    assert!(
        result.is_err(),
        "required field `state` set to explicit null should be rejected"
    );
}

/// Sanity anchor for the oracle: the schema declares exactly these fields, in
/// this order.
///
/// The ADR-0005 §1 table is the first seven. The last four arrived in WP C4,
/// when impel-core's SECOND, richer definition of this same kind was deleted
/// and folded in here — `task_kind` and `attempts` from the kernel scheduler,
/// `source_app` and `external_id` from impel's Swift bridge. They were being
/// written the whole time; the schema just didn't know, because the writers
/// were validating against a registry entry spelled `impel/task` while they
/// wrote `task@1.0.0`.
///
/// The oracle below is unaffected: every added field is OPTIONAL, and
/// `validate` never rejects an item for extra or absent optional fields — only
/// `title` and `state` are required, which is what `validation_matches_adr_oracle`
/// pins.
#[test]
fn task_schema_matches_adr_field_table() {
    let s = task_schema();
    let names: Vec<&str> = s.fields.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(
        names,
        vec![
            // ADR-0005 §1.
            "title",
            "state",
            "description",
            // WP C4: the kernel's executor dispatch key. `ready_tasks` requires
            // it, so a task without one is not schedulable.
            "task_kind",
            "assigned_to",
            "attempts",
            "due_at",
            "output_schema",
            "error",
            // WP C4: impel's SharedTaskBridge mirror provenance.
            "source_app",
            "external_id",
        ]
    );
    let required: Vec<&str> = s
        .fields
        .iter()
        .filter(|f| f.required)
        .map(|f| f.name.as_str())
        .collect();
    assert_eq!(
        required,
        vec!["title", "state"],
        "the union must not have promoted any writer's field to required — a \
         mirrored row carries only title/state plus optionals and must validate"
    );
}
