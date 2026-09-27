//! `{{…}}` resolution for a scenario, reusing `impress_surface::template`
//! (docs/plan-self-reflective-layer.md § Scenarios: "Templates are the
//! surface's `{{…}}` resolver, reused, extended with `{{uuid}}` and
//! captures").
//!
//! Captures are supplied through the surface template's `state` root — a
//! scenario has no `param`/`source`/`event`/`item` context, so those roots
//! stay empty and any reference into them is simply `MissingPath`.
//! `{{uuid}}` is not a path into any root (it names a fresh value each
//! time it appears), so it is substituted in a text pre-pass before the
//! surface resolver ever sees the string.

use impress_surface::template::{resolve_value, Context};
use serde_json::Value;

/// Resolve every `{{…}}` in `value` against `captures` (exposed as the
/// `state` root), substituting a fresh `{{uuid}}` per occurrence first.
pub fn resolve(value: &Value, captures: &Value) -> Result<Value, String> {
    let with_uuids = substitute_uuids(value);
    let empty = Value::Null;
    let ctx = Context::new(captures, &empty, &empty, &empty);
    resolve_value(&with_uuids, &ctx).map_err(|e| e.to_string())
}

/// Walk `value`, replacing every literal occurrence of `{{uuid}}` inside a
/// string with a freshly minted v4 UUID. Two occurrences in the same string
/// get two different values — a scenario that wants the same generated
/// value twice captures it once and references `{{captures.<name>}}`
/// instead.
fn substitute_uuids(value: &Value) -> Value {
    match value {
        Value::String(s) => Value::String(replace_uuid_tokens(s)),
        Value::Array(items) => Value::Array(items.iter().map(substitute_uuids).collect()),
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), substitute_uuids(v)))
                .collect(),
        ),
        other => other.clone(),
    }
}

fn replace_uuid_tokens(s: &str) -> String {
    const TOKEN: &str = "{{uuid}}";
    if !s.contains(TOKEN) {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(idx) = rest.find(TOKEN) {
        out.push_str(&rest[..idx]);
        out.push_str(&uuid::Uuid::new_v4().to_string());
        rest = &rest[idx + TOKEN.len()..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn uuid_tokens_are_distinct_and_valid() {
        let resolved = resolve(&json!({"a": "{{uuid}}", "b": "{{uuid}}"}), &Value::Null).unwrap();
        let a = resolved["a"].as_str().unwrap();
        let b = resolved["b"].as_str().unwrap();
        assert_ne!(a, b);
        assert!(uuid::Uuid::parse_str(a).is_ok());
        assert!(uuid::Uuid::parse_str(b).is_ok());
    }

    #[test]
    fn captures_resolve_through_the_state_root() {
        let captures = json!({"name": "layout-42"});
        let resolved = resolve(&json!({"name": "{{state.name}}"}), &captures).unwrap();
        assert_eq!(resolved["name"], json!("layout-42"));
    }

    #[test]
    fn mixed_text_stringifies_the_capture() {
        let captures = json!({"n": 3});
        let resolved = resolve(&json!("count is {{state.n}}"), &captures).unwrap();
        assert_eq!(resolved, json!("count is 3"));
    }

    #[test]
    fn a_missing_capture_is_an_error() {
        assert!(resolve(&json!("{{state.missing}}"), &Value::Null).is_err());
    }
}
