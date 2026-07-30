//! MathML traversal, with two renderings.
//!
//! Parses MathML from scientific abstracts. Handles `<inline-formula>` and
//! `<mml:math>` tags from ADS and other sources.
//!
//! **The traversal is written once and the rendering is a parameter**
//! ([`MathTarget`]), because there are two legitimate targets for the same tree
//! and they were previously two copies of the same scanner:
//!
//! | | [`MathTarget::Unicode`] | [`MathTarget::Latex`] |
//! |---|---|---|
//! | `msup` | `H²` | `{H}^{2}` |
//! | `msub` | `x₁` | `{x}_{1}` |
//! | `mfrac`, `msqrt` | not handled | `\frac{a}{b}`, `\sqrt{a}` |
//! | wrapper | content inlined | content wrapped in `$…$` |
//! | consumer | the FTS index ([`parse_mathml`], live, called from Swift) | MathJax ([`super::abstract_parser::mathml_to_latex`]) |
//!
//! Unicode super/subscripts are right for a search index — `H²O` and `H2O` both
//! fold to something a reader recognises, and there is no renderer downstream.
//! LaTeX is right for an abstract on its way to a MathJax web view. Neither is
//! a bug; only having two scanners was.
//!
//! `parse_mathml`'s observable behaviour is unchanged by the parameterisation —
//! that is what the nine unit tests at the bottom of this file are for. Two
//! deliberate asymmetries survive as [`MathTarget`] methods rather than being
//! unified, and both are documented there: the LaTeX side trims each extracted
//! child (Swift's `stripMathMLTags` ended in `trimmingCharacters`) and uses
//! Foundation's whitespace set, the Unicode side does neither.

use lazy_static::lazy_static;
use regex::Regex;
use std::collections::HashMap;

use impress_smart_search::foundation::trim_ws;

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

    // `mfrac` and `msqrt` are reached only by the LaTeX rendering: the Unicode
    // one has no character to put a fraction bar on, so it lets the tag
    // stripper flatten them (`a/b` → `ab`, admittedly lossy, but it feeds an
    // index whose tokenizer would split on `/` anyway).
    static ref MFRAC_RE: Regex = Regex::new(
        r"(?is)<mml:mfrac[^>]*>(.*?)</mml:mfrac>"
    ).unwrap();

    static ref MSQRT_RE: Regex = Regex::new(
        r"(?is)<mml:msqrt[^>]*>(.*?)</mml:msqrt>"
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

/// Which rendering the shared traversal emits. See the module docs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MathTarget {
    /// Unicode super/subscript characters — for the full-text search index.
    Unicode,
    /// LaTeX `{base}^{exp}` / `\frac` / `\sqrt` — for MathJax.
    Latex,
}

impl MathTarget {
    /// Strip `<mml:…>` tags from an extracted child.
    ///
    /// The LaTeX side trims afterwards because Swift's `stripMathMLTags` ended
    /// in `trimmingCharacters(in: .whitespaces)`; the Unicode side never did,
    /// and adding a trim there would change `parse_mathml` output for
    /// pretty-printed MathML. Neither is worth breaking to make them match.
    fn strip_tags(self, text: &str) -> String {
        let stripped = strip_mathml_tags(text);
        match self {
            MathTarget::Unicode => stripped,
            MathTarget::Latex => trim_ws(&stripped).to_string(),
        }
    }

    /// Trim the edges of a finished rendering.
    ///
    /// Foundation's `.whitespaces` contains U+200B and excludes newlines, so it
    /// is neither `str::trim()` nor a subset of it — see
    /// `impress_smart_search::foundation`.
    fn trim_edges(self, text: &str) -> &str {
        match self {
            MathTarget::Unicode => text.trim(),
            MathTarget::Latex => trim_ws(text),
        }
    }

    fn render_sup(self, base: &str, exponent: &str) -> String {
        match self {
            MathTarget::Unicode => format!("{}{}", base, convert_to_superscript(exponent)),
            MathTarget::Latex => format!("{{{}}}^{{{}}}", base, exponent),
        }
    }

    fn render_sub(self, base: &str, subscript: &str) -> String {
        match self {
            MathTarget::Unicode => format!("{}{}", base, convert_to_subscript(subscript)),
            MathTarget::Latex => format!("{{{}}}_{{{}}}", base, subscript),
        }
    }
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
    replace_mathml_wrappers(&text, |content| {
        convert_mathml_content(content, MathTarget::Unicode)
    })
}

/// Rewrite every `<inline-formula>` and every standalone `<mml:math>` wrapper,
/// handing each one's inner MathML to `render`.
///
/// Both wrapper passes run in that order, and each replaces its matches
/// back-to-front so earlier byte offsets stay valid.
pub(crate) fn replace_mathml_wrappers(text: &str, render: impl Fn(&str) -> String) -> String {
    let after_inline = replace_captures_reversed(&INLINE_FORMULA_RE, text, &render);
    replace_captures_reversed(&STANDALONE_MATHML_RE, &after_inline, &render)
}

/// Replace every match of `re` with `render(capture group 1)`, back-to-front.
///
/// This was written out four times (inline-formula, mml:math, msup, msub) with
/// the same off-by-nothing index bookkeeping in each copy.
fn replace_captures_reversed(re: &Regex, text: &str, render: impl Fn(&str) -> String) -> String {
    let mut result = text.to_string();
    let matches: Vec<(usize, usize, String)> = re
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

    for (start, end, content) in matches.into_iter().rev() {
        result.replace_range(start..end, &render(&content));
    }

    result
}

/// As [`replace_captures_reversed`], but repeated until no match remains, which
/// is how `msup`/`msub` reach nested occurrences: the lazy `(.*?)` stops at the
/// *first* closing tag, so one pass over `<msup><msup>…</msup>…</msup>` leaves
/// the outer element behind.
fn replace_captures_until_stable(
    re: &Regex,
    text: &str,
    render: impl Fn(&str) -> String,
) -> String {
    let mut result = text.to_string();
    while re.is_match(&result) {
        result = replace_captures_reversed(re, &result, &render);
    }
    result
}

/// Convert one MathML fragment (the inside of a wrapper) to `target`'s syntax.
pub(crate) fn convert_mathml_content(content: &str, target: MathTarget) -> String {
    let mut result = replace_captures_until_stable(&MSUP_RE, content, |inner| {
        let (base, exponent) = extract_two_children(inner, target);
        target.render_sup(&target.strip_tags(&base), &target.strip_tags(&exponent))
    });

    result = replace_captures_until_stable(&MSUB_RE, &result, |inner| {
        let (base, subscript) = extract_two_children(inner, target);
        target.render_sub(&target.strip_tags(&base), &target.strip_tags(&subscript))
    });

    if target == MathTarget::Latex {
        // PRESERVED QUIRK — a nesting gap. `msup`/`msub` loop until stable but
        // `mfrac`/`msqrt` get a single pass, so `\frac` inside `\frac` survives
        // in the output as a residual tag that the stripper then flattens. That
        // is what the Swift original did, and closing the gap would change
        // rendered abstracts (for the better, probably) rather than port them.
        // Do it as its own change, with corpus cases that show the improvement.
        result = replace_captures_reversed(&MFRAC_RE, &result, |inner| {
            let (numerator, denominator) = extract_two_children(inner, target);
            format!(
                "\\frac{{{}}}{{{}}}",
                target.strip_tags(&numerator),
                target.strip_tags(&denominator)
            )
        });
        result = replace_captures_reversed(&MSQRT_RE, &result, |inner| {
            format!("\\sqrt{{{}}}", target.strip_tags(inner))
        });
    }

    result = target.strip_tags(&result);
    result = WHITESPACE_RE.replace_all(&result, " ").to_string();
    target.trim_edges(&result).to_string()
}

/// Extract the first two top-level children of a two-argument element.
///
/// A single child yields an empty second slot, and no children at all yields
/// the whole fragment as the first — which is how `${a2}^{}3$` (the nested-msup
/// corpus case) happens: the depth scanner finds no *complete* element in the
/// outer fragment, so the base becomes the flattened inner text and the
/// exponent becomes empty.
fn extract_two_children(content: &str, target: MathTarget) -> (String, String) {
    let children = extract_top_level_elements(content, target);
    match children.len() {
        0 => (content.to_string(), String::new()),
        1 => (children[0].clone(), String::new()),
        _ => (children[0].clone(), children[1].clone()),
    }
}

/// Extract top-level MathML elements from content using stack-based parsing
fn extract_top_level_elements(content: &str, target: MathTarget) -> Vec<String> {
    let mut elements = Vec::new();
    let chars: Vec<char> = content.chars().collect();
    let mut i = 0;
    let mut depth = 0;
    let mut current_element_start: Option<usize> = None;

    while i < chars.len() {
        if chars[i] == '<' && i < chars.len() - 1 {
            let rest: String = chars[i..].iter().collect();

            // Check for self-closing tag: <mml:xxx ... />
            //
            // This branch has no counterpart in the Swift original, and now
            // that the scanner is shared, the LaTeX rendering inherits it.
            // Swift's opening-tag pattern was `^<mml:[a-z]+[^>]*>`, and `[^>]*`
            // happily matches the `/`, so `<mml:mspace/>` counted as an OPEN
            // tag that never closed: depth stayed above zero and every later
            // sibling was swallowed into an element that was never emitted. No
            // corpus case carries a self-closing tag — `<mml:mspace/>` and
            // `<mml:none/>` are rare in ADS output — so this is an unobservable
            // improvement rather than a listed divergence. Noted because it is
            // a real behaviour difference and should not be discovered twice.
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
        vec![target.trim_edges(content).to_string()]
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
        for target in [MathTarget::Unicode, MathTarget::Latex] {
            let elements = extract_top_level_elements(content, target);
            assert_eq!(elements.len(), 2);
            assert_eq!(elements[0], "<mml:mi>x</mml:mi>");
            assert_eq!(elements[1], "<mml:mn>2</mml:mn>");
        }
    }

    /// The scanner is shared, so the two renderings must stay distinguishable
    /// on the same input — otherwise a future "simplification" could collapse
    /// them and only the FTS index (or only MathJax) would notice.
    #[test]
    fn the_two_targets_render_the_same_tree_differently() {
        let msup = "<mml:msup><mml:mi>H</mml:mi><mml:mn>2</mml:mn></mml:msup>";
        assert_eq!(convert_mathml_content(msup, MathTarget::Unicode), "H²");
        assert_eq!(convert_mathml_content(msup, MathTarget::Latex), "{H}^{2}");

        let msub = "<mml:msub><mml:mi>x</mml:mi><mml:mn>1</mml:mn></mml:msub>";
        assert_eq!(convert_mathml_content(msub, MathTarget::Unicode), "x₁");
        assert_eq!(convert_mathml_content(msub, MathTarget::Latex), "{x}_{1}");

        // `mfrac`/`msqrt` are LaTeX-only; the Unicode target flattens them.
        let mfrac = "<mml:mfrac><mml:mi>a</mml:mi><mml:mi>b</mml:mi></mml:mfrac>";
        assert_eq!(convert_mathml_content(mfrac, MathTarget::Unicode), "ab");
        assert_eq!(
            convert_mathml_content(mfrac, MathTarget::Latex),
            "\\frac{a}{b}"
        );
    }
}
