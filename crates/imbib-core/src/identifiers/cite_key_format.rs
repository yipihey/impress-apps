//! Cite key format parsing and generation
//!
//! Provides BibDesk-inspired customizable cite key format support.
//! Users can define format strings using specifiers like `%a` (author), `%Y` (year), `%t` (title word).

use std::collections::HashMap;
use unicode_normalization::UnicodeNormalization;

/// Represents a parsed specifier in a cite key format string
#[derive(Debug, Clone, PartialEq)]
pub enum CiteKeySpecifier {
    /// First N author last names (default N=1)
    Author(usize),
    /// All authors (up to 3, then EtAl)
    AllAuthors,
    /// Year with specified digits (2 or 4)
    Year(usize),
    /// First N significant title words (default N=1)
    Title(usize),
    /// Unique letter suffix (a-z)
    UniqueLetter,
    /// Unique number suffix (2, 3, 4, ...)
    UniqueNumber,
    /// Custom field value
    Field(String),
    /// Literal text (not a specifier)
    Literal(String),
}

/// Result of validating a format string
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct CiteKeyFormatValidation {
    /// Whether the format is valid
    pub is_valid: bool,
    /// Error message if invalid, empty if valid
    pub error_message: String,
    /// List of warnings (valid but potentially problematic)
    pub warnings: Vec<String>,
}

/// Error that can occur when parsing a format string
#[derive(Debug, Clone, PartialEq)]
pub struct FormatError {
    pub message: String,
    pub position: usize,
}

impl std::fmt::Display for FormatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} at position {}", self.message, self.position)
    }
}

impl std::error::Error for FormatError {}

/// Parse a format string into a list of specifiers
///
/// # Format Specifiers
///
/// | Specifier | Description |
/// |-----------|-------------|
/// | `%a` | First author last name |
/// | `%a2` | First two author last names |
/// | `%A` | All authors (up to 3, then EtAl) |
/// | `%y` | Year (2 digit) |
/// | `%Y` | Year (4 digit) |
/// | `%t` | First significant title word |
/// | `%T2` | First N title words |
/// | `%u` | Unique letter suffix (a-z) |
/// | `%n` | Unique number suffix |
/// | `%f{field}` | Custom field value |
/// | `%%` | Literal percent sign |
///
/// # Examples
///
/// ```
/// use imbib_core::identifiers::cite_key_format::parse_format;
///
/// let specifiers = parse_format("%a1%Y%t").unwrap();
/// assert_eq!(specifiers.len(), 3);
/// ```
pub fn parse_format(format: &str) -> Result<Vec<CiteKeySpecifier>, FormatError> {
    let mut specifiers = Vec::new();
    let mut chars = format.chars().peekable();
    let mut position = 0;
    let mut literal_buffer = String::new();

    while let Some(c) = chars.next() {
        if c == '%' {
            // Flush any accumulated literal text
            if !literal_buffer.is_empty() {
                specifiers.push(CiteKeySpecifier::Literal(literal_buffer.clone()));
                literal_buffer.clear();
            }

            position += 1;

            match chars.next() {
                Some('%') => {
                    // Escaped percent
                    literal_buffer.push('%');
                    position += 1;
                }
                Some('a') => {
                    // Author specifier - check for count
                    position += 1;
                    let count = parse_number(&mut chars, &mut position).unwrap_or(1);
                    specifiers.push(CiteKeySpecifier::Author(count));
                }
                Some('A') => {
                    // All authors
                    position += 1;
                    specifiers.push(CiteKeySpecifier::AllAuthors);
                }
                Some('y') => {
                    // 2-digit year
                    position += 1;
                    specifiers.push(CiteKeySpecifier::Year(2));
                }
                Some('Y') => {
                    // 4-digit year
                    position += 1;
                    specifiers.push(CiteKeySpecifier::Year(4));
                }
                Some('t') => {
                    // Title word specifier
                    position += 1;
                    specifiers.push(CiteKeySpecifier::Title(1));
                }
                Some('T') => {
                    // Title words specifier - check for count
                    position += 1;
                    let count = parse_number(&mut chars, &mut position).unwrap_or(1);
                    specifiers.push(CiteKeySpecifier::Title(count));
                }
                Some('u') => {
                    // Unique letter suffix
                    position += 1;
                    specifiers.push(CiteKeySpecifier::UniqueLetter);
                }
                Some('n') => {
                    // Unique number suffix
                    position += 1;
                    specifiers.push(CiteKeySpecifier::UniqueNumber);
                }
                Some('f') => {
                    // Custom field
                    position += 1;
                    if chars.next() != Some('{') {
                        return Err(FormatError {
                            message: "Expected '{' after %f".to_string(),
                            position,
                        });
                    }
                    position += 1;

                    let mut field_name = String::new();
                    loop {
                        match chars.next() {
                            Some('}') => {
                                position += 1;
                                break;
                            }
                            Some(c) => {
                                field_name.push(c);
                                position += 1;
                            }
                            None => {
                                return Err(FormatError {
                                    message: "Unclosed field specifier".to_string(),
                                    position,
                                });
                            }
                        }
                    }

                    if field_name.is_empty() {
                        return Err(FormatError {
                            message: "Empty field name".to_string(),
                            position,
                        });
                    }

                    specifiers.push(CiteKeySpecifier::Field(field_name));
                }
                Some(c) => {
                    return Err(FormatError {
                        message: format!("Unknown specifier: %{}", c),
                        position,
                    });
                }
                None => {
                    return Err(FormatError {
                        message: "Incomplete specifier at end of format".to_string(),
                        position,
                    });
                }
            }
        } else {
            literal_buffer.push(c);
            position += 1;
        }
    }

    // Flush remaining literal text
    if !literal_buffer.is_empty() {
        specifiers.push(CiteKeySpecifier::Literal(literal_buffer));
    }

    Ok(specifiers)
}

/// Parse a number from the character stream
fn parse_number(
    chars: &mut std::iter::Peekable<std::str::Chars>,
    position: &mut usize,
) -> Option<usize> {
    let mut num_str = String::new();

    while let Some(&c) = chars.peek() {
        if c.is_ascii_digit() {
            num_str.push(c);
            chars.next();
            *position += 1;
        } else {
            break;
        }
    }

    if num_str.is_empty() {
        None
    } else {
        num_str.parse().ok()
    }
}

/// Generate a cite key using the specified format
///
/// # Arguments
///
/// * `format` - The format string to use
/// * `author` - The author string (may contain multiple authors separated by "and")
/// * `year` - The publication year
/// * `title` - The publication title
/// * `fields` - Additional fields that can be referenced via `%f{field}`
///
/// # Returns
///
/// The generated cite key, or an error if the format is invalid
pub fn generate_cite_key_with_format(
    format: &str,
    author: Option<&str>,
    year: Option<&str>,
    title: Option<&str>,
    fields: Option<&HashMap<String, String>>,
) -> Result<String, FormatError> {
    let specifiers = parse_format(format)?;
    let mut key = String::new();

    for spec in specifiers {
        match spec {
            CiteKeySpecifier::Author(count) => {
                if let Some(author_str) = author {
                    let names = extract_author_names(author_str, count);
                    key.push_str(&names);
                }
            }
            CiteKeySpecifier::AllAuthors => {
                if let Some(author_str) = author {
                    let names = extract_all_author_names(author_str);
                    key.push_str(&names);
                }
            }
            CiteKeySpecifier::Year(digits) => {
                if let Some(year_str) = year {
                    let year_digits: String = year_str
                        .chars()
                        .filter(|c| c.is_ascii_digit())
                        .take(4)
                        .collect();
                    if year_digits.len() == 4 {
                        if digits == 2 {
                            key.push_str(&year_digits[2..]);
                        } else {
                            key.push_str(&year_digits);
                        }
                    }
                }
            }
            CiteKeySpecifier::Title(count) => {
                if let Some(title_str) = title {
                    let words = extract_significant_words(title_str, count);
                    key.push_str(&words);
                }
            }
            CiteKeySpecifier::UniqueLetter | CiteKeySpecifier::UniqueNumber => {
                // These are placeholders that will be resolved by make_cite_key_unique
                // We don't add anything here
            }
            CiteKeySpecifier::Field(field_name) => {
                if let Some(fields_map) = fields {
                    if let Some(value) = fields_map.get(&field_name) {
                        // Normalize the field value for use in cite key
                        key.push_str(&normalize_for_key(value));
                    }
                }
            }
            CiteKeySpecifier::Literal(text) => {
                // Only allow safe characters in literals
                for c in text.chars() {
                    if c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == ':' {
                        key.push(c);
                    }
                }
            }
        }
    }

    // If key is empty, generate a placeholder
    if key.is_empty() {
        key = "Unknown".to_string();
    }

    Ok(key)
}

/// Check if a format string contains unique suffix specifiers (%u or %n)
pub fn format_has_unique_suffix(format: &str) -> bool {
    if let Ok(specifiers) = parse_format(format) {
        specifiers.iter().any(|s| {
            matches!(
                s,
                CiteKeySpecifier::UniqueLetter | CiteKeySpecifier::UniqueNumber
            )
        })
    } else {
        false
    }
}

/// Validate a cite key format string
#[cfg(feature = "native")]
#[uniffi::export]
pub fn validate_cite_key_format(format: String) -> CiteKeyFormatValidation {
    validate_cite_key_format_internal(&format)
}

pub fn validate_cite_key_format_internal(format: &str) -> CiteKeyFormatValidation {
    let mut warnings = Vec::new();

    // Try parsing
    match parse_format(format) {
        Err(e) => CiteKeyFormatValidation {
            is_valid: false,
            error_message: e.message,
            warnings: vec![],
        },
        Ok(specifiers) => {
            // Check for empty format
            if specifiers.is_empty() {
                return CiteKeyFormatValidation {
                    is_valid: false,
                    error_message: "Format string is empty".to_string(),
                    warnings: vec![],
                };
            }

            // Check for at least one non-literal specifier
            let has_specifier = specifiers.iter().any(|s| !matches!(s, CiteKeySpecifier::Literal(_)));
            if !has_specifier {
                warnings.push("Format contains no specifiers, all cite keys will be identical".to_string());
            }

            // Check for author or year (recommended)
            let has_author = specifiers.iter().any(|s| {
                matches!(
                    s,
                    CiteKeySpecifier::Author(_) | CiteKeySpecifier::AllAuthors
                )
            });
            let has_year = specifiers
                .iter()
                .any(|s| matches!(s, CiteKeySpecifier::Year(_)));

            if !has_author && !has_year {
                warnings.push("Format has neither author nor year, consider adding one for uniqueness".to_string());
            }

            CiteKeyFormatValidation {
                is_valid: true,
                error_message: String::new(),
                warnings,
            }
        }
    }
}

/// Generate a preview cite key using example data
#[cfg(feature = "native")]
#[uniffi::export]
pub fn preview_cite_key_format(format: String) -> String {
    preview_cite_key_format_internal(&format)
}

pub fn preview_cite_key_format_internal(format: &str) -> String {
    let mut fields = HashMap::new();
    fields.insert("journal".to_string(), "Nature".to_string());

    generate_cite_key_with_format(
        format,
        Some("Smith, John and Jones, Jane and Doe, Alice and Brown, Bob"),
        Some("2024"),
        Some("Machine Learning for Scientific Discovery"),
        Some(&fields),
    )
    .unwrap_or_else(|_| "Invalid format".to_string())
}

/// Generate a cite key with the specified format (UniFFI export)
#[cfg(feature = "native")]
#[uniffi::export]
pub fn generate_cite_key_formatted(
    format: String,
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
    lowercase: bool,
) -> String {
    let key = generate_cite_key_with_format(
        &format,
        author.as_deref(),
        year.as_deref(),
        title.as_deref(),
        None,
    )
    .unwrap_or_else(|_| "Unknown".to_string());

    if lowercase {
        key.to_lowercase()
    } else {
        key
    }
}

/// Generate a unique cite key with the specified format (UniFFI export)
#[cfg(feature = "native")]
#[uniffi::export]
pub fn generate_unique_cite_key_formatted(
    format: String,
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
    lowercase: bool,
    existing_keys: Vec<String>,
) -> String {
    let base = generate_cite_key_formatted(format, author, year, title, lowercase);
    super::cite_key::make_cite_key_unique(base, existing_keys)
}

// ===== Helper Functions =====

/// Extract author last names from an author string
fn extract_author_names(author: &str, count: usize) -> String {
    let authors = split_authors(author);
    let mut result = String::new();

    for (i, author_part) in authors.iter().enumerate() {
        if i >= count {
            break;
        }
        if let Some(last_name) = extract_last_name(author_part) {
            result.push_str(&normalize_for_key(&last_name));
        }
    }

    result
}

/// Extract all author names (up to 3, then EtAl)
fn extract_all_author_names(author: &str) -> String {
    let authors = split_authors(author);
    let mut result = String::new();

    for (i, author_part) in authors.iter().enumerate() {
        if i >= 3 {
            result.push_str("EtAl");
            break;
        }
        if let Some(last_name) = extract_last_name(author_part) {
            result.push_str(&normalize_for_key(&last_name));
        }
    }

    result
}

/// Split an author string into individual authors
fn split_authors(author: &str) -> Vec<&str> {
    // Split by " and " (case insensitive) or by semicolon
    let mut authors = Vec::new();
    let mut remaining = author;

    // First try " and "
    while let Some(pos) = remaining.to_lowercase().find(" and ") {
        let part = &remaining[..pos];
        if !part.trim().is_empty() {
            authors.push(part.trim());
        }
        remaining = &remaining[pos + 5..];
    }

    // Handle the last part or if no " and " was found
    if !remaining.is_empty() {
        // Also split by semicolon
        for part in remaining.split(';') {
            if !part.trim().is_empty() {
                authors.push(part.trim());
            }
        }
    }

    authors
}

/// Extract last name from a single author string
fn extract_last_name(author: &str) -> Option<String> {
    let trimmed = author.trim();
    if trimmed.is_empty() {
        return None;
    }

    // Check for "Last, First" format
    if let Some(comma_pos) = trimmed.find(',') {
        return Some(trimmed[..comma_pos].trim().to_string());
    }

    // "First Last" format - take last word
    trimmed
        .split_whitespace()
        .last()
        .map(|s| s.to_string())
}

/// Extract significant words from a title
fn extract_significant_words(title: &str, count: usize) -> String {
    let stopwords = [
        "a", "an", "the", "on", "in", "of", "for", "to", "and", "with", "by", "from", "as", "at",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does",
        "did", "will", "would", "could", "should", "may", "might", "must", "shall", "can",
    ];

    let mut words = Vec::new();

    for word in title.split_whitespace() {
        // Clean word of punctuation
        let clean: String = word.chars().filter(|c| c.is_alphanumeric()).collect();

        if clean.is_empty() {
            continue;
        }

        if !stopwords.contains(&clean.to_lowercase().as_str()) {
            words.push(capitalize_first(&normalize_for_key(&clean)));
            if words.len() >= count {
                break;
            }
        }
    }

    // If we didn't find enough significant words, use whatever we can get
    if words.is_empty() {
        for word in title.split_whitespace().take(count) {
            let clean: String = word.chars().filter(|c| c.is_alphanumeric()).collect();
            if !clean.is_empty() {
                words.push(capitalize_first(&normalize_for_key(&clean)));
            }
        }
    }

    words.join("")
}

/// Normalize a string for use in a cite key
fn normalize_for_key(s: &str) -> String {
    s.nfkd()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
}

/// Capitalize the first letter of a string
fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(first) => first.to_ascii_uppercase().to_string() + &chars.as_str().to_lowercase(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_format_basic() {
        let specs = parse_format("%a%Y%t").unwrap();
        assert_eq!(specs.len(), 3);
        assert_eq!(specs[0], CiteKeySpecifier::Author(1));
        assert_eq!(specs[1], CiteKeySpecifier::Year(4));
        assert_eq!(specs[2], CiteKeySpecifier::Title(1));
    }

    #[test]
    fn test_parse_format_with_counts() {
        let specs = parse_format("%a2%T3").unwrap();
        assert_eq!(specs[0], CiteKeySpecifier::Author(2));
        assert_eq!(specs[1], CiteKeySpecifier::Title(3));
    }

    #[test]
    fn test_parse_format_with_literal() {
        let specs = parse_format("%a_%Y").unwrap();
        assert_eq!(specs.len(), 3);
        assert_eq!(specs[0], CiteKeySpecifier::Author(1));
        assert_eq!(specs[1], CiteKeySpecifier::Literal("_".to_string()));
        assert_eq!(specs[2], CiteKeySpecifier::Year(4));
    }

    #[test]
    fn test_parse_format_all_authors() {
        let specs = parse_format("%A%Y").unwrap();
        assert_eq!(specs[0], CiteKeySpecifier::AllAuthors);
        assert_eq!(specs[1], CiteKeySpecifier::Year(4));
    }

    #[test]
    fn test_parse_format_two_digit_year() {
        let specs = parse_format("%a%y").unwrap();
        assert_eq!(specs[1], CiteKeySpecifier::Year(2));
    }

    #[test]
    fn test_parse_format_unique_suffixes() {
        let specs = parse_format("%a%y%u").unwrap();
        assert_eq!(specs[2], CiteKeySpecifier::UniqueLetter);

        let specs = parse_format("%a%y%n").unwrap();
        assert_eq!(specs[2], CiteKeySpecifier::UniqueNumber);
    }

    #[test]
    fn test_parse_format_custom_field() {
        let specs = parse_format("%f{journal}").unwrap();
        assert_eq!(specs[0], CiteKeySpecifier::Field("journal".to_string()));
    }

    #[test]
    fn test_parse_format_escaped_percent() {
        let specs = parse_format("100%% done").unwrap();
        // Will be two literals: "100%" and " done" because we flush on seeing %
        assert_eq!(specs.len(), 2);
        assert_eq!(
            specs[0],
            CiteKeySpecifier::Literal("100".to_string())
        );
        assert_eq!(
            specs[1],
            CiteKeySpecifier::Literal("% done".to_string())
        );
    }

    #[test]
    fn test_parse_format_error_unknown_specifier() {
        let result = parse_format("%x");
        assert!(result.is_err());
        assert!(result.unwrap_err().message.contains("Unknown specifier"));
    }

    #[test]
    fn test_parse_format_error_incomplete() {
        let result = parse_format("%");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_format_error_unclosed_field() {
        let result = parse_format("%f{journal");
        assert!(result.is_err());
        assert!(result.unwrap_err().message.contains("Unclosed"));
    }

    #[test]
    fn test_generate_classic_format() {
        let result = generate_cite_key_with_format(
            "%a%Y%t",
            Some("Smith, John"),
            Some("2024"),
            Some("Machine Learning for Everyone"),
            None,
        )
        .unwrap();
        assert_eq!(result, "Smith2024Machine");
    }

    #[test]
    fn test_generate_authors_year_format() {
        let result = generate_cite_key_with_format(
            "%a2_%Y",
            Some("Smith, John and Jones, Jane"),
            Some("2024"),
            Some("Test"),
            None,
        )
        .unwrap();
        assert_eq!(result, "SmithJones_2024");
    }

    #[test]
    fn test_generate_short_format() {
        let result = generate_cite_key_with_format(
            "%a:%y",
            Some("Smith, John"),
            Some("2024"),
            Some("Test"),
            None,
        )
        .unwrap();
        assert_eq!(result, "Smith:24");
    }

    #[test]
    fn test_generate_all_authors_format() {
        let result = generate_cite_key_with_format(
            "%A%Y",
            Some("Smith, John and Jones, Jane and Doe, Alice and Brown, Bob"),
            Some("2024"),
            Some("Test"),
            None,
        )
        .unwrap();
        assert_eq!(result, "SmithJonesDoeEtAl2024");
    }

    #[test]
    fn test_generate_multiple_title_words() {
        let result = generate_cite_key_with_format(
            "%a%Y%T2",
            Some("Smith, John"),
            Some("2024"),
            Some("Machine Learning Approaches"),
            None,
        )
        .unwrap();
        assert_eq!(result, "Smith2024MachineLearning");
    }

    #[test]
    fn test_generate_with_custom_field() {
        let mut fields = HashMap::new();
        fields.insert("journal".to_string(), "Nature".to_string());

        let result = generate_cite_key_with_format(
            "%a%Y_%f{journal}",
            Some("Smith, John"),
            Some("2024"),
            Some("Test"),
            Some(&fields),
        )
        .unwrap();
        assert_eq!(result, "Smith2024_Nature");
    }

    #[test]
    fn test_generate_with_diacritics() {
        let result = generate_cite_key_with_format(
            "%a%Y%t",
            Some("Müller, François"),
            Some("2024"),
            Some("Études"),
            None,
        )
        .unwrap();
        assert_eq!(result, "Muller2024Etudes");
    }

    #[test]
    fn test_validate_format_valid() {
        let result = validate_cite_key_format_internal("%a%Y%t");
        assert!(result.is_valid);
        assert!(result.error_message.is_empty());
    }

    #[test]
    fn test_validate_format_invalid() {
        let result = validate_cite_key_format_internal("%x");
        assert!(!result.is_valid);
        assert!(!result.error_message.is_empty());
    }

    #[test]
    fn test_validate_format_warning_no_author_year() {
        let result = validate_cite_key_format_internal("%t");
        assert!(result.is_valid);
        assert!(!result.warnings.is_empty());
    }

    #[test]
    fn test_preview_cite_key_format() {
        let result = preview_cite_key_format_internal("%a%Y%t");
        assert_eq!(result, "Smith2024Machine");
    }

    #[test]
    fn test_preview_cite_key_format_all_authors() {
        let result = preview_cite_key_format_internal("%A%Y");
        assert_eq!(result, "SmithJonesDoeEtAl2024");
    }

    #[test]
    fn test_format_has_unique_suffix() {
        assert!(format_has_unique_suffix("%a%Y%u"));
        assert!(format_has_unique_suffix("%a%Y%n"));
        assert!(!format_has_unique_suffix("%a%Y%t"));
    }

    #[test]
    fn test_split_authors() {
        let authors = split_authors("Smith, John and Jones, Jane");
        assert_eq!(authors.len(), 2);
        assert_eq!(authors[0], "Smith, John");
        assert_eq!(authors[1], "Jones, Jane");
    }

    #[test]
    fn test_split_authors_semicolon() {
        let authors = split_authors("Smith, John; Jones, Jane");
        assert_eq!(authors.len(), 2);
    }

    #[test]
    fn test_extract_last_name_last_first() {
        assert_eq!(
            extract_last_name("Smith, John"),
            Some("Smith".to_string())
        );
    }

    #[test]
    fn test_extract_last_name_first_last() {
        assert_eq!(
            extract_last_name("John Smith"),
            Some("Smith".to_string())
        );
    }

    #[test]
    fn test_extract_significant_words() {
        assert_eq!(
            extract_significant_words("The Quick Brown Fox", 2),
            "QuickBrown"
        );
    }

    #[test]
    fn test_extract_significant_words_all_stopwords() {
        // If all words are stopwords, should return the first word
        assert_eq!(extract_significant_words("The A An", 1), "The");
    }
}
