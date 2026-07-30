//! mbox archive parsing for imbib's export format.
//!
//! Ported from `PublicationManagerCore/Mbox/MboxParser.swift` (356 lines) in
//! Stage 7 item 9; pinned by `test_fixtures/golden/mbox_parse.json`.
//!
//! Consumers are `MboxImporter` and `EverythingImporter` — the "Import mbox" and
//! "Import Everything archive" paths. Both parsed the whole file into memory
//! already (Swift's `parseStreaming` called `parse` and yielded, so it was never
//! streaming and had no callers at all; it is not ported).

use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};
use lazy_static::lazy_static;
use regex::Regex;
use std::collections::BTreeMap;

use super::mime::{
    self, charset_of, decode_header_value, decode_multipart, extract_boundary, header,
    unescape_from_lines, unfold_headers,
};

// ── Types ───────────────────────────────────────────────────────────────────

/// An attachment carried by an mbox message. Mirrors Swift `MboxAttachment`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MboxAttachment {
    pub filename: String,
    pub content_type: String,
    pub data: Vec<u8>,
    /// `X-Imbib-*` headers only, matching Swift's filter.
    pub custom_headers: BTreeMap<String, String>,
}

/// A parsed mbox message. Mirrors Swift `MboxMessage`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MboxMessage {
    pub from: String,
    pub subject: String,
    /// `None` when the message carried no `Message-ID`. Swift substituted a
    /// fresh UUID here; a parser that invents identity cannot be tested and
    /// cannot be deduplicated against, so the absence is reported instead and
    /// the FFI layer mints the UUID if a caller still wants one.
    pub message_id: Option<String>,
    /// `None` when neither a parseable `Date:` header nor a `From ` envelope
    /// date was present. Swift substituted `Date()` — see `message_id`.
    pub date: Option<DateTime<Utc>>,
    /// `X-Imbib-*` headers only.
    pub headers: BTreeMap<String, String>,
    pub body: String,
    pub attachments: Vec<MboxAttachment>,
}

// ── Splitting ───────────────────────────────────────────────────────────────

lazy_static! {
    /// Swift's message splitter: start-of-string, or a newline, immediately
    /// before `From ` / `>From `. `^` without `anchorsMatchLines` matches only
    /// at offset 0, and the lookahead consumes nothing.
    ///
    /// The `regex` crate has no lookahead, so the `(?=…)` is expressed by
    /// matching the delimiter and then checking the following bytes by hand —
    /// the same technique the SmartSearch port used for the boolean-operator
    /// rule, and for the same reason: folding a lookahead into a consuming
    /// class eats the character the next match needs.
    static ref RE_NEWLINE: Regex = Regex::new(r"\n").unwrap();
}

/// Byte offsets of Swift's zero-width match positions, in order.
///
/// Returns `(match_start, match_end)` pairs: a start-of-file hit is `(0, 0)`
/// and a newline hit is `(i, i + 1)` — the newline is consumed, which is why
/// the message body begins after it.
fn split_positions(normalized: &str) -> Vec<(usize, usize)> {
    let mut positions = Vec::new();
    if starts_a_message(normalized) {
        positions.push((0, 0));
    }
    for m in RE_NEWLINE.find_iter(normalized) {
        let after = m.end();
        if starts_a_message(&normalized[after..]) {
            positions.push((m.start(), after));
        }
    }
    positions
}

/// The lookahead body: `>?From `.
fn starts_a_message(s: &str) -> bool {
    s.starts_with("From ") || s.starts_with(">From ")
}

/// Parse a whole mbox document. Swift `MboxParser.parseContent`.
///
/// Preserved quirks, each observable in the golden corpus:
///
/// * A preamble before the first `From ` line becomes its OWN message, with
///   `from = "unknown@imbib.local"`, no `Message-ID` and no date
///   (`preamble-before-first-from`). Anything a researcher's mail client wrote
///   above the first envelope line therefore imports as a publication.
/// * A section whose trimmed form is empty is skipped.
/// * `parseMessage` was declared `throws` but had no `throw`, and every call
///   site used `try?`, so no input is ever rejected.
pub fn parse_content(content: &str) -> Vec<MboxMessage> {
    let normalized = content.replace("\r\n", "\n");
    let positions = split_positions(&normalized);

    if positions.is_empty() {
        // Swift's no-match branch: only a document that *begins* with a From
        // line yields anything, which cannot happen here (that would have
        // produced a `(0, 0)` position), so the result is empty. Kept explicit
        // because the Swift code's shape invites the opposite conclusion.
        return Vec::new();
    }

    let mut messages = Vec::new();
    let mut last_end = 0usize;

    for (index, (start, after)) in positions.iter().enumerate() {
        // Text between the previous message's end and this delimiter. Only ever
        // non-empty for the leading preamble.
        if last_end < *start {
            let section = &normalized[last_end..*start];
            if !section.trim_matches(is_ws_nl).is_empty() {
                messages.push(parse_message(section));
            }
        }

        let body_start = *after;
        let body_end = match positions.get(index + 1) {
            Some((next_start, _)) => *next_start,
            None => normalized.len(),
        };
        let section = &normalized[body_start..body_end];
        if !section.trim_matches(is_ws_nl).is_empty() {
            messages.push(parse_message(section));
        }
        last_end = body_end;
    }

    if last_end < normalized.len() {
        let remaining = &normalized[last_end..];
        if !remaining.trim_matches(is_ws_nl).is_empty() {
            messages.push(parse_message(remaining));
        }
    }

    messages
}

fn is_ws_nl(c: char) -> bool {
    impress_smart_search::foundation::is_ws_nl(c)
}

// ── One message ─────────────────────────────────────────────────────────────

fn parse_message(content: &str) -> MboxMessage {
    let mut lines = mime::split_keeping_empties(content, '\n');

    // The `From ` envelope line, when present. Note the test is `hasPrefix`
    // on `"From "`, so a `>From ` envelope line is NOT recognised and falls
    // through into the header block, where the time in the date supplies a
    // colon and it parses as a bogus header. Preserved.
    let mut from_line_date = None;
    if lines.first().is_some_and(|l| l.starts_with("From ")) {
        from_line_date = parse_from_line_date(lines[0]);
        lines.remove(0);
    }

    // Header block: everything up to the first empty line. When there is no
    // empty line, `header_end` stays 0 and the body becomes the whole message
    // INCLUDING its headers. Preserved (`no-blank-line-before-body`) — the
    // input is a truncated message and there is no right answer, so the
    // existing one stands.
    let mut header_end = 0usize;
    let mut header_lines: Vec<&str> = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        if line.is_empty() {
            header_end = index + 1;
            break;
        }
        header_lines.push(line);
    }
    let headers = unfold_headers(&header_lines, false);

    let from = header(&headers, "From")
        .unwrap_or("unknown@imbib.local")
        .to_string();
    let subject = decode_header_value(header(&headers, "Subject").unwrap_or(""));
    let message_id = header(&headers, "Message-ID").map(extract_message_id);
    let date = parse_rfc2822_date(header(&headers, "Date")).or(from_line_date);

    let body_content = lines[header_end..].join("\n");
    let content_type = header(&headers, "Content-Type").unwrap_or("text/plain");

    let mut body = String::new();
    let mut attachments = Vec::new();

    // Swift's test is `contentType.lowercased().contains("multipart/")` on the
    // WHOLE header value, parameters included — not on the base type. An
    // unanchored `contains` on the full value is wider than it looks
    // (`name="multipart/notes.txt"` would qualify), and it is what shipped.
    if content_type.to_ascii_lowercase().contains("multipart/") {
        // A `multipart/*` Content-Type with no `boundary=` parameter loses the
        // body entirely. Preserved (`multipart-missing-boundary-param`).
        if let Some(boundary) = extract_boundary(content_type) {
            for part in decode_multipart(&body_content, &boundary) {
                let is_inline_text = part
                    .content_type
                    .to_ascii_lowercase()
                    .starts_with("text/plain")
                    && part.filename.is_none();
                if is_inline_text {
                    body = unescape_from_lines(&String::from_utf8_lossy(&part.content));
                } else if let Some(filename) = part.filename.clone() {
                    attachments.push(MboxAttachment {
                        filename,
                        content_type: part.content_type.clone(),
                        data: part.content.clone(),
                        custom_headers: imbib_headers(&part.headers),
                    });
                }
            }
        }
    } else {
        let charset = charset_of(content_type);
        let transfer = header(&headers, "Content-Transfer-Encoding")
            .map(str::to_ascii_lowercase)
            .unwrap_or_default();
        body = match transfer.as_str() {
            "quoted-printable" => mime::quoted_printable_decode(&body_content, &charset),
            "base64" => mime::base64_decode(&body_content)
                .map(|bytes| mime::decode_text(&bytes, &charset))
                .unwrap_or_default(),
            _ => body_content.clone(),
        };
        body = unescape_from_lines(&body);
    }

    MboxMessage {
        from: decode_header_value(&from),
        subject,
        message_id,
        date,
        headers: imbib_headers(&headers),
        body,
        attachments,
    }
}

/// Swift's `X-Imbib-` filter. Case-SENSITIVE on the prefix, matching Swift —
/// imbib writes the canonical spelling and nothing else should be claiming this
/// namespace.
fn imbib_headers(headers: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    headers
        .iter()
        .filter(|(k, _)| k.starts_with("X-Imbib-"))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}

/// Swift `extractMessageID`: strip one leading `<` and one trailing `>`, then
/// truncate at the first `@`. So `<abc@imbib.local>` becomes `abc`, and the
/// domain is discarded — which means two archives that reused a local part
/// collide. Preserved: the value is persisted and changing it would orphan
/// every existing dedup match.
fn extract_message_id(value: &str) -> String {
    let mut id = value.trim_matches(|c: char| impress_smart_search::foundation::is_ws(c));
    id = id.strip_prefix('<').unwrap_or(id);
    id = id.strip_suffix('>').unwrap_or(id);
    match id.find('@') {
        Some(i) => id[..i].to_string(),
        None => id.to_string(),
    }
}

// ── Dates ───────────────────────────────────────────────────────────────────

/// Drop a leading RFC 5322 day-of-week token (`Thu, ` or `Thu `).
///
/// **This is a Foundation emulation, not a convenience.** `DateFormatter` with
/// `EEE` parses the weekday name and then *ignores* whether it agrees with the
/// date, while `chrono` rejects the combination as `Impossible`. Real mbox files
/// are full of wrong weekdays — the golden corpus caught it on its very first
/// run, because `Thu, 01 Jan 2024` is a Monday and every date in the corpus
/// therefore came back `None` from a `%a`-bearing format. Stripping the token
/// and never validating it is what Foundation does.
fn strip_weekday(s: &str) -> &str {
    let trimmed = s.trim();
    let bytes = trimmed.as_bytes();
    if bytes.len() > 4 && bytes[..3].iter().all(u8::is_ascii_alphabetic) {
        if bytes[3] == b',' && bytes[4] == b' ' {
            return trimmed[5..].trim_start();
        }
        if bytes[3] == b' ' {
            return trimmed[4..].trim_start();
        }
    }
    trimmed
}

/// Swift `parseFromLineDate`: split the envelope line into at most 3 parts and
/// parse the remainder as `EEE MMM dd HH:mm:ss yyyy`.
///
/// **Divergence (environmental):** the Swift `DateFormatter` carried no
/// timezone, so it used the *device's* zone — the same archive imported to a
/// different wall-clock date in Berlin than in California. This reads it as UTC.
/// The goldens were captured under `TZ=UTC`, so they agree.
fn parse_from_line_date(line: &str) -> Option<DateTime<Utc>> {
    let mut parts = line.splitn(3, ' ');
    let _from = parts.next()?;
    let _addr = parts.next()?;
    let date_string = strip_weekday(parts.next()?);
    let naive = NaiveDateTime::parse_from_str(date_string, "%b %d %H:%M:%S %Y").ok()?;
    Some(Utc.from_utc_datetime(&naive))
}

/// Swift `parseRFC2822Date`: three `DateFormatter` shapes, in order.
///
/// * `EEE, dd MMM yyyy HH:mm:ss Z` — numeric offset.
/// * `EEE, dd MMM yyyy HH:mm:ss z` — named zone (`GMT`, `UTC`).
/// * `dd MMM yyyy HH:mm:ss Z` — no weekday.
///
/// All three collapse to one format here once the weekday is stripped, because
/// the weekday is decorative (see [`strip_weekday`]) and Foundation's `Z` and
/// `z` both accept the numeric form.
fn parse_rfc2822_date(value: Option<&str>) -> Option<DateTime<Utc>> {
    let s = strip_weekday(value?);
    if let Ok(dt) = DateTime::parse_from_str(s, "%d %b %Y %H:%M:%S %z") {
        return Some(dt.with_timezone(&Utc));
    }
    // Foundation's `z` accepts a named zone. `chrono`'s `%Z` parses the name but
    // yields no offset, so the two zones that actually appear are matched
    // literally and read as UTC — which is what they mean.
    for suffix in ["GMT", "UTC", "Z"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(s, &format!("%d %b %Y %H:%M:%S {suffix}"))
        {
            return Some(Utc.from_utc_datetime(&naive));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_message() {
        let msgs = parse_content(concat!(
            "From s@example.com Thu Jan 01 00:00:00 2024\n",
            "From: S <s@example.com>\n",
            "Subject: Title\n",
            "Date: Thu, 01 Jan 2024 00:00:00 +0000\n",
            "Message-ID: <abc@imbib.local>\n\n",
            "the abstract\n"
        ));
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].subject, "Title");
        assert_eq!(msgs[0].message_id.as_deref(), Some("abc"));
        assert_eq!(msgs[0].body.trim(), "the abstract");
    }

    #[test]
    fn preamble_becomes_its_own_message() {
        let msgs = parse_content(concat!(
            "junk preamble\n",
            "From s@example.com Thu Jan 01 00:00:00 2024\n",
            "From: S <s@example.com>\n",
            "Subject: Real\n\n",
            "body\n"
        ));
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].from, "unknown@imbib.local");
        assert!(msgs[0].message_id.is_none());
        assert!(msgs[0].date.is_none());
        assert_eq!(msgs[1].subject, "Real");
    }

    #[test]
    fn lowercase_headers_are_read_unlike_swift() {
        let msgs = parse_content(concat!(
            "From s@example.com Thu Jan 01 00:00:00 2024\n",
            "subject: lowercase works now\n",
            "message-id: <low@x>\n\n",
            "body\n"
        ));
        assert_eq!(msgs[0].subject, "lowercase works now");
        assert_eq!(msgs[0].message_id.as_deref(), Some("low"));
    }

    #[test]
    fn quoted_printable_body_is_no_longer_mojibake() {
        let msgs = parse_content(concat!(
            "From s@example.com Thu Jan 01 00:00:00 2024\n",
            "Subject: QP\n",
            "Content-Type: text/plain; charset=utf-8\n",
            "Content-Transfer-Encoding: quoted-printable\n\n",
            "M=C3=BCller measured 50=25\n"
        ));
        assert_eq!(msgs[0].body.trim(), "Müller measured 50%");
    }

    #[test]
    fn dates_cover_all_three_swift_formats() {
        assert!(parse_rfc2822_date(Some("Mon, 15 Apr 2024 13:45:02 -0700")).is_some());
        assert!(parse_rfc2822_date(Some("Mon, 15 Apr 2024 13:45:02 GMT")).is_some());
        assert!(parse_rfc2822_date(Some("15 Apr 2024 13:45:02 +0000")).is_some());
        assert!(parse_rfc2822_date(Some("yesterday afternoon")).is_none());
    }

    #[test]
    fn message_id_truncates_at_at_sign() {
        assert_eq!(extract_message_id("<abc@imbib.local>"), "abc");
        assert_eq!(extract_message_id("bare-id@somewhere"), "bare-id");
        assert_eq!(extract_message_id("no-at-sign"), "no-at-sign");
    }
}
