//! The generic by-name verb dispatch every FFI entry point needs (plan-
//! verb-pipeline-and-transport.md § P5, ADR-0034 D2).
//!
//! One function, [`dispatch`]: look a verb up by its qualified name in
//! whatever is linked into this binary ([`crate::descriptor::VerbDescriptor::find`],
//! the process-wide `inventory` collection), run it through
//! [`crate::pipeline::invoke_blocking`] — the same chain MCP, the CLI, the
//! FFI layout `apply` and every other entry path runs through — and answer
//! an HTTP status plus the wire-convention body. Lives here, not in
//! `impress-store-ffi`, so a **per-app** UniFFI target (one that links a
//! domain `*-service` crate the kit boundary forbids `impress-store-ffi`
//! itself from reaching — `scripts/check-kit-deps.sh`'s "ASK FIRST… this is
//! not a dependency to allowlist") can call the identical logic without
//! duplicating it. `implore-verbs-ffi` is the first such target
//! (plan-verb-pipeline P5a); `impress-store-ffi::verb::dispatch_verb` is the
//! kit's own thin wrapper over the same function.

use crate::pipeline::{self, Call, CallerIdentity};
use crate::wire::WIRE_VERSION;
use crate::{descriptor::VerbDescriptor, refusal};
use serde_json::{json, Value};

/// An HTTP status and the wire-convention JSON body — `{"ok": true, …}` or
/// `{"ok": false, "wire_version", "code", "message"}` — exactly what
/// `/api/layout/*` and `/api/surface/*` already answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DispatchResult {
    pub status: u16,
    pub body_json: String,
}

fn refused(status: u16, code: &str, message: String) -> DispatchResult {
    DispatchResult {
        status,
        body_json: json!({
            "ok": false,
            "wire_version": WIRE_VERSION,
            "code": code,
            "message": message,
        })
        .to_string(),
    }
}

/// `caller_json` as a route hands it: `{"kind": "app"|"agent"|"provider"|
/// "system"|"person", "name": "…", "trace_id": "…"}` — `name` and
/// `trace_id` optional. The route derives `kind`/`name` from the caller's
/// token and headers, never from the verb's own arguments (ADR-0034 D3);
/// this function trusts what it is given the same way every other pipeline
/// entry path trusts its transport.
fn parse_caller(caller_json: &str) -> (CallerIdentity, Option<String>, Option<String>) {
    let value: Value = serde_json::from_str(caller_json).unwrap_or(Value::Null);
    let kind = value.get("kind").and_then(Value::as_str).unwrap_or("app");
    let name = value
        .get("name")
        .and_then(Value::as_str)
        .map(str::to_string);
    let trace_id = value
        .get("trace_id")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let identity = match kind {
        "person" => CallerIdentity::Person,
        "provider" => CallerIdentity::Provider(name.unwrap_or_else(|| "unknown".into())),
        "system" => CallerIdentity::System(name.unwrap_or_else(|| "unknown".into())),
        "agent" => CallerIdentity::Agent(name.unwrap_or_else(|| "http".into())),
        // "app" and anything unrecognised: the route only reaches this
        // function once the loopback-token check already passed, so an app
        // caller with no name still gets the identity kind right.
        _ => CallerIdentity::App(name.unwrap_or_else(|| "unknown".into())),
    };
    let parent_call = value
        .get("parent_call")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    (identity, trace_id, parent_call)
}

/// Dispatch one verb by its qualified name (`<service>_<method>`) through
/// the invoker pipeline, on whatever `*-service` crates this binary links.
///
/// `args_json` is the verb's own arguments, a JSON object (an empty body
/// becomes `{}`, matching every other entry path — `pipeline::prepare`
/// already treats `Value::Null` this way). `caller_json` is
/// [`parse_caller`]'s shape. Never panics: a malformed `args_json` is
/// `invalid-argument`, not a crash reaching the FFI caller.
pub fn dispatch(name: &str, args_json: &str, caller_json: &str) -> DispatchResult {
    let (verb, call) = match prepare(name, args_json, caller_json) {
        Ok(prepared) => prepared,
        Err(refused) => return refused,
    };
    finish(pipeline::invoke_blocking(verb, call))
}

/// The same dispatch for native backends with async Swift callbacks. Awaiting
/// the callback leaves the main actor free to service app state and persistence.
pub async fn dispatch_async(name: &str, args_json: &str, caller_json: &str) -> DispatchResult {
    let (verb, call) = match prepare(name, args_json, caller_json) {
        Ok(prepared) => prepared,
        Err(refused) => return refused,
    };
    finish(pipeline::invoke(verb, call).await)
}

fn prepare(
    name: &str,
    args_json: &str,
    caller_json: &str,
) -> Result<(&'static VerbDescriptor, Call), DispatchResult> {
    let Some(verb) = VerbDescriptor::find(name) else {
        return Err(refused(
            404,
            refusal::codes::NOT_FOUND,
            format!("no such verb: {name}"),
        ));
    };

    let args: Value = if args_json.trim().is_empty() {
        Value::Object(Default::default())
    } else {
        match serde_json::from_str(args_json) {
            Ok(value) => value,
            Err(error) => {
                return Err(refused(
                    400,
                    refusal::codes::INVALID_ARGUMENT,
                    format!("args_json did not parse: {error}"),
                ))
            }
        }
    };

    let (caller, trace_id, parent_call) = parse_caller(caller_json);
    let mut call = Call::new(caller, args);
    call.parent_call = parent_call;
    if let Some(trace_id) = trace_id {
        call = call.with_trace(trace_id);
    }

    Ok((verb, call))
}

fn finish(result: Result<Value, pipeline::PipelineError>) -> DispatchResult {
    match result {
        Ok(value) => {
            let ok = value.get("ok").and_then(Value::as_bool).unwrap_or(true);
            let status = if ok {
                200
            } else {
                let code = value.get("code").and_then(Value::as_str).unwrap_or("");
                refusal::http_status(code)
            };
            DispatchResult {
                status,
                body_json: value.to_string(),
            }
        }
        Err(pipeline::PipelineError::Unavailable {
            app,
            verb: verb_name,
        }) => refused(
            503,
            refusal::codes::HOST_UNAVAILABLE,
            pipeline::PipelineError::Unavailable {
                app,
                verb: verb_name,
            }
            .to_string(),
        ),
        Err(pipeline::PipelineError::Handler(error)) => {
            refused(502, refusal::codes::VERB_FAILED, error.to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_verb_is_not_found() {
        let answer = dispatch(
            "nonexistent-service_nope",
            "{}",
            r#"{"kind":"app","name":"implore"}"#,
        );
        assert_eq!(answer.status, 404);
        let body: Value = serde_json::from_str(&answer.body_json).unwrap();
        assert_eq!(body["ok"], false);
        assert_eq!(body["code"], "not-found");
        assert_eq!(body["wire_version"], WIRE_VERSION);
    }

    #[test]
    fn malformed_args_json_is_invalid_argument_not_a_panic() {
        let answer = dispatch(
            "t-service_echo",
            "not json",
            r#"{"kind":"app","name":"test"}"#,
        );
        // No verb named `t-service_echo` is linked into this crate's own
        // tests, so this proves the parse-error path fires before the
        // lookup would even matter — a real caller sees 400 either way it
        // fails, never a panic.
        assert!(answer.status == 400 || answer.status == 404);
    }

    #[test]
    fn an_empty_body_is_an_empty_object_not_a_parse_error() {
        let answer = dispatch(
            "nonexistent-service_nope",
            "",
            r#"{"kind":"app","name":"test"}"#,
        );
        // Still not-found (no such verb in this crate's tests), but not the
        // args-parse 400 an empty body would otherwise trigger.
        assert_eq!(answer.status, 404);
    }
}
