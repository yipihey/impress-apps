//! Running a linked verb by its MCP tool name.
//!
//! The one copy of "find the descriptor, run its handler". It lives here
//! rather than in `impress-capabilities-kit` because `impress-surface-service`
//! runs verbs too (a surface's sources and `call` effects), and the kit
//! depends on that crate, so the crate cannot depend back on the kit (review
//! RS-S21). Every crate that links an inventory already depends on this one.
//!
//! `impress-capabilities-kit` re-exports all of it, and `impress-capabilities`
//! re-exports the kit's, so every existing caller compiles unchanged.

use serde_json::Value;

use crate::{runtime, McpToolDescriptor};

/// Error from [`call`] / [`call_async`].
///
/// Mirrors the two failure modes `impress-mcp::inventory_bridge` returned as
/// plain strings before the `impress-capabilities` move (ADR-0033 D4 plan
/// S2), preserved again here (`"Unknown tool: {name}"` and
/// `"{descriptor}: {handler error}"`); `Display` on this type reproduces
/// those exact strings so callers that used to `.to_string()` the old
/// `Result<Value, String>` see byte-identical error text.
#[derive(Debug, thiserror::Error)]
pub enum CallError {
    /// No descriptor with this name is registered — either a typo, or the
    /// crate that would have linked it is not linked into this binary.
    #[error("Unknown tool: {0}")]
    UnknownTool(String),
    /// The descriptor's handler future resolved to `Err`. The message is
    /// already formatted as `"{descriptor.name}: {handler error}"`.
    #[error("{0}")]
    Handler(String),
}

/// Every MCP tool descriptor linked into this binary — the one process-wide
/// `inventory` collection, not a subset of it.
pub fn descriptors() -> impl Iterator<Item = &'static McpToolDescriptor> {
    McpToolDescriptor::iter()
}

/// Look up one descriptor by its exact MCP tool name
/// (`"surface-demo-service_series"`, kebab-case method ident).
pub fn find(name: &str) -> Option<&'static McpToolDescriptor> {
    McpToolDescriptor::iter().find(|d| d.name == name)
}

/// Invoke an inventory tool synchronously, running its handler future to
/// completion on the shared `impress-service` runtime
/// ([`runtime::block_on`]).
///
/// Use this from a synchronous context (CLI dispatch, an FFI shim); use
/// [`call_async`] from a context already running on a Tokio runtime, where
/// `block_on` would panic.
pub fn call(name: &str, args: Value) -> Result<Value, CallError> {
    let descriptor = find(name).ok_or_else(|| CallError::UnknownTool(name.to_string()))?;
    let future = (descriptor.handler)(args);
    runtime::block_on(future).map_err(|e| CallError::Handler(format!("{}: {}", descriptor.name, e)))
}

/// The `async` counterpart to [`call`], for callers already on the runtime.
pub async fn call_async(name: &str, args: Value) -> Result<Value, CallError> {
    let descriptor = find(name).ok_or_else(|| CallError::UnknownTool(name.to_string()))?;
    (descriptor.handler)(args)
        .await
        .map_err(|e| CallError::Handler(format!("{}: {}", descriptor.name, e)))
}
