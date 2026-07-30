//! RFC 2045 / 2047 primitives for imbib's mbox archive format.
//!
//! Ported from `PublicationManagerCore/Mbox/MIMEDecoder.swift` (375 lines) in
//! Stage 7 item 9. Behaviour is pinned by
//! `test_fixtures/golden/mime_*.json`, captured from the Swift original before
//! its body became a shim.
//!
//! # Why this is not `impart-core::mime`
//!
//! `crates/impart-core/src/mime.rs` parses *live IMAP mail* with `mailparse`,
//! and is spec-correct by delegation. This module parses **imbib's own export
//! format** plus whatever third-party mbox a researcher drags in, and it has to
//! reproduce a decade of `MIMEDecoder`'s decisions about malformed input —
//! including the ones that are wrong. Pointing imbib's importer at `mailparse`
//! would change what every existing archive imports as, silently, with no test
//! able to tell you. The two are kept separate deliberately; see
//! `docs/parser-batch-swift-rust-split.md`.
//!
//! # The one thing that was fixed rather than reproduced
//!
//! Swift's `quotedPrintableDecode` builds `Character(UnicodeScalar(byte))` per
//! `=XX` octet — **one Latin-1 scalar per byte** — so a UTF-8 sequence decodes
//! to mojibake. Since `MIMEEncoder` writes bodies as
//! `Content-Transfer-Encoding: quoted-printable` over UTF-8 bytes, imbib's own
//! export → import round trip corrupted every non-ASCII abstract:
//! `Müller` → `MÃ¼ller`. Nothing caught it because the only quoted-printable
//! test in the suite used `=3D`.
//!
//! The fix is structural, not a second implementation:
//! [`quoted_printable_tokens`] makes every decision once and yields a token
//! stream, and the two *renderers* project it. [`render_swift_latin1`]
//! reproduces Swift exactly and is what the golden corpus asserts — so the port
//! is provably faithful. [`render_text`] accumulates the octets and decodes them
//! with the declared charset, and is what ships.

use encoding_rs::{Encoding, ISO_8859_2, UTF_8, WINDOWS_1252};
use lazy_static::lazy_static;
use regex::Regex;
use std::collections::BTreeMap;

// ── Charsets ────────────────────────────────────────────────────────────────

/// Swift `encodingForCharset` — the five charsets `MIMEDecoder` names, and
/// UTF-8 for everything else (including unknown labels).
pub fn encoding_for_charset(charset: &str) -> &'static Encoding {
    match charset.to_ascii_uppercase().as_str() {
        "UTF-8" | "UTF8" => UTF_8,
        // Foundation's `.isoLatin1` is a straight byte→scalar map. `encoding_rs`
        // has no ISO-8859-1 (the WHATWG spec aliases it to windows-1252, which
        // differs in 0x80..=0x9F), so Latin-1 is handled by `decode_latin1`
        // rather than through this table.
        "ISO-8859-1" | "LATIN1" => WINDOWS_1252,
        "ISO-8859-2" | "LATIN2" => ISO_8859_2,
        "US-ASCII" | "ASCII" => UTF_8,
        "WINDOWS-1252" => WINDOWS_1252,
        _ => UTF_8,
    }
}

/// True when the label names ISO-8859-1, which Foundation maps byte-for-byte.
fn is_latin1(charset: &str) -> bool {
    matches!(
        charset.to_ascii_uppercase().as_str(),
        "ISO-8859-1" | "LATIN1"
    )
}

/// Foundation `String(data:encoding:.isoLatin1)` — every byte is its own scalar.
pub fn decode_latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|b| char::from(*b)).collect()
}

/// Decode `bytes` as `charset`, falling back to Latin-1 when the bytes are not
/// valid in it. The fallback matters: a body labelled `utf-8` that actually
/// carries Latin-1 octets is common in old archives, and Foundation's
/// `String(data:encoding:)` would return nil there — which the Swift caller
/// turned into an empty body, losing the text entirely.
pub fn decode_text(bytes: &[u8], charset: &str) -> String {
    if is_latin1(charset) {
        return decode_latin1(bytes);
    }
    let encoding = encoding_for_charset(charset);
    let (cow, _, had_errors) = encoding.decode(bytes);
    if had_errors && encoding == UTF_8 {
        decode_latin1(bytes)
    } else {
        cow.into_owned()
    }
}

// ── Quoted-printable ────────────────────────────────────────────────────────

/// One unit of a quoted-printable decode.
///
/// The distinction is the whole point: a `Literal` came through as source text
/// and a `Byte` came out of a `=XX` escape. Swift conflated them by widening
/// every octet to a scalar; keeping them apart is what lets one tokenizer serve
/// both the parity projection and the correct one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QpToken<'a> {
    /// One source grapheme cluster, verbatim. A cluster and not a `char`
    /// because Swift's `Character` is a cluster — see
    /// [`quoted_printable_tokens`].
    Literal(&'a str),
    /// An octet decoded from `=XX`.
    Byte(u8),
}

/// Decode quoted-printable into tokens, reproducing every branch of Swift's
/// `quotedPrintableDecode`:
///
/// * `=` then `\n` — soft line break, both dropped.
/// * `=` then `\r` then `\n` — soft line break, all three dropped. **Dead in
///   practice**, see below.
/// * `=` then two hex digits — the octet (either case).
/// * `=` then anything else, or fewer than two units left — the `=` is emitted
///   literally and scanning continues at the next unit.
///
/// # Why grapheme clusters
///
/// Swift iterates `String` by `Character`, i.e. by **extended grapheme
/// cluster**, and `"\r\n"` is a single cluster. So `encoded[nextIndex] == "\r"`
/// is *false* for a CRLF: the CRLF branch above is unreachable, the hex attempt
/// consumes the cluster plus one more unit and fails, and `=\r\n` therefore
/// survives verbatim — quoted-printable's own soft line break is not honoured in
/// its canonical CRLF spelling. `chars()` would silently "fix" that and diverge.
/// The golden case `"a=\r\nb"` pins it.
///
/// This is invisible in production only because both callers
/// (`MboxParser.parseContent` and `MIMEDecoder.decode`) normalise CRLF to LF
/// before the decoder runs. It is visible to anyone calling the primitive.
pub fn quoted_printable_tokens(encoded: &str) -> Vec<QpToken<'_>> {
    use unicode_segmentation::UnicodeSegmentation;

    let units: Vec<&str> = encoded.graphemes(true).collect();
    let mut out = Vec::with_capacity(units.len());
    let mut i = 0;
    while i < units.len() {
        let unit = units[i];
        if unit == "=" && i + 1 < units.len() {
            let next = units[i + 1];
            if next == "\n" {
                i += 2;
                continue;
            }
            if next == "\r" && i + 2 < units.len() && units[i + 2] == "\n" {
                i += 3;
                continue;
            }
            // Swift takes `index(nextIndex, offsetBy: 2, limitedBy: endIndex)`,
            // in Character units, so a single remaining unit is not a candidate.
            if i + 3 <= units.len() {
                let hex = format!("{}{}", units[i + 1], units[i + 2]);
                if let Ok(byte) = u8::from_str_radix(&hex, 16) {
                    out.push(QpToken::Byte(byte));
                    i += 3;
                    continue;
                }
            }
        }
        out.push(QpToken::Literal(unit));
        i += 1;
    }
    out
}

/// Project tokens the way Swift did: every `=XX` octet becomes the Latin-1
/// scalar of that byte. **Reproduces the mojibake.** Used by the golden parity
/// suite to prove the tokenizer is faithful; not used in production.
pub fn render_swift_latin1(tokens: &[QpToken<'_>]) -> String {
    let mut out = String::new();
    for token in tokens {
        match token {
            QpToken::Literal(s) => out.push_str(s),
            QpToken::Byte(b) => out.push(char::from(*b)),
        }
    }
    out
}

/// Project tokens correctly: literals keep their UTF-8 encoding, `=XX` octets
/// are accumulated, and the whole octet stream is decoded as `charset`.
pub fn render_text(tokens: &[QpToken<'_>], charset: &str) -> String {
    let mut bytes = Vec::new();
    for token in tokens {
        match token {
            QpToken::Literal(s) => bytes.extend_from_slice(s.as_bytes()),
            QpToken::Byte(b) => bytes.push(*b),
        }
    }
    decode_text(&bytes, charset)
}

/// Swift-compatible entry point, kept only for the golden corpus.
pub fn quoted_printable_decode_swift(encoded: &str) -> String {
    render_swift_latin1(&quoted_printable_tokens(encoded))
}

/// The production entry point: charset-aware quoted-printable decode.
pub fn quoted_printable_decode(encoded: &str, charset: &str) -> String {
    render_text(&quoted_printable_tokens(encoded), charset)
}

// ── Base64 ──────────────────────────────────────────────────────────────────

/// Swift `base64Decode`: strip `\r`, `\n` and spaces, then decode with
/// Foundation's default (padding REQUIRED, no other whitespace tolerated, and
/// `nil` on any error).
pub fn base64_decode(encoded: &str) -> Option<Vec<u8>> {
    use base64::Engine as _;
    let cleaned: String = encoded
        .chars()
        .filter(|c| *c != '\r' && *c != '\n' && *c != ' ')
        .collect();
    // Foundation rejects an unpadded body; `STANDARD` does too.
    base64::engine::general_purpose::STANDARD
        .decode(cleaned)
        .ok()
}

// ── mboxrd ──────────────────────────────────────────────────────────────────

/// Swift `unescapeFromLines`: drop exactly one leading `>` from any line whose
/// run of leading `>` is followed immediately by `From `.
///
/// Note what this does NOT do: `>Fromage`, `>From` (no trailing space) and
/// `> From` are all left alone, because the test is `hasPrefix("From ")` on the
/// remainder after the `>` run. Preserved.
pub fn unescape_from_lines(text: &str) -> String {
    split_keeping_empties(text, '\n')
        .into_iter()
        .map(|line| {
            let gt = line.chars().take_while(|c| *c == '>').count();
            if gt > 0 && line[gt..].starts_with("From ") {
                line.chars().skip(1).collect::<String>()
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Swift `split(separator:omittingEmptySubsequences: false)`.
pub(crate) fn split_keeping_empties(s: &str, sep: char) -> Vec<&str> {
    s.split(sep).collect()
}

// ── Header parameters ───────────────────────────────────────────────────────

/// Swift `extractParameter(from:name:)` — `name="value"` or `name=value`,
/// case-insensitive, first match wins.
///
/// The pattern is unanchored, so `xboundary=` matches a request for
/// `boundary`. Preserved: narrowing it changes which archives import.
pub fn extract_parameter(header_value: &str, name: &str) -> Option<String> {
    let pattern = format!(
        r#"(?i){}\s*=\s*(?:"([^"]*)"|([^;\s]*))"#,
        regex::escape(name)
    );
    let re = Regex::new(&pattern).ok()?;
    let caps = re.captures(header_value)?;
    if let Some(m) = caps.get(1) {
        return Some(m.as_str().to_string());
    }
    caps.get(2).map(|m| m.as_str().to_string())
}

/// Swift `extractBoundary(from:)`.
pub fn extract_boundary(content_type: &str) -> Option<String> {
    extract_parameter(content_type, "boundary")
}

/// Swift `extractBaseContentType` — truncate at `;`, then trim.
pub fn base_content_type(content_type: &str) -> String {
    match content_type.find(';') {
        Some(i) => content_type[..i].trim().to_string(),
        None => content_type.trim().to_string(),
    }
}

/// The `charset=` parameter, defaulting to UTF-8 the way Swift's
/// `encodingForCharset` does for an unknown or absent label.
pub fn charset_of(content_type: &str) -> String {
    extract_parameter(content_type, "charset").unwrap_or_else(|| "UTF-8".to_string())
}

// ── RFC 2047 encoded-words ──────────────────────────────────────────────────

lazy_static! {
    static ref RE_ENCODED_WORD: Regex = Regex::new(r"=\?([^?]+)\?([BbQq])\?([^?]*)\?=").unwrap();
}

/// Swift `decodeHeaderValue` — RFC 2047 `=?charset?B|Q?text?=`.
///
/// Replacements run last-match-first so earlier byte offsets stay valid, which
/// is observable only in that an undecodable word is left in place.
///
/// **Divergence:** Swift routed `Q` through `quotedPrintableDecode` and so
/// ignored the declared charset, decoding `=?UTF-8?Q?M=C3=BCller?=` to
/// `MÃ¼ller`. `B` honoured the charset correctly. This honours it for both.
/// Empirically `Q` is the encoding third-party mailers pick for mostly-ASCII
/// non-English subjects, so the bug hit real titles.
pub fn decode_header_value(value: &str) -> String {
    decode_header_value_inner(value, false)
}

/// Swift-compatible projection, for the golden corpus only.
pub fn decode_header_value_swift(value: &str) -> String {
    decode_header_value_inner(value, true)
}

fn decode_header_value_inner(value: &str, swift_q_semantics: bool) -> String {
    let mut result = value.to_string();
    let matches: Vec<_> = RE_ENCODED_WORD.captures_iter(value).collect();
    for caps in matches.iter().rev() {
        let full = caps.get(0).unwrap();
        let charset = caps.get(1).unwrap().as_str();
        let encoding = caps.get(2).unwrap().as_str().to_ascii_uppercase();
        let text = caps.get(3).unwrap().as_str();

        let decoded: Option<String> = if encoding == "B" {
            base64_decode(text).map(|bytes| {
                if is_latin1(charset) {
                    decode_latin1(&bytes)
                } else {
                    decode_text(&bytes, charset)
                }
            })
        } else {
            // Q: `_` is a space, and a literal `=\n` is dropped, before the
            // ordinary quoted-printable pass.
            let prepared = text.replace('_', " ").replace("=\n", "");
            Some(if swift_q_semantics {
                quoted_printable_decode_swift(&prepared)
            } else {
                quoted_printable_decode(&prepared, charset)
            })
        };

        if let Some(text) = decoded {
            result.replace_range(full.start()..full.end(), &text);
        }
    }
    result
}

// ── Multipart ───────────────────────────────────────────────────────────────

/// A decoded MIME part. Mirrors Swift `MIMEPart`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MimePart {
    pub content_type: String,
    pub transfer_encoding: Option<String>,
    pub filename: Option<String>,
    /// Header names as written; lookups go through [`header`].
    pub headers: BTreeMap<String, String>,
    pub content: Vec<u8>,
}

impl MimePart {
    /// Case-insensitive header lookup.
    ///
    /// **Divergence:** Swift subscripted the dictionary with exact-case keys
    /// (`headers["Content-Type"]`), so a part written with `content-type:` was
    /// treated as having no headers at all. RFC 5322 §1.2.2 makes field names
    /// case-insensitive.
    pub fn header(&self, name: &str) -> Option<&str> {
        header(&self.headers, name)
    }
}

/// Case-insensitive lookup over a captured header map.
pub fn header<'a>(headers: &'a BTreeMap<String, String>, name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

/// Swift `MIMEDecoder.decode(_:boundary:)`.
///
/// Splits on `--<boundary>` and skips any section whose trimmed form is empty
/// or starts with `--` (which is how the closing delimiter and the epilogue are
/// discarded). **Not recursive** — a nested `multipart/alternative` arrives as
/// one part whose content is the inner document verbatim. Preserved: recursing
/// would change which body imbib picks as the abstract for every nested
/// archive already on disk.
pub fn decode_multipart(content: &str, boundary: &str) -> Vec<MimePart> {
    let delimiter = format!("--{boundary}");
    let normalized = content.replace("\r\n", "\n");
    normalized
        .split(delimiter.as_str())
        .filter_map(|section| {
            let trimmed = section.trim_matches(|c: char| c.is_whitespace());
            if trimmed.is_empty() || trimmed.starts_with("--") {
                return None;
            }
            parse_part(trimmed)
        })
        .collect()
}

/// Swift `parsePart` — unfold headers, then decode the body by its
/// `Content-Transfer-Encoding`.
fn parse_part(raw: &str) -> Option<MimePart> {
    let lines = split_keeping_empties(raw, '\n');
    let mut header_lines: Vec<&str> = Vec::new();
    let mut body_start = 0usize;
    for (index, line) in lines.iter().enumerate() {
        if line.is_empty() {
            body_start = index + 1;
            break;
        }
        header_lines.push(line);
    }

    let headers = unfold_headers(&header_lines, true);

    let body: String = if body_start <= lines.len() {
        lines[body_start..].join("\n")
    } else {
        String::new()
    };

    let content_type = header(&headers, "Content-Type")
        .unwrap_or("text/plain")
        .to_string();
    let transfer_encoding = header(&headers, "Content-Transfer-Encoding").map(str::to_string);
    let filename = extract_filename(&headers);
    let charset = charset_of(&content_type);

    let content: Vec<u8> = match transfer_encoding.as_deref().map(str::to_ascii_lowercase) {
        Some(ref e) if e == "base64" => base64_decode(&body).unwrap_or_default(),
        Some(ref e) if e == "quoted-printable" => {
            quoted_printable_decode(&body, &charset).into_bytes()
        }
        _ => body.clone().into_bytes(),
    };

    Some(MimePart {
        content_type: base_content_type(&content_type),
        transfer_encoding,
        filename,
        headers,
        content,
    })
}

/// Swift `extractFilename` — `Content-Disposition; filename=` first, then
/// `Content-Type; name=`, each RFC 2047-decoded. No RFC 2231 `filename*=`
/// support, matching Swift.
fn extract_filename(headers: &BTreeMap<String, String>) -> Option<String> {
    if let Some(disposition) = header(headers, "Content-Disposition") {
        if let Some(name) = extract_parameter(disposition, "filename") {
            return Some(decode_header_value(&name));
        }
    }
    if let Some(content_type) = header(headers, "Content-Type") {
        if let Some(name) = extract_parameter(content_type, "name") {
            return Some(decode_header_value(&name));
        }
    }
    None
}

/// RFC 5322 header unfolding, shared by the part parser and the message parser.
///
/// `trim_names` selects between the two spellings the Swift original used: the
/// part parser trimmed header names, the message parser did not. Kept as a flag
/// rather than unified, because the difference is observable on a header line
/// written as `X-Imbib-Foo : v`.
///
/// A line that is neither a continuation nor contains `:` is DROPPED, and any
/// duplicate name keeps the LAST value. Both preserved.
pub(crate) fn unfold_headers(lines: &[&str], trim_names: bool) -> BTreeMap<String, String> {
    let mut headers = BTreeMap::new();
    let mut current_name: Option<String> = None;
    let mut current_value = String::new();

    for line in lines {
        if line.starts_with(' ') || line.starts_with('\t') {
            current_value.push(' ');
            current_value.push_str(line.trim_matches(is_foundation_ws));
        } else if let Some(colon) = line.find(':') {
            if let Some(name) = current_name.take() {
                headers.insert(name, std::mem::take(&mut current_value));
            }
            let name = &line[..colon];
            current_name = Some(if trim_names {
                name.trim_matches(is_foundation_ws).to_string()
            } else {
                name.to_string()
            });
            current_value = line[colon + 1..].trim_matches(is_foundation_ws).to_string();
        }
    }
    if let Some(name) = current_name {
        headers.insert(name, current_value);
    }
    headers
}

/// Foundation `CharacterSet.whitespaces`, reused from the SmartSearch port so
/// the U+200B disagreement is handled once.
fn is_foundation_ws(c: char) -> bool {
    impress_smart_search::foundation::is_ws(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qp_tokens_split_literals_from_octets() {
        let t = quoted_printable_tokens("a=C3=A9b");
        assert_eq!(
            t,
            vec![
                QpToken::Literal("a"),
                QpToken::Byte(0xC3),
                QpToken::Byte(0xA9),
                QpToken::Literal("b")
            ]
        );
    }

    #[test]
    fn crlf_is_one_grapheme_so_the_soft_break_is_not_honoured() {
        // The Swift quirk, pinned here as well as in the golden corpus: a
        // `chars()`-based tokenizer returns "ab".
        assert_eq!(quoted_printable_decode("a=\r\nb", "UTF-8"), "a=\r\nb");
        // The LF spelling IS honoured.
        assert_eq!(quoted_printable_decode("a=\nb", "UTF-8"), "ab");
    }

    #[test]
    fn the_two_renderers_disagree_exactly_where_swift_was_wrong() {
        let t = quoted_printable_tokens("M=C3=BCller");
        assert_eq!(render_swift_latin1(&t), "MÃ¼ller");
        assert_eq!(render_text(&t, "UTF-8"), "Müller");
    }

    #[test]
    fn latin1_body_survives_both_renderers() {
        // A genuinely Latin-1 body: one octet per character, so Swift's
        // accidental Latin-1 projection was right and the fix agrees.
        let t = quoted_printable_tokens("M=FCller");
        assert_eq!(render_swift_latin1(&t), "Müller");
        assert_eq!(render_text(&t, "ISO-8859-1"), "Müller");
    }

    #[test]
    fn literal_non_ascii_is_not_mangled_by_the_correct_renderer() {
        let t = quoted_printable_tokens("already ü unicode");
        assert_eq!(render_text(&t, "UTF-8"), "already ü unicode");
        assert_eq!(render_swift_latin1(&t), "already ü unicode");
    }

    #[test]
    fn invalid_utf8_octets_fall_back_to_latin1() {
        // `=C3` alone is a truncated UTF-8 lead byte.
        assert_eq!(quoted_printable_decode("=C3", "UTF-8"), "Ã");
    }

    #[test]
    fn soft_breaks_and_bad_escapes() {
        assert_eq!(quoted_printable_decode("a=\nb", "UTF-8"), "ab");
        // The CRLF spelling is NOT a soft break — see
        // `crlf_is_one_grapheme_so_the_soft_break_is_not_honoured`.
        assert_eq!(quoted_printable_decode("=ZZ", "UTF-8"), "=ZZ");
        assert_eq!(quoted_printable_decode("=2", "UTF-8"), "=2");
        assert_eq!(quoted_printable_decode("=", "UTF-8"), "=");
    }

    #[test]
    fn header_lookup_is_case_insensitive_unlike_swift() {
        let mut h = BTreeMap::new();
        h.insert("content-type".to_string(), "text/html".to_string());
        assert_eq!(header(&h, "Content-Type"), Some("text/html"));
    }

    #[test]
    fn q_encoding_honours_the_declared_charset() {
        assert_eq!(decode_header_value("=?UTF-8?Q?M=C3=BCller?="), "Müller");
        // …and the Swift projection still reproduces the bug, for the corpus.
        assert_eq!(
            decode_header_value_swift("=?UTF-8?Q?M=C3=BCller?="),
            "MÃ¼ller"
        );
    }

    #[test]
    fn unknown_encoding_letter_is_not_an_encoded_word() {
        let input = "=?UTF-8?X?unknown?=";
        assert_eq!(decode_header_value(input), input);
    }

    #[test]
    fn boundary_extraction_matches_the_unanchored_swift_pattern() {
        assert_eq!(
            extract_boundary("multipart/mixed; boundary=\"----=_Part_A\""),
            Some("----=_Part_A".to_string())
        );
        // The decoy: `xboundary` satisfies an unanchored `boundary` search.
        assert_eq!(
            extract_boundary("multipart/mixed; xboundary=\"decoy\""),
            Some("decoy".to_string())
        );
    }

    #[test]
    fn from_line_unescaping_is_narrow() {
        assert_eq!(unescape_from_lines(">From a"), "From a");
        assert_eq!(unescape_from_lines(">>From a"), ">From a");
        assert_eq!(unescape_from_lines(">Fromage"), ">Fromage");
        assert_eq!(unescape_from_lines("> From a"), "> From a");
        assert_eq!(unescape_from_lines(">From"), ">From");
    }
}
