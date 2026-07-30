//! Section extraction from manuscript source (Stage 7 item 6).
//!
//! Sections are defined by headings — Typst `= Title` / `== Subtitle` or LaTeX
//! `\section{Title}` / `\subsection{Title}`. A section runs from its heading
//! line up to the next heading (of any level) or end of file.
//!
//! Each section gets a deterministic UUID derived from the document id plus the
//! heading's normalized title plus its order index — stable across edits to body
//! content, unstable only when a heading is added, removed, or renamed. That is
//! the right level of stability for agent workflows: agents refer to sections by
//! id across turns, and the id naturally rebinds when you rename a heading.
//!
//! ## Why the derivation is frozen
//!
//! These ids are **persisted** as `manuscript-section` row ids
//! (`imprint_service::sections`). Changing the digest input, the truncation, or
//! the version/variant bit twiddling orphans every existing section row — the
//! store matches by id, so the rows do not error, they simply stop being found.
//! [`section_id`] therefore reproduces Swift's `SectionExtractor.sectionID`
//! byte-for-byte, including the **uppercase** `UUID.uuidString` spelling of the
//! document id (Rust's `Uuid::to_string` is lowercase; the digest differs
//! completely if you forget). `sections_golden.json` pins real documents' full
//! id sets against the Swift capture.
//!
//! ## Offsets are grapheme clusters
//!
//! `start` / `end` / `body_start` count Swift `Character`s — extended grapheme
//! clusters — because the Swift implementation indexed `Array(source)` and every
//! consumer splices source text with these numbers (`ImprintHTTPRouter`'s
//! section PATCH/DELETE cut the document at them). A `char`-based (scalar) count
//! would be off by one per combining mark and silently corrupt a document
//! containing decomposed accents.
//!
//! The `*_utf16` fields carry the same positions in UTF-16 code units, which is
//! what `NSRange` and the AppKit/UIKit text stack actually want. Swift's
//! `DocumentStructure` was feeding Character offsets into `NSRange` and getting
//! away with it only for ASCII source; it reads the `*_utf16` fields now.

use sha2::{Digest, Sha256};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

/// Document format used for heading detection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SectionFormat {
    Typst,
    Latex,
}

impl SectionFormat {
    /// The lowercase name used on the wire and in FFI string parameters.
    pub fn as_str(&self) -> &'static str {
        match self {
            SectionFormat::Typst => "typst",
            SectionFormat::Latex => "latex",
        }
    }

    /// Parse leniently: only `latex` selects LaTeX, everything else (including
    /// `markdown`, `plaintext` and junk) falls back to Typst — matching the
    /// Swift call sites, which all spell the fallback `format == .latex ? … : .typst`.
    pub fn from_str_lenient(s: &str) -> Self {
        if s.eq_ignore_ascii_case("latex") {
            SectionFormat::Latex
        } else {
            SectionFormat::Typst
        }
    }

    /// Auto-detect from source content. Defaults to Typst when ambiguous.
    ///
    /// LaTeX documents almost always start with `\documentclass` or contain
    /// `\begin{document}`; Typst documents use `#import` or bare content.
    pub fn auto_detect(source: &str) -> Self {
        if source.contains("\\documentclass") || source.contains("\\begin{document}") {
            SectionFormat::Latex
        } else {
            SectionFormat::Typst
        }
    }
}

/// A section extracted from a manuscript source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtractedSection {
    /// Stable id derived from `(document_id, normalized title, order index)`.
    pub id: Uuid,
    /// Heading text, without the leading `=` or `\section{}`.
    pub title: String,
    /// Typst: number of `=`. LaTeX: 1 for `\section`, 2 for `\subsection`, ….
    pub level: u32,
    /// Grapheme offset where the section starts (inclusive) — the heading line.
    pub start: usize,
    /// Grapheme offset where the section ends (exclusive).
    pub end: usize,
    /// Grapheme offset of the first character after the heading line.
    pub body_start: usize,
    /// `start` in UTF-16 code units (`NSRange` semantics).
    pub start_utf16: usize,
    /// `end` in UTF-16 code units.
    pub end_utf16: usize,
    /// `body_start` in UTF-16 code units.
    pub body_start_utf16: usize,
    /// Zero-based position among all headings in the source.
    pub order_index: usize,
    /// Semantic classification derived from the heading title, or `None`.
    pub section_type: Option<String>,
    /// Approximate word count of the section body.
    pub word_count: usize,
}

/// Extract every section from `source`, in document order.
///
/// `format` of `None` auto-detects.
pub fn extract(
    source: &str,
    document_id: Uuid,
    format: Option<SectionFormat>,
) -> Vec<ExtractedSection> {
    let fmt = format.unwrap_or_else(|| SectionFormat::auto_detect(source));
    let doc = Graphemes::new(source);
    let headings = match fmt {
        SectionFormat::Typst => typst_headings(&doc),
        SectionFormat::Latex => latex_headings(&doc),
    };
    if headings.is_empty() {
        return vec![];
    }

    let total = doc.len();
    headings
        .iter()
        .enumerate()
        .map(|(idx, h)| {
            let end = headings
                .get(idx + 1)
                .map(|next| next.start)
                .unwrap_or(total);
            let body = doc.slice(h.body_start, end);
            ExtractedSection {
                id: section_id(document_id, &h.title, idx),
                title: h.title.clone(),
                level: h.level,
                start: h.start,
                end,
                body_start: h.body_start,
                start_utf16: doc.utf16_offset(h.start),
                end_utf16: doc.utf16_offset(end),
                body_start_utf16: doc.utf16_offset(h.body_start),
                order_index: idx,
                section_type: classify_section_type(&h.title),
                word_count: count_words(body),
            }
        })
        .collect()
}

/// Find the section with the given id, if any.
pub fn find_by_id(
    source: &str,
    document_id: Uuid,
    section_id: Uuid,
    format: Option<SectionFormat>,
) -> Option<ExtractedSection> {
    extract(source, document_id, format)
        .into_iter()
        .find(|s| s.id == section_id)
}

/// Find the section at `index` in document order, if any.
pub fn find_by_index(
    source: &str,
    document_id: Uuid,
    index: usize,
    format: Option<SectionFormat>,
) -> Option<ExtractedSection> {
    extract(source, document_id, format).into_iter().nth(index)
}

/// Deterministic UUID-v5-shaped section id: SHA-256 of a composed key,
/// truncated to 16 bytes, with the version and variant bits set per RFC 4122.
///
/// **Frozen.** See the module docs — these ids are persisted row ids. Note the
/// document id is spelled the way Swift's `UUID.uuidString` spells it:
/// uppercase, hyphenated.
pub fn section_id(document_id: Uuid, title: &str, order_index: usize) -> Uuid {
    let normalized = trim_swift_whitespace(&title.to_lowercase()).to_string();
    let composed = format!(
        "manuscript-section:{}:{}:{}",
        document_id.hyphenated().to_string().to_uppercase(),
        order_index,
        normalized
    );

    let digest = Sha256::digest(composed.as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    Uuid::from_bytes(bytes)
}

// ── Heading scanning ─────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct Heading {
    title: String,
    level: u32,
    /// Grapheme offset of the line start.
    start: usize,
    /// Grapheme offset of the first character after the heading line.
    body_start: usize,
}

/// `source` split into extended grapheme clusters, with a UTF-16 prefix-length
/// table so a grapheme offset can be converted to an `NSRange` location.
struct Graphemes<'a> {
    cells: Vec<&'a str>,
    /// `utf16_prefix[i]` = UTF-16 length of `cells[..i]`. One longer than `cells`.
    utf16_prefix: Vec<usize>,
}

impl<'a> Graphemes<'a> {
    fn new(source: &'a str) -> Self {
        let cells: Vec<&str> = source.graphemes(true).collect();
        let mut utf16_prefix = Vec::with_capacity(cells.len() + 1);
        let mut running = 0usize;
        utf16_prefix.push(0);
        for cell in &cells {
            running += cell.encode_utf16().count();
            utf16_prefix.push(running);
        }
        Self {
            cells,
            utf16_prefix,
        }
    }

    fn len(&self) -> usize {
        self.cells.len()
    }

    /// Whether the grapheme at `index` is exactly `expected`.
    fn is(&self, index: usize, expected: &str) -> bool {
        self.cells[index] == expected
    }

    /// Swift's `Character.isWhitespace` — decided by the cluster's base scalar.
    fn is_whitespace(&self, index: usize) -> bool {
        self.cells[index]
            .chars()
            .next()
            .map(char::is_whitespace)
            .unwrap_or(false)
    }

    fn slice(&self, start: usize, end: usize) -> String {
        let lo = start.min(self.len());
        let hi = end.clamp(lo, self.len());
        self.cells[lo..hi].concat()
    }

    fn utf16_offset(&self, grapheme_offset: usize) -> usize {
        self.utf16_prefix[grapheme_offset.min(self.len())]
    }
}

/// Typst headings: `=`…`======` followed by a single space and non-empty text.
///
/// Quirk preserved from Swift: the line scan looks for a grapheme equal to
/// `"\n"`, and in a CRLF document `"\r\n"` is a *single* grapheme that is not
/// equal to `"\n"` — so a CRLF Typst file is treated as one long line and yields
/// no headings. Real documents from the editor are LF. Fixing it would change
/// which sections exist (and therefore which ids exist) for CRLF sources, so it
/// is a separate, deliberate decision rather than a side effect of this port.
fn typst_headings(doc: &Graphemes<'_>) -> Vec<Heading> {
    let mut result = Vec::new();
    let count = doc.len();
    let mut line_start = 0usize;

    while line_start < count {
        let mut line_end = line_start;
        while line_end < count && !doc.is(line_end, "\n") {
            line_end += 1;
        }

        let mut idx = line_start;
        while idx < line_end && doc.is_whitespace(idx) {
            idx += 1;
        }

        let mut level = 0u32;
        while idx < line_end && doc.is(idx, "=") {
            level += 1;
            idx += 1;
        }

        // A real heading has `=`(s), then a space, then text.
        if level > 0 && level <= 6 && idx < line_end && doc.is(idx, " ") {
            let raw_title = doc.slice(idx + 1, line_end);
            let title = trim_swift_whitespace(&raw_title);
            if !title.is_empty() {
                result.push(Heading {
                    title: title.to_string(),
                    level,
                    start: line_start,
                    body_start: if line_end < count {
                        line_end + 1
                    } else {
                        line_end
                    },
                });
            }
        }

        line_start = line_end + 1;
    }

    result
}

/// LaTeX sectioning commands, longest-distinguishing first is *not* required:
/// the Swift loop tests them in this order and `\section` cannot prefix-match
/// `\subsection` (the third character already differs).
const LATEX_LEVELS: [(&str, u32); 5] = [
    ("\\section", 1),
    ("\\subsection", 2),
    ("\\subsubsection", 3),
    ("\\paragraph", 4),
    ("\\subparagraph", 5),
];

fn latex_headings(doc: &Graphemes<'_>) -> Vec<Heading> {
    let mut result = Vec::new();
    let count = doc.len();
    let mut i = 0usize;

    while i < count {
        if !doc.is(i, "\\") {
            i += 1;
            continue;
        }

        let mut matched: Option<u32> = None;
        for (prefix, level) in LATEX_LEVELS.iter() {
            // Swift compared `prefix.count` *Characters*; every LaTeX command
            // is ASCII, so grapheme count and byte count agree here.
            let end = i + prefix.len();
            if end <= count && doc.slice(i, end) == *prefix {
                // Must be followed by `{` or `*{`.
                let mut after = end;
                if after < count && doc.is(after, "*") {
                    after += 1;
                }
                if after < count && doc.is(after, "{") {
                    matched = Some(*level);
                    i = after;
                    break;
                }
            }
        }
        let Some(level) = matched else {
            i += 1;
            continue;
        };

        // `i` points at `{` — scan to the matching `}` tracking brace depth.
        let brace_start = i + 1;
        let mut depth = 1i32;
        let mut j = brace_start;
        while j < count && depth > 0 {
            if doc.is(j, "{") {
                depth += 1;
            } else if doc.is(j, "}") {
                depth -= 1;
            }
            if depth > 0 {
                j += 1;
            }
        }
        let title = trim_swift_whitespace(&doc.slice(brace_start, j)).to_string();

        // The heading "line" in LaTeX is the whole `\section{…}` token; move
        // body_start past any trailing newline so the body begins cleanly.
        let mut body_start = j + 1;
        if body_start < count && doc.is(body_start, "\n") {
            body_start += 1;
        }

        // Walk back to the start of the line holding the command, then forward
        // over indentation so `start` lands on the backslash rather than on
        // leading whitespace.
        let mut heading_start = i;
        while heading_start > 0 && !doc.is(heading_start - 1, "\n") {
            heading_start -= 1;
        }
        while heading_start < count && (doc.is(heading_start, " ") || doc.is(heading_start, "\t")) {
            heading_start += 1;
        }

        if !title.is_empty() {
            result.push(Heading {
                title,
                level,
                start: heading_start,
                body_start,
            });
        }

        i = body_start;
    }

    result
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Foundation's `CharacterSet.whitespaces`: Unicode `Zs` plus horizontal tab.
/// Deliberately *not* `str::trim`, which also strips newlines.
fn trim_swift_whitespace(s: &str) -> &str {
    s.trim_matches(|c: char| {
        matches!(
            c,
            '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
                ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
        )
    })
}

/// Words = runs between `CharacterSet.whitespacesAndNewlines` members.
fn count_words(text: String) -> usize {
    text.split(|c: char| {
        matches!(
            c,
            '\t' | '\n'
                | '\u{0B}'
                | '\u{0C}'
                | '\r'
                | ' '
                | '\u{0085}'
                | '\u{00A0}'
                | '\u{1680}'
                | '\u{2000}'
                ..='\u{200A}' | '\u{2028}' | '\u{2029}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
        )
    })
    .filter(|word| !word.is_empty())
    .count()
}

/// Section-type keywords, in match order — the first family that matches wins,
/// so "Intro to background" classifies as `introduction`, not `background`.
const SECTION_TYPE_KEYWORDS: [(&str, &[&str]); 10] = [
    ("abstract", &["abstract"]),
    ("introduction", &["introduction", "intro"]),
    ("background", &["background", "related work"]),
    (
        "methods",
        &["methods", "methodology", "approach", "experimental setup"],
    ),
    (
        "results",
        &["results", "findings", "experiments", "experimental results"],
    ),
    ("discussion", &["discussion", "analysis"]),
    ("conclusion", &["conclusion", "conclusions", "summary"]),
    (
        "acknowledgements",
        &[
            "acknowledgement",
            "acknowledgements",
            "acknowledgment",
            "acknowledgments",
        ],
    ),
    ("references", &["references", "bibliography"]),
    ("appendix", &["appendix", "appendices"]),
];

/// Classify a heading title: exact match, leading word(s), or trailing word(s).
fn classify_section_type(title: &str) -> Option<String> {
    let normalized = trim_swift_whitespace(&title.to_lowercase()).to_string();
    for (kind, patterns) in SECTION_TYPE_KEYWORDS.iter() {
        for pattern in patterns.iter() {
            if normalized == *pattern
                || normalized.starts_with(&format!("{pattern} "))
                || normalized.ends_with(&format!(" {pattern}"))
            {
                return Some((*kind).to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc_id() -> Uuid {
        Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap()
    }

    #[test]
    fn typst_headings_are_extracted_in_order() {
        let source = "= One\nbody one\n\n== Two\nbody two\n= Three\n";
        let sections = extract(source, doc_id(), Some(SectionFormat::Typst));
        assert_eq!(sections.len(), 3);
        assert_eq!(sections[0].title, "One");
        assert_eq!(sections[0].level, 1);
        assert_eq!(sections[0].start, 0);
        assert_eq!(sections[0].body_start, 6);
        assert_eq!(sections[1].title, "Two");
        assert_eq!(sections[1].level, 2);
        assert_eq!(sections[0].end, sections[1].start);
        assert_eq!(sections[2].end, source.chars().count());
        assert_eq!(sections[2].order_index, 2);
    }

    #[test]
    fn equals_without_a_space_is_not_a_heading() {
        let sections = extract("=NotAHeading\n=======  seven\n", doc_id(), None);
        assert!(sections.is_empty(), "got {sections:?}");
    }

    #[test]
    fn an_empty_title_is_not_a_heading() {
        assert!(extract("=   \n", doc_id(), None).is_empty());
    }

    #[test]
    fn indented_typst_headings_still_count_but_start_at_the_line() {
        let sections = extract("    = Indented\nbody\n", doc_id(), None);
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].title, "Indented");
        assert_eq!(sections[0].start, 0, "start is the line, not the `=`");
    }

    #[test]
    fn latex_sectioning_commands_map_to_levels() {
        let source = "\\documentclass{article}\n\\begin{document}\n\
                      \\section{One}\ntext\n\\subsection*{Two}\nmore\n\
                      \\subsubsection{Three}\n\\paragraph{Four}\n\\subparagraph{Five}\n";
        let sections = extract(source, doc_id(), None);
        let levels: Vec<u32> = sections.iter().map(|s| s.level).collect();
        assert_eq!(levels, vec![1, 2, 3, 4, 5]);
        assert_eq!(sections[1].title, "Two", "starred form is accepted");
    }

    #[test]
    fn latex_titles_track_nested_braces() {
        let source = "\\section{A {nested} title}\nbody\n";
        let sections = extract(source, doc_id(), Some(SectionFormat::Latex));
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].title, "A {nested} title");
    }

    #[test]
    fn auto_detect_prefers_latex_only_on_preamble_markers() {
        assert_eq!(
            SectionFormat::auto_detect("\\documentclass{article}"),
            SectionFormat::Latex
        );
        assert_eq!(
            SectionFormat::auto_detect("\\begin{document}"),
            SectionFormat::Latex
        );
        // A bare \section is not enough — Typst is the default.
        assert_eq!(
            SectionFormat::auto_detect("\\section{x}"),
            SectionFormat::Typst
        );
    }

    #[test]
    fn section_types_are_classified_by_keyword_family() {
        let cases = [
            ("Abstract", Some("abstract")),
            ("Introduction", Some("introduction")),
            ("1. Intro to the problem", None),
            ("Intro to the problem", Some("introduction")),
            ("Related Work", Some("background")),
            ("Experimental Setup", Some("methods")),
            // "results " is a leading-word match, and the results family is
            // tested before discussion — so a combined heading reads as results.
            ("Results and Discussion", Some("results")),
            ("Discussion", Some("discussion")),
            ("Conclusions", Some("conclusion")),
            ("Acknowledgments", Some("acknowledgements")),
            ("Bibliography", Some("references")),
            // Leading-word match, so a numbered appendix still classifies.
            ("Appendix A", Some("appendix")),
            ("Appendix", Some("appendix")),
            // "introduction" is a *word* match, not a substring one.
            ("Reintroduction of the model", None),
            ("Preliminaries", None),
            ("A Note On Scaling", None),
        ];
        for (title, expected) in cases {
            assert_eq!(
                classify_section_type(title).as_deref(),
                expected,
                "classifying {title:?}"
            );
        }
    }

    #[test]
    fn word_count_counts_body_only() {
        let sections = extract("= Title\none two three\n\nfour\n", doc_id(), None);
        assert_eq!(sections[0].word_count, 4);
    }

    #[test]
    fn ids_are_stable_across_body_edits_and_move_on_rename() {
        let a = extract("= Methods\nfirst draft\n", doc_id(), None);
        let b = extract("= Methods\na completely rewritten body\n", doc_id(), None);
        assert_eq!(a[0].id, b[0].id, "body edits must not rebind the id");

        let renamed = extract("= Method\nfirst draft\n", doc_id(), None);
        assert_ne!(a[0].id, renamed[0].id, "a rename must rebind the id");
    }

    #[test]
    fn id_derivation_is_frozen() {
        // Regression pin: any change to the composed key, the truncation, or the
        // version/variant bits orphans every persisted section row.
        let id = section_id(doc_id(), "Introduction", 0);
        assert_eq!(id.to_string(), "c59b7e3b-471c-53ea-bb4b-3b61fd2032eb");
        assert_eq!(id.get_version_num(), 5, "version nibble must read as v5");
        assert_eq!(
            id.as_bytes()[8] & 0xC0,
            0x80,
            "RFC 4122 variant bits must be set"
        );
    }

    #[test]
    fn id_derivation_uppercases_the_document_uuid() {
        // The whole point of the previous test: prove the case matters, so a
        // future refactor to `Uuid::to_string()` fails loudly instead of
        // silently orphaning rows.
        let normalized_lowercase = format!(
            "manuscript-section:{}:0:introduction",
            doc_id().hyphenated()
        );
        let wrong = {
            let digest = Sha256::digest(normalized_lowercase.as_bytes());
            let mut bytes = [0u8; 16];
            bytes.copy_from_slice(&digest[..16]);
            bytes[6] = (bytes[6] & 0x0F) | 0x50;
            bytes[8] = (bytes[8] & 0x3F) | 0x80;
            Uuid::from_bytes(bytes)
        };
        assert_ne!(section_id(doc_id(), "Introduction", 0), wrong);
    }

    #[test]
    fn id_normalizes_case_and_surrounding_spaces_of_the_title() {
        assert_eq!(
            section_id(doc_id(), "  Introduction  ", 3),
            section_id(doc_id(), "INTRODUCTION", 3)
        );
    }

    #[test]
    fn offsets_are_grapheme_clusters_and_utf16_is_reported_separately() {
        // "é" as e + U+0301: one Character, two scalars, two UTF-16 units.
        let source = "e\u{0301}\n= Title\nbody\n";
        let sections = extract(source, doc_id(), Some(SectionFormat::Typst));
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].start, 2, "graphemes: [é, \\n] then the heading");
        assert_eq!(sections[0].start_utf16, 3, "utf16: [e, ́ , \\n]");

        // An emoji ZWJ sequence is one Character but four scalars / seven units.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        let source = format!("{family}\n= Title\nbody\n");
        let sections = extract(&source, doc_id(), Some(SectionFormat::Typst));
        assert_eq!(sections[0].start, 2);
        // Three surrogate pairs (6) + two ZWJ (2) + the newline (1).
        assert_eq!(sections[0].start_utf16, 9);
    }

    #[test]
    fn a_crlf_typst_document_collapses_into_one_giant_heading() {
        // Preserved Swift quirk — documented in `typst_headings`. `"\r\n"` is a
        // single grapheme that is not `"\n"`, so the line scan never terminates
        // and the whole document reads as one heading line.
        let sections = extract(
            "= One\r\nbody\r\n= Two\r\n",
            doc_id(),
            Some(SectionFormat::Typst),
        );
        assert_eq!(sections.len(), 1);
        // Not even the trailing newline is trimmed: `CharacterSet.whitespaces`
        // strips spaces and tabs, never newlines.
        assert_eq!(sections[0].title, "One\r\nbody\r\n= Two\r\n");
        assert_eq!(sections[0].level, 1);
    }

    #[test]
    fn find_helpers_resolve_by_id_and_index() {
        let source = "= One\na\n= Two\nb\n";
        let sections = extract(source, doc_id(), None);
        let found = find_by_id(source, doc_id(), sections[1].id, None).unwrap();
        assert_eq!(found.title, "Two");
        assert_eq!(
            find_by_index(source, doc_id(), 0, None).unwrap().title,
            "One"
        );
        assert!(find_by_index(source, doc_id(), 9, None).is_none());
        assert!(find_by_id(source, doc_id(), Uuid::nil(), None).is_none());
    }

    #[test]
    fn a_source_with_no_headings_extracts_nothing() {
        assert!(extract("", doc_id(), None).is_empty());
        assert!(extract("just prose\n\nmore prose\n", doc_id(), None).is_empty());
    }

    #[test]
    fn format_strings_round_trip_leniently() {
        assert_eq!(SectionFormat::from_str_lenient("latex").as_str(), "latex");
        assert_eq!(SectionFormat::from_str_lenient("LaTeX").as_str(), "latex");
        assert_eq!(SectionFormat::from_str_lenient("typst").as_str(), "typst");
        assert_eq!(
            SectionFormat::from_str_lenient("markdown").as_str(),
            "typst"
        );
        assert_eq!(SectionFormat::from_str_lenient("").as_str(), "typst");
    }
}
