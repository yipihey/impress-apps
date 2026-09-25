//! docs/agent-surfaces.md is what an agent copies from, so its JSON is
//! tested against the code (review AC-F23, RS-S18): every block marked
//! `<!-- wire: KIND [NAME] -->` must parse as the real type, and every key it
//! shows must be a key that type actually has — `"pane"` where the field is
//! `tile`, `"cursor"` where it is `next_seq`, a `focusable` that is
//! `focus_order` all fail here.

use impress_service_core::McpToolDescriptor;
use impress_surface::{Event, RenderTree};
use impress_surface_service::dto::{
    SurfaceDispatchResult, SurfaceResult, SurfaceShowResult, SurfaceValidateResult,
    SurfaceWaitResult,
};
use impress_surface_service::DefaultImpressSurfaceService;
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::Value;

// The demo verbs the signal explorer calls.
use surface_demo_service as _;

const DOC: &str = include_str!("../../../docs/agent-surfaces.md");

/// `(label, json)` for every marked block.
fn blocks() -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut rest = DOC;
    while let Some(start) = rest.find("<!-- wire: ") {
        rest = &rest[start + "<!-- wire: ".len()..];
        let end = rest.find("-->").expect("an unterminated wire marker");
        let label = rest[..end].trim().to_string();
        rest = &rest[end..];
        let open = rest
            .find("```json")
            .expect("a wire marker with no json block after it");
        rest = &rest[open + "```json".len()..];
        let close = rest.find("```").expect("an unterminated json block");
        out.push((label, rest[..close].trim().to_string()));
        rest = &rest[close + 3..];
    }
    out
}

/// Every key path in `shown` exists in `actual` (the same value as the type
/// writes it).
fn keys_exist(shown: &Value, actual: &Value, at: &str, missing: &mut Vec<String>) {
    match (shown, actual) {
        (Value::Object(s), Value::Object(a)) => {
            for (key, value) in s {
                match a.get(key) {
                    Some(av) => keys_exist(value, av, &format!("{at}/{key}"), missing),
                    None => missing.push(format!("{at}/{key}")),
                }
            }
        }
        (Value::Array(s), Value::Array(a)) => {
            for (i, (sv, av)) in s.iter().zip(a).enumerate() {
                keys_exist(sv, av, &format!("{at}/{i}"), missing);
            }
        }
        _ => {}
    }
}

fn round_trips<T: DeserializeOwned + Serialize>(label: &str, json: &Value) {
    let parsed: T = serde_json::from_value(json.clone())
        .unwrap_or_else(|e| panic!("{label}: the doc's JSON is not a {label}: {e}\n{json}"));
    let actual = serde_json::to_value(&parsed).unwrap();
    let mut missing = Vec::new();
    keys_exist(json, &actual, "", &mut missing);
    assert!(
        missing.is_empty(),
        "{label}: the doc shows keys the type does not have: {missing:?}"
    );
}

#[test]
fn every_wire_block_in_the_how_to_is_the_real_shape() {
    let blocks = blocks();
    assert!(
        blocks.len() >= 10,
        "found only {} wire blocks",
        blocks.len()
    );
    let service = DefaultImpressSurfaceService::new();
    for (label, text) in blocks {
        let json: Value = serde_json::from_str(&text)
            .unwrap_or_else(|e| panic!("{label}: not JSON ({e}):\n{text}"));
        let mut words = label.split_whitespace();
        match (words.next(), words.next()) {
            (Some("spec"), None) => {
                let (_, problems) = service.problems_of(&json);
                let errors: Vec<_> = problems.iter().filter(|p| p.is_error()).collect();
                assert!(errors.is_empty(), "the doc's spec has errors: {errors:?}");
            }
            (Some("event"), None) => round_trips::<Event>("Event", &json),
            (Some("render"), None) => round_trips::<RenderTree>("RenderTree", &json),
            (Some("args"), Some(tool)) => {
                let descriptor = McpToolDescriptor::iter()
                    .find(|d| d.name == tool)
                    .unwrap_or_else(|| panic!("the doc's args name {tool}, not a tool"));
                let schema = (descriptor.input_schema)();
                let validator = jsonschema::validator_for(&schema).unwrap();
                let errors: Vec<String> = validator
                    .iter_errors(&json)
                    .map(|e| e.to_string())
                    .collect();
                assert!(
                    errors.is_empty(),
                    "{tool}: the doc's args do not fit: {errors:?}"
                );
            }
            (Some("result"), Some(ty)) => match ty {
                "SurfaceValidateResult" => round_trips::<SurfaceValidateResult>(ty, &json),
                "SurfaceResult" => round_trips::<SurfaceResult>(ty, &json),
                "SurfaceShowResult" => round_trips::<SurfaceShowResult>(ty, &json),
                "SurfaceWaitResult" => round_trips::<SurfaceWaitResult>(ty, &json),
                "SurfaceDispatchResult" => round_trips::<SurfaceDispatchResult>(ty, &json),
                other => panic!("the doc marks a result of unknown type {other}"),
            },
            _ => panic!("an unknown wire marker: {label}"),
        }
    }
}
