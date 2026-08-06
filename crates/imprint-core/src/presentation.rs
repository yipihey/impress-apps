//! Structural editing for Typst presentation sources.
//!
//! Imprint presentations use an intentionally small convention on top of
//! ordinary Typst: every graphically reorderable slide is a `#slide(...)[]`
//! call with a stable string `id` and an optional throughline `beat` label.
//! The source remains authoritative; this module only discovers byte spans and
//! moves those spans. It never persists a parallel page order.

use std::collections::{BTreeMap, BTreeSet};

/// One explicitly-addressable slide in a Typst source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PresentationSlide {
    pub id: String,
    pub beat: Option<String>,
    pub title: Option<String>,
    pub order_index: usize,
    /// UTF-8 byte offset of `#slide`.
    pub start: usize,
    /// UTF-8 byte offset one past the slide's closing content bracket.
    pub end: usize,
    /// UTF-16 offsets for AppKit/UIKit text APIs.
    pub start_utf16: usize,
    pub end_utf16: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PresentationError {
    #[error("slide at byte {offset} has malformed arguments or content")]
    MalformedSlide { offset: usize },
    #[error("slide at byte {offset} is missing a non-empty string id")]
    MissingSlideId { offset: usize },
    #[error("duplicate slide id '{0}'")]
    DuplicateSlideId(String),
    #[error("unknown slide id '{0}'")]
    UnknownSlide(String),
    #[error("the requested target is the slide being moved")]
    SameSlide,
    #[error("invalid throughline beat label '{0}'")]
    InvalidBeat(String),
}

#[derive(Debug, Clone)]
struct ParsedSlide {
    public_slide: PresentationSlide,
}

/// Extract `#slide(id: "…", beat: "tl-…", title: "…")[…]` calls.
///
/// Calls inside strings and comments are ignored. Delimiters inside slide
/// arguments/content may be nested. A malformed real `#slide` call is an error
/// rather than something the graphical editor guesses around.
pub fn extract_slides(source: &str) -> Result<Vec<PresentationSlide>, PresentationError> {
    parse_slides(source).map(|slides| slides.into_iter().map(|s| s.public_slide).collect())
}

/// Move `slide_id` immediately before `before_slide_id`, or to the end when
/// the target is `None`. Only slide spans move; the preamble and suffix remain
/// byte-for-byte unchanged. Inter-slide whitespace/comments travel with the
/// slide immediately before them.
pub fn reorder_slide(
    source: &str,
    slide_id: &str,
    before_slide_id: Option<&str>,
) -> Result<String, PresentationError> {
    if before_slide_id == Some(slide_id) {
        return Err(PresentationError::SameSlide);
    }
    let slides = parse_slides(source)?;
    let from = slides
        .iter()
        .position(|s| s.public_slide.id == slide_id)
        .ok_or_else(|| PresentationError::UnknownSlide(slide_id.to_string()))?;
    let target = match before_slide_id {
        Some(id) => Some(
            slides
                .iter()
                .position(|s| s.public_slide.id == id)
                .ok_or_else(|| PresentationError::UnknownSlide(id.to_string()))?,
        ),
        None => None,
    };

    let mut order: Vec<usize> = (0..slides.len()).collect();
    let moved = order.remove(from);
    let insertion = target
        .and_then(|target_index| order.iter().position(|index| *index == target_index))
        .unwrap_or(order.len());
    order.insert(insertion, moved);
    if order.iter().copied().eq(0..slides.len()) {
        return Ok(source.to_string());
    }

    let first = slides
        .first()
        .expect("the moved slide proves the deck is non-empty");
    let last = slides
        .last()
        .expect("the moved slide proves the deck is non-empty");
    let mut chunks = Vec::with_capacity(slides.len());
    for (index, slide) in slides.iter().enumerate() {
        let start = slide.public_slide.start;
        let end = slides
            .get(index + 1)
            .map(|next| next.public_slide.start)
            .unwrap_or(slide.public_slide.end);
        chunks.push(&source[start..end]);
    }

    let mut out = String::with_capacity(source.len() + 2);
    out.push_str(&source[..first.public_slide.start]);
    for index in order {
        let chunk = chunks[index];
        out.push_str(chunk);
        if !chunk.chars().last().is_some_and(char::is_whitespace) {
            out.push_str("\n\n");
        }
    }
    let suffix = &source[last.public_slide.end..];
    if !suffix.is_empty()
        && !out.chars().last().is_some_and(char::is_whitespace)
        && !suffix.chars().next().is_some_and(char::is_whitespace)
    {
        out.push('\n');
    }
    out.push_str(suffix);
    Ok(out)
}

/// Assign a slide to a throughline beat by editing its named `beat` argument.
/// An empty beat clears the association (represented as `beat: ""` when the
/// argument already exists). Existing argument formatting is preserved; a
/// missing non-empty argument is appended.
pub fn set_slide_beat(
    source: &str,
    slide_id: &str,
    beat: &str,
) -> Result<String, PresentationError> {
    if !beat.is_empty()
        && !beat
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return Err(PresentationError::InvalidBeat(beat.to_string()));
    }
    let slides = parse_slides(source)?;
    let slide = slides
        .iter()
        .find(|slide| slide.public_slide.id == slide_id)
        .ok_or_else(|| PresentationError::UnknownSlide(slide_id.to_string()))?;
    let bytes = source.as_bytes();
    let args_start = skip_space(bytes, slide.public_slide.start + b"#slide".len());
    let args_end = matching_delimiter(bytes, args_start, b'(', b')').ok_or(
        PresentationError::MalformedSlide {
            offset: slide.public_slide.start,
        },
    )?;

    let mut out = source.to_string();
    if let Some((value_start, value_end)) =
        find_named_string_value_span(source, args_start + 1, args_end, "beat")
    {
        out.replace_range(value_start..value_end, beat);
    } else if !beat.is_empty() {
        let existing = source[args_start + 1..args_end].trim_end();
        let separator = if existing.is_empty() || existing.ends_with(',') {
            ""
        } else {
            ","
        };
        out.insert_str(args_end, &format!("{separator} beat: \"{beat}\""));
    }
    Ok(out)
}

fn parse_slides(source: &str) -> Result<Vec<ParsedSlide>, PresentationError> {
    let bytes = source.as_bytes();
    let mut candidates = Vec::new();
    let mut i = 0usize;
    let mut state = LexState::Code;
    while i < bytes.len() {
        if advance_lex(bytes, &mut i, &mut state) {
            continue;
        }
        if state == LexState::Code && bytes[i..].starts_with(b"#slide") {
            let after = i + b"#slide".len();
            if after == bytes.len() || !is_identifier_byte(bytes[after]) {
                candidates.push(i);
                i = after;
                continue;
            }
        }
        i += 1;
    }

    let mut out = Vec::with_capacity(candidates.len());
    let mut seen = BTreeSet::new();
    for start in candidates {
        let mut cursor = skip_space(bytes, start + b"#slide".len());
        if bytes.get(cursor) != Some(&b'(') {
            return Err(PresentationError::MalformedSlide { offset: start });
        }
        let args_end = matching_delimiter(bytes, cursor, b'(', b')')
            .ok_or(PresentationError::MalformedSlide { offset: start })?;
        let args = parse_named_string_arguments(source, cursor + 1, args_end)?;
        let id = args
            .get("id")
            .filter(|value| !value.is_empty())
            .cloned()
            .ok_or(PresentationError::MissingSlideId { offset: start })?;
        if !seen.insert(id.clone()) {
            return Err(PresentationError::DuplicateSlideId(id));
        }
        cursor = skip_space(bytes, args_end + 1);
        if bytes.get(cursor) != Some(&b'[') {
            return Err(PresentationError::MalformedSlide { offset: start });
        }
        let content_end = matching_delimiter(bytes, cursor, b'[', b']')
            .ok_or(PresentationError::MalformedSlide { offset: start })?;
        let end = content_end + 1;
        out.push(ParsedSlide {
            public_slide: PresentationSlide {
                id,
                beat: args.get("beat").filter(|value| !value.is_empty()).cloned(),
                title: args.get("title").filter(|value| !value.is_empty()).cloned(),
                order_index: out.len(),
                start,
                end,
                start_utf16: source[..start].encode_utf16().count(),
                end_utf16: source[..end].encode_utf16().count(),
            },
        });
    }
    Ok(out)
}

fn parse_named_string_arguments(
    source: &str,
    start: usize,
    end: usize,
) -> Result<BTreeMap<String, String>, PresentationError> {
    let bytes = source.as_bytes();
    let mut out = BTreeMap::new();
    let mut i = start;
    while i < end {
        i = skip_space_and_commas(bytes, i, end);
        if i >= end {
            break;
        }
        let key_start = i;
        while i < end && is_identifier_byte(bytes[i]) {
            i += 1;
        }
        if key_start == i {
            i += 1;
            continue;
        }
        let key = &source[key_start..i];
        i = skip_space(bytes, i);
        if i >= end || bytes[i] != b':' {
            continue;
        }
        i = skip_space(bytes, i + 1);
        if i >= end || bytes[i] != b'"' {
            continue;
        }
        let (value, next) = parse_string(source, i, end)
            .ok_or(PresentationError::MalformedSlide { offset: start })?;
        if matches!(key, "id" | "beat" | "title") {
            out.insert(key.to_string(), value);
        }
        i = next;
    }
    Ok(out)
}

fn parse_string(source: &str, quote: usize, end: usize) -> Option<(String, usize)> {
    let bytes = source.as_bytes();
    let mut i = quote + 1;
    let mut value = String::new();
    while i < end {
        match bytes[i] {
            b'"' => return Some((value, i + 1)),
            b'\\' if i + 1 < end => {
                let escaped = bytes[i + 1];
                value.push(match escaped {
                    b'n' => '\n',
                    b'r' => '\r',
                    b't' => '\t',
                    b'"' => '"',
                    b'\\' => '\\',
                    other => other as char,
                });
                i += 2;
            }
            _ => {
                let ch = source[i..].chars().next()?;
                value.push(ch);
                i += ch.len_utf8();
            }
        }
    }
    None
}

fn find_named_string_value_span(
    source: &str,
    start: usize,
    end: usize,
    wanted: &str,
) -> Option<(usize, usize)> {
    let bytes = source.as_bytes();
    let mut i = start;
    while i < end {
        i = skip_space_and_commas(bytes, i, end);
        let key_start = i;
        while i < end && is_identifier_byte(bytes[i]) {
            i += 1;
        }
        if key_start == i {
            i += 1;
            continue;
        }
        let key = &source[key_start..i];
        i = skip_space(bytes, i);
        if i >= end || bytes[i] != b':' {
            continue;
        }
        i = skip_space(bytes, i + 1);
        if i >= end || bytes[i] != b'"' {
            continue;
        }
        let value_start = i + 1;
        let (_, next) = parse_string(source, i, end)?;
        if key == wanted {
            return Some((value_start, next - 1));
        }
        i = next;
    }
    None
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LexState {
    Code,
    String,
    LineComment,
    BlockComment(usize),
}

/// Advance one lexical token when the cursor begins a string/comment or is
/// already inside one. Returns true when it consumed bytes.
fn advance_lex(bytes: &[u8], i: &mut usize, state: &mut LexState) -> bool {
    match *state {
        LexState::Code => {
            if bytes.get(*i) == Some(&b'"') {
                *state = LexState::String;
                *i += 1;
                true
            } else if bytes.get(*i..*i + 2) == Some(b"//") {
                *state = LexState::LineComment;
                *i += 2;
                true
            } else if bytes.get(*i..*i + 2) == Some(b"/*") {
                *state = LexState::BlockComment(1);
                *i += 2;
                true
            } else {
                false
            }
        }
        LexState::String => {
            if bytes.get(*i) == Some(&b'\\') {
                *i = (*i + 2).min(bytes.len());
            } else {
                if bytes.get(*i) == Some(&b'"') {
                    *state = LexState::Code;
                }
                *i += 1;
            }
            true
        }
        LexState::LineComment => {
            if bytes.get(*i) == Some(&b'\n') {
                *state = LexState::Code;
            }
            *i += 1;
            true
        }
        LexState::BlockComment(depth) => {
            if bytes.get(*i..*i + 2) == Some(b"/*") {
                *state = LexState::BlockComment(depth + 1);
                *i += 2;
            } else if bytes.get(*i..*i + 2) == Some(b"*/") {
                *state = if depth == 1 {
                    LexState::Code
                } else {
                    LexState::BlockComment(depth - 1)
                };
                *i += 2;
            } else {
                *i += 1;
            }
            true
        }
    }
}

fn matching_delimiter(bytes: &[u8], open_at: usize, open: u8, close: u8) -> Option<usize> {
    let mut depth = 0usize;
    let mut i = open_at;
    let mut state = LexState::Code;
    while i < bytes.len() {
        if advance_lex(bytes, &mut i, &mut state) {
            continue;
        }
        if bytes[i] == open {
            depth += 1;
        } else if bytes[i] == close {
            depth = depth.checked_sub(1)?;
            if depth == 0 {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

fn skip_space(bytes: &[u8], mut i: usize) -> usize {
    while bytes.get(i).is_some_and(u8::is_ascii_whitespace) {
        i += 1;
    }
    i
}

fn skip_space_and_commas(bytes: &[u8], mut i: usize, end: usize) -> usize {
    while i < end && (bytes[i].is_ascii_whitespace() || bytes[i] == b',') {
        i += 1;
    }
    i
}

fn is_identifier_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    const DECK: &str = r#"#let slide(id: "", beat: "", title: "", body) = [#body]

#slide(id: "problem", beat: "tl-why", title: "The problem")[
  A string with a bracket: "[not structural]"
]

// travels with problem
#slide(
  title: "Evidence",
  id: "evidence",
  beat: "tl-result",
)[
  Nested [content]
]
"#;

    #[test]
    fn extracts_stable_slide_metadata_and_offsets() {
        let slides = extract_slides(DECK).unwrap();
        assert_eq!(slides.len(), 2);
        assert_eq!(slides[0].id, "problem");
        assert_eq!(slides[0].beat.as_deref(), Some("tl-why"));
        assert_eq!(slides[0].title.as_deref(), Some("The problem"));
        assert_eq!(&DECK[slides[1].start..slides[1].start + 6], "#slide");
        assert!(slides[0].end_utf16 > slides[0].start_utf16);
    }

    #[test]
    fn ignores_calls_in_comments_and_strings() {
        let source = r##"// #slide(id: "nope")[]
#let example = "#slide(id: \"also-nope\")[]"
#slide(id: "yes")[]
"##;
        assert_eq!(extract_slides(source).unwrap()[0].id, "yes");
    }

    #[test]
    fn reorders_source_blocks_without_touching_preamble() {
        let reordered = reorder_slide(DECK, "evidence", Some("problem")).unwrap();
        assert!(reordered.starts_with("#let slide"));
        assert!(
            reordered.find("id: \"evidence\"").unwrap()
                < reordered.find("id: \"problem\"").unwrap()
        );
        assert_eq!(
            extract_slides(&reordered)
                .unwrap()
                .iter()
                .map(|s| s.id.as_str())
                .collect::<Vec<_>>(),
            vec!["evidence", "problem"]
        );
        assert!(reordered.contains("// travels with problem"));
    }

    #[test]
    fn rejects_duplicate_ids() {
        let err = extract_slides("#slide(id: \"same\")[]\n#slide(id: \"same\")[]").unwrap_err();
        assert_eq!(err, PresentationError::DuplicateSlideId("same".into()));
    }

    #[test]
    fn unicode_offsets_are_utf16_not_bytes() {
        let slides = extract_slides("🧪\n#slide(id: \"one\")[]").unwrap();
        assert_eq!(slides[0].start, 5);
        assert_eq!(slides[0].start_utf16, 3);
    }

    #[test]
    fn assigns_and_replaces_throughline_beat() {
        let assigned = set_slide_beat("#slide(id: \"one\")[]", "one", "tl-method").unwrap();
        assert!(assigned.contains("beat: \"tl-method\""));
        let replaced = set_slide_beat(&assigned, "one", "tl-result").unwrap();
        assert_eq!(
            extract_slides(&replaced).unwrap()[0].beat.as_deref(),
            Some("tl-result")
        );
        assert!(!replaced.contains("tl-method"));
    }

    #[test]
    fn clears_a_beat_without_changing_slide_structure() {
        let source = "#slide(id: \"one\", beat: \"tl-method\")[Body]";
        let cleared = set_slide_beat(source, "one", "").unwrap();
        assert!(cleared.contains("beat: \"\""));
        assert_eq!(extract_slides(&cleared).unwrap()[0].beat, None);
        assert_eq!(
            set_slide_beat("#slide(id: \"one\")[Body]", "one", "").unwrap(),
            "#slide(id: \"one\")[Body]"
        );
    }
}
