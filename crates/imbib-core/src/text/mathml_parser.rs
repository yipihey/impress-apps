//! MathML parsing and Unicode conversion
//!
//! Parses MathML from scientific abstracts and converts to readable Unicode text.
//! Handles `<inline-formula>` and `<mml:math>` tags from ADS and other sources.

use lazy_static::lazy_static;
use regex::Regex;
use std::collections::HashMap;

lazy_static! {
    /// Superscript Unicode characters
    static ref SUPERSCRIPT_MAP: HashMap<char, char> = {
        let mut m = HashMap::new();
        m.insert('0', '⁰'); m.insert('1', '¹'); m.insert('2', '²');
        m.insert('3', '³'); m.insert('4', '⁴'); m.insert('5', '⁵');
        m.insert('6', '⁶'); m.insert('7', '⁷'); m.insert('8', '⁸');
        m.insert('9', '⁹');
        m.insert('+', '⁺'); m.insert('-', '⁻'); m.insert('=', '⁼');
        m.insert('(', '⁽'); m.insert(')', '⁾');
        m.insert('n', 'ⁿ'); m.insert('i', 'ⁱ'); m.insert('a', 'ᵃ');
        m.insert('b', 'ᵇ'); m.insert('c', 'ᶜ'); m.insert('d', 'ᵈ');
        m.insert('e', 'ᵉ'); m.insert('f', 'ᶠ'); m.insert('g', 'ᵍ');
        m.insert('h', 'ʰ'); m.insert('j', 'ʲ'); m.insert('k', 'ᵏ');
        m.insert('l', 'ˡ'); m.insert('m', 'ᵐ'); m.insert('o', 'ᵒ');
        m.insert('p', 'ᵖ'); m.insert('r', 'ʳ'); m.insert('s', 'ˢ');
        m.insert('t', 'ᵗ'); m.insert('u', 'ᵘ'); m.insert('v', 'ᵛ');
        m.insert('w', 'ʷ'); m.insert('x', 'ˣ'); m.insert('y', 'ʸ');
        m.insert('z', 'ᶻ');
        m
    };

    /// Subscript Unicode characters
    static ref SUBSCRIPT_MAP: HashMap<char, char> = {
        let mut m = HashMap::new();
        m.insert('0', '₀'); m.insert('1', '₁'); m.insert('2', '₂');
        m.insert('3', '₃'); m.insert('4', '₄'); m.insert('5', '₅');
        m.insert('6', '₆'); m.insert('7', '₇'); m.insert('8', '₈');
        m.insert('9', '₉');
        m.insert('+', '₊'); m.insert('-', '₋'); m.insert('=', '₌');
        m.insert('(', '₍'); m.insert(')', '₎');
        m.insert('a', 'ₐ'); m.insert('e', 'ₑ'); m.insert('h', 'ₕ');
        m.insert('i', 'ᵢ'); m.insert('j', 'ⱼ'); m.insert('k', 'ₖ');
        m.insert('l', 'ₗ'); m.insert('m', 'ₘ'); m.insert('n', 'ₙ');
        m.insert('o', 'ₒ'); m.insert('p', 'ₚ'); m.insert('r', 'ᵣ');
        m.insert('s', 'ₛ'); m.insert('t', 'ₜ'); m.insert('u', 'ᵤ');
        m.insert('v', 'ᵥ'); m.insert('x', 'ₓ');
        m
    };

    // Regex patterns
    static ref INLINE_FORMULA_RE: Regex = Regex::new(
        r"(?is)<inline-formula[^>]*>(.*?)</inline-formula>"
    ).unwrap();

    static ref STANDALONE_MATHML_RE: Regex = Regex::new(
        r"(?is)<mml:math[^>]*>(.*?)</mml:math>"
    ).unwrap();

    static ref MSUP_RE: Regex = Regex::new(
        r"(?is)<mml:msup[^>]*>(.*?)</mml:msup>"
    ).unwrap();

    static ref MSUB_RE: Regex = Regex::new(
        r"(?is)<mml:msub[^>]*>(.*?)</mml:msub>"
    ).unwrap();

    static ref MATHML_TAG_RE: Regex = Regex::new(
        r"(?i)</?mml:[a-z]+[^>]*>"
    ).unwrap();

    static ref WHITESPACE_RE: Regex = Regex::new(r"\s+").unwrap();

    // For extracting top-level elements
    static ref SELF_CLOSING_RE: Regex = Regex::new(
        r"(?i)^<mml:[a-z]+[^>]*/>"
    ).unwrap();

    static ref OPEN_TAG_RE: Regex = Regex::new(
        r"(?i)^<mml:([a-z]+)[^>]*>"
    ).unwrap();

    static ref CLOSE_TAG_RE: Regex = Regex::new(
        r"(?i)^</mml:([a-z]+)>"
    ).unwrap();
}

/// Parse text containing MathML and convert to readable Unicode text.
///
/// Example input:
/// ```text
/// Text with <inline-formula><mml:math><mml:mi>S</mml:mi><mml:mo>/</mml:mo><mml:mi>N</mml:mi></mml:math></inline-formula> ratio
/// ```
/// Example output:
/// ```text
/// Text with S/N ratio
/// ```
#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_mathml(text: String) -> String {
    let mut result = text;

    // Process <inline-formula>...</inline-formula> tags
    result = process_inline_formulas(&result);

    // Process standalone <mml:math>...</mml:math> tags (without inline-formula wrapper)
    result = process_standalone_mathml(&result);

    result
}

/// Process inline-formula tags and extract their content
fn process_inline_formulas(text: &str) -> String {
    let mut result = text.to_string();

    // Collect all matches first
    let matches: Vec<_> = INLINE_FORMULA_RE
        .captures_iter(&result)
        .map(|cap| {
            let full_match = cap.get(0).unwrap();
            let content = cap
                .get(1)
                .map(|m| m.as_str().to_string())
                .unwrap_or_default();
            (full_match.start(), full_match.end(), content)
        })
        .collect();

    // Process in reverse order to preserve indices
    for (start, end, content) in matches.into_iter().rev() {
        let parsed = parse_mathml_content(&content);
        result.replace_range(start..end, &parsed);
    }

    result
}

/// Process standalone mml:math tags
fn process_standalone_mathml(text: &str) -> String {
    let mut result = text.to_string();

    // Collect all matches first
    let matches: Vec<_> = STANDALONE_MATHML_RE
        .captures_iter(&result)
        .map(|cap| {
            let full_match = cap.get(0).unwrap();
            let content = cap
                .get(1)
                .map(|m| m.as_str().to_string())
                .unwrap_or_default();
            (full_match.start(), full_match.end(), content)
        })
        .collect();

    // Process in reverse order to preserve indices
    for (start, end, content) in matches.into_iter().rev() {
        let parsed = parse_mathml_content(&content);
        result.replace_range(start..end, &parsed);
    }

    result
}

/// Parse MathML content and convert to Unicode text
fn parse_mathml_content(content: &str) -> String {
    let mut result = content.to_string();

    // Process msup (superscript) first - before stripping tags
    result = process_superscripts(&result);

    // Process msub (subscript) - before stripping tags
    result = process_subscripts(&result);

    // Now strip remaining MathML tags and extract text content
    result = strip_mathml_tags(&result);

    // Normalize whitespace
    result = WHITESPACE_RE.replace_all(&result, " ").to_string();
    result = result.trim().to_string();

    result
}

/// Process msup elements and convert to Unicode superscript
fn process_superscripts(text: &str) -> String {
    let mut result = text.to_string();

    // Keep processing until no more matches (handles nested elements)
    loop {
        let matches: Vec<_> = MSUP_RE
            .captures_iter(&result)
            .map(|cap| {
                let full_match = cap.get(0).unwrap();
                let content = cap
                    .get(1)
                    .map(|m| m.as_str().to_string())
                    .unwrap_or_default();
                (full_match.start(), full_match.end(), content)
            })
            .collect();

        if matches.is_empty() {
            break;
        }

        // Process in reverse order to preserve indices
        for (start, end, content) in matches.into_iter().rev() {
            let (base, superscript) = extract_msup_parts(&content);
            let base_text = strip_mathml_tags(&base);
            let sup_text = convert_to_superscript(&strip_mathml_tags(&superscript));
            result.replace_range(start..end, &format!("{}{}", base_text, sup_text));
        }
    }

    result
}

/// Process msub elements and convert to Unicode subscript
fn process_subscripts(text: &str) -> String {
    let mut result = text.to_string();

    // Keep processing until no more matches (handles nested elements)
    loop {
        let matches: Vec<_> = MSUB_RE
            .captures_iter(&result)
            .map(|cap| {
                let full_match = cap.get(0).unwrap();
                let content = cap
                    .get(1)
                    .map(|m| m.as_str().to_string())
                    .unwrap_or_default();
                (full_match.start(), full_match.end(), content)
            })
            .collect();

        if matches.is_empty() {
            break;
        }

        // Process in reverse order to preserve indices
        for (start, end, content) in matches.into_iter().rev() {
            let (base, subscript) = extract_msub_parts(&content);
            let base_text = strip_mathml_tags(&base);
            let sub_text = convert_to_subscript(&strip_mathml_tags(&subscript));
            result.replace_range(start..end, &format!("{}{}", base_text, sub_text));
        }
    }

    result
}

/// Extract base and superscript parts from msup content
fn extract_msup_parts(content: &str) -> (String, String) {
    let children = extract_top_level_elements(content);
    if children.len() >= 2 {
        (children[0].clone(), children[1].clone())
    } else if children.len() == 1 {
        (children[0].clone(), String::new())
    } else {
        (content.to_string(), String::new())
    }
}

/// Extract base and subscript parts from msub content
fn extract_msub_parts(content: &str) -> (String, String) {
    let children = extract_top_level_elements(content);
    if children.len() >= 2 {
        (children[0].clone(), children[1].clone())
    } else if children.len() == 1 {
        (children[0].clone(), String::new())
    } else {
        (content.to_string(), String::new())
    }
}

/// Extract top-level MathML elements from content using stack-based parsing
fn extract_top_level_elements(content: &str) -> Vec<String> {
    let mut elements = Vec::new();
    let chars: Vec<char> = content.chars().collect();
    let mut i = 0;
    let mut depth = 0;
    let mut current_element_start: Option<usize> = None;

    while i < chars.len() {
        if chars[i] == '<' && i < chars.len() - 1 {
            let rest: String = chars[i..].iter().collect();

            // Check for self-closing tag: <mml:xxx ... />
            if let Some(m) = SELF_CLOSING_RE.find(&rest) {
                if depth == 0 {
                    elements.push(rest[..m.end()].to_string());
                    i += m.end();
                    continue;
                }
            }

            // Check for opening tag: <mml:xxx>
            if let Some(m) = OPEN_TAG_RE.find(&rest) {
                if depth == 0 {
                    current_element_start = Some(i);
                }
                depth += 1;
                i += m.end();
                continue;
            }

            // Check for closing tag: </mml:xxx>
            if let Some(m) = CLOSE_TAG_RE.find(&rest) {
                depth -= 1;
                let tag_end = i + m.end();
                if depth == 0 {
                    if let Some(start) = current_element_start {
                        let element: String = chars[start..tag_end].iter().collect();
                        elements.push(element);
                        current_element_start = None;
                    }
                }
                i = tag_end;
                continue;
            }
        }

        i += 1;
    }

    // If no elements found, return the content as-is
    if elements.is_empty() {
        vec![content.trim().to_string()]
    } else {
        elements
    }
}

/// Strip all MathML tags and return plain text content
fn strip_mathml_tags(text: &str) -> String {
    MATHML_TAG_RE.replace_all(text, "").to_string()
}

/// Convert text to Unicode superscript characters where possible
fn convert_to_superscript(text: &str) -> String {
    text.chars()
        .map(|c| {
            SUPERSCRIPT_MAP
                .get(&c)
                .or_else(|| SUPERSCRIPT_MAP.get(&c.to_ascii_lowercase()))
                .copied()
                .unwrap_or(c)
        })
        .collect()
}

/// Convert text to Unicode subscript characters where possible
fn convert_to_subscript(text: &str) -> String {
    text.chars()
        .map(|c| {
            SUBSCRIPT_MAP
                .get(&c)
                .or_else(|| SUBSCRIPT_MAP.get(&c.to_ascii_lowercase()))
                .copied()
                .unwrap_or(c)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_math() {
        let input = "<mml:math><mml:mi>S</mml:mi><mml:mo>/</mml:mo><mml:mi>N</mml:mi></mml:math>";
        assert_eq!(parse_mathml(input.to_string()), "S/N");
    }

    #[test]
    fn test_inline_formula() {
        let input = "Text with <inline-formula><mml:math><mml:mi>x</mml:mi></mml:math></inline-formula> value";
        assert_eq!(parse_mathml(input.to_string()), "Text with x value");
    }

    #[test]
    fn test_superscript() {
        let input =
            "<mml:math><mml:msup><mml:mi>x</mml:mi><mml:mn>2</mml:mn></mml:msup></mml:math>";
        assert_eq!(parse_mathml(input.to_string()), "x²");
    }

    #[test]
    fn test_subscript() {
        let input = "<mml:math><mml:msub><mml:mi>H</mml:mi><mml:mn>2</mml:mn></mml:msub><mml:mi>O</mml:mi></mml:math>";
        assert_eq!(parse_mathml(input.to_string()), "H₂O");
    }

    #[test]
    fn test_complex_expression() {
        // E = mc²
        let input = "<mml:math><mml:mi>E</mml:mi><mml:mo>=</mml:mo><mml:mi>m</mml:mi><mml:msup><mml:mi>c</mml:mi><mml:mn>2</mml:mn></mml:msup></mml:math>";
        assert_eq!(parse_mathml(input.to_string()), "E=mc²");
    }

    #[test]
    fn test_convert_superscript() {
        assert_eq!(convert_to_superscript("123"), "¹²³");
        assert_eq!(convert_to_superscript("+-"), "⁺⁻");
        assert_eq!(convert_to_superscript("n"), "ⁿ");
    }

    #[test]
    fn test_convert_subscript() {
        assert_eq!(convert_to_subscript("123"), "₁₂₃");
        assert_eq!(convert_to_subscript("+-"), "₊₋");
    }

    #[test]
    fn test_no_mathml() {
        let input = "Plain text without MathML";
        assert_eq!(parse_mathml(input.to_string()), "Plain text without MathML");
    }

    #[test]
    fn test_extract_top_level_elements() {
        let content = "<mml:mi>x</mml:mi><mml:mn>2</mml:mn>";
        let elements = extract_top_level_elements(content);
        assert_eq!(elements.len(), 2);
        assert_eq!(elements[0], "<mml:mi>x</mml:mi>");
        assert_eq!(elements[1], "<mml:mn>2</mml:mn>");
    }
}
