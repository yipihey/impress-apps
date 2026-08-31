//! Runtime support for the impress service codegen pipeline.
//!
//! This crate provides the building blocks used by the
//! [`impress-service-macros`](../impress_service_macros/index.html) procedural
//! macros to turn a single trait declaration into:
//!
//! * an `#[uniffi::export]` adapter (Swift binding),
//! * a `#[pyfunction]` wrapper (Python binding),
//! * an [`McpToolDescriptor`] registered via [`inventory`] (MCP server pickup),
//! * a [`CliSubcommand`] registered via [`inventory`] (CLI binary pickup).
//!
//! Phase 0 deliberately keeps the surface area small: enough to demonstrate the
//! generation pipeline end-to-end with the `echo_demo` example.

#![forbid(unsafe_code)]

use std::error::Error as StdError;
use std::fmt;
use std::future::Future;
use std::pin::Pin;

pub mod runtime;

#[cfg(feature = "cli")]
pub mod cli;

// Re-export crates that generated code depends on so callers do not have to
// pin matching versions in their own Cargo.toml files.
pub use async_trait;
pub use inventory;
pub use schemars;
pub use serde_json;
pub use tokio;

/// Boxed error returned by service handlers at the FFI boundary.
pub type BoxError = Box<dyn StdError + Send + Sync + 'static>;

/// Future returned by an [`McpToolDescriptor`] handler.
pub type ServiceFuture = Pin<Box<dyn Future<Output = Result<serde_json::Value, BoxError>> + Send>>;

/// Trait every service-level error should implement.
///
/// The codegen layer uses this to map a single error into:
/// * a Swift `LocalizedError` (`user_message` powers `errorDescription`),
/// * a Python exception (the `code` becomes the exception type),
/// * an MCP error object (`code` + `user_message`),
/// * a CLI exit code (via `exit_code`).
pub trait ServiceError: StdError + Send + Sync + 'static {
    /// Short machine-readable code, kebab-case (e.g. `"not-found"`).
    fn code(&self) -> &str;

    /// Human-readable, end-user-friendly message.
    fn user_message(&self) -> String;

    /// Exit code to use when the CLI surfaces this error. Defaults to `1`.
    fn exit_code(&self) -> i32 {
        1
    }
}

/// A simple [`ServiceError`] implementation suitable for prototyping and
/// generated default error types.
#[derive(Debug, Clone)]
pub struct BasicServiceError {
    code: String,
    message: String,
    exit_code: i32,
}

impl BasicServiceError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            exit_code: 1,
        }
    }

    pub fn with_exit_code(mut self, exit_code: i32) -> Self {
        self.exit_code = exit_code;
        self
    }
}

impl fmt::Display for BasicServiceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl StdError for BasicServiceError {}

impl ServiceError for BasicServiceError {
    fn code(&self) -> &str {
        &self.code
    }

    fn user_message(&self) -> String {
        self.message.clone()
    }

    fn exit_code(&self) -> i32 {
        self.exit_code
    }
}

/// Resolve a tool description at compile time.
///
/// The description a model sees can come from two places, and for most of the
/// inventory's life it came from neither:
///
/// 1. a `///` comment inside `impress_service_impl! { methods = [...] }`, or
/// 2. the `///` comment on the trait method, captured by `#[impress_service]`
///    into a `__IMPRESS_SERVICE_DOCS_*` table.
///
/// Only (1) used to be read, so any service that documented its trait — which
/// is where a Rust developer naturally writes it, and where every service but
/// the `*-text-service` ones did — silently shipped `"Invoke Service.method"`.
/// 119 of 133 tools were in that state. This resolves (1), then (2), then the
/// fallback, so the docs can live where they belong and still reach the model.
///
/// `const fn` because `inventory::submit!` builds a `static`.
pub const fn resolve_description(
    inline_doc: &'static str,
    trait_docs: &'static [(&'static str, &'static str)],
    method: &'static str,
    fallback: &'static str,
) -> &'static str {
    if !inline_doc.is_empty() {
        return inline_doc;
    }
    let mut i = 0;
    while i < trait_docs.len() {
        if const_str_eq(trait_docs[i].0, method) && !trait_docs[i].1.is_empty() {
            return trait_docs[i].1;
        }
        i += 1;
    }
    fallback
}

/// `&str` equality usable in a const context.
const fn const_str_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

/// Descriptor for a single MCP tool exposed by a service method.
///
/// Generated `inventory::submit!` blocks register one of these per method,
/// and the MCP server simply iterates [`McpToolDescriptor::iter`] to publish
/// `tools/list` and dispatch `tools/call`.
pub struct McpToolDescriptor {
    /// Tool name as seen by the MCP client (kebab-case method ident).
    pub name: &'static str,
    /// Description (the method's doc comment).
    pub description: &'static str,
    /// JSON Schema for the tool's input object (derived from the args struct).
    pub input_schema: fn() -> serde_json::Value,
    /// Async handler: takes a JSON args object, returns a JSON result.
    pub handler: fn(serde_json::Value) -> ServiceFuture,
}

impl McpToolDescriptor {
    /// Iterate all descriptors registered in this binary via `inventory`.
    pub fn iter() -> impl Iterator<Item = &'static McpToolDescriptor> {
        inventory::iter::<McpToolDescriptor>.into_iter()
    }
}

impl fmt::Debug for McpToolDescriptor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("McpToolDescriptor")
            .field("name", &self.name)
            .field("description", &self.description)
            .finish()
    }
}

inventory::collect!(McpToolDescriptor);

/// Reserved result field used by generated services that need MCP-native
/// content (notably images). Transports remove it from structured output and
/// publish its blocks as the tool result's `content` array.
pub const MCP_CONTENT_FIELD: &str = "_mcp_content";

/// Split MCP-native content from an otherwise ordinary generated service
/// result. Keeping this convention here lets every service remain generated
/// while stdio, HTTP, and suite-wide hosts share one mixed-content behavior.
pub fn split_mcp_content(
    mut value: serde_json::Value,
) -> (Vec<serde_json::Value>, serde_json::Value) {
    let blocks = value
        .as_object_mut()
        .and_then(|object| object.remove(MCP_CONTENT_FIELD))
        .and_then(|content| content.as_array().cloned())
        .unwrap_or_default();
    (blocks, value)
}

/// Reshape a generated service result so it is legal as MCP
/// `structuredContent`, which the spec requires to be a JSON **object**.
///
/// Generated methods return their natural Rust shape: `Vec<T>` serializes to
/// an array, `Option<T>` to `null` on a miss, a count to a bare number, a
/// rendered string to a bare string. MCP clients (Claude Code among them)
/// validate the spec shape and reject the whole call otherwise — which made
/// every list-, option- and scalar-returning generated tool unusable over
/// stdio. The envelope is applied by the MCP transports at the boundary, so
/// services stay generated and other transports (CLI, HTTP, Swift, impel)
/// keep the raw value:
///
/// - object → unchanged, so every already-conforming tool keeps its shape
/// - array  → `{"items": [...]}`
/// - null   → `{"item": null}`
/// - string / number / bool → `{"value": ...}`
pub fn envelope_structured_content(value: serde_json::Value) -> serde_json::Value {
    use serde_json::{json, Value};
    match value {
        Value::Object(_) => value,
        Value::Array(_) => json!({ "items": value }),
        Value::Null => json!({ "item": Value::Null }),
        other => json!({ "value": other }),
    }
}

/// Descriptor for a single CLI subcommand exposed by a service method.
///
/// Generated `inventory::submit!` blocks register one of these per method.
/// A CLI binary collects them at startup and builds the `clap::Command` tree
/// dynamically.
pub struct CliSubcommand {
    /// Subcommand name (kebab-case method ident).
    pub name: &'static str,
    /// Description (the method's doc comment).
    pub description: &'static str,
    /// JSON Schema for the args object (used to build clap args).
    pub input_schema: fn() -> serde_json::Value,
    /// Apply the parsed args (already deserialized into a JSON object) and
    /// return a JSON result. Same shape as `McpToolDescriptor::handler` so the
    /// two paths share generated code.
    pub apply: fn(serde_json::Value) -> ServiceFuture,
}

impl CliSubcommand {
    pub fn iter() -> impl Iterator<Item = &'static CliSubcommand> {
        inventory::iter::<CliSubcommand>.into_iter()
    }
}

impl fmt::Debug for CliSubcommand {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CliSubcommand")
            .field("name", &self.name)
            .field("description", &self.description)
            .finish()
    }
}

inventory::collect!(CliSubcommand);

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The transport-level guarantee behind "no generated tool can emit a
    /// non-object structuredContent": every JSON kind a generated handler can
    /// return leaves this function as an object. Transports (impress-mcp's
    /// flat and grouped paths, impress-mcp-host) all route through it.
    #[test]
    fn envelope_yields_an_object_for_every_json_kind() {
        let cases = [
            json!(null),
            json!(true),
            json!(42),
            json!("Café"),
            json!([1, 2, 3]),
            json!({"ok": true}),
        ];
        for value in cases {
            let enveloped = envelope_structured_content(value.clone());
            assert!(
                enveloped.is_object(),
                "envelope of {value} is not an object: {enveloped}"
            );
        }
    }

    #[test]
    fn envelope_shapes_match_their_contract() {
        assert_eq!(
            envelope_structured_content(json!(["a", "b"])),
            json!({"items": ["a", "b"]})
        );
        assert_eq!(
            envelope_structured_content(json!(null)),
            json!({"item": null})
        );
        assert_eq!(
            envelope_structured_content(json!("Café")),
            json!({"value": "Café"})
        );
        assert_eq!(envelope_structured_content(json!(7)), json!({"value": 7}));
        // Objects pass through byte-identical — already-conforming tools
        // (e.g. store-query-service_search-all's {"hits": [...]}) keep their
        // shape.
        let object = json!({"hits": [], "ok": true, "message": "0 hit(s)"});
        assert_eq!(envelope_structured_content(object.clone()), object);
    }

    #[test]
    fn split_then_envelope_composes_for_mixed_content() {
        let (blocks, raw) = split_mcp_content(json!({
            "status": "resolved",
            MCP_CONTENT_FIELD: [{"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"}]
        }));
        assert_eq!(blocks.len(), 1);
        let structured = envelope_structured_content(raw);
        assert!(structured.is_object());
        assert_eq!(structured["status"], "resolved");
        assert!(structured.get(MCP_CONTENT_FIELD).is_none());
    }
}
