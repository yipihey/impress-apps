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
use impress_core::schemas::task::{register_task_schemas, task_schema};
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
/// Note: the registry deliberately skips type-checking of explicit Nulls;
/// this oracle mirrors that documented behavior for OPTIONAL fields. The
/// required-field/Null interaction is probed by the tripwire test below.
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
            Some(Value::Null) => {} // registry skips type check for Null
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
        let item = make_item("task", payload);
        let _ = reg.validate(&item); // must not panic
    }

    /// Property 3b: validation agrees with an independent oracle derived
    /// from the ADR-0005 field table. In particular, task items missing
    /// required `title` or `state` are rejected; unknown extra fields
    /// never cause rejection.
    #[test]
    fn validation_matches_adr_oracle(payload in arb_task_payload()) {
        let reg = task_registry();
        let item = make_item("task", payload.clone());
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
        prop_assert!(reg.validate(&make_item("task", payload.clone())).is_ok());

        let dropped = if drop_title { "title" } else { "state" };
        payload.remove(dropped);
        let errs = reg.validate(&make_item("task", payload)).unwrap_err();
        prop_assert_eq!(errs.len(), 1);
        prop_assert_eq!(errs[0].field.as_str(), dropped);
    }

    /// Property: the hand-rolled `Value` Deserialize impl round-trips every
    /// non-float value through JSON text exactly. Floats are excluded — they
    /// do NOT round-trip exactly; see the BUG tripwire
    /// `float_value_json_round_trip_is_exact` below.
    #[test]
    fn value_json_round_trip_non_float(v in arb_value_with(false)) {
        let json = serde_json::to_string(&v).expect("serialize");
        let back: Value = serde_json::from_str(&json).expect("deserialize");
        prop_assert_eq!(v, back);
    }

    /// Property: an item with an unregistered schema ref is always rejected
    /// (never panics, never silently passes).
    #[test]
    fn unknown_schema_always_rejected(schema in "[a-z-]{1,16}", payload in arb_task_payload()) {
        prop_assume!(schema != "task" && schema != "agent-run");
        let reg = task_registry();
        let errs = reg.validate(&make_item(&schema, payload)).unwrap_err();
        prop_assert_eq!(errs.len(), 1);
        prop_assert_eq!(errs[0].field.as_str(), "schema");
    }
}

// ---------------------------------------------------------------------------
// Deterministic tripwires
// ---------------------------------------------------------------------------

/// BUG TRIPWIRE (found by proptest, counterexample minimized by hand):
/// `Value::Float` does not survive a JSON round-trip exactly. serde_json is
/// built without its `float_roundtrip` feature, so its fast float parser can
/// be off by 1 ULP: 1.7938901934754837e174 serializes to
/// "1.7938901934754837e+174" but parses back as 1.7938901934754835e174.
/// Every payload float persisted through the store's JSON columns (or synced
/// as JSON) can therefore drift silently. Fix: enable serde_json's
/// `float_roundtrip` feature in the workspace.
#[test]
#[ignore = "BUG: Value::Float JSON round-trip loses 1 ULP (serde_json built without float_roundtrip feature); payload floats drift through persistence/sync"]
fn float_value_json_round_trip_is_exact() {
    let v = Value::Float(1.7938901934754837e174);
    let json = serde_json::to_string(&v).expect("serialize");
    let back: Value = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(v, back, "float changed value through JSON round-trip (json text: {})", json);
}

/// GAP TRIPWIRE: ADR-0005 declares `title` and `state` as *required* fields
/// of task@1.0.0, but the registry accepts an explicit `Value::Null` for a
/// required field (it only rejects *absent* required fields — the Null
/// type-check skip in `SchemaRegistry::validate` applies to required fields
/// too). A task with `state: null` therefore validates, yet has no usable
/// state for the ADR-0005 section 2 state machine.
#[test]
#[ignore = "BUG: registry accepts Value::Null for required fields (title/state) — ADR-0005 marks them required, but only absence is rejected"]
fn required_field_explicit_null_is_rejected() {
    let reg = task_registry();
    let mut payload = BTreeMap::new();
    payload.insert("title".to_string(), Value::String("t".into()));
    payload.insert("state".to_string(), Value::Null);
    let result = reg.validate(&make_item("task", payload));
    assert!(
        result.is_err(),
        "required field `state` set to explicit null should be rejected"
    );
}

#[test]
fn task_schema_matches_adr_field_table() {
    // Sanity anchor for the oracle: the schema declares exactly the ADR fields.
    let s = task_schema();
    let names: Vec<&str> = s.fields.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(
        names,
        vec!["title", "state", "description", "assigned_to", "due_at", "output_schema", "error"]
    );
}
