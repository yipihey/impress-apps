//! Cite-key extraction from manuscript source.
//!
//! Ported from `apps/imprint/macOS/Services/BibliographyGenerator.swift`
//! (the `extractCiteKeys` family of methods) and
//! `apps/imprint/Packages/ImprintCore/Sources/ImprintCore/CitationUsageTracker.swift`
//! (its `extractCiteKeys(from:)` helper).
//!
//! ## Behavioural goals
//!
//! - **LaTeX**: recognize `\cite{key}`, `\citep{key}`, `\citet{key}`,
//!   `\citeauthor{key}`, `\citeyear{key}`, `\citealp`, `\citealt`,
//!   `\citenum`, `\citetext`, and their starred variants (`\cite*{...}`).
//!   Also recognize biblatex commands `\textcite`, `\parencite`, `\autocite`,
//!   `\footcite`, `\smartcite`, `\supercite`. Multiple comma-separated keys
//!   within one `\cite{...}` are split.
//! - **Typst**: recognize `@citeKey` with the same word-boundary guard the
//!   Swift implementation uses (`(?<![a-zA-Z0-9_@])`), plus the exclusion
//!   list (`param`, `example`, `deprecated`, `available`, `objc`, `main`)
//!   so common `@-annotations` don't pollute the citation set.
//!
//! ## Departures from Swift
//!
//! - The Swift code does **not** track byte offsets, command kinds, or the
//!   surrounding source context. We extend the contract to expose all three
//!   so downstream Rust consumers (TUI, MCP tool, future "jump to next
//!   citation" feature) can ground each usage back to the source. The
//!   Swift call sites only ever ask for the *set* of keys; that contract is
//!   preserved via [`extract_cite_key_set`].
//! - The Swift regex `\\cite[pt]?\\{([^}]+)\\}` is a strict subset of the
//!   biblatex/natbib pattern. We use the broader natbib+biblatex regex from
//!   `BibliographyProjector.swift` (`\\cite(?:author|year|alp|alt|p|t|num|text)?`
//!   plus `\\textcite`, `\\parencite`, `\\autocite`, `\\footcite`,
//!   `\\smartcite`, `\\supercite`) so all three Swift call sites agree when
//!   they share this implementation.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

/// Which family of citation commands to look for.
///
/// Mixed mode runs both extractors and merges the results — used when the
/// caller doesn't know whether the manuscript is Typst- or LaTeX-flavoured
/// (the live HTTP router takes this stance).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CitationSyntax {
    /// Typst markup — recognize `@citeKey`.
    Typst,
    /// LaTeX markup — recognize `\cite{...}`, `\textcite{...}`, etc.
    Latex,
    /// Run both extractors.
    Mixed,
}

impl CitationSyntax {
    /// Parse a caller-supplied syntax name. Unknown (and empty) values map to
    /// [`CitationSyntax::Mixed`] — the same stance the live HTTP router takes
    /// when it doesn't know whether the manuscript is Typst- or LaTeX-flavoured.
    ///
    /// Lives here rather than in each caller so the FFI, the service trait and
    /// the HTTP router all accept exactly the same spellings.
    pub fn from_str_lenient(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "typst" => Self::Typst,
            "latex" | "tex" => Self::Latex,
            _ => Self::Mixed,
        }
    }
}

/// Which specific citation command produced a usage.
///
/// The Swift code throws this away (it only collects the set of keys), but
/// we surface it so a downstream view layer can distinguish parenthetical
/// from in-text citations without re-scanning the source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CiteCommand {
    /// `\cite{...}` (LaTeX, natbib).
    Cite,
    /// `\citep{...}` (natbib parenthetical).
    Citep,
    /// `\citet{...}` (natbib in-text).
    Citet,
    /// `\citeauthor{...}` and `\citeyear{...}` family.
    CiteAuthorYear,
    /// `\citealp{...}`, `\citealt{...}`, `\citenum{...}`, `\citetext{...}`.
    CiteOther,
    /// `\textcite{...}` (biblatex).
    TextCite,
    /// `\parencite{...}` (biblatex).
    ParenCite,
    /// `\autocite{...}` (biblatex).
    AutoCite,
    /// `\footcite{...}`, `\smartcite{...}`, `\supercite{...}` (biblatex).
    OtherBiblatex,
    /// Typst `@citeKey`.
    TypstAt,
}

/// One occurrence of a cite key in source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CiteKeyUsage {
    /// The cite key as written (post comma-split for grouped LaTeX cites).
    pub key: String,
    /// Byte offset where the key starts in the original source string.
    pub byte_offset: usize,
    /// Byte length of the key.
    pub byte_len: usize,
    /// Which citation command produced this usage.
    pub command: CiteCommand,
    /// A trimmed window of source text around the usage, capped at ~80
    /// chars before and after, with leading/trailing whitespace collapsed
    /// so the surrounding context is easy to render in a list view.
    pub context: String,
}

/// Convenience: just the unique sorted set of cite keys (matches Swift's
/// `extractCiteKeys(from:) -> [String]` return contract).
pub fn extract_cite_key_set(source: &str, syntax: CitationSyntax) -> Vec<String> {
    let mut keys: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for u in extract_cite_keys(source, syntax) {
        keys.insert(u.key);
    }
    keys.into_iter().collect()
}

/// Extract every cite-key usage from `source`, in source order.
///
/// Duplicates are preserved (the caller can dedupe via [`extract_cite_key_set`]
/// or by building a [`super::usage::UsageIndex`]).
pub fn extract_cite_keys(source: &str, syntax: CitationSyntax) -> Vec<CiteKeyUsage> {
    let mut out: Vec<CiteKeyUsage> = Vec::new();

    match syntax {
        CitationSyntax::Typst => extract_typst(source, &mut out),
        CitationSyntax::Latex => extract_latex(source, &mut out),
        CitationSyntax::Mixed => {
            extract_typst(source, &mut out);
            extract_latex(source, &mut out);
        }
    }

    // Sort by byte_offset so consumers can iterate in source order even
    // when the LaTeX and Typst extractors interleave.
    out.sort_by_key(|u| u.byte_offset);
    out
}

/// Excluded Typst `@-annotation` prefixes (case-insensitive), mirrors the
/// Swift `excludedPrefixes` list in `BibliographyGenerator.swift`.
const TYPST_EXCLUDED_PREFIXES: &[&str] = &[
    "param",
    "example",
    "deprecated",
    "available",
    "objc",
    "main",
];

fn extract_typst(source: &str, out: &mut Vec<CiteKeyUsage>) {
    // (?<![a-zA-Z0-9_@])@([a-zA-Z][a-zA-Z0-9_-]*)
    //
    // The Rust `regex` crate doesn't support lookbehind, so we emulate the
    // word-boundary guard by checking the byte preceding the `@`. We scan
    // for every `@` and validate manually.
    let bytes = source.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'@' {
            i += 1;
            continue;
        }
        // Look at preceding byte: reject if alphanumeric, '_', or '@'.
        if i > 0 {
            let prev = bytes[i - 1];
            if prev.is_ascii_alphanumeric() || prev == b'_' || prev == b'@' {
                i += 1;
                continue;
            }
        }
        // Match key: [a-zA-Z][a-zA-Z0-9_-]*
        let key_start = i + 1;
        if key_start >= bytes.len() {
            break;
        }
        let first = bytes[key_start];
        if !first.is_ascii_alphabetic() {
            i += 1;
            continue;
        }
        let mut j = key_start + 1;
        while j < bytes.len() {
            let c = bytes[j];
            if c.is_ascii_alphanumeric() || c == b'_' || c == b'-' {
                j += 1;
            } else {
                break;
            }
        }
        let key = std::str::from_utf8(&bytes[key_start..j])
            .unwrap_or("")
            .to_string();
        let lower = key.to_ascii_lowercase();
        if TYPST_EXCLUDED_PREFIXES.iter().any(|p| lower.starts_with(p)) {
            i = j;
            continue;
        }
        let byte_len = j - key_start;
        let context = make_context(source, key_start, byte_len);
        out.push(CiteKeyUsage {
            key,
            byte_offset: key_start,
            byte_len,
            command: CiteCommand::TypstAt,
            context,
        });
        i = j;
    }
}

/// Combined LaTeX cite-command regex (compiled once).
fn latex_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // Names captured so we can map them to a CiteCommand.
        //
        // The Swift code uses three patterns; we merge them into one with a
        // named alternation. Note `\b` after the command name so e.g.
        // `\citetext` doesn't accidentally match `\cite`.
        Regex::new(
            r"(?x)
            \\(?P<cmd>
                  cite (?P<sub>author|year|alp|alt|p|t|num|text)? \*?
                | textcite \*?
                | parencite \*?
                | autocite \*?
                | footcite \*?
                | smartcite \*?
                | supercite \*?
            )
            \{ (?P<keys> [^}]* ) \}
            ",
        )
        .expect("static LaTeX cite regex must compile")
    })
}

fn extract_latex(source: &str, out: &mut Vec<CiteKeyUsage>) {
    let re = latex_regex();
    for caps in re.captures_iter(source) {
        let cmd_text = caps.name("cmd").map(|m| m.as_str()).unwrap_or("");
        let sub = caps.name("sub").map(|m| m.as_str());
        let cmd = classify_latex_command(cmd_text, sub);

        let keys_match = match caps.name("keys") {
            Some(m) => m,
            None => continue,
        };
        let keys_text = keys_match.as_str();
        let keys_start = keys_match.start();

        // Split on commas, tracking byte offsets so we can attribute each
        // key to its position in the source.
        let mut cursor = 0usize;
        for piece in keys_text.split(',') {
            let piece_start_in_keys = cursor;
            let trimmed = piece.trim();
            cursor += piece.len() + 1; // +1 for the comma
            if trimmed.is_empty() {
                continue;
            }
            // Find the trimmed key's offset within the untrimmed piece.
            let leading_ws = piece.len() - piece.trim_start().len();
            let abs_offset = keys_start + piece_start_in_keys + leading_ws;
            let byte_len = trimmed.len();
            let context = make_context(source, abs_offset, byte_len);
            out.push(CiteKeyUsage {
                key: trimmed.to_string(),
                byte_offset: abs_offset,
                byte_len,
                command: cmd,
                context,
            });
        }
    }
}

fn classify_latex_command(cmd_text: &str, sub: Option<&str>) -> CiteCommand {
    // cmd_text already includes any trailing `*`; strip it for matching.
    let stripped = cmd_text.trim_end_matches('*');
    if stripped.starts_with("cite") {
        match sub {
            None => CiteCommand::Cite,
            Some("p") => CiteCommand::Citep,
            Some("t") => CiteCommand::Citet,
            Some("author") | Some("year") => CiteCommand::CiteAuthorYear,
            Some("alp") | Some("alt") | Some("num") | Some("text") => CiteCommand::CiteOther,
            Some(_) => CiteCommand::Cite,
        }
    } else if stripped == "textcite" {
        CiteCommand::TextCite
    } else if stripped == "parencite" {
        CiteCommand::ParenCite
    } else if stripped == "autocite" {
        CiteCommand::AutoCite
    } else {
        // footcite, smartcite, supercite
        CiteCommand::OtherBiblatex
    }
}

/// Build a small surrounding-context string for a usage. We grab ~80 bytes
/// on each side and collapse internal whitespace so list views stay tidy.
fn make_context(source: &str, byte_offset: usize, byte_len: usize) -> String {
    const WINDOW: usize = 80;
    let bytes = source.as_bytes();
    let end_of_key = byte_offset + byte_len;
    if byte_offset > bytes.len() || end_of_key > bytes.len() {
        return String::new();
    }

    // Snap to char boundaries so we don't slice through UTF-8 sequences.
    let start = back_to_char_boundary(source, byte_offset.saturating_sub(WINDOW));
    let end = forward_to_char_boundary(source, end_of_key.saturating_add(WINDOW));
    let slice = &source[start..end];

    // Collapse whitespace runs into single spaces, trim ends.
    let mut s = String::with_capacity(slice.len());
    let mut last_was_ws = true;
    for c in slice.chars() {
        if c.is_whitespace() {
            if !last_was_ws {
                s.push(' ');
                last_was_ws = true;
            }
        } else {
            s.push(c);
            last_was_ws = false;
        }
    }
    s.trim().to_string()
}

fn back_to_char_boundary(s: &str, mut idx: usize) -> usize {
    if idx >= s.len() {
        return s.len();
    }
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

fn forward_to_char_boundary(s: &str, mut idx: usize) -> usize {
    if idx >= s.len() {
        return s.len();
    }
    while idx < s.len() && !s.is_char_boundary(idx) {
        idx += 1;
    }
    idx
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(source: &str, syntax: CitationSyntax) -> Vec<String> {
        extract_cite_key_set(source, syntax)
    }

    // -- Typst -----------------------------------------------------------

    #[test]
    fn typst_simple_at_citation() {
        let src = "See @smith2020 for details.";
        assert_eq!(keys(src, CitationSyntax::Typst), vec!["smith2020"]);
    }

    #[test]
    fn typst_email_does_not_match() {
        let src = "Email author@example.com for a copy.";
        // 'author' is alphanumeric-preceded so `@example` should not match.
        assert!(keys(src, CitationSyntax::Typst).is_empty());
    }

    #[test]
    fn typst_excluded_prefix_main() {
        let src = "Decorated function @main does the thing.";
        assert!(keys(src, CitationSyntax::Typst).is_empty());
    }

    #[test]
    fn typst_excluded_prefix_param_case_insensitive() {
        let src = "@Parameter is also excluded";
        assert!(keys(src, CitationSyntax::Typst).is_empty());
    }

    #[test]
    fn typst_double_at_does_not_match() {
        // `@@foo` — the second `@` is preceded by `@`, which the guard rejects.
        // The first `@` is followed by `@`, which isn't alphabetic, so it
        // also doesn't start a key.
        let src = "Symbol @@foo here";
        assert!(keys(src, CitationSyntax::Typst).is_empty());
    }

    #[test]
    fn typst_at_must_be_followed_by_alpha() {
        let src = "@123abc is not a key";
        assert!(keys(src, CitationSyntax::Typst).is_empty());
    }

    #[test]
    fn typst_hyphen_and_underscore_in_key() {
        let src = "See @smith-jones_2020 and @abc-123.";
        let mut expected = vec!["abc-123".to_string(), "smith-jones_2020".to_string()];
        expected.sort();
        let mut got = keys(src, CitationSyntax::Typst);
        got.sort();
        assert_eq!(got, expected);
    }

    #[test]
    fn typst_multiple_in_one_paragraph_dedup() {
        let src = "@a @b @a @c @b";
        assert_eq!(keys(src, CitationSyntax::Typst), vec!["a", "b", "c"]);
    }

    // -- LaTeX -----------------------------------------------------------

    #[test]
    fn latex_cite_single_key() {
        let src = r"As shown in \cite{smith2020}, this works.";
        assert_eq!(keys(src, CitationSyntax::Latex), vec!["smith2020"]);
    }

    #[test]
    fn latex_cite_multiple_keys() {
        let src = r"\cite{a,b,c}";
        assert_eq!(keys(src, CitationSyntax::Latex), vec!["a", "b", "c"]);
    }

    #[test]
    fn latex_cite_multiple_with_whitespace() {
        let src = r"\cite{ a , b ,c}";
        assert_eq!(keys(src, CitationSyntax::Latex), vec!["a", "b", "c"]);
    }

    #[test]
    fn latex_citep_citet() {
        let src = r"\citep{smith2020} and \citet{jones2021}";
        let mut got = keys(src, CitationSyntax::Latex);
        got.sort();
        assert_eq!(got, vec!["jones2021", "smith2020"]);
    }

    #[test]
    fn latex_starred_variants() {
        let src = r"\cite*{a} \citep*{b} \citet*{c}";
        let mut got = keys(src, CitationSyntax::Latex);
        got.sort();
        assert_eq!(got, vec!["a", "b", "c"]);
    }

    #[test]
    fn latex_extended_commands() {
        let src = r"\citeauthor{a} \citeyear{b} \citealp{c} \citealt{d} \citenum{e} \citetext{f}";
        let mut got = keys(src, CitationSyntax::Latex);
        got.sort();
        assert_eq!(got, vec!["a", "b", "c", "d", "e", "f"]);
    }

    #[test]
    fn latex_biblatex_commands() {
        let src =
            r"\textcite{a} \parencite{b} \autocite{c} \footcite{d} \smartcite{e} \supercite{f}";
        let mut got = keys(src, CitationSyntax::Latex);
        got.sort();
        assert_eq!(got, vec!["a", "b", "c", "d", "e", "f"]);
    }

    #[test]
    fn latex_command_kind_classification() {
        let src = r"\cite{a} \citep{b} \citet{c} \textcite{d} \parencite{e} \autocite{f} \footcite{g} \citeauthor{h} \citealp{i}";
        let usages = extract_cite_keys(src, CitationSyntax::Latex);
        let by_key: std::collections::HashMap<_, _> =
            usages.iter().map(|u| (u.key.clone(), u.command)).collect();
        assert_eq!(by_key["a"], CiteCommand::Cite);
        assert_eq!(by_key["b"], CiteCommand::Citep);
        assert_eq!(by_key["c"], CiteCommand::Citet);
        assert_eq!(by_key["d"], CiteCommand::TextCite);
        assert_eq!(by_key["e"], CiteCommand::ParenCite);
        assert_eq!(by_key["f"], CiteCommand::AutoCite);
        assert_eq!(by_key["g"], CiteCommand::OtherBiblatex);
        assert_eq!(by_key["h"], CiteCommand::CiteAuthorYear);
        assert_eq!(by_key["i"], CiteCommand::CiteOther);
    }

    #[test]
    fn latex_empty_braces_yields_no_keys() {
        let src = r"\cite{}";
        assert!(keys(src, CitationSyntax::Latex).is_empty());
    }

    #[test]
    fn latex_does_not_match_typst_at() {
        // Plain LaTeX shouldn't trip the Typst extractor when we explicitly
        // ask for LaTeX mode.
        let src = "@notacite \\cite{real}";
        assert_eq!(keys(src, CitationSyntax::Latex), vec!["real"]);
    }

    #[test]
    fn typst_does_not_match_latex_cite() {
        let src = r"\cite{notme} but @yesme";
        assert_eq!(keys(src, CitationSyntax::Typst), vec!["yesme"]);
    }

    // -- Mixed -----------------------------------------------------------

    #[test]
    fn mixed_extracts_both() {
        let src = r"\cite{a,b} text @c more text \textcite{d}";
        let mut got = keys(src, CitationSyntax::Mixed);
        got.sort();
        assert_eq!(got, vec!["a", "b", "c", "d"]);
    }

    // -- Position and metadata ------------------------------------------

    #[test]
    fn offsets_are_byte_accurate() {
        let src = "X @abc Y";
        let usages = extract_cite_keys(src, CitationSyntax::Typst);
        assert_eq!(usages.len(), 1);
        assert_eq!(usages[0].byte_offset, 3);
        assert_eq!(usages[0].byte_len, 3);
        assert_eq!(
            &src[usages[0].byte_offset..usages[0].byte_offset + usages[0].byte_len],
            "abc"
        );
    }

    #[test]
    fn offsets_are_source_order_in_mixed_mode() {
        let src = r"@a \cite{b} @c";
        let usages = extract_cite_keys(src, CitationSyntax::Mixed);
        let keys: Vec<_> = usages.iter().map(|u| u.key.as_str()).collect();
        assert_eq!(keys, vec!["a", "b", "c"]);
    }

    #[test]
    fn context_captures_surrounding_text() {
        let src = "Hello world @smith2020 and others.";
        let usages = extract_cite_keys(src, CitationSyntax::Typst);
        assert_eq!(usages.len(), 1);
        assert!(usages[0].context.contains("smith2020"));
        assert!(usages[0].context.contains("Hello"));
        assert!(usages[0].context.contains("others"));
    }

    #[test]
    fn comma_split_offsets_are_accurate() {
        let src = r"\cite{aaa, bbb, ccc}";
        let usages = extract_cite_keys(src, CitationSyntax::Latex);
        assert_eq!(usages.len(), 3);
        for u in &usages {
            assert_eq!(
                &src[u.byte_offset..u.byte_offset + u.byte_len],
                u.key.as_str()
            );
        }
    }

    // -- Edge cases ------------------------------------------------------

    #[test]
    fn handles_unicode_source() {
        let src = "Café paper @résumé2020 next \\cite{α}";
        // Typst key is ASCII-only by design, so `résumé2020` ought NOT
        // to match (regex requires `[a-zA-Z]` first char). Greek alpha
        // doesn't match `[A-Za-z0-9_-]` either, so `\cite{α}` produces a
        // non-empty key string but it's still extracted (the LaTeX regex
        // is `[^}]+`).
        let typst = keys(src, CitationSyntax::Typst);
        // `résumé` first char is `r` ASCII — matches start of [a-zA-Z],
        // then `é` is not in `[a-zA-Z0-9_-]` so the key ends at the `é`.
        assert_eq!(typst, vec!["r"]);

        let latex = keys(src, CitationSyntax::Latex);
        assert_eq!(latex, vec!["α"]);
    }

    #[test]
    fn does_not_panic_on_empty_source() {
        let usages = extract_cite_keys("", CitationSyntax::Mixed);
        assert!(usages.is_empty());
    }

    #[test]
    fn handles_braces_inside_other_macros() {
        // Make sure we don't accidentally match `\section{foo}`.
        let src = r"\section{Introduction} \cite{real}";
        assert_eq!(keys(src, CitationSyntax::Latex), vec!["real"]);
    }

    #[test]
    fn detects_real_world_swift_test_snippet() {
        // A snippet that exercises the patterns the Swift test corpus
        // would hit (multi-key cite, citep, citet, Typst @-cite, biblatex).
        let src = r#"
            We follow \citet{smith2020} and \citep{jones2021,brown2022}.
            See also @rust2024 for the implementation, plus \textcite{wong2023}.
            "#;
        let mut got = keys(src, CitationSyntax::Mixed);
        got.sort();
        assert_eq!(
            got,
            vec![
                "brown2022",
                "jones2021",
                "rust2024",
                "smith2020",
                "wong2023",
            ]
        );
    }
}
