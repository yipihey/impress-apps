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
use std::collections::HashMap;

use super::entry::{BibTeXEntry, BibTeXEntryType};

/// Parse error information
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct BibTeXParseError {
    pub line: u32,
    pub column: u32,
    pub message: String,
}

/// Result of parsing a BibTeX file
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct BibTeXParseResult {
    pub entries: Vec<BibTeXEntry>,
    pub preambles: Vec<String>,
    pub strings: HashMap<String, String>,
    pub errors: Vec<BibTeXParseError>,
}

/// Error type for parsing failures
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error))]
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

/// Parse a BibTeX string
pub fn parse(input: String) -> Result<BibTeXParseResult, ParseError> {
    parse_bibtex(&input)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn parse_ffi(input: String) -> Result<BibTeXParseResult, ParseError> {
    parse(input)
}

/// Parse a single BibTeX entry
pub fn parse_entry(input: String) -> Result<BibTeXEntry, ParseError> {
    let result = parse_bibtex(&input)?;
    result
        .entries
        .into_iter()
        .next()
        .ok_or(ParseError::InvalidSyntax)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn parse_entry_ffi(input: String) -> Result<BibTeXEntry, ParseError> {
    parse_entry(input)
}

/// Internal parsing function
fn parse_bibtex(input: &str) -> Result<BibTeXParseResult, ParseError> {
    let mut result = BibTeXParseResult {
        entries: Vec::new(),
        preambles: Vec::new(),
        strings: HashMap::new(),
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
            match parse_at_entry(remaining, &result.strings) {
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
                        AtEntry::Comment => {}
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

    Ok(result)
}

/// Result of parsing an @ entry
enum AtEntry {
    Entry(BibTeXEntry),
    String(String, String),
    Preamble(String),
    Comment,
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
) -> IResult<&'a str, AtEntry> {
    let (rest, _) = char('@')(input)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, entry_type) = take_while1(|c: char| c.is_ascii_alphanumeric())(rest)?;

    match entry_type.to_lowercase().as_str() {
        "string" => {
            let (rest, (key, value)) = parse_string_definition(rest, strings)?;
            Ok((rest, AtEntry::String(key, value)))
        }
        "preamble" => {
            let (rest, text) = parse_preamble(rest, strings)?;
            Ok((rest, AtEntry::Preamble(text)))
        }
        "comment" => {
            let (rest, _) = parse_comment_body(rest)?;
            Ok((rest, AtEntry::Comment))
        }
        _ => {
            let (rest, entry) = parse_entry_body(rest, entry_type, strings)?;
            Ok((rest, AtEntry::Entry(entry)))
        }
    }
}

/// Parse a @string definition
fn parse_string_definition<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
) -> IResult<&'a str, (String, String)> {
    let (rest, _) = multispace0(input)?;
    let (rest, _) = char('{')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, key) =
        take_while1(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char('=')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, value) = parse_field_value(rest, strings)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char('}')(rest)?;

    Ok((rest, (key.to_string(), value)))
}

/// Parse a @preamble
fn parse_preamble<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
) -> IResult<&'a str, String> {
    let (rest, _) = multispace0(input)?;
    let (rest, _) = char('{')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, value) = parse_field_value(rest, strings)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char('}')(rest)?;

    Ok((rest, value))
}

/// Parse a @comment body (skip everything in braces or to end of line)
fn parse_comment_body(input: &str) -> IResult<&str, ()> {
    let (rest, _) = multispace0(input)?;
    if rest.starts_with('{') {
        let (rest, _) = parse_braced_content(rest)?;
        Ok((rest, ()))
    } else {
        // Skip to end of line
        let pos = rest.find('\n').unwrap_or(rest.len());
        Ok((&rest[pos..], ()))
    }
}

/// Parse an entry body
fn parse_entry_body<'a>(
    input: &'a str,
    entry_type: &str,
    strings: &HashMap<String, String>,
) -> IResult<&'a str, BibTeXEntry> {
    let (rest, _) = multispace0(input)?;
    let (rest, _) = char('{')(rest)?;
    let (rest, _) = multispace0(rest)?;

    // Parse cite key
    let (rest, cite_key) =
        take_while1(|c: char| c.is_ascii_alphanumeric() || "_-:./".contains(c))(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char(',')(rest)?;

    // Parse fields
    let (rest, fields) = parse_fields(rest, strings)?;

    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char('}')(rest)?;

    let mut entry = BibTeXEntry::new(cite_key.to_string(), BibTeXEntryType::from_str(entry_type));
    for (key, value) in fields {
        entry.add_field(key, value);
    }

    Ok((rest, entry))
}

/// Parse fields within an entry
fn parse_fields<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
) -> IResult<&'a str, Vec<(String, String)>> {
    let mut fields = Vec::new();
    let mut remaining = input;

    loop {
        let (rest, _) = multispace0(remaining)?;

        // Check for end of entry
        if rest.starts_with('}') {
            return Ok((rest, fields));
        }

        // Try to parse a field
        match parse_single_field(rest, strings) {
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
) -> IResult<&'a str, (String, String)> {
    let (rest, _) = multispace0(input)?;
    let (rest, key) =
        take_while1(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, _) = char('=')(rest)?;
    let (rest, _) = multispace0(rest)?;
    let (rest, value) = parse_field_value(rest, strings)?;

    Ok((rest, (key.to_string(), value)))
}

/// Parse a field value (braced, quoted, number, or string reference)
fn parse_field_value<'a>(
    input: &'a str,
    strings: &HashMap<String, String>,
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
                    // String reference
                    strings.get(s).cloned().unwrap_or_else(|| s.to_string())
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
            b'\\' => {
                // Skip escaped character
                pos += 1;
            }
            _ => {}
        }
        pos += 1;
    }

    Err(nom::Err::Error(nom::error::Error::new(
        input,
        nom::error::ErrorKind::Char,
    )))
}

/// Parse a quoted value "content"
fn parse_quoted_value(input: &str) -> IResult<&str, String> {
    if !input.starts_with('"') {
        return Err(nom::Err::Error(nom::error::Error::new(
            input,
            nom::error::ErrorKind::Char,
        )));
    }

    let mut result = String::new();
    let mut pos = 1; // Skip opening quote
    let bytes = input.as_bytes();
    let mut brace_depth = 0;

    while pos < bytes.len() {
        match bytes[pos] {
            b'"' if brace_depth == 0 => {
                return Ok((&input[pos + 1..], result));
            }
            b'{' => {
                brace_depth += 1;
                result.push('{');
            }
            b'}' => {
                brace_depth -= 1;
                result.push('}');
            }
            b'\\' if pos + 1 < bytes.len() => {
                // Handle escape sequences
                result.push('\\');
                pos += 1;
                result.push(bytes[pos] as char);
            }
            c => {
                result.push(c as char);
            }
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
}
