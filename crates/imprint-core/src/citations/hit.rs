//! Locating the cite key under a caret / touch point.
//!
//! The macOS editor answers "is the pointer on a citation?" with a hand-rolled
//! Swift scanner (`CiteKeyAtLocation` in `CiteKeyHoverPreview.swift`) that walks
//! backwards for a `@` or a `\cite{`. That scanner is a SECOND definition of the
//! cite-key grammar, and a second definition drifts: it already disagrees with
//! [`super::extract`] about Typst's excluded `@`-annotation prefixes (`@param`,
//! `@example`, …), which the hover happily previews as citations.
//!
//! This module derives the answer from the canonical scanner instead. It calls
//! [`super::extract::extract_cite_keys`] — the same function behind
//! `imprint-text-service_extract-cite-key-usages`, the bibliography compile
//! path, and the usage index — and picks the usage whose span covers the
//! offset. There is no second grammar to keep in step, so a change to the
//! scanner's idea of a cite key is inherited here (and by iOS) for free.
//!
//! ## Hit span vs key span
//!
//! [`CiteKeyUsage::byte_offset`] points at the KEY, not at the token the reader
//! sees. For Typst the reader sees `@key` and will put a finger on the `@`, so
//! the hit span is widened one byte to the left to include the sigil — matching
//! what the macOS hover does (`location >= i` where `i` is the `@`). For LaTeX
//! the reader sees `\cite{key}` and the macOS hover only treats the text
//! *inside* the braces as the target, so the hit span is the key span. Both
//! decisions are grammar, which is why they live here and not in Swift.

use super::extract::{extract_cite_keys, CitationSyntax, CiteCommand, CiteKeyUsage};

/// One cite-key occurrence, with the span a pointer/touch hit-test should use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CiteKeyHit {
    /// The cite key as written.
    pub key: String,
    /// Which citation command produced this occurrence.
    pub command: CiteCommand,
    /// Byte offset of the KEY text in the source.
    pub key_byte_offset: usize,
    /// Byte length of the KEY text.
    pub key_byte_len: usize,
    /// Byte offset of the span that counts as "on the citation" — includes the
    /// Typst `@` sigil; equals `key_byte_offset` for LaTeX.
    pub hit_byte_offset: usize,
    /// Byte length of that span.
    pub hit_byte_len: usize,
}

impl CiteKeyHit {
    /// Half-open byte range `[start, end)` that counts as on the citation.
    pub fn hit_byte_range(&self) -> std::ops::Range<usize> {
        self.hit_byte_offset..self.hit_byte_offset + self.hit_byte_len
    }

    fn from_usage(u: CiteKeyUsage) -> Self {
        let (hit_byte_offset, hit_byte_len) = match u.command {
            // Typst `@key`: the sigil is part of the token the reader taps.
            // `byte_offset` is always ≥ 1 here (the `@` precedes it), but
            // saturate rather than trust that across future scanner edits.
            CiteCommand::TypstAt => (u.byte_offset.saturating_sub(1), u.byte_len + 1),
            // LaTeX: the key text inside the braces, as the macOS hover does.
            _ => (u.byte_offset, u.byte_len),
        };
        Self {
            key: u.key,
            command: u.command,
            key_byte_offset: u.byte_offset,
            key_byte_len: u.byte_len,
            hit_byte_offset,
            hit_byte_len,
        }
    }
}

/// Every cite-key occurrence in `source`, in source order, with hit spans.
pub fn cite_key_hits(source: &str, syntax: CitationSyntax) -> Vec<CiteKeyHit> {
    extract_cite_keys(source, syntax)
        .into_iter()
        .map(CiteKeyHit::from_usage)
        .collect()
}

/// The cite key whose hit span covers `byte_offset`, if any.
///
/// The span is half-open, so the offset one past the last character of a
/// citation is NOT a hit — a caret sitting after `@smith2024` is "after the
/// citation", the same stance the macOS hover takes. Callers doing touch
/// hit-testing, where the nearest caret position can land one past the glyph
/// the finger was actually on, should probe `offset` and then `offset - 1`.
///
/// When occurrences overlap (they can only do so in `Mixed`, where a LaTeX
/// `\cite{...}` body could also contain an `@`), the LONGEST hit wins, so the
/// enclosing construct is preferred over a fragment of it.
pub fn cite_key_at_byte_offset(
    source: &str,
    byte_offset: usize,
    syntax: CitationSyntax,
) -> Option<CiteKeyHit> {
    cite_key_hits(source, syntax)
        .into_iter()
        .filter(|h| h.hit_byte_range().contains(&byte_offset))
        .max_by_key(|h| h.hit_byte_len)
}

// ── UTF-16 views, for the Apple text stack ───────────────────────────────────
//
// `NSRange`/`UITextView` index in UTF-16 code units; Rust indexes in bytes.
// Converting on the Swift side would put index arithmetic over a foreign
// encoding in the caller, so both directions live here.

/// UTF-16 code-unit offset corresponding to a byte offset. Offsets past the end
/// clamp to the source's UTF-16 length.
pub fn byte_offset_to_utf16(source: &str, byte_offset: usize) -> usize {
    if byte_offset >= source.len() {
        return source.encode_utf16().count();
    }
    source[..byte_offset].encode_utf16().count()
}

/// Byte offset corresponding to a UTF-16 code-unit offset. Offsets past the end
/// clamp to `source.len()`; an offset landing on the trailing surrogate of a
/// pair resolves to the start of that character.
pub fn utf16_offset_to_byte(source: &str, utf16_offset: usize) -> usize {
    let mut units = 0usize;
    for (byte_idx, ch) in source.char_indices() {
        if units >= utf16_offset {
            return byte_idx;
        }
        units += ch.len_utf16();
    }
    source.len()
}

/// Same as [`cite_key_at_byte_offset`], but the offset is a UTF-16 code-unit
/// index (what `NSRange`/`UITextView` hand out).
pub fn cite_key_at_utf16_offset(
    source: &str,
    utf16_offset: usize,
    syntax: CitationSyntax,
) -> Option<CiteKeyHit> {
    cite_key_at_byte_offset(source, utf16_offset_to_byte(source, utf16_offset), syntax)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typst_at(src: &str, off: usize) -> Option<String> {
        cite_key_at_byte_offset(src, off, CitationSyntax::Typst).map(|h| h.key)
    }

    #[test]
    fn typst_hit_span_covers_the_sigil_and_the_key() {
        // 0123456789
        // see @abc.
        let src = "see @abc.";
        assert_eq!(typst_at(src, 3), None, "the space before @ is not a hit");
        assert_eq!(typst_at(src, 4).as_deref(), Some("abc"), "the @ itself");
        assert_eq!(typst_at(src, 5).as_deref(), Some("abc"));
        assert_eq!(typst_at(src, 7).as_deref(), Some("abc"), "last key char");
        assert_eq!(typst_at(src, 8), None, "one past the key is after it");
    }

    #[test]
    fn typst_prefers_the_longest_key_when_two_share_a_prefix() {
        let src = "@abc and @abcdef";
        assert_eq!(typst_at(src, 12).as_deref(), Some("abcdef"));
        assert_eq!(typst_at(src, 1).as_deref(), Some("abc"));
    }

    #[test]
    fn typst_excluded_annotations_are_not_citations() {
        // The macOS Swift scanner has no exclusion list and previews these as
        // citations; deriving from the canonical scanner inherits the list.
        for src in ["@param foo", "@example x", "@deprecated"] {
            assert_eq!(
                typst_at(src, 2),
                None,
                "{src:?} is an annotation, not a citation"
            );
        }
    }

    #[test]
    fn typst_email_addresses_are_not_citations() {
        let src = "write to ada@example.org";
        assert_eq!(typst_at(src, 14), None);
    }

    #[test]
    fn latex_hit_span_is_the_key_inside_the_braces() {
        //          1         2
        // 0123456789012345678901
        // We cite \cite{smith24}.
        let src = "We cite \\cite{smith24}.";
        let at = |o: usize| cite_key_at_byte_offset(src, o, CitationSyntax::Latex).map(|h| h.key);
        assert_eq!(at(10), None, "the command name is not the target");
        assert_eq!(at(13), None, "the opening brace is not the target");
        assert_eq!(at(14).as_deref(), Some("smith24"));
        assert_eq!(at(20).as_deref(), Some("smith24"));
        assert_eq!(at(21), None, "the closing brace is not the target");
    }

    #[test]
    fn latex_grouped_keys_resolve_per_key() {
        let src = "\\citep{a2020, b2021}";
        let at = |o: usize| cite_key_at_byte_offset(src, o, CitationSyntax::Latex).map(|h| h.key);
        assert_eq!(at(7).as_deref(), Some("a2020"));
        assert_eq!(at(12), None, "the comma separates the two keys");
        assert_eq!(at(14).as_deref(), Some("b2021"));
    }

    #[test]
    fn utf16_offsets_survive_astral_characters() {
        // "𝄞" is one char, 4 bytes, 2 UTF-16 code units.
        let src = "𝄞 @abc";
        let byte_of_at = src.find('@').unwrap();
        assert_eq!(byte_of_at, 5);
        let utf16_of_at = byte_offset_to_utf16(src, byte_of_at);
        assert_eq!(utf16_of_at, 3, "2 units for 𝄞 + 1 for the space");
        assert_eq!(
            cite_key_at_utf16_offset(src, utf16_of_at, CitationSyntax::Typst).map(|h| h.key),
            Some("abc".to_string())
        );
        // And a round trip.
        assert_eq!(utf16_offset_to_byte(src, utf16_of_at), byte_of_at);
    }

    #[test]
    fn out_of_range_offsets_are_misses_not_panics() {
        let src = "@abc";
        assert_eq!(typst_at(src, 999), None);
        assert_eq!(
            cite_key_at_utf16_offset(src, 999, CitationSyntax::Typst),
            None
        );
        assert_eq!(cite_key_at_byte_offset("", 0, CitationSyntax::Mixed), None);
    }

    #[test]
    fn hits_enumerate_in_source_order_with_both_spans() {
        let src = "@alpha then \\cite{beta}";
        let hits = cite_key_hits(src, CitationSyntax::Mixed);
        let keys: Vec<&str> = hits.iter().map(|h| h.key.as_str()).collect();
        assert_eq!(keys, vec!["alpha", "beta"]);

        let alpha = &hits[0];
        assert_eq!(alpha.key_byte_offset, 1, "the key starts after the @");
        assert_eq!(alpha.hit_byte_offset, 0, "the hit span includes the @");
        assert_eq!(alpha.hit_byte_len, alpha.key_byte_len + 1);

        let beta = &hits[1];
        assert_eq!(
            beta.hit_byte_offset, beta.key_byte_offset,
            "LaTeX hit span is the key span"
        );
        assert_eq!(&src[beta.hit_byte_range()], "beta");
    }
}
