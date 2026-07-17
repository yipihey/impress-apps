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
pub type ServiceFuture =
    Pin<Box<dyn Future<Output = Result<serde_json::Value, BoxError>> + Send>>;

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
