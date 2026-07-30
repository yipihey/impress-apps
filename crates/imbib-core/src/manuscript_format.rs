//! FFI surface for the manuscript-format grammar table (Stage 7 item 4).
//!
//! The table itself lives in `impress_core::manuscript_format` — one row per
//! format, next to `SUPPORTED_MANUSCRIPT_FORMATS`, so the format *list* and the
//! format *grammar* cannot drift apart. This module only shapes it for UniFFI.
//!
//! Swift's `DocumentFormat` keeps its enum and its public property names (dozens
//! of call sites depend on both), but every property body now reads a row of
//! this table, fetched once and cached — the values are compile-time constants,
//! so one call at first access is the whole cost.
//!
//! Cite-key *parsing* is deliberately absent: `imprint_core::citations::extract`
//! and `::hit` already own finding `@key` / `\cite{key}` in existing text. The
//! `citation_insert` affixes here are the editor-side *insertion* strings only.

use impress_core::manuscript_format as grammar;

/// A prefix/suffix pair wrapped around a selection.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct FormatAffixes {
    pub prefix: String,
    pub suffix: String,
}

impl From<grammar::Affixes> for FormatAffixes {
    fn from(a: grammar::Affixes) -> Self {
        Self {
            prefix: a.prefix.to_string(),
            suffix: a.suffix.to_string(),
        }
    }
}

/// One manuscript source format's full editor grammar.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ManuscriptFormatDescriptor {
    /// `manuscript.format` payload value / Swift enum raw value.
    pub id: String,
    pub display_name: String,
    /// `compiledPDF` | `renderedMarkdown` | `none`.
    pub preview_kind: String,
    /// True when the format has any rendered counterpart to the source.
    pub has_preview: bool,
    /// True when the preview comes from a compile pass.
    pub requires_compile: bool,
    /// Canonical extension, also the one used for `main_file_name`.
    pub file_extension: String,
    /// `main.<file_extension>`.
    pub main_file_name: String,
    /// Every extension that detects as this format, canonical one first.
    pub extensions: Vec<String>,
    /// Line-comment prefix; `None` disables comment toggling.
    pub comment_prefix: Option<String>,
    /// Citation *insertion* affixes; `None` disables citation insert.
    pub citation_insert: Option<FormatAffixes>,
    pub bold_wrap: Option<FormatAffixes>,
    pub italic_wrap: Option<FormatAffixes>,
    pub default_debounce_ms: u32,
}

impl From<&grammar::ManuscriptFormatGrammar> for ManuscriptFormatDescriptor {
    fn from(g: &grammar::ManuscriptFormatGrammar) -> Self {
        Self {
            id: g.id.to_string(),
            display_name: g.display_name.to_string(),
            preview_kind: g.preview_kind.to_string(),
            has_preview: g.has_preview(),
            requires_compile: g.requires_compile(),
            file_extension: g.file_extension.to_string(),
            main_file_name: g.main_file_name(),
            extensions: g.extensions.iter().map(|e| e.to_string()).collect(),
            comment_prefix: g.comment_prefix.map(str::to_string),
            citation_insert: g.citation_insert.map(FormatAffixes::from),
            bold_wrap: g.bold_wrap.map(FormatAffixes::from),
            italic_wrap: g.italic_wrap.map(FormatAffixes::from),
            default_debounce_ms: g.default_debounce_ms,
        }
    }
}

pub(crate) fn manuscript_format_grammar_internal() -> Vec<ManuscriptFormatDescriptor> {
    grammar::MANUSCRIPT_FORMAT_GRAMMAR
        .iter()
        .map(ManuscriptFormatDescriptor::from)
        .collect()
}

/// The whole grammar table, in `DocumentFormat.allCases` order.
///
/// Called once per process and cached Swift-side — every value is a constant.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn manuscript_format_grammar() -> Vec<ManuscriptFormatDescriptor> {
    manuscript_format_grammar_internal()
}

pub(crate) fn detect_manuscript_format_internal(source: &str, title: Option<&str>) -> String {
    grammar::detect_manuscript_format(source, title).to_string()
}

/// Detect a format id from source content, optionally hinted by a title whose
/// extension is trusted above the content heuristics.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn detect_manuscript_format(source: String, title: Option<String>) -> String {
    detect_manuscript_format_internal(&source, title.as_deref())
}

/// Format id for a bare file extension (no dot), or `None` if unrecognised.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn manuscript_format_for_extension(ext: String) -> Option<String> {
    grammar::manuscript_format_for_extension(&ext).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptors_carry_every_row() {
        let table = manuscript_format_grammar_internal();
        assert_eq!(table.len(), 4);
        let ids: Vec<&str> = table.iter().map(|d| d.id.as_str()).collect();
        assert_eq!(ids, ["typst", "latex", "markdown", "plaintext"]);
    }

    #[test]
    fn derived_fields_are_filled_in() {
        let table = manuscript_format_grammar_internal();
        let latex = table.iter().find(|d| d.id == "latex").unwrap();
        assert_eq!(latex.main_file_name, "main.tex");
        assert!(latex.has_preview && latex.requires_compile);
        assert_eq!(latex.comment_prefix.as_deref(), Some("%"));
        assert_eq!(
            latex.citation_insert,
            Some(FormatAffixes {
                prefix: "\\cite{".into(),
                suffix: "}".into()
            })
        );
        assert_eq!(latex.default_debounce_ms, 1500);

        let plain = table.iter().find(|d| d.id == "plaintext").unwrap();
        assert!(!plain.has_preview && !plain.requires_compile);
        assert!(plain.comment_prefix.is_none());
        assert!(plain.citation_insert.is_none());
        assert!(plain.bold_wrap.is_none());
        assert!(plain.italic_wrap.is_none());
        assert_eq!(plain.default_debounce_ms, 0);
    }

    #[test]
    fn detection_delegates_to_the_table() {
        assert_eq!(
            detect_manuscript_format_internal("", Some("a.md")),
            "markdown"
        );
        assert_eq!(
            detect_manuscript_format_internal("\\begin{document}", None),
            "latex"
        );
        assert_eq!(detect_manuscript_format_internal("", None), "typst");
    }
}
