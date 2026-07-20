//! Shared clap-from-inventory dispatch for `*-cli` binaries.
//!
//! Both `imbib-cli` and `imprint-cli` (and any future per-app CLI) iterate
//! [`crate::CliSubcommand`] and build a `clap::Command` tree at startup. The
//! schemas captured by the `#[impress_service]` macro carry enough type
//! information to derive `--flag` args automatically; this module centralizes
//! the conversion so the binaries stay tiny.
//!
//! ## Supported argument shapes
//!
//! The args struct emitted by the macro derives `JsonSchema`, producing a
//! JSON Schema object of the form:
//!
//! ```json
//! {
//!   "type": "object",
//!   "properties": {
//!     "input": { "type": "string" },
//!     "count": { "type": "integer" }
//!   },
//!   "required": ["input", "count"]
//! }
//! ```
//!
//! For Phase 3 we accept the primitive shapes used by the imbib/imprint
//! service traits: `string`, `integer`, `number`, `boolean`, `Option<String>`
//! (rendered as a nullable string), and `Vec<String>` (rendered as an array
//! of strings). Anything outside that set is currently exposed as a raw JSON
//! string flag (the user passes a JSON literal) — good enough for ship-ready
//! CLIs in this phase, and easy to extend later.
//!
//! ## Usage
//!
//! ```ignore
//! use impress_service_core::cli;
//!
//! fn main() {
//!     let app = cli::build_cli_from_inventory("imbib")
//!         .about("imbib service CLI — auto-generated from #[impress_service] traits");
//!     let matches = app.get_matches();
//!     match cli::dispatch_matches(&matches) {
//!         Ok(value) => {
//!             println!(
//!                 "{}",
//!                 serde_json::to_string_pretty(&value).unwrap_or_default()
//!             );
//!         }
//!         Err(e) => {
//!             eprintln!("error: {e}");
//!             std::process::exit(1);
//!         }
//!     }
//! }
//! ```

use std::collections::HashSet;

use clap::{Arg, ArgAction, ArgMatches, Command};
use serde_json::{Map, Value};

use crate::{runtime, BoxError, CliSubcommand};

/// Build a `clap::Command` for the binary named `app_name`, with one
/// subcommand per registered [`CliSubcommand`].
pub fn build_cli_from_inventory(app_name: &str) -> Command {
    let mut app = Command::new(app_name.to_string())
        .subcommand_required(true)
        .arg_required_else_help(true);

    for sub in CliSubcommand::iter() {
        app = app.subcommand(build_subcommand(sub));
    }

    app
}

/// Build one `clap::Command` from a single [`CliSubcommand`] descriptor.
fn build_subcommand(sub: &'static CliSubcommand) -> Command {
    let schema = (sub.input_schema)();

    let mut cmd = Command::new(sub.name.to_string()).about(sub.description.to_string());

    let required: HashSet<String> = schema
        .get("required")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|x| x.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    if let Some(props) = schema.get("properties").and_then(|p| p.as_object()) {
        for (name, prop) in props {
            cmd = cmd.arg(build_arg(name, prop, required.contains(name)));
        }
    }

    cmd
}

/// Build a `clap::Arg` from a single JSON-Schema property.
fn build_arg(name: &str, prop: &Value, required: bool) -> Arg {
    let kind = property_kind(prop);
    let long: String = name.replace('_', "-");

    let mut arg = Arg::new(name.to_string()).long(long).required(required);

    match kind {
        PropertyKind::Boolean => {
            arg = arg.action(ArgAction::SetTrue).required(false);
        }
        PropertyKind::Array => {
            arg = arg.action(ArgAction::Append);
        }
        _ => {
            arg = arg.action(ArgAction::Set);
        }
    }

    arg
}

#[derive(Debug, Clone, Copy)]
enum PropertyKind {
    String,
    Integer,
    Number,
    Boolean,
    Array,
    /// Anything else (object, complex enum, untyped). The CLI accepts a raw
    /// JSON-literal string and we'll attempt to parse it during dispatch.
    Json,
}

fn property_kind(prop: &Value) -> PropertyKind {
    // Direct `"type": "string"` etc.
    if let Some(t) = prop.get("type") {
        if let Some(s) = t.as_str() {
            return match s {
                "string" => PropertyKind::String,
                "integer" => PropertyKind::Integer,
                "number" => PropertyKind::Number,
                "boolean" => PropertyKind::Boolean,
                "array" => PropertyKind::Array,
                _ => PropertyKind::Json,
            };
        }
        // `"type": ["string", "null"]` — Option<String>.
        if let Some(arr) = t.as_array() {
            for entry in arr {
                if entry.as_str() == Some("string") {
                    return PropertyKind::String;
                }
                if entry.as_str() == Some("integer") {
                    return PropertyKind::Integer;
                }
                if entry.as_str() == Some("number") {
                    return PropertyKind::Number;
                }
                if entry.as_str() == Some("boolean") {
                    return PropertyKind::Boolean;
                }
                if entry.as_str() == Some("array") {
                    return PropertyKind::Array;
                }
            }
        }
    }
    // schemars sometimes emits `"anyOf": [{"type": "string"}, {"type": "null"}]`
    if let Some(arr) = prop.get("anyOf").and_then(|v| v.as_array()) {
        for entry in arr {
            match property_kind(entry) {
                PropertyKind::Json => continue,
                other => return other,
            }
        }
    }
    PropertyKind::Json
}

/// Find the matched subcommand, build a JSON args object from the parsed
/// args, and run the handler on the shared runtime.
pub fn dispatch_matches(matches: &ArgMatches) -> Result<Value, BoxError> {
    let (sub_name, sub_matches) = matches
        .subcommand()
        .ok_or_else(|| -> BoxError { "no subcommand provided".into() })?;

    let descriptor = CliSubcommand::iter()
        .find(|c| c.name == sub_name)
        .ok_or_else(|| -> BoxError { format!("unknown subcommand `{sub_name}`").into() })?;

    let schema = (descriptor.input_schema)();
    let json_args = matches_to_json(sub_matches, &schema)?;

    runtime::block_on((descriptor.apply)(json_args))
}

fn matches_to_json(matches: &ArgMatches, schema: &Value) -> Result<Value, BoxError> {
    let mut map = Map::new();

    let props = schema
        .get("properties")
        .and_then(|p| p.as_object())
        .cloned()
        .unwrap_or_default();
    let required: HashSet<String> = schema
        .get("required")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|x| x.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    for (name, prop) in &props {
        let kind = property_kind(prop);
        match kind {
            PropertyKind::Boolean => {
                let v = matches.get_flag(name);
                map.insert(name.clone(), Value::Bool(v));
            }
            PropertyKind::Array => {
                let mut arr: Vec<Value> = Vec::new();
                if let Some(values) = matches.get_many::<String>(name) {
                    for v in values {
                        arr.push(Value::String(v.clone()));
                    }
                }
                if arr.is_empty() && !required.contains(name) {
                    // Optional + absent: leave null so serde Option<Vec<>>
                    // (if ever used) deserializes correctly.
                } else {
                    map.insert(name.clone(), Value::Array(arr));
                }
            }
            PropertyKind::String => {
                if let Some(v) = matches.get_one::<String>(name) {
                    map.insert(name.clone(), Value::String(v.clone()));
                } else if !required.contains(name) {
                    map.insert(name.clone(), Value::Null);
                }
            }
            PropertyKind::Integer => {
                if let Some(v) = matches.get_one::<String>(name) {
                    let parsed: i64 = v.parse().map_err(|e| -> BoxError {
                        format!("--{name}: expected integer ({e})").into()
                    })?;
                    map.insert(name.clone(), Value::from(parsed));
                } else if !required.contains(name) {
                    map.insert(name.clone(), Value::Null);
                }
            }
            PropertyKind::Number => {
                if let Some(v) = matches.get_one::<String>(name) {
                    let parsed: f64 = v.parse().map_err(|e| -> BoxError {
                        format!("--{name}: expected number ({e})").into()
                    })?;
                    map.insert(
                        name.clone(),
                        serde_json::Number::from_f64(parsed)
                            .map(Value::Number)
                            .unwrap_or(Value::Null),
                    );
                } else if !required.contains(name) {
                    map.insert(name.clone(), Value::Null);
                }
            }
            PropertyKind::Json => {
                if let Some(v) = matches.get_one::<String>(name) {
                    let parsed: Value = serde_json::from_str(v).map_err(|e| -> BoxError {
                        format!("--{name}: expected JSON literal ({e})").into()
                    })?;
                    map.insert(name.clone(), parsed);
                } else if !required.contains(name) {
                    map.insert(name.clone(), Value::Null);
                }
            }
        }
    }

    Ok(Value::Object(map))
}
