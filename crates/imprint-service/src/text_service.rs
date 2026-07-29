//! `ImprintTextService` — stateless text utilities exposed via the impress
//! service codegen pipeline.
//!
//! This module mirrors the imbib-side `ImbibTextService` pattern: a single
//! `#[impress_service]` trait declaration generates one
//! `McpToolDescriptor` + one `CliSubcommand` inventory entry per method,
//! ready for `imprint-cli` and the rewired MCP server to pick up at link
//! time.
//!
//! The methods here intentionally adapt the underlying `imprint_core`
//! signatures so they fit the macro's "simple types only" contract:
//! `String`, `Option<String>`, `Vec<String>`, plus return types that are
//! Serialize (the macro serializes them via `serde_json::to_value`).
//! Anything that takes a complex `FormatOptions` / `CitationSyntax` enum
//! is wrapped here to take a flat `String` and translated internally.
//!
//! Stateful imprint operations (section CRUD, search, compile) live in the
//! existing `ImprintHttpHandlers` trait in `handlers.rs`; promoting those
//! into the macro pipeline waits on a follow-up wave that teaches the macro
//! about complex DTOs.

use impress_service_core::async_trait;
// `impress_method` is referenced as a path-only attribute on trait methods.
// `#[impress_service]` strips the attribute, so the symbol is structurally
// unused at the trait declaration site — keep it imported because Rust still
// needs to resolve the path when the macro expands.
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use imprint_core::citations::extract::{
    extract_cite_keys as core_extract_cite_keys, CitationSyntax, CiteKeyUsage,
};

// Re-export so downstream crates (imprint-service-http) can name the type
// without taking a direct imprint-core dep.
pub use imprint_core::citations::extract::CiteKeyUsage as CiteKeyUsageType;
use imprint_core::latex::formatter::{format_latex as core_format_latex, FormatOptions};

// ── Service trait ────────────────────────────────────────────────────────────

/// Stateless imprint text utilities — LaTeX beautification, citation
/// extraction — exposed via the uniform service-codegen pipeline.
#[impress_service]
pub trait ImprintTextService: Send + Sync + 'static {
    /// Beautify a LaTeX source string using the conservative native
    /// formatter (indent body of `\begin{env}` … `\end{env}` blocks, trim
    /// trailing whitespace, collapse runs of blank lines). Idempotent.
    #[impress_method]
    async fn format_latex(&self, source: String) -> String;

    /// Extract the unique sorted set of cite keys from a manuscript source.
    ///
    /// `syntax` accepts `typst`, `latex`, or `mixed` (case-insensitive).
    /// Unknown values fall back to `mixed`, which runs both extractors.
    #[impress_method]
    async fn extract_cite_keys(&self, source: String, syntax: String) -> Vec<String>;

    /// Extract every cite-key usage from a manuscript source, in source
    /// order, with byte offsets and surrounding context preserved.
    ///
    /// `syntax` accepts `typst`, `latex`, or `mixed` (case-insensitive).
    #[impress_method]
    async fn extract_cite_key_usages(&self, source: String, syntax: String) -> Vec<CiteKeyUsage>;

    /// Compose an inline citation token. `format` = `typst` | `latex`.
    /// Typst → `@key`, LaTeX → `\cite{key}`; `append_space` prepends one space.
    #[impress_method]
    async fn compose_citation(
        &self,
        cite_key: String,
        format: String,
        append_space: bool,
    ) -> String;

    /// Compose a heading line at `level` (1-based). `format` = `typst` | `latex`.
    #[impress_method]
    async fn compose_heading(&self, title: String, level: i64, format: String) -> String;
}

// ── Default impl ─────────────────────────────────────────────────────────────

/// Default implementation that delegates to the underlying `imprint_core`
/// functions. Stateless and `Default`-constructible.
#[derive(Default, Clone, Copy)]
pub struct DefaultImprintTextService;

#[async_trait::async_trait]
impl ImprintTextService for DefaultImprintTextService {
    async fn format_latex(&self, source: String) -> String {
        core_format_latex(&source, &FormatOptions::default())
    }

    async fn extract_cite_keys(&self, source: String, syntax: String) -> Vec<String> {
        let syntax = parse_syntax(&syntax);
        imprint_core::citations::extract::extract_cite_key_set(&source, syntax)
    }

    async fn extract_cite_key_usages(&self, source: String, syntax: String) -> Vec<CiteKeyUsage> {
        let syntax = parse_syntax(&syntax);
        core_extract_cite_keys(&source, syntax)
    }

    async fn compose_citation(
        &self,
        cite_key: String,
        format: String,
        append_space: bool,
    ) -> String {
        imprint_core::citations::compose::compose_citation(
            &cite_key,
            imprint_core::citations::compose::ComposeFormat::from_str_lenient(&format),
            append_space,
        )
    }

    async fn compose_heading(&self, title: String, level: i64, format: String) -> String {
        imprint_core::citations::compose::compose_heading(
            &title,
            level.max(0) as u32,
            imprint_core::citations::compose::ComposeFormat::from_str_lenient(&format),
        )
    }
}

/// Lenient parser for the `syntax` argument. Delegates to `imprint-core` so
/// this trait, the UniFFI cite-key exports and the HTTP router accept exactly
/// the same spellings; unknown values map to [`CitationSyntax::Mixed`].
fn parse_syntax(s: &str) -> CitationSyntax {
    CitationSyntax::from_str_lenient(s)
}

// ── Inventory wiring ─────────────────────────────────────────────────────────
//
// Generates, per method:
//   `__Impress_ImprintTextService_<method>_Args` struct (Deserialize + JsonSchema)
//   `__impress_ImprintTextService_<method>_invoke` async function
//   MCP descriptor + CLI subcommand inventory entries.
impress_service_impl! {
    service = ImprintTextService,
    impl = DefaultImprintTextService,
    instance = || crate::backend::text_service_instance(),
    methods = [
        /// Beautify a LaTeX source string.
        format_latex(source: String) -> String,
        /// Extract the unique sorted set of cite keys from a manuscript source.
        extract_cite_keys(source: String, syntax: String) -> Vec<String>,
        /// Extract every cite-key usage with offsets + context.
        extract_cite_key_usages(source: String, syntax: String) -> Vec<CiteKeyUsage>,
        /// Compose an inline citation token (typst `@key` / latex `\cite{key}`).
        compose_citation(cite_key: String, format: String, append_space: bool) -> String,
        /// Compose a heading line at a 1-based level.
        compose_heading(title: String, level: i64, format: String) -> String,
    ],
}

#[cfg(test)]
mod tests {
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    #[test]
    fn all_three_methods_registered_in_mcp_inventory() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        for expected in [
            "imprint-text-service_format-latex",
            "imprint-text-service_extract-cite-keys",
            "imprint-text-service_extract-cite-key-usages",
        ] {
            assert!(
                names.contains(&expected),
                "MCP inventory missing {expected}; have: {names:?}"
            );
        }
    }

    #[test]
    fn all_three_methods_registered_in_cli_inventory() {
        let names: Vec<&str> = CliSubcommand::iter().map(|c| c.name).collect();
        for expected in [
            "format-latex",
            "extract-cite-keys",
            "extract-cite-key-usages",
        ] {
            assert!(
                names.contains(&expected),
                "CLI inventory missing {expected}; have: {names:?}"
            );
        }
    }

    #[test]
    fn format_latex_round_trips_through_inventory() {
        use impress_service_core::runtime;
        use impress_service_core::serde_json::json;

        let tool = McpToolDescriptor::iter()
            .find(|d| d.name == "imprint-text-service_format-latex")
            .expect("format-latex tool");

        let result = runtime::block_on((tool.handler)(json!({
            "source": "\\begin{document}\nhi\n\\end{document}\n"
        })))
        .expect("handler succeeded");

        let s = result.as_str().expect("string return");
        assert!(s.contains("  hi"));
    }
}
