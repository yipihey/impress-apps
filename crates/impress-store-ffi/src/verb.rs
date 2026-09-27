//! The P5 transport's server side: one FFI function that dispatches any
//! kit-linked verb by name (plan-verb-pipeline-and-transport.md § P5,
//! ADR-0034 D2).
//!
//! `ImpressAutomation`'s `POST /api/verb/<name>` hands `{name, args_json,
//! caller_json}` here; this is a thin wrapper over
//! `impress_service_core::dispatch::dispatch` — the generic lookup-and-
//! invoke every FFI dispatch target shares (see that module's doc for why
//! the logic lives there rather than here). Swift decides nothing about the
//! verb: it maps a path segment to a name, a body to `args_json`, a
//! `traceparent` header and the caller its own token check already
//! established to `caller_json`, and this module's status/body back onto
//! an `HTTPResponse`.
//!
//! **This crate's inventory is the kit's** (store, layout, surface,
//! surface-demo — `force_link_kit` above): a domain `*-service` crate
//! (`implore-service`, …) is exactly what `scripts/check-kit-deps.sh`
//! refuses to let a kit crate reach ("ASK FIRST… this is not a dependency
//! to allowlist"), confirmed live when this session tried it. Reaching
//! implore's own verbs — the plan's five previously-dead ones — needs a
//! **per-app** UniFFI target that links `implore-service` directly, outside
//! the kit; `crates/implore-verbs-ffi` is that target's Rust half (P5a); the
//! Swift package and Xcode wiring that would let a running implore actually
//! answer through it are P5b's to finish (session log has the detail).

use impress_service_core::dispatch;

/// What [`dispatch_verb`] answers: an HTTP status and the wire body —
/// `{"ok": true, "wire_version", …}` or `{"ok": false, "wire_version",
/// "code", "message"}` — exactly the convention `/api/layout/…` and
/// `/api/surface/…` already answer (`impress_service_core::wire`).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedVerbDispatchResult {
    pub status: u16,
    pub body_json: String,
}

impl From<dispatch::DispatchResult> for SharedVerbDispatchResult {
    fn from(result: dispatch::DispatchResult) -> Self {
        Self {
            status: result.status,
            body_json: result.body_json,
        }
    }
}

/// Dispatch one verb by its qualified name (`<service>_<method>`) through
/// the invoker pipeline, on whatever `*-service` crates this binary links
/// (the kit, for this crate — see the module doc for what that excludes).
#[cfg_attr(feature = "native", uniffi::export)]
pub fn dispatch_verb(
    name: String,
    args_json: String,
    caller_json: String,
) -> SharedVerbDispatchResult {
    dispatch::dispatch(&name, &args_json, &caller_json).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn an_unknown_verb_is_not_found() {
        let answer = dispatch_verb(
            "nonexistent-service_nope".into(),
            "{}".into(),
            r#"{"kind":"app","name":"implore"}"#.into(),
        );
        assert_eq!(answer.status, 404);
        let body: Value = serde_json::from_str(&answer.body_json).unwrap();
        assert_eq!(body["ok"], false);
        assert_eq!(body["code"], "not-found");
    }

    #[test]
    fn a_kit_verb_is_reachable_by_name() {
        // `impress-surface-service_surface-schema` is read-only,
        // side-effect-free, and always in the kit inventory — proof that a
        // real kit verb answers through this route.
        let answer = dispatch_verb(
            "impress-surface-service_surface-schema".into(),
            "{}".into(),
            r#"{"kind":"app","name":"implore"}"#.into(),
        );
        assert_eq!(answer.status, 200);
    }

    #[test]
    fn malformed_args_json_is_invalid_argument_not_a_panic() {
        let answer = dispatch_verb(
            "impress-surface-service_surface-schema".into(),
            "not json".into(),
            r#"{"kind":"app","name":"implore"}"#.into(),
        );
        assert_eq!(answer.status, 400);
        let body: Value = serde_json::from_str(&answer.body_json).unwrap();
        assert_eq!(body["code"], "invalid-argument");
    }

    #[test]
    fn an_empty_body_is_an_empty_object_not_a_parse_error() {
        let answer = dispatch_verb(
            "impress-surface-service_surface-schema".into(),
            "".into(),
            r#"{"kind":"app","name":"implore"}"#.into(),
        );
        assert_eq!(answer.status, 200);
    }
}
