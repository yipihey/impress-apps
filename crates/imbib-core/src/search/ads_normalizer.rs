//! ADS query normalization.
//!
//! Port of Swift `ADSQueryNormalizer.swift`. Pure-string transformation that
//! fixes common LLM-generated ADS query mistakes (unquoted multi-word values,
//! missing quotes around `author:Last, F.`, lower-case boolean operators,
//! shorthand prefix expansion, etc.).
//!
//! Rules applied in order:
//!   0. Expand field shorthands: `a:` → `author:`, `t:` → `title:`, `b:` → `bibcode:`.
//!   1. Remove spaces after `field:` qualifier when followed by a value.
//!   2. Quote unquoted author names containing a comma.
//!   3. Quote unquoted multi-word values for text fields.
//!   4. Uppercase boolean operators (`and`/`or`/`not`).
//!   5. Re-order `author:"First Last"` → `author:"Last, F"`.
//!
//! Each rule returns a list of human-readable corrections so the UI can
//! surface them. `Result::was_modified` is true iff anything was rewritten.

use lazy_static::lazy_static;
use regex::Regex;
use std::collections::HashSet;

/// Result of normalization.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizationResult {
    pub corrected_query: String,
    pub corrections: Vec<String>,
}

impl NormalizationResult {
    pub fn was_modified(&self) -> bool {
        !self.corrections.is_empty()
    }
}

/// Normalize an ADS query string.
pub fn normalize(query: &str) -> NormalizationResult {
    let mut current = query.to_string();
    let mut corrections: Vec<String> = Vec::new();

    // Rule 0
    let (s, c) = expand_shorthands(&current);
    current = s;
    corrections.extend(c);

    // Rule 1
    let (s, c) = remove_spaces_after_colons(&current);
    current = s;
    corrections.extend(c);

    // Rule 2
    let (s, c) = quote_unquoted_authors(&current);
    current = s;
    corrections.extend(c);

    // Rule 3
    let (s, c) = quote_multi_word_values(&current);
    current = s;
    corrections.extend(c);

    // Rule 4
    let (s, c) = uppercase_boolean_operators(&current);
    current = s;
    corrections.extend(c);

    // Rule 5
    let (s, c) = fix_author_name_order(&current);
    current = s;
    corrections.extend(c);

    NormalizationResult {
        corrected_query: current,
        corrections,
    }
}

// --- known fields and shorthands ------------------------------------------

lazy_static! {
    static ref ALL_KNOWN_FIELDS: HashSet<&'static str> = {
        let fields = [
            "author", "first_author", "abs", "abstract", "title",
            "year", "bibcode", "doi", "arxiv", "orcid",
            "aff", "affiliation", "inst", "full", "object", "body",
            "ack", "keyword", "identifier", "citations", "references",
            "property", "doctype", "collection", "bibstem",
            "arxiv_class", "aff_id", "orcid_pub", "orcid_user", "orcid_other",
            "pubdate", "volume", "issue", "page", "bibgroup", "grant", "facility",
            "author_count", "citation_count", "read_count", "vizier", "database",
        ];
        fields.iter().copied().collect()
    };

    static ref TEXT_FIELDS: HashSet<&'static str> = {
        ["abs", "title", "object", "full", "body", "aff", "keyword"].iter().copied().collect()
    };

    // Single-letter shortcuts.
    static ref SHORTHANDS: Vec<(&'static str, &'static str)> = vec![
        ("a", "author"),
        ("t", "title"),
        ("b", "bibcode"),
    ];
}

// --- Rule 0: expand shorthands --------------------------------------------

fn expand_shorthands(query: &str) -> (String, Vec<String>) {
    let mut result = query.to_string();
    let mut corrections = Vec::new();

    for (short, full) in SHORTHANDS.iter() {
        // (?<!\w)short:(?=\S) — word boundary lookbehind + non-space lookahead.
        // `regex` doesn't support lookaround, so implement it manually with a
        // scan.
        result = expand_one_shorthand(&result, short, full, &mut corrections);
    }

    (result, corrections)
}

fn expand_one_shorthand(input: &str, short: &str, full: &str, corrections: &mut Vec<String>) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    let needle = format!("{}:", short);
    let needle_bytes = needle.as_bytes();

    while i < bytes.len() {
        // Check if this position starts a match.
        let starts_here = i + needle_bytes.len() <= bytes.len()
            && &bytes[i..i + needle_bytes.len()] == needle_bytes;

        if starts_here {
            // Word-char lookbehind: previous byte must not be alphanumeric/_.
            let prev_is_word = i > 0 && is_word_byte(bytes[i - 1]);
            // Lookahead: next byte after the colon must be non-whitespace.
            let next_idx = i + needle_bytes.len();
            let next_is_non_space = next_idx < bytes.len() && !is_space_byte(bytes[next_idx]);

            if !prev_is_word && next_is_non_space {
                out.push_str(full);
                out.push(':');
                corrections.push(format!("Expanded {}: → {}:", short, full));
                i += needle_bytes.len();
                continue;
            }
        }

        // Push the current char (handle multi-byte).
        let ch_len = utf8_char_len(bytes[i]);
        out.push_str(&input[i..i + ch_len]);
        i += ch_len;
    }

    out
}

fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn is_space_byte(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r')
}

fn utf8_char_len(first_byte: u8) -> usize {
    if first_byte < 0x80 { 1 }
    else if first_byte < 0xC0 { 1 } // continuation byte; shouldn't happen at start
    else if first_byte < 0xE0 { 2 }
    else if first_byte < 0xF0 { 3 }
    else { 4 }
}

// --- Rule 1: remove space after colon -------------------------------------

lazy_static! {
    static ref FIELD_COLON_SPACE_RE: Regex = Regex::new(r"(\w+):\s+(?:[^\s])").unwrap();
}

fn remove_spaces_after_colons(query: &str) -> (String, Vec<String>) {
    let mut corrections = Vec::new();
    // We need to verify the field name is known. Iterate matches and rebuild.
    let mut out = String::with_capacity(query.len());
    let mut last_end = 0;

    // Collect matches first (regex doesn't easily let us replace inline based on capture content).
    let captures: Vec<_> = FIELD_COLON_SPACE_RE.captures_iter(query).collect();

    for cap in captures {
        let full_match = cap.get(0).unwrap();
        let field_match = cap.get(1).unwrap();
        let field = field_match.as_str();
        if !ALL_KNOWN_FIELDS.contains(field.to_lowercase().as_str()) {
            continue;
        }

        // Append everything up to but not including the field name.
        out.push_str(&query[last_end..field_match.start()]);
        // Append "field:" (drop the trailing whitespace before the value char).
        out.push_str(field);
        out.push(':');
        // Resume right at the first non-space char (full_match.end()-1: regex consumed 1 char of the value).
        last_end = full_match.end() - 1;
        corrections.push(format!("Removed space after {}:", field));
    }
    out.push_str(&query[last_end..]);
    (out, corrections)
}

// --- Rule 2: quote unquoted authors with commas ---------------------------

lazy_static! {
    static ref AUTHOR_COMMA_RE: Regex = Regex::new(r#"((?:first_)?author):([^"\s]+,\s*[^"\s]+)"#).unwrap();
}

fn quote_unquoted_authors(query: &str) -> (String, Vec<String>) {
    let mut corrections = Vec::new();
    let mut last_end = 0;
    let mut out = String::with_capacity(query.len());

    for cap in AUTHOR_COMMA_RE.captures_iter(query) {
        let full = cap.get(0).unwrap();
        let field = &cap[1];
        let value = &cap[2];
        out.push_str(&query[last_end..full.start()]);
        out.push_str(field);
        out.push(':');
        out.push('"');
        out.push_str(value);
        out.push('"');
        corrections.push(format!("Quoted author name: {}:\"{}\"", field, value));
        last_end = full.end();
    }
    out.push_str(&query[last_end..]);
    (out, corrections)
}

// --- Rule 3: quote multi-word values for text fields ----------------------

#[derive(Debug)]
enum TokenKind {
    FieldValue { field: String, value: String, quoted: bool },
    Word(String),
    Operator(String),
    Paren(String),
}

#[derive(Debug)]
struct Token {
    kind: TokenKind,
    text: String,
    leading_ws: String,
}

fn quote_multi_word_values(query: &str) -> (String, Vec<String>) {
    let mut corrections: Vec<String> = Vec::new();
    let tokens = tokenize_for_quoting(query);
    if tokens.is_empty() {
        return (query.to_string(), corrections);
    }

    let mut out = String::with_capacity(query.len());
    let mut i = 0;
    while i < tokens.len() {
        let token = &tokens[i];
        match &token.kind {
            TokenKind::FieldValue { field, value, quoted } => {
                out.push_str(&token.leading_ws);
                if !quoted && TEXT_FIELDS.contains(field.to_lowercase().as_str()) {
                    // Scan forward collecting bare words.
                    let mut extras: Vec<String> = Vec::new();
                    let mut j = i + 1;
                    while j < tokens.len() {
                        match &tokens[j].kind {
                            TokenKind::Word(w) => {
                                let upper = w.to_uppercase();
                                if upper == "AND" || upper == "OR" || upper == "NOT" {
                                    break;
                                }
                                extras.push(w.clone());
                                j += 1;
                                continue;
                            }
                            _ => break,
                        }
                    }
                    if !extras.is_empty() {
                        let mut full_value = value.clone();
                        for w in &extras {
                            full_value.push(' ');
                            full_value.push_str(w);
                        }
                        out.push_str(field);
                        out.push(':');
                        out.push('"');
                        out.push_str(&full_value);
                        out.push('"');
                        corrections.push(format!("Quoted multi-word value: {}:\"{}\"", field, full_value));
                        i = j;
                        continue;
                    } else {
                        out.push_str(&token.text);
                    }
                } else {
                    out.push_str(&token.text);
                }
            }
            _ => {
                out.push_str(&token.leading_ws);
                out.push_str(&token.text);
            }
        }
        i += 1;
    }

    (out, corrections)
}

fn tokenize_for_quoting(query: &str) -> Vec<Token> {
    let chars: Vec<char> = query.chars().collect();
    let mut tokens = Vec::new();
    let mut pos = 0;

    while pos < chars.len() {
        // Consume leading whitespace.
        let ws_start = pos;
        while pos < chars.len() && chars[pos].is_whitespace() {
            pos += 1;
        }
        let ws: String = chars[ws_start..pos].iter().collect();

        if pos >= chars.len() {
            break;
        }

        // Functional operator: citations(...), references(...), etc.
        if let Some(end) = match_functional_operator(&chars, pos) {
            let text: String = chars[pos..end].iter().collect();
            tokens.push(Token {
                kind: TokenKind::Word(text.clone()),
                text,
                leading_ws: ws,
            });
            pos = end;
            continue;
        }

        // Parentheses.
        if chars[pos] == '(' || chars[pos] == ')' {
            let s = chars[pos].to_string();
            tokens.push(Token {
                kind: TokenKind::Paren(s.clone()),
                text: s,
                leading_ws: ws,
            });
            pos += 1;
            continue;
        }

        // Field:value
        if let Some(fv) = match_field_value(&chars, pos) {
            let text: String = chars[pos..fv.end].iter().collect();
            tokens.push(Token {
                kind: TokenKind::FieldValue {
                    field: fv.field,
                    value: fv.value,
                    quoted: fv.quoted,
                },
                text,
                leading_ws: ws,
            });
            pos = fv.end;
            continue;
        }

        // Bare word — read until whitespace or paren.
        let word_start = pos;
        while pos < chars.len() && !chars[pos].is_whitespace() && chars[pos] != '(' && chars[pos] != ')' {
            pos += 1;
        }
        let word: String = chars[word_start..pos].iter().collect();
        if word.is_empty() {
            continue;
        }
        let upper = word.to_uppercase();
        let kind = if upper == "AND" || upper == "OR" || upper == "NOT" {
            TokenKind::Operator(word.clone())
        } else {
            TokenKind::Word(word.clone())
        };
        tokens.push(Token {
            kind,
            text: word,
            leading_ws: ws,
        });
    }

    tokens
}

struct FieldValueMatch {
    field: String,
    value: String,
    quoted: bool,
    end: usize, // exclusive char-index end
}

fn match_field_value(chars: &[char], start: usize) -> Option<FieldValueMatch> {
    // Match field name (letters/underscore) followed by colon.
    let mut pos = start;
    while pos < chars.len() && (chars[pos].is_alphabetic() || chars[pos] == '_') {
        pos += 1;
    }
    if pos == start || pos >= chars.len() || chars[pos] != ':' {
        return None;
    }
    let field: String = chars[start..pos].iter().collect();
    pos += 1; // skip colon

    if pos >= chars.len() {
        return Some(FieldValueMatch {
            field,
            value: String::new(),
            quoted: false,
            end: pos,
        });
    }

    if chars[pos] == '"' {
        let q_start = pos + 1;
        let mut q_end = q_start;
        while q_end < chars.len() && chars[q_end] != '"' {
            q_end += 1;
        }
        let value: String = chars[q_start..q_end].iter().collect();
        let end = if q_end < chars.len() { q_end + 1 } else { q_end };
        return Some(FieldValueMatch { field, value, quoted: true, end });
    }

    if chars[pos] == '(' {
        let mut depth = 1;
        let mut p = pos + 1;
        while p < chars.len() && depth > 0 {
            if chars[p] == '(' {
                depth += 1;
            } else if chars[p] == ')' {
                depth -= 1;
            }
            p += 1;
        }
        let value: String = chars[pos..p].iter().collect();
        return Some(FieldValueMatch { field, value, quoted: true, end: p });
    }

    let v_start = pos;
    while pos < chars.len() && !chars[pos].is_whitespace() && chars[pos] != '(' && chars[pos] != ')' {
        pos += 1;
    }
    let value: String = chars[v_start..pos].iter().collect();
    Some(FieldValueMatch { field, value, quoted: false, end: pos })
}

fn match_functional_operator(chars: &[char], start: usize) -> Option<usize> {
    let names = ["citations", "references", "similar", "trending", "reviews"];
    for name in &names {
        let nchars: Vec<char> = name.chars().collect();
        if start + nchars.len() >= chars.len() {
            continue;
        }
        let slice = &chars[start..start + nchars.len()];
        let matches = slice.iter().zip(nchars.iter()).all(|(a, b)| a == b);
        if !matches {
            continue;
        }
        let after = start + nchars.len();
        if after >= chars.len() || chars[after] != '(' {
            continue;
        }
        // Find matching paren.
        let mut depth = 1;
        let mut p = after + 1;
        while p < chars.len() && depth > 0 {
            if chars[p] == '(' { depth += 1; }
            else if chars[p] == ')' { depth -= 1; }
            p += 1;
        }
        return Some(p);
    }
    None
}

// --- Rule 4: uppercase boolean operators ----------------------------------

lazy_static! {
    static ref BOOL_OP_RE: Regex = Regex::new(r#"(?i)(?:^|[^"\w])(and|or|not)(?:$|[^"\w])"#).unwrap();
}

fn uppercase_boolean_operators(query: &str) -> (String, Vec<String>) {
    // The regex matches the operator with surrounding context; we want to
    // uppercase only the operator capture. Walk matches and rebuild.
    let mut out = String::with_capacity(query.len());
    let mut last_end = 0;
    let mut corrections = Vec::new();

    for cap in BOOL_OP_RE.captures_iter(query) {
        let g = cap.get(1).unwrap();
        let op = g.as_str();
        if op.chars().any(|c| c.is_ascii_lowercase()) {
            // Push everything up to the operator.
            out.push_str(&query[last_end..g.start()]);
            let upper = op.to_uppercase();
            corrections.push(format!("Uppercased operator: {} → {}", op, upper));
            out.push_str(&upper);
            last_end = g.end();
        }
    }
    out.push_str(&query[last_end..]);
    (out, corrections)
}

// --- Rule 5: re-order "First Last" → "Last, F" ----------------------------

lazy_static! {
    static ref AUTHOR_NAME_ORDER_RE: Regex =
        Regex::new(r#"((?:first_)?author):"([A-Z][a-z]+)\s+([A-Z][a-z]+)""#).unwrap();
}

fn fix_author_name_order(query: &str) -> (String, Vec<String>) {
    let mut out = String::with_capacity(query.len());
    let mut last_end = 0;
    let mut corrections = Vec::new();

    for cap in AUTHOR_NAME_ORDER_RE.captures_iter(query) {
        let full = cap.get(0).unwrap();
        let field = &cap[1];
        let first = &cap[2];
        let last = &cap[3];
        let initial: String = first.chars().take(1).collect();
        out.push_str(&query[last_end..full.start()]);
        let replacement = format!("{}:\"{}, {}\"", field, last, initial);
        corrections.push(format!(
            "Fixed author order: \"{} {}\" → \"{}, {}\"",
            first, last, last, initial
        ));
        out.push_str(&replacement);
        last_end = full.end();
    }
    out.push_str(&query[last_end..]);
    (out, corrections)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_query_no_changes() {
        let r = normalize("");
        assert_eq!(r.corrected_query, "");
        assert!(!r.was_modified());
    }

    #[test]
    fn well_formed_query_no_changes() {
        let r = normalize("author:\"Einstein, A\" year:1905");
        assert_eq!(r.corrected_query, "author:\"Einstein, A\" year:1905");
        assert!(!r.was_modified());
    }

    #[test]
    fn shorthand_a_expanded() {
        let r = normalize("a:Einstein");
        assert_eq!(r.corrected_query, "author:Einstein");
        assert!(r.was_modified());
        assert!(r.corrections.iter().any(|c| c.contains("a:")));
    }

    #[test]
    fn shorthand_t_expanded() {
        let r = normalize("t:relativity");
        assert_eq!(r.corrected_query, "title:relativity");
    }

    #[test]
    fn shorthand_b_expanded() {
        let r = normalize("b:2023ApJ");
        assert_eq!(r.corrected_query, "bibcode:2023ApJ");
    }

    #[test]
    fn shorthand_not_expanded_inside_word() {
        // "data:foo" should NOT expand `a:` from the middle.
        let r = normalize("data:foo");
        assert_eq!(r.corrected_query, "data:foo");
        assert!(!r.was_modified());
    }

    #[test]
    fn space_after_colon_removed() {
        let r = normalize("title: galaxy");
        assert_eq!(r.corrected_query, "title:galaxy");
        assert!(r.was_modified());
    }

    #[test]
    fn space_after_unknown_field_not_touched() {
        let r = normalize("madeup: galaxy");
        assert_eq!(r.corrected_query, "madeup: galaxy");
    }

    #[test]
    fn unquoted_author_with_comma_gets_quoted() {
        let r = normalize("author:Einstein, A");
        assert_eq!(r.corrected_query, "author:\"Einstein, A\"");
    }

    #[test]
    fn first_author_with_comma_gets_quoted() {
        let r = normalize("first_author:Smith, J");
        assert_eq!(r.corrected_query, "first_author:\"Smith, J\"");
    }

    #[test]
    fn multi_word_text_field_value_gets_quoted() {
        let r = normalize("title:dark energy");
        assert_eq!(r.corrected_query, "title:\"dark energy\"");
    }

    #[test]
    fn multi_word_value_stops_at_boolean() {
        let r = normalize("title:dark energy AND year:2020");
        assert_eq!(r.corrected_query, "title:\"dark energy\" AND year:2020");
    }

    #[test]
    fn identifier_field_value_not_quoted() {
        // bibcode is an identifier field; multi-word follow-up should NOT be
        // attached to it.
        let r = normalize("bibcode:2023ApJ Smith");
        // Smith stays as a bare word.
        assert!(r.corrected_query.starts_with("bibcode:2023ApJ"));
        assert!(r.corrected_query.contains("Smith"));
    }

    #[test]
    fn lowercase_and_uppercased() {
        let r = normalize("title:galaxy and year:2020");
        assert!(r.corrected_query.contains(" AND "));
    }

    #[test]
    fn lowercase_or_uppercased() {
        let r = normalize("title:galaxy or title:nebula");
        assert!(r.corrected_query.contains(" OR "));
    }

    #[test]
    fn already_uppercase_boolean_unchanged() {
        let r = normalize("title:galaxy AND year:2020");
        assert_eq!(r.corrected_query, "title:galaxy AND year:2020");
    }

    #[test]
    fn author_first_last_reordered() {
        let r = normalize("author:\"Albert Einstein\"");
        assert_eq!(r.corrected_query, "author:\"Einstein, A\"");
    }

    #[test]
    fn author_with_comma_not_reordered() {
        let r = normalize("author:\"Einstein, A\"");
        assert_eq!(r.corrected_query, "author:\"Einstein, A\"");
    }

    #[test]
    fn multiple_rules_compose() {
        // Use forms that all rules can actually trigger on:
        //  - `a:Albert` (no space → shorthand expands to author:)
        //  - lower-case `and`
        //  - `title:dark energy` (unquoted multi-word text-field value)
        //  - `author:"Albert Einstein"` later in the query (name reorder)
        let r = normalize("a:Albert and title:dark energy author:\"Marie Curie\"");
        assert!(r.was_modified());
        // Shorthand expanded.
        assert!(r.corrected_query.contains("author:Albert"), "got `{}`", r.corrected_query);
        // Boolean uppercased.
        assert!(r.corrected_query.contains(" AND "), "got `{}`", r.corrected_query);
        // Multi-word title value quoted.
        assert!(r.corrected_query.contains("title:\"dark energy\""), "got `{}`", r.corrected_query);
        // Author name reordered.
        assert!(r.corrected_query.contains("author:\"Curie, M\""), "got `{}`", r.corrected_query);
    }

    #[test]
    fn functional_operator_preserved_as_word() {
        let r = normalize("citations(bibcode:2023ApJ...)");
        // Functional operators should not be picked apart.
        assert!(r.corrected_query.starts_with("citations("));
    }

    #[test]
    fn case_insensitive_field_name_for_space_rule() {
        let r = normalize("TITLE: galaxy");
        assert_eq!(r.corrected_query, "TITLE:galaxy");
    }

    #[test]
    fn quoted_value_preserves_internal_spaces() {
        // Pre-quoted multi-word should not be re-quoted.
        let r = normalize("title:\"already quoted phrase\"");
        assert_eq!(r.corrected_query, "title:\"already quoted phrase\"");
    }

    #[test]
    fn was_modified_flag_reflects_corrections() {
        let r = normalize("a:foo");
        assert!(r.was_modified());

        let r2 = normalize("author:foo");
        assert!(!r2.was_modified());
    }
}
