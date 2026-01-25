//! Scientific text preprocessing
//!
//! Provides preprocessing utilities for scientific text:
//! - HTML entity decoding
//! - LaTeX Greek letter replacement
//! - Font command stripping
//! - Standalone brace removal
//!
//! Note: The full scientific text parser with AttributedString building
//! remains in Swift since it requires SwiftUI-specific types.

use lazy_static::lazy_static;

lazy_static! {
    /// Greek letters - lowercase
    static ref GREEK_LOWER: Vec<(&'static str, &'static str)> = vec![
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
        ("\\epsilon", "ε"), ("\\varepsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"),
        ("\\theta", "θ"), ("\\vartheta", "ϑ"), ("\\iota", "ι"), ("\\kappa", "κ"),
        ("\\lambda", "λ"), ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"),
        ("\\pi", "π"), ("\\varpi", "ϖ"), ("\\rho", "ρ"), ("\\varrho", "ϱ"),
        ("\\sigma", "σ"), ("\\varsigma", "ς"), ("\\tau", "τ"), ("\\upsilon", "υ"),
        ("\\phi", "φ"), ("\\varphi", "ϕ"), ("\\chi", "χ"), ("\\psi", "ψ"),
        ("\\omega", "ω"),
    ];

    /// Greek letters - uppercase
    static ref GREEK_UPPER: Vec<(&'static str, &'static str)> = vec![
        ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"), ("\\Lambda", "Λ"),
        ("\\Xi", "Ξ"), ("\\Pi", "Π"), ("\\Sigma", "Σ"), ("\\Upsilon", "Υ"),
        ("\\Phi", "Φ"), ("\\Psi", "Ψ"), ("\\Omega", "Ω"),
    ];

    /// Common math symbols
    static ref MATH_SYMBOLS: Vec<(&'static str, &'static str)> = vec![
        ("\\infty", "∞"), ("\\partial", "∂"), ("\\nabla", "∇"),
        ("\\pm", "±"), ("\\mp", "∓"), ("\\times", "×"), ("\\div", "÷"),
        ("\\cdot", "·"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\neq", "≠"),
        ("\\approx", "≈"), ("\\equiv", "≡"), ("\\sim", "∼"), ("\\simeq", "≃"),
        ("\\propto", "∝"), ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"),
        ("\\sqrt", "√"), ("\\forall", "∀"), ("\\exists", "∃"),
        ("\\in", "∈"), ("\\notin", "∉"), ("\\subset", "⊂"), ("\\supset", "⊃"),
        ("\\cup", "∪"), ("\\cap", "∩"), ("\\emptyset", "∅"),
        ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\Rightarrow", "⇒"),
        ("\\Leftarrow", "⇐"), ("\\leftrightarrow", "↔"), ("\\Leftrightarrow", "⇔"),
        // Script/special letters
        ("\\ell", "ℓ"), ("\\hbar", "ℏ"), ("\\Re", "ℜ"), ("\\Im", "ℑ"),
        ("\\aleph", "ℵ"), ("\\wp", "℘"),
        // Additional operators
        ("\\ll", "≪"), ("\\gg", "≫"), ("\\lesssim", "≲"), ("\\gtrsim", "≳"),
        ("\\asymp", "≍"), ("\\dagger", "†"), ("\\ddagger", "‡"),
        ("\\prime", "′"), ("\\circ", "∘"), ("\\bullet", "•"),
    ];

    /// Font commands to strip
    static ref FONT_COMMANDS: Vec<&'static str> = vec![
        "\\rm ", "\\it ", "\\bf ", "\\sf ", "\\tt ",
        "\\rm{", "\\it{", "\\bf{", "\\sf{", "\\tt{",
        "\\textrm ", "\\textit ", "\\textbf ",
    ];
}

/// Decode HTML entities to their Unicode equivalents
#[cfg(feature = "native")]
#[uniffi::export]
pub fn decode_html_entities(text: String) -> String {
    let mut result = text;
    result = result.replace("&lt;", "<");
    result = result.replace("&gt;", ">");
    result = result.replace("&amp;", "&");
    result = result.replace("&nbsp;", " ");
    result = result.replace("&quot;", "\"");
    result = result.replace("&apos;", "'");
    result
}

/// Replace LaTeX Greek letter commands with Unicode characters
#[cfg(feature = "native")]
#[uniffi::export]
pub fn replace_greek_letters(text: String) -> String {
    let mut result = text;

    for (latex, unicode) in GREEK_LOWER.iter() {
        result = result.replace(latex, unicode);
    }
    for (latex, unicode) in GREEK_UPPER.iter() {
        result = result.replace(latex, unicode);
    }
    for (latex, unicode) in MATH_SYMBOLS.iter() {
        result = result.replace(latex, unicode);
    }

    result
}

/// Strip LaTeX font-switching commands
#[cfg(feature = "native")]
#[uniffi::export]
pub fn strip_font_commands(text: String) -> String {
    let mut result = text;
    for cmd in FONT_COMMANDS.iter() {
        result = result.replace(cmd, "");
    }
    result
}

/// Remove standalone LaTeX braces like {pc} → pc
/// Preserves braces that are part of ^{...} or _{...} notation
#[cfg(feature = "native")]
#[uniffi::export]
pub fn strip_standalone_braces(text: String) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut i = 0;
    let mut inside_special_brace = false;

    while i < chars.len() {
        let c = chars[i];

        if c == '{' {
            // Check if preceded by ^ or _
            let is_preceded_by_special = if i > 0 {
                let prev = chars[i - 1];
                prev == '^' || prev == '_'
            } else {
                false
            };

            if is_preceded_by_special {
                // Keep the brace - it's part of ^{...} or _{...}
                result.push(c);
                inside_special_brace = true;
            } else {
                // Find closing brace and extract content
                if let Some(close_idx) = find_closing_brace(&chars, i) {
                    // Append content between braces
                    result.extend(&chars[(i + 1)..close_idx]);
                    i = close_idx;
                } else {
                    // No closing brace, keep the opening one
                    result.push(c);
                }
            }
        } else if c == '}' {
            if inside_special_brace {
                // Keep the closing brace - it's part of ^{...} or _{...}
                result.push(c);
                inside_special_brace = false;
            }
            // Standalone closing braces are skipped
        } else {
            result.push(c);
        }

        i += 1;
    }

    result
}

/// Find closing brace index starting from open_idx (which should point to '{')
fn find_closing_brace(chars: &[char], open_idx: usize) -> Option<usize> {
    for (idx, &c) in chars.iter().enumerate().skip(open_idx + 1) {
        if c == '}' {
            return Some(idx);
        }
    }
    None
}

/// Combined preprocessing for scientific text
///
/// Applies all preprocessing steps in order:
/// 1. Decode HTML entities
/// 2. Replace Greek letters
/// 3. Strip font commands
/// 4. Strip standalone braces
#[cfg(feature = "native")]
#[uniffi::export]
pub fn preprocess_scientific_text(text: String) -> String {
    let mut result = text;
    result = decode_html_entities(result);
    result = replace_greek_letters(result);
    result = strip_font_commands(result);
    result = strip_standalone_braces(result);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_html_entities() {
        assert_eq!(
            decode_html_entities("a &lt; b &amp; c &gt; d".to_string()),
            "a < b & c > d"
        );
        assert_eq!(
            decode_html_entities("&quot;hello&quot;".to_string()),
            "\"hello\""
        );
    }

    #[test]
    fn test_greek_letters() {
        assert_eq!(
            replace_greek_letters("\\alpha + \\beta = \\gamma".to_string()),
            "α + β = γ"
        );
        assert_eq!(
            replace_greek_letters("\\Gamma function".to_string()),
            "Γ function"
        );
    }

    #[test]
    fn test_math_symbols() {
        assert_eq!(replace_greek_letters("a \\leq b".to_string()), "a ≤ b");
        assert_eq!(replace_greek_letters("\\infty".to_string()), "∞");
    }

    #[test]
    fn test_strip_font_commands() {
        assert_eq!(strip_font_commands("\\rm text".to_string()), "text");
        assert_eq!(
            strip_font_commands("\\bf{bold}".to_string()),
            "bold}" // Note: only strips the command, not the braces
        );
    }

    #[test]
    fn test_strip_standalone_braces() {
        // Regular braces should be stripped
        assert_eq!(
            strip_standalone_braces("{pc} parsec".to_string()),
            "pc parsec"
        );

        // Braces after ^ or _ should be preserved
        assert_eq!(
            strip_standalone_braces("x^{2} + y_{1}".to_string()),
            "x^{2} + y_{1}"
        );

        // Mixed case
        assert_eq!(
            strip_standalone_braces("M_{\\rm BH}".to_string()),
            "M_{\\rm BH}"
        );
    }

    #[test]
    fn test_preprocess_combined() {
        let input = "&lt;sub&gt;\\alpha {pc}&lt;/sub&gt;";
        let result = preprocess_scientific_text(input.to_string());
        assert!(result.contains("α"));
        assert!(result.contains("<sub>"));
        assert!(!result.contains("{pc}"));
        assert!(result.contains("pc"));
    }

    #[test]
    fn test_empty_string() {
        assert_eq!(preprocess_scientific_text("".to_string()), "");
    }

    #[test]
    fn test_no_special_chars() {
        let input = "Plain text without any special characters";
        assert_eq!(preprocess_scientific_text(input.to_string()), input);
    }
}
