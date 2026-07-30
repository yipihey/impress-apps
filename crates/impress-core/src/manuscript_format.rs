//! The manuscript-format *grammar* table (Stage 7 item 4).
//!
//! [`manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS`] already owned the format
//! *list*. Everything a format actually means to the editor — how it previews,
//! what its file extensions are, its line-comment prefix, its citation-insert
//! and bold/italic wrapping affixes, its auto-compile debounce — lived in eight
//! parallel `switch` statements in Swift's `DocumentFormat`. Eight switches over
//! the same enum is eight chances to forget a case: adding a format compiled
//! only after all eight were touched, and *reading* the format's behaviour meant
//! reading eight places.
//!
//! Here it is one row per format. Adding a format is one row.
//!
//! ## Scope
//!
//! These are **editor-side** strings: what to type into the buffer when the user
//! hits ⌘B or picks a citation. Cite-key *parsing* (finding `@key` /
//! `\cite{key}` in existing text) is not here and must not be duplicated here —
//! that is `imprint_core::citations::{extract, hit}`.
//!
//! ## Detection
//!
//! [`detect_manuscript_format`] and [`manuscript_format_for_extension`] are the
//! ported Swift heuristics, extension lookup driven by the table's `extensions`
//! column. The Swift bodies were reproduced exactly, including the character-set
//! semantics of `trimmingCharacters(in: .whitespaces)` — see
//! [`is_swift_whitespace`].
//!
//! [`manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS`]: crate::manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS

/// How the non-source pane renders a format. String-valued because it crosses
/// the FFI into a Swift enum with the same three cases.
pub mod preview_kind {
    /// Compile the source (Typst in-process / LaTeX via tectonic) to PDF.
    pub const COMPILED_PDF: &str = "compiledPDF";
    /// Render the live source with MarkdownUI — no compile step.
    pub const RENDERED_MARKDOWN: &str = "renderedMarkdown";
    /// No rendered state (plain text) — the Preview affordance is hidden.
    pub const NONE: &str = "none";
}

/// A prefix/suffix pair wrapped around a selection (bold, italic, citation).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Affixes {
    pub prefix: &'static str,
    pub suffix: &'static str,
}

const fn affix(prefix: &'static str, suffix: &'static str) -> Option<Affixes> {
    Some(Affixes { prefix, suffix })
}

/// Everything the editor needs to know about one manuscript source format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ManuscriptFormatGrammar {
    /// The `manuscript.format` payload value, and the Swift enum's raw value.
    pub id: &'static str,
    /// Human-facing name ("Plain Text", not "plaintext").
    pub display_name: &'static str,
    /// One of [`preview_kind`].
    pub preview_kind: &'static str,
    /// Canonical extension used when writing `main.<ext>`.
    pub file_extension: &'static str,
    /// Every extension that detects as this format, canonical one first.
    /// Lowercase; matching lowercases its input.
    pub extensions: &'static [&'static str],
    /// Line-comment prefix; `None` disables comment toggling.
    pub comment_prefix: Option<&'static str>,
    /// Citation *insertion* affixes; `None` disables citation insert.
    pub citation_insert: Option<Affixes>,
    /// Bold wrapping; `None` disables the Bold command.
    pub bold_wrap: Option<Affixes>,
    /// Italic wrapping; `None` disables the Italic command.
    pub italic_wrap: Option<Affixes>,
    /// Default auto-compile/preview debounce in milliseconds.
    pub default_debounce_ms: u32,
}

impl ManuscriptFormatGrammar {
    /// Whether this format has ANY rendered counterpart to the source — the
    /// single source of truth for showing/hiding a preview affordance.
    pub fn has_preview(&self) -> bool {
        self.preview_kind != preview_kind::NONE
    }

    /// Whether the preview is produced by a compile pass (Typst/LaTeX → PDF).
    pub fn requires_compile(&self) -> bool {
        self.preview_kind == preview_kind::COMPILED_PDF
    }

    /// `main.<ext>` — the entry file a project of this format compiles from.
    pub fn main_file_name(&self) -> String {
        format!("main.{}", self.file_extension)
    }
}

/// One row per manuscript format. **This is the table.**
///
/// Order is the order Swift's `DocumentFormat.allCases` yields, so a caller can
/// present the table directly without re-sorting.
pub const MANUSCRIPT_FORMAT_GRAMMAR: [ManuscriptFormatGrammar; 4] = [
    ManuscriptFormatGrammar {
        id: "typst",
        display_name: "Typst",
        preview_kind: preview_kind::COMPILED_PDF,
        file_extension: "typ",
        extensions: &["typ"],
        comment_prefix: Some("//"),
        citation_insert: affix("@", ""),
        bold_wrap: affix("*", "*"),
        italic_wrap: affix("_", "_"),
        default_debounce_ms: 300,
    },
    ManuscriptFormatGrammar {
        id: "latex",
        display_name: "LaTeX",
        preview_kind: preview_kind::COMPILED_PDF,
        file_extension: "tex",
        extensions: &["tex", "latex"],
        comment_prefix: Some("%"),
        citation_insert: affix("\\cite{", "}"),
        bold_wrap: affix("\\textbf{", "}"),
        italic_wrap: affix("\\textit{", "}"),
        // LaTeX compilation is heavy.
        default_debounce_ms: 1500,
    },
    ManuscriptFormatGrammar {
        id: "markdown",
        display_name: "Markdown",
        preview_kind: preview_kind::RENDERED_MARKDOWN,
        file_extension: "md",
        extensions: &["md", "markdown", "mdown"],
        // Markdown has no line comments.
        comment_prefix: None,
        // The pandoc `@key` convention.
        citation_insert: affix("@", ""),
        bold_wrap: affix("**", "**"),
        italic_wrap: affix("_", "_"),
        // Markdown re-renders are cheap.
        default_debounce_ms: 200,
    },
    ManuscriptFormatGrammar {
        id: "plaintext",
        display_name: "Plain Text",
        preview_kind: preview_kind::NONE,
        file_extension: "txt",
        extensions: &["txt", "text"],
        // Plain text has no syntax at all.
        comment_prefix: None,
        citation_insert: None,
        bold_wrap: None,
        italic_wrap: None,
        default_debounce_ms: 0,
    },
];

/// The grammar row for a `manuscript.format` value, or `None` if unknown.
pub fn manuscript_format_grammar(id: &str) -> Option<&'static ManuscriptFormatGrammar> {
    MANUSCRIPT_FORMAT_GRAMMAR.iter().find(|g| g.id == id)
}

// ── Detection ────────────────────────────────────────────────────────────────

/// Format id for a bare file extension (no dot), or `None`.
///
/// Case-insensitive, driven by the table's `extensions` column.
pub fn manuscript_format_for_extension(ext: &str) -> Option<&'static str> {
    let lowered = ext.to_lowercase();
    MANUSCRIPT_FORMAT_GRAMMAR
        .iter()
        .find(|g| g.extensions.contains(&lowered.as_str()))
        .map(|g| g.id)
}

/// Detect a format from source content, optionally using the manuscript title
/// as a hint (titles are often file names: "ADR-11.md").
///
/// Used as the fallback when a stored `format` is missing or unrecognized —
/// blindly assuming Typst there sends Markdown bodies into the Typst compiler,
/// whose first complaint is `expected expression` on `# Heading`.
///
/// 1. Title extension hint — cheapest and most reliable when present.
/// 2. LaTeX preamble markers.
/// 3. Markdown markers that are not valid Typst.
/// 4. Typst (the suite default).
pub fn detect_manuscript_format(source: &str, title: Option<&str>) -> &'static str {
    if let Some(title) = title {
        if let Some(dot) = title.rfind('.') {
            let ext = &title[dot + 1..];
            if !ext.is_empty() {
                if let Some(by_extension) = manuscript_format_for_extension(ext) {
                    return by_extension;
                }
            }
        }
    }

    let trimmed = source.trim_matches(is_swift_whitespace_or_newline);
    if trimmed.contains("\\documentclass") || trimmed.contains("\\begin{document}") {
        return "latex";
    }
    if looks_like_markdown(trimmed) {
        return "markdown";
    }
    "typst"
}

/// Markdown markers that are NOT valid Typst: an ATX heading (`# ` — in Typst
/// `#` starts code mode, so `#` + space is a syntax error), a fenced code
/// block, or a setext-style `---` front-matter fence.
///
/// Only the first 200 lines are scanned, matching the Swift `.prefix(200)`.
fn looks_like_markdown(source: &str) -> bool {
    for raw_line in source.split('\n').take(200) {
        let line = raw_line.trim_matches(is_swift_whitespace);
        if line.starts_with("```") || line.starts_with("~~~") {
            return true;
        }
        if !line.starts_with('#') {
            continue;
        }
        let hashes = line.chars().take_while(|c| *c == '#').count();
        if hashes <= 6 && line[hashes..].starts_with(' ') {
            return true;
        }
    }
    false
}

/// Foundation's `CharacterSet.whitespaces`: Unicode `Zs` plus horizontal tab.
///
/// Spelled out rather than using `char::is_whitespace` because the Rust
/// predicate is the Unicode `White_Space` property, which additionally includes
/// `\n`, `\r`, `\u{0B}`, `\u{0C}`, `\u{85}`, `\u{2028}` and `\u{2029}`. Trimming
/// those from a *line* would silently change the CRLF behaviour this port has to
/// reproduce.
fn is_swift_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// Foundation's `CharacterSet.whitespacesAndNewlines`.
fn is_swift_whitespace_or_newline(c: char) -> bool {
    is_swift_whitespace(c)
        || matches!(
            c,
            '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "sqlite")]
    #[test]
    fn grammar_covers_exactly_the_supported_format_list() {
        let ids: Vec<&str> = MANUSCRIPT_FORMAT_GRAMMAR.iter().map(|g| g.id).collect();
        assert_eq!(
            ids.as_slice(),
            crate::manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS.as_slice(),
            "the grammar table and SUPPORTED_MANUSCRIPT_FORMATS diverged"
        );
    }

    #[test]
    fn every_row_is_internally_consistent() {
        for g in MANUSCRIPT_FORMAT_GRAMMAR.iter() {
            assert!(!g.display_name.is_empty(), "{} has no display name", g.id);
            assert!(!g.file_extension.is_empty(), "{} has no extension", g.id);
            assert_eq!(
                g.extensions.first(),
                Some(&g.file_extension),
                "{}: file_extension must lead the extensions list",
                g.id
            );
            for ext in g.extensions {
                assert_eq!(*ext, ext.to_lowercase(), "{}: {ext} is not lowercase", g.id);
            }
            assert!(
                matches!(
                    g.preview_kind,
                    preview_kind::COMPILED_PDF
                        | preview_kind::RENDERED_MARKDOWN
                        | preview_kind::NONE
                ),
                "{}: unknown preview kind {}",
                g.id,
                g.preview_kind
            );
        }
    }

    #[test]
    fn extensions_are_unambiguous() {
        let mut seen: Vec<&str> = vec![];
        for g in MANUSCRIPT_FORMAT_GRAMMAR.iter() {
            for ext in g.extensions {
                assert!(!seen.contains(ext), "{ext} claimed by two formats");
                seen.push(ext);
            }
        }
    }

    #[test]
    fn preview_flags_follow_the_preview_kind() {
        let typst = manuscript_format_grammar("typst").unwrap();
        assert!(typst.has_preview() && typst.requires_compile());
        let md = manuscript_format_grammar("markdown").unwrap();
        assert!(md.has_preview() && !md.requires_compile());
        let txt = manuscript_format_grammar("plaintext").unwrap();
        assert!(!txt.has_preview() && !txt.requires_compile());
        assert_eq!(typst.main_file_name(), "main.typ");
    }

    #[test]
    fn extension_lookup_is_case_insensitive() {
        assert_eq!(manuscript_format_for_extension("TEX"), Some("latex"));
        assert_eq!(
            manuscript_format_for_extension("Markdown"),
            Some("markdown")
        );
        assert_eq!(manuscript_format_for_extension("typ"), Some("typst"));
        assert_eq!(manuscript_format_for_extension("text"), Some("plaintext"));
        assert_eq!(manuscript_format_for_extension("rs"), None);
        assert_eq!(manuscript_format_for_extension(""), None);
    }

    #[test]
    fn title_extension_beats_content_heuristics() {
        assert_eq!(
            detect_manuscript_format("", Some("ADR-0011.md")),
            "markdown"
        );
        assert_eq!(detect_manuscript_format("", Some("notes.txt")), "plaintext");
        // Unknown extension falls through to content.
        assert_eq!(
            detect_manuscript_format("\\documentclass{article}", Some("paper.unknown")),
            "latex"
        );
        // A dotted title with an empty extension falls through too.
        assert_eq!(detect_manuscript_format("", Some("trailing.")), "typst");
    }

    #[test]
    fn markdown_body_is_not_mistaken_for_typst() {
        let adr = "# ADR-0011\n\n## Status\nAccepted\n";
        assert_eq!(detect_manuscript_format(adr, None), "markdown");
        // Typst code mode uses `#` with NO space.
        let typst = "#import \"@preview/cetz:0.2.0\"\n\n= Introduction\n";
        assert_eq!(detect_manuscript_format(typst, None), "typst");
        // Seven hashes is not an ATX heading.
        assert_eq!(detect_manuscript_format("####### deep\n", None), "typst");
        assert_eq!(
            detect_manuscript_format("```swift\nlet x = 1\n```\n", None),
            "markdown"
        );
        assert_eq!(
            detect_manuscript_format("~~~\ncode\n~~~\n", None),
            "markdown"
        );
    }

    #[test]
    fn markdown_scan_stops_after_two_hundred_lines() {
        let mut source = "= Typst heading\n".to_string();
        for _ in 0..250 {
            source.push_str("body\n");
        }
        source.push_str("# late markdown heading\n");
        assert_eq!(detect_manuscript_format(&source, None), "typst");
    }

    #[test]
    fn empty_source_and_no_hint_stay_typst() {
        assert_eq!(detect_manuscript_format("", None), "typst");
        assert_eq!(detect_manuscript_format("   \n\n ", None), "typst");
        assert_eq!(
            detect_manuscript_format("", Some("ADR-0011: The impress Journal")),
            "typst"
        );
    }

    #[test]
    fn line_trimming_does_not_swallow_newlines() {
        // `\r` must survive the per-line trim so CRLF markdown still reads as
        // markdown via the `# ` branch rather than by accident.
        assert_eq!(
            detect_manuscript_format("# Heading\r\nbody\r\n", None),
            "markdown"
        );
    }
}
