//! BibTeX parser implementation using nom
//!
//! This parser handles standard BibTeX format including:
//! - @string definitions
//! - @preamble declarations
//! - @comment sections
//! - All standard entry types
//! - Braced and quoted field values
//! - String concatenation with #
//! - Nested braces in field values

use nom::{
    branch::alt,
    bytes::complete::take_while1,
    character::complete::{char, multispace0},
    combinator::map,
    IResult,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use super::entry::{BibTeXEntry, BibTeXEntryType};

/// Parse error information
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BibTeXParseError {
    pub line: u32,
    pub column: u32,
    pub message: String,
}

/// Result of parsing a BibTeX file
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BibTeXParseResult {
    pub entries: Vec<BibTeXEntry>,
    pub preambles: Vec<String>,
    pub strings: HashMap<String, String>,
    /// `@comment{…}` bodies, in source order.
    ///
    /// Kept because a parse → serialise round trip must not silently delete a
    /// user's comment blocks; the exporter re-emits them.
    pub comments: Vec<String>,
    pub errors: Vec<BibTeXParseError>,
}

/// Error type for parsing failures
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, thiserror::Error)]
pub enum ParseError {
    #[error("Invalid syntax")]
    InvalidSyntax,
    #[error("Unexpected token")]
    UnexpectedToken,
    #[error("Missing required field")]
    MissingField,
    #[error("Invalid entry type")]
    InvalidEntryType,
    #[error("Encoding error")]
    EncodingError,
}

/// Parser options.
///
/// The defaults mirror the behaviour of the Swift `BibTeXParser` this parser
/// replaced (`expandMacros: true, resolveCrossrefs: true`), so the editor
/// round-trip path and the import path cannot disagree. See
/// `crates/imbib-core/tests/golden_parity.rs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParseOptions {
    /// Expand `@string` macros and the built-in month macros in field values.
    pub expand_macros: bool,
    /// Merge fields inherited through `crossref` into the referring entry.
    pub resolve_crossrefs: bool,
}

impl Default for ParseOptions {
    fn default() -> Self {
        Self {
            expand_macros: true,
            resolve_crossrefs: true,
        }
    }
}

/// Built-in month macros, always available even without a `@string` definition.
///
/// BibTeX styles emit `month = sep` unquoted; without this table the value
/// survives as the bare token `sep` and readers see a different month spelling
/// than the one shown in the editor.
const MONTH_MACROS: [(&str, &str); 12] = [
    ("jan", "January"),
    ("feb", "February"),
    ("mar", "March"),
    ("apr", "April"),
    ("may", "May"),
    ("jun", "June"),
    ("jul", "July"),
    ("aug", "August"),
    ("sep", "September"),
    ("oct", "October"),
    ("nov", "November"),
    ("dec", "December"),
];

/// Resolve a bare token to a macro value.
///
/// `@string` definitions win over the built-in months, and lookup is
/// case-insensitive (`@string{Nature = ...}` is referenced as `nature`).
fn lookup_macro(strings: &HashMap<String, String>, name: &str) -> Option<String> {
    if let Some(value) = strings.get(name) {
        return Some(value.clone());
    }
    let lowered = name.to_lowercase();
    if let Some((_, value)) = strings.iter().find(|(k, _)| k.to_lowercase() == lowered) {
        return Some(value.clone());
    }
    MONTH_MACROS
        .iter()
        .find(|(macro_name, _)| *macro_name == lowered)
        .map(|(_, value)| (*value).to_string())
}

/// Parse a BibTeX string with the default options.
pub fn parse(input: String) -> Result<BibTeXParseResult, ParseError> {
    parse_bibtex(&input, ParseOptions::default())
}

/// Parse a BibTeX string with explicit options.
pub fn parse_with_options(
    input: String,
    options: ParseOptions,
) -> Result<BibTeXParseResult, ParseError> {
    parse_bibtex(&input, options)
}

/// Parse a single BibTeX entry
pub fn parse_entry(input: String) -> Result<BibTeXEntry, ParseError> {
    let result = parse_bibtex(&input, ParseOptions::default())?;
    result
        .entries
        .into_iter()
        .next()
        .ok_or(ParseError::InvalidSyntax)
}

/// Merge `crossref` parents into their children.
///
/// The child's own fields win and keep their original order; inherited fields
/// are appended so round-trip serialisation stays stable.
fn resolve_crossrefs(entries: &mut [BibTeXEntry]) {
    let lookup: HashMap<String, Vec<crate::entry::BibTeXField>> = entries
        .iter()
        .map(|e| (e.cite_key.to_lowercase(), e.fields.clone()))
        .collect();

    for entry in entries.iter_mut() {
        let Some(parent_key) = entry.get_field("crossref").map(|s| s.to_lowercase()) else {
            continue;
        };
        let Some(parent_fields) = lookup.get(&parent_key) else {
            continue;
        };
        let own: Vec<String> = entry.fields.iter().map(|f| f.key.to_lowercase()).collect();
        for field in parent_fields {
            if !own.contains(&field.key.to_lowercase()) {
                entry.fields.push(field.clone());
            }
        }
    }
}

/// Internal parsing function
fn parse_bibtex(input: &str, options: ParseOptions) -> Result<BibTeXParseResult, ParseError> {
    let mut result = BibTeXParseResult {
        entries: Vec::new(),
        preambles: Vec::new(),
        strings: HashMap::new(),
        comments: Vec::new(),
        errors: Vec::new(),
    };

    let mut remaining = input;
    let mut current_line = 1u32;

    while !remaining.is_empty() {
        // Skip whitespace and count newlines
        let (rest, skipped) = skip_whitespace_and_comments(remaining);
        current_line += skipped.matches('\n').count() as u32;
        remaining = rest;

        if remaining.is_empty() {
            break;
        }

        // Try to parse an entry
        if remaining.starts_with('@') {
            match parse_at_entry(remaining, &result.strings, options) {
                Ok((rest, entry_result)) => {
                    match entry_result {
                        AtEntry::Entry(mut entry) => {
                            // Calculate raw BibTeX for this entry
                            let consumed = &remaining[..remaining.len() - rest.len()];
                            entry.raw_bibtex = Some(consumed.trim().to_string());
                            result.entries.push(entry);
                        }
                        AtEntry::String(key, value) => {
                            result.strings.insert(key, value);
                        }
                        AtEntry::Preamble(text) => {
                            result.preambles.push(text);
                        }
                        AtEntry::Comment(text) => {
                            result.comments.push(text);
                        }
                    }
                    remaining = rest;
                }
                Err(_) => {
                    // Record error and try to recover
                    result.errors.push(BibTeXParseError {
                        line: current_line,
                        column: 1,
                        message: "Failed to parse entry".to_string(),
                    });
                    // Skip to next @ or end
                    if let Some(pos) = remaining[1..].find('@') {
                        remaining = &remaining[pos + 1..];
                    } else {
                        break;
                    }
                }
            }
        } else {
            // Skip to next @ or end
            if let Some(pos) = remaining.find('@') {
                remaining = &remaining[pos..];
            } else {
                break;
            }
        }
    }

    if options.resolve_crossrefs {
        resolve_crossrefs(&mut result.entries);
    }

    Ok(result)
}

/// Result of parsing an @ entry
enum AtEntry {
    Entry(BibTeXEntry),
    String(String, String),
    Preamble(String),
    Comment(String),
}

/// Skip whitespace and comments, return remaining input and skipped text
fn skip_whitespace_and_comments(input: &str) -> (&str, &str) {
    let mut pos = 0;
    let bytes = input.as_bytes();

    while pos < bytes.len() {
        if bytes[pos].is_ascii_whitespace() {
            pos += 1;
        } else if pos + 1 < bytes.len() && bytes[pos] == b'%' {
            // Line comment
            while pos < bytes.len() && bytes[pos] != b'\n' {
                pos += 1;
            }
        } else {
            break;
        }
    }

    (&input[pos..], &input[..pos])
}

/// Parse an @ entry (entry, string, preamble, or comment)
fn parse_at_entry<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
    options: ParseOptions,
) -> IResult<&'a str, AtEntry> {
    let (rest, _) = char('@')(input)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, entry_type) = take_while1(|c: char| c.is_ascii_alphanumeric())(rest)?;

    match entry_type.to_lowercase().as_str() {
        "string" => {
            let (rest, (key, value)) = parse_string_definition(rest, strings, options)?;
            Ok((rest, AtEntry::String(key, value)))
        }
        "preamble" => {
            let (rest, text) = parse_preamble(rest, strings, options)?;
            Ok((rest, AtEntry::Preamble(text)))
        }
        "comment" => {
            let (rest, text) = parse_comment_body(rest)?;
            Ok((rest, AtEntry::Comment(text)))
        }
        _ => {
            let (rest, entry) = parse_entry_body(rest, entry_type, strings, options)?;
            Ok((rest, AtEntry::Entry(entry)))
        }
    }
}

/// Consume the opening delimiter of an `@…` body, returning the matching closer.
///
/// BibTeX allows `@article{…}` and `@article(…)` interchangeably; BibDesk and
/// several reference managers emit the parenthesised form.
fn open_delimiter(input: &str) -> IResult<&str, char> {
    alt((map(char('{'), |_| '}'), map(char('('), |_| ')')))(input)
}

/// Parse a @string definition
fn parse_string_definition<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
    options: ParseOptions,
) -> IResult<&'a str, (String, String)> {
    let (rest, _) = multispace0(input)?;
    let (rest, closer) = open_delimiter(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, key) =
        take_while1(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char('=')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, value) = parse_field_value(rest, strings, options)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char(closer)(rest)?;

    Ok((rest, (key.to_string(), value)))
}

/// Parse a @preamble
fn parse_preamble<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
    options: ParseOptions,
) -> IResult<&'a str, String> {
    let (rest, _) = multispace0(input)?;
    let (rest, closer) = open_delimiter(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, value) = parse_field_value(rest, strings, options)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char(closer)(rest)?;

    Ok((rest, value))
}

/// Parse a @comment body — braced content, or the rest of the line.
fn parse_comment_body(input: &str) -> IResult<&str, String> {
    let (rest, _) = multispace0(input)?;
    if rest.starts_with('{') {
        let (rest, content) = parse_braced_content(rest)?;
        // Strip the outer braces, keeping the body verbatim.
        Ok((rest, content[1..content.len() - 1].to_string()))
    } else {
        let pos = rest.find('\n').unwrap_or(rest.len());
        Ok((&rest[pos..], rest[..pos].to_string()))
    }
}

/// Parse an entry body
fn parse_entry_body<'a>(
    input: &'a str,
    entry_type: &str,
    strings: &HashMap<String, String>,
    options: ParseOptions,
) -> IResult<&'a str, BibTeXEntry> {
    let (rest, _) = multispace0(input)?;
    let (rest, closer) = open_delimiter(rest)?;
    let (rest, _) = multispace0(rest)?;

    // Parse cite key — any non-whitespace character except the field/entry
    // punctuation (ADS uses & in keys like "2024A&A...686A.276A")
    let (rest, cite_key) =
        take_while1(|c: char| !c.is_ascii_whitespace() && !",{}()=".contains(c))(rest)?;
    let (rest, _) = multispace0(rest)?;

    let mut entry = BibTeXEntry::new(cite_key.to_string(), BibTeXEntryType::from_str(entry_type));

    // An entry may legitimately carry no fields at all: `@misc{key}`.
    if let Some(after) = rest.strip_prefix(closer) {
        return Ok((after, entry));
    }

    let (rest, _) = char(',')(rest)?;

    // Parse fields
    let (rest, fields) = parse_fields(rest, strings, closer, options)?;

    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char(closer)(rest)?;

    for (key, value) in fields {
        entry.add_field(key, value);
    }

    Ok((rest, entry))
}

/// Parse fields within an entry
fn parse_fields<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
    closer: char,
    options: ParseOptions,
) -> IResult<&'a str, Vec<(String, String)>> {
    let mut fields = Vec::new();
    let mut remaining = input;

    loop {
        let (rest, _) = multispace0(remaining)?;

        // Check for end of entry
        if rest.starts_with(closer) {
            return Ok((rest, fields));
        }

        // Try to parse a field
        match parse_single_field(rest, strings, options) {
            Ok((rest, (key, value))) => {
                fields.push((key, value));
                remaining = rest;

                // Skip optional comma
                let (rest, _) = multispace0(remaining)?;
                remaining = rest.strip_prefix(',').unwrap_or(rest);
            }
            Err(_) => {
                // No more fields
                return Ok((remaining, fields));
            }
        }
    }
}

/// Parse a single field (key = value)
fn parse_single_field<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
    options: ParseOptions,
) -> IResult<&'a str, (String, String)> {
    let (rest, _) = multispace0(input)?;
    let (rest, key) =
        take_while1(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char('=')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, value) = parse_field_value(rest, strings, options)?;

    Ok((rest, (key.to_string(), value)))
}

/// Parse a field value (braced, quoted, number, or string reference)
fn parse_field_value<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
    options: ParseOptions,
) -> IResult<&'a str, String> {
    let mut result = String::new();
    let mut remaining = input;

    loop {
        let (rest, _) = multispace0(remaining)?;

        let (rest, part) = alt((
            parse_braced_value,
            parse_quoted_value,
            map(take_while1(|c: char| c.is_ascii_digit()), |s: &str| {
                s.to_string()
            }),
            map(
                take_while1(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-'),
                |s: &str| {
                    // Bare token: a `@string` or built-in month macro reference.
                    if options.expand_macros {
                        lookup_macro(strings, s).unwrap_or_else(|| s.to_string())
                    } else {
                        s.to_string()
                    }
                },
            ),
        ))(rest)?;

        result.push_str(&part);
        remaining = rest;

        // Check for concatenation
        let (rest, _) = multispace0(remaining)?;
        if let Some(stripped) = rest.strip_prefix('#') {
            remaining = stripped;
        } else {
            return Ok((rest, result));
        }
    }
}

/// Parse a braced value {content}
fn parse_braced_value(input: &str) -> IResult<&str, String> {
    let (rest, content) = parse_braced_content(input)?;
    // Remove outer braces
    let inner = &content[1..content.len() - 1];
    Ok((rest, inner.to_string()))
}

/// Parse braced content including nested braces
fn parse_braced_content(input: &str) -> IResult<&str, &str> {
    if !input.starts_with('{') {
        return Err(nom::Err::Error(nom::error::Error::new(
            input,
            nom::error::ErrorKind::Char,
        )));
    }

    let mut depth = 0;
    let mut pos = 0;
    let bytes = input.as_bytes();

    while pos < bytes.len() {
        match bytes[pos] {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Ok((&input[pos + 1..], &input[..pos + 1]));
                }
            }
            b'\\' => pos += skip_escape(bytes, pos),
            _ => {}
        }
        pos += 1;
    }

    Err(nom::Err::Error(nom::error::Error::new(
        input,
        nom::error::ErrorKind::Char,
    )))
}

/// Extra bytes to consume for the escape sequence starting at `pos`.
///
/// `\{` escapes one brace. Real-world `.bib` files (and BibDesk exports) also
/// contain `\\{ … \\}` where the brace is *still* meant literally — treating it
/// as structural leaves the entry permanently unbalanced and the whole record
/// is dropped. One such value (`N\\{z\}` in an abstract) silently cost an entry
/// out of a 374-entry bibliography before this was handled.
fn skip_escape(bytes: &[u8], pos: usize) -> usize {
    debug_assert_eq!(bytes[pos], b'\\');
    // Always consume the escaped character.
    let mut extra = 1;
    if bytes.get(pos + 1) == Some(&b'\\') && matches!(bytes.get(pos + 2), Some(&b'{') | Some(&b'}'))
    {
        extra += 1;
    }
    extra
}

/// Parse a quoted value "content"
fn parse_quoted_value(input: &str) -> IResult<&str, String> {
    if !input.starts_with('"') {
        return Err(nom::Err::Error(nom::error::Error::new(
            input,
            nom::error::ErrorKind::Char,
        )));
    }

    let bytes = input.as_bytes();
    let mut brace_depth: i32 = 0;
    let mut pos = 1; // skip the opening quote

    while pos < bytes.len() {
        match bytes[pos] {
            b'"' if brace_depth == 0 => {
                return Ok((&input[pos + 1..], input[1..pos].to_string()));
            }
            b'{' => brace_depth += 1,
            b'}' => {
                if brace_depth > 0 {
                    brace_depth -= 1;
                }
            }
            b'\\' => pos += skip_escape(bytes, pos),
            _ => {}
        }
        pos += 1;
    }

    Err(nom::Err::Error(nom::error::Error::new(
        input,
        nom::error::ErrorKind::Char,
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_entry() {
        let input = r#"
@article{Smith2024,
    author = {John Smith},
    title = {A Great Paper},
    year = {2024},
    journal = {Nature},
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.errors.len(), 0);

        let entry = &result.entries[0];
        assert_eq!(entry.cite_key, "Smith2024");
        assert_eq!(entry.entry_type, BibTeXEntryType::Article);
        assert_eq!(entry.author(), Some("John Smith"));
        assert_eq!(entry.title(), Some("A Great Paper"));
        assert_eq!(entry.year(), Some("2024"));
    }

    #[test]
    fn test_parse_quoted_values() {
        let input = r#"
@article{Test2024,
    author = "Jane Doe",
    title = "Testing \"Quotes\"",
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].author(), Some("Jane Doe"));
    }

    #[test]
    fn test_parse_nested_braces() {
        let input = r#"
@article{Test2024,
    title = {A {B}ook about {LaTeX}},
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].title(), Some("A {B}ook about {LaTeX}"));
    }

    #[test]
    fn test_parse_string_definitions() {
        let input = r#"
@string{nature = "Nature"}
@article{Test2024,
    journal = nature,
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.strings.get("nature"), Some(&"Nature".to_string()));
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].journal(), Some("Nature"));
    }

    #[test]
    fn test_parse_multiple_entries() {
        let input = r#"
@article{First2024,
    title = {First Paper},
}

@book{Second2024,
    title = {Second Book},
}
"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 2);
        assert_eq!(result.entries[0].cite_key, "First2024");
        assert_eq!(result.entries[1].cite_key, "Second2024");
    }

    #[test]
    fn parse_ads_cite_key_with_ampersand() {
        // ADS exports cite keys like "2024A&A...686A.276A" — the & must be accepted
        let input = r#"@ARTICLE{2024A&A...686A.276A,
       author = {{Ay{\c{c}}oberry}, Emma},
        title = "{A theoretical view}",
      journal = {\aap},
         year = 2024,
          doi = {10.1051/0004-6361/202348170},
       eprint = {2310.03548}
}"#;
        let result = parse(input.to_string()).unwrap();
        assert_eq!(result.entries.len(), 1);
        assert_eq!(result.entries[0].cite_key, "2024A&A...686A.276A");
        assert_eq!(
            result.entries[0]
                .fields
                .iter()
                .find(|f| f.key == "doi")
                .map(|f| f.value.as_str()),
            Some("10.1051/0004-6361/202348170")
        );
    }
}
