//! Audit: one `core/verb-call@1.0.0` record per non-read-only call
//! (ADR-0036 D2; plan-verb-pipeline D-P3 as amended by
//! plan-self-reflective-layer D-R2, D-R3).
//!
//! The record is built here, after the envelope, from what the pipeline
//! knows: the verb, the caller, the trace and parent ids, the outcome, the
//! duration and a privacy-filtered argument summary (§ Call log's rule:
//! ids and sizes by default, short scalars by value, long strings as a
//! length and a hash, objects as their keys). It is then handed to the
//! installed [`Sink`], which owns the store write; this crate is on the
//! kit's pure tier and cannot open a store. `impress-store-service`
//! installs the sink — a bounded channel and one writer thread — through
//! [`crate::pipeline::Installer`], so any process that links the store
//! services records calls, and a process that does not counts them in
//! [`dropped`] rather than losing them silently.
//!
//! Read-only calls are not recorded (their timing is the span's) unless
//! `IMPRESS_CALL_LOG=all` is set for the session.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, RwLock};

use serde_json::{json, Map, Value};

use super::identity::CallerIdentity;
use crate::descriptor::VerbDescriptor;

/// The canonical spelling of the call record's kind.
pub const VERB_CALL_SCHEMA: &str = "core/verb-call@1.0.0";

/// Scalars longer than this are stored as a length and a hash.
pub const SCALAR_MAX: usize = 64;
/// Id lists longer than this are stored as a length and their first eight.
pub const ID_LIST_MAX: usize = 64;

/// One call, as the audit layer records it.
#[derive(Debug, Clone)]
pub struct VerbCallRecord {
    /// The row id: the call id, which is also every written operation's
    /// `batch_id`.
    pub call_id: String,
    pub verb: &'static str,
    pub since: &'static str,
    pub caller: CallerIdentity,
    pub trace_id: String,
    pub parent_call: Option<String>,
    /// The privacy-filtered argument summary.
    pub args: Value,
    pub ok: bool,
    pub code: Option<String>,
    pub message_len: usize,
    /// RFC 3339.
    pub started_at: String,
    pub duration_ms: u64,
    pub arg_bytes: usize,
    pub result_bytes: usize,
    /// The per-call store override, when the call ran on one
    /// ([`super::invoke_on`]); the sink writes the row there.
    pub store_override: Option<Arc<dyn std::any::Any + Send + Sync>>,
}

impl VerbCallRecord {
    /// The row's payload, as § Call log states it.
    pub fn payload(&self) -> Map<String, Value> {
        let mut payload = Map::new();
        payload.insert("verb".into(), json!(self.verb));
        payload.insert("since".into(), json!(self.since));
        payload.insert("caller".into(), self.caller.to_json());
        payload.insert("trace_id".into(), json!(self.trace_id));
        payload.insert("parent_call".into(), json!(self.parent_call));
        payload.insert("args".into(), self.args.clone());
        payload.insert("ok".into(), json!(self.ok));
        payload.insert("code".into(), json!(self.code));
        payload.insert("message_len".into(), json!(self.message_len));
        payload.insert("started_at".into(), json!(self.started_at));
        payload.insert("duration_ms".into(), json!(self.duration_ms));
        payload.insert("arg_bytes".into(), json!(self.arg_bytes));
        payload.insert("result_bytes".into(), json!(self.result_bytes));
        payload.insert("wire_version".into(), json!(crate::wire::WIRE_VERSION));
        payload
    }
}

/// Where records go. The sink must not block the caller: hand the record
/// to a bounded channel and return.
pub trait Sink: Send + Sync {
    fn record(&self, record: VerbCallRecord);
}

static SINK: RwLock<Option<Arc<dyn Sink>>> = RwLock::new(None);
static DROPPED: AtomicU64 = AtomicU64::new(0);
static LOG_ALL: OnceLock<bool> = OnceLock::new();

/// Install (or replace) the process's sink.
pub fn install(sink: Arc<dyn Sink>) {
    if let Ok(mut slot) = SINK.write() {
        *slot = Some(sink);
    }
}

/// Whether a sink is installed.
pub fn has_sink() -> bool {
    SINK.read().ok().is_some_and(|s| s.is_some())
}

/// Records that reached no sink (none installed). A sink counts its own
/// overflow.
pub fn dropped() -> u64 {
    DROPPED.load(Ordering::Relaxed)
}

/// Count a record a sink could not keep.
pub fn count_dropped() {
    DROPPED.fetch_add(1, Ordering::Relaxed);
}

/// Whether read-only calls are recorded too (`IMPRESS_CALL_LOG=all`).
pub fn log_all() -> bool {
    *LOG_ALL.get_or_init(|| std::env::var("IMPRESS_CALL_LOG").as_deref() == Ok("all"))
}

/// Hand a record to the sink.
pub fn record(record: VerbCallRecord) {
    let sink = SINK.read().ok().and_then(|s| s.clone());
    match sink {
        Some(sink) => sink.record(record),
        None => {
            DROPPED.fetch_add(1, Ordering::Relaxed);
            tracing::debug!(
                target: "verb",
                verb = record.verb,
                call_id = %record.call_id,
                "no audit sink installed; call record dropped"
            );
        }
    }
}

/// Whether a field name is an id by the rule's spelling.
fn is_id_field(name: &str) -> bool {
    name == "id"
        || name == "ids"
        || name.ends_with("_id")
        || name.ends_with("_ids")
        || name == "cite_key"
        || name == "cite_keys"
}

fn hashed(s: &str) -> Value {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(s.as_bytes());
    let hex: String = digest.iter().take(4).map(|b| format!("{b:02x}")).collect();
    json!({ "len": s.chars().count(), "sha256_8": hex })
}

fn scalar(value: &Value) -> Value {
    match value {
        Value::String(s) if s.chars().count() > SCALAR_MAX => hashed(s),
        other => other.clone(),
    }
}

fn is_scalar(value: &Value) -> bool {
    !matches!(value, Value::Object(_) | Value::Array(_))
}

/// One field's summary.
fn summarize_field(name: &str, value: &Value) -> Value {
    match value {
        Value::Array(items) if is_id_field(name) && items.iter().all(is_scalar) => {
            if items.len() <= ID_LIST_MAX {
                Value::Array(items.iter().map(scalar).collect())
            } else {
                json!({ "len": items.len(), "first": items.iter().take(8).map(scalar).collect::<Vec<_>>() })
            }
        }
        Value::Array(items) => {
            let keys: Vec<&String> = items
                .iter()
                .find_map(Value::as_object)
                .map(|o| o.keys().collect())
                .unwrap_or_default();
            if keys.is_empty() {
                json!({ "len": items.len() })
            } else {
                json!({ "len": items.len(), "keys": keys })
            }
        }
        Value::Object(fields) => {
            json!({ "len": fields.len(), "keys": fields.keys().collect::<Vec<_>>() })
        }
        other => scalar(other),
    }
}

/// The privacy-filtered summary of an argument object (§ Call log's table).
/// `x-private` (H-P1-2) is honoured when the schema marks a property so;
/// until P1's attribute lands, no property is.
pub fn summarize_args(args: &Value, input_schema: &Value) -> Value {
    let Some(fields) = args.as_object() else {
        return summarize_field("", args);
    };
    let properties = input_schema.get("properties").and_then(Value::as_object);
    let private = |name: &str| -> bool {
        properties
            .and_then(|p| p.get(name))
            .and_then(|s| s.get("x-private"))
            .and_then(Value::as_bool)
            .unwrap_or(false)
    };
    let mut out = Map::new();
    for (name, value) in fields {
        let summary = if private(name) {
            match value {
                Value::String(s) => hashed(s),
                Value::Null => Value::Null,
                other => hashed(&other.to_string()),
            }
        } else {
            summarize_field(name, value)
        };
        out.insert(name.clone(), summary);
    }
    Value::Object(out)
}

/// An estimate of a value's serialized size, without serializing it: the
/// span's `arg_bytes` and `result_bytes`. Strings count their bytes, numbers
/// and literals a fixed width, containers their punctuation.
pub fn approx_size(value: &Value) -> usize {
    match value {
        Value::Null => 4,
        Value::Bool(_) => 5,
        Value::Number(_) => 3,
        Value::String(s) => s.len() + 2,
        Value::Array(items) => 2 + items.iter().map(|v| approx_size(v) + 1).sum::<usize>(),
        Value::Object(fields) => {
            2 + fields
                .iter()
                .map(|(k, v)| k.len() + 4 + approx_size(v))
                .sum::<usize>()
        }
    }
}

/// The verb descriptor's input schema, for [`summarize_args`].
pub fn schema_of(verb: &VerbDescriptor) -> Value {
    (verb.input_schema)()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_and_short_scalars_keep_their_values() {
        let args = json!({
            "id": "abc",
            "publication_ids": ["a", "b"],
            "cite_key": "smith2020",
            "limit": 10,
            "starred": true,
            "name": "short",
        });
        let summary = summarize_args(&args, &json!({}));
        assert_eq!(summary, args);
    }

    #[test]
    fn long_strings_bodies_and_objects_are_sizes_and_keys() {
        let long = "x".repeat(100);
        let args = json!({
            "text": long,
            "spec": {"surface": "s", "root": {}},
            "items": [{"a": 1}, {"a": 2}],
            "ids": (0..70).map(|i| i.to_string()).collect::<Vec<_>>(),
        });
        let summary = summarize_args(&args, &json!({}));
        assert_eq!(summary["text"]["len"], 100);
        assert_eq!(summary["text"]["sha256_8"].as_str().unwrap().len(), 8);
        assert_eq!(
            summary["spec"],
            json!({"len": 2, "keys": ["root", "surface"]})
        );
        assert_eq!(summary["items"], json!({"len": 2, "keys": ["a"]}));
        assert_eq!(summary["ids"]["len"], 70);
        assert_eq!(summary["ids"]["first"].as_array().unwrap().len(), 8);
        assert!(!summary.to_string().contains(&"x".repeat(65)));
    }

    #[test]
    fn a_private_field_never_appears_by_value() {
        let schema = json!({"properties": {"token": {"type": "string", "x-private": true}}});
        let summary = summarize_args(&json!({"token": "secret"}), &schema);
        assert!(!summary.to_string().contains("secret"));
        assert_eq!(summary["token"]["len"], 6);
    }

    #[test]
    fn approx_size_tracks_serialized_size() {
        let v = json!({"a": "hello", "b": [1, 2, 3], "c": null, "d": {"e": "x".repeat(200)}});
        let exact = v.to_string().len();
        let approx = approx_size(&v);
        assert!(approx.abs_diff(exact) * 10 < exact, "{approx} vs {exact}");
    }

    #[test]
    fn without_a_sink_records_are_counted_not_lost_silently() {
        let before = dropped();
        record(VerbCallRecord {
            call_id: "c".into(),
            verb: "t-service_x",
            since: "0.1.0",
            caller: CallerIdentity::Person,
            trace_id: "t".into(),
            parent_call: None,
            args: Value::Null,
            ok: true,
            code: None,
            message_len: 0,
            started_at: String::new(),
            duration_ms: 0,
            arg_bytes: 0,
            result_bytes: 0,
            store_override: None,
        });
        assert!(dropped() > before || has_sink());
    }
}
