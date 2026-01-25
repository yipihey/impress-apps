//! Bidirectional LaTeX ↔ Typst conversion
//!
//! This module provides conversion between LaTeX and Typst markup, enabling:
//!
//! - **Paste detection**: Automatically detect when pasted content is LaTeX
//! - **Inline conversion**: Convert LaTeX fragments to Typst with suggestions
//! - **Export to LaTeX**: Export Typst documents for journal submission
//!
//! # Confidence Levels
//!
//! Conversions are tagged with confidence levels:
//! - **Exact**: 1:1 mapping, safe to auto-convert
//! - **Equivalent**: Semantically equivalent, might look slightly different
//! - **Approximate**: Best effort, may need manual review
//! - **Manual**: Cannot auto-convert, requires user intervention
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::latex::{LatexConverter, Confidence};
//!
//! let converter = LatexConverter::new();
//!
//! // Detect LaTeX in pasted content
//! if converter.is_latex(pasted_text) {
//!     let suggestions = converter.detect_latex(pasted_text);
//!     for suggestion in suggestions {
//!         println!("{}: {} ({})",
//!             suggestion.explanation,
//!             suggestion.typst_replacement,
//!             suggestion.confidence);
//!     }
//! }
//! ```

use serde::{Deserialize, Serialize};
use std::ops::Range;

/// Confidence level for a conversion.
///
/// Ordered from lowest to highest confidence: Manual < Approximate < Equivalent < Exact
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Confidence {
    /// Cannot auto-convert, requires manual intervention
    Manual,
    /// Best effort conversion, may need manual review
    Approximate,
    /// Semantically equivalent, output may look slightly different
    Equivalent,
    /// 1:1 mapping, safe to auto-convert without review
    Exact,
}

impl Confidence {
    /// Numeric value for ordering (higher = more confident)
    fn rank(&self) -> u8 {
        match self {
            Confidence::Manual => 0,
            Confidence::Approximate => 1,
            Confidence::Equivalent => 2,
            Confidence::Exact => 3,
        }
    }
}

impl PartialOrd for Confidence {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Confidence {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.rank().cmp(&other.rank())
    }
}

impl Confidence {
    /// Check if this confidence level is safe for auto-conversion.
    pub fn is_safe_auto(&self) -> bool {
        matches!(self, Confidence::Exact | Confidence::Equivalent)
    }

    /// Get a human-readable description.
    pub fn description(&self) -> &'static str {
        match self {
            Confidence::Exact => "exact match",
            Confidence::Equivalent => "semantically equivalent",
            Confidence::Approximate => "approximate, review recommended",
            Confidence::Manual => "manual conversion required",
        }
    }
}

impl std::fmt::Display for Confidence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.description())
    }
}

/// A suggestion for converting LaTeX to Typst.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversionSuggestion {
    /// Range in the original LaTeX text
    pub latex_range: Range<usize>,
    /// The original LaTeX text
    pub latex_text: String,
    /// The suggested Typst replacement
    pub typst_replacement: String,
    /// Explanation of what this conversion does
    pub explanation: &'static str,
    /// Confidence level for this conversion
    pub confidence: Confidence,
}

impl ConversionSuggestion {
    fn new(
        latex_range: Range<usize>,
        latex_text: impl Into<String>,
        typst_replacement: impl Into<String>,
        explanation: &'static str,
        confidence: Confidence,
    ) -> Self {
        Self {
            latex_range,
            latex_text: latex_text.into(),
            typst_replacement: typst_replacement.into(),
            explanation,
            confidence,
        }
    }
}

/// Result of a conversion operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversionResult {
    /// The converted output
    pub output: String,
    /// Overall confidence (minimum of all suggestions)
    pub confidence: Confidence,
    /// Warnings or notes about the conversion
    pub warnings: Vec<String>,
    /// Parts that could not be converted
    pub unconverted: Vec<String>,
}

impl ConversionResult {
    fn new(output: String) -> Self {
        Self {
            output,
            confidence: Confidence::Exact,
            warnings: Vec::new(),
            unconverted: Vec::new(),
        }
    }

    fn with_confidence(mut self, confidence: Confidence) -> Self {
        self.confidence = confidence;
        self
    }

    fn with_warning(mut self, warning: impl Into<String>) -> Self {
        self.warnings.push(warning.into());
        self
    }
}

/// A mapping from LaTeX pattern to Typst replacement.
struct LatexMapping {
    /// Pattern to match (simplified - in production would use regex)
    pattern: &'static str,
    /// Replacement pattern (with {1}, {2}, etc. for captures)
    replacement: &'static str,
    /// Human-readable explanation
    explanation: &'static str,
    /// Confidence level
    confidence: Confidence,
}

/// Built-in LaTeX to Typst mappings.
///
/// These cover common LaTeX commands and their Typst equivalents.
const LATEX_TO_TYPST_MAPPINGS: &[LatexMapping] = &[
    // Document structure
    LatexMapping {
        pattern: r"\section",
        replacement: "= ",
        explanation: "Typst uses '=' for headings",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\subsection",
        replacement: "== ",
        explanation: "Typst uses '==' for subsections",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\subsubsection",
        replacement: "=== ",
        explanation: "Typst uses '===' for subsubsections",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\paragraph",
        replacement: "==== ",
        explanation: "Typst uses '====' for paragraphs",
        confidence: Confidence::Equivalent,
    },

    // Text formatting
    LatexMapping {
        pattern: r"\textbf",
        replacement: "*",
        explanation: "*...* for bold",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\textit",
        replacement: "_",
        explanation: "_..._ for italic",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\emph",
        replacement: "_",
        explanation: "_..._ for emphasis",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\underline",
        replacement: "#underline",
        explanation: "#underline[] for underlined text",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\texttt",
        replacement: "`",
        explanation: "`...` for code",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\textsc",
        replacement: "#smallcaps",
        explanation: "#smallcaps[] for small caps",
        confidence: Confidence::Exact,
    },

    // Citations and references
    LatexMapping {
        pattern: r"\cite",
        replacement: "@",
        explanation: "@ prefix for citations",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\ref",
        replacement: "@",
        explanation: "@ prefix for references",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\label",
        replacement: "<",
        explanation: "<label> for labels",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\footnote",
        replacement: "#footnote",
        explanation: "#footnote[] for footnotes",
        confidence: Confidence::Exact,
    },

    // Math delimiters
    LatexMapping {
        pattern: r"\(",
        replacement: "$",
        explanation: "$ for inline math",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\)",
        replacement: "$",
        explanation: "$ for inline math",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\[",
        replacement: "$ ",
        explanation: "$ ... $ for display math",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\]",
        replacement: " $",
        explanation: "$ ... $ for display math",
        confidence: Confidence::Exact,
    },

    // Common math commands
    LatexMapping {
        pattern: r"\frac",
        replacement: "/",
        explanation: "a/b for fractions in Typst",
        confidence: Confidence::Equivalent,
    },
    LatexMapping {
        pattern: r"\sqrt",
        replacement: "sqrt",
        explanation: "sqrt() for square root",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\sum",
        replacement: "sum",
        explanation: "sum for summation",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\prod",
        replacement: "product",
        explanation: "product for product",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\int",
        replacement: "integral",
        explanation: "integral for integration",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\lim",
        replacement: "lim",
        explanation: "lim for limits",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\infty",
        replacement: "infinity",
        explanation: "infinity for infinity symbol",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\alpha",
        replacement: "alpha",
        explanation: "alpha for Greek letters",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\beta",
        replacement: "beta",
        explanation: "beta for Greek letters",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\gamma",
        replacement: "gamma",
        explanation: "gamma for Greek letters",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\delta",
        replacement: "delta",
        explanation: "delta for Greek letters",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\lambda",
        replacement: "lambda",
        explanation: "lambda for Greek letters",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\mu",
        replacement: "mu",
        explanation: "mu for Greek letters",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\pi",
        replacement: "pi",
        explanation: "pi for pi",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\sigma",
        replacement: "sigma",
        explanation: "sigma for Greek letters",
        confidence: Confidence::Exact,
    },
    LatexMapping {
        pattern: r"\omega",
        replacement: "omega",
        explanation: "omega for Greek letters",
        confidence: Confidence::Exact,
    },

    // Environments (approximations)
    LatexMapping {
        pattern: r"\begin{itemize}",
        replacement: "",
        explanation: "Typst uses - for lists",
        confidence: Confidence::Equivalent,
    },
    LatexMapping {
        pattern: r"\end{itemize}",
        replacement: "",
        explanation: "Typst lists don't need explicit end",
        confidence: Confidence::Equivalent,
    },
    LatexMapping {
        pattern: r"\begin{enumerate}",
        replacement: "",
        explanation: "Typst uses + for numbered lists",
        confidence: Confidence::Equivalent,
    },
    LatexMapping {
        pattern: r"\end{enumerate}",
        replacement: "",
        explanation: "Typst lists don't need explicit end",
        confidence: Confidence::Equivalent,
    },
    LatexMapping {
        pattern: r"\item",
        replacement: "- ",
        explanation: "- for list items",
        confidence: Confidence::Equivalent,
    },
];

/// Typst to LaTeX mappings for export.
///
/// These mappings are used by `typst_to_latex` for export to journal submission formats.
#[allow(dead_code)]
const TYPST_TO_LATEX_MAPPINGS: &[(&str, &str)] = &[
    // Headings
    ("= ", "\\section{"),
    ("== ", "\\subsection{"),
    ("=== ", "\\subsubsection{"),

    // Text formatting
    ("*", "\\textbf{"),
    ("_", "\\textit{"),
    ("`", "\\texttt{"),

    // Citations
    ("@", "\\cite{"),

    // Math
    ("$", "\\("),
    ("sqrt(", "\\sqrt{"),
    ("sum", "\\sum"),
    ("product", "\\prod"),
    ("integral", "\\int"),
    ("infinity", "\\infty"),

    // Greek letters
    ("alpha", "\\alpha"),
    ("beta", "\\beta"),
    ("gamma", "\\gamma"),
    ("delta", "\\delta"),
    ("lambda", "\\lambda"),
    ("mu", "\\mu"),
    ("pi", "\\pi"),
    ("sigma", "\\sigma"),
    ("omega", "\\omega"),
];

/// LaTeX ↔ Typst converter.
pub struct LatexConverter {
    /// Minimum confidence for auto-conversion
    auto_convert_threshold: Confidence,
}

impl LatexConverter {
    /// Create a new converter with default settings.
    pub fn new() -> Self {
        Self {
            auto_convert_threshold: Confidence::Equivalent,
        }
    }

    /// Set the minimum confidence for auto-conversion.
    pub fn with_auto_convert_threshold(mut self, threshold: Confidence) -> Self {
        self.auto_convert_threshold = threshold;
        self
    }

    /// Check if the input looks like LaTeX.
    ///
    /// Returns true if the input contains common LaTeX patterns.
    pub fn is_latex(&self, input: &str) -> bool {
        // Check for common LaTeX indicators
        let indicators = [
            r"\section",
            r"\begin{",
            r"\end{",
            r"\textbf",
            r"\textit",
            r"\cite",
            r"\ref",
            r"\frac",
            r"\sum",
            r"\int",
            r"\\",
            r"\item",
        ];

        // Count how many indicators are present
        let count = indicators.iter().filter(|&ind| input.contains(ind)).count();

        // If we find 2+ indicators, or the document starts with common LaTeX patterns
        count >= 2
            || input.trim_start().starts_with(r"\documentclass")
            || input.trim_start().starts_with(r"\begin{document}")
            || input.trim_start().starts_with(r"\section")
    }

    /// Detect LaTeX patterns in the input and return conversion suggestions.
    pub fn detect_latex(&self, source: &str) -> Vec<ConversionSuggestion> {
        let mut suggestions = Vec::new();

        for mapping in LATEX_TO_TYPST_MAPPINGS {
            let mut search_start = 0;
            while let Some(pos) = source[search_start..].find(mapping.pattern) {
                let abs_pos = search_start + pos;

                // Determine the extent of the match
                let (match_end, latex_text, typst_text) =
                    self.extract_latex_command(source, abs_pos, mapping);

                suggestions.push(ConversionSuggestion::new(
                    abs_pos..match_end,
                    latex_text,
                    typst_text,
                    mapping.explanation,
                    mapping.confidence,
                ));

                search_start = match_end;
            }
        }

        // Sort by position
        suggestions.sort_by_key(|s| s.latex_range.start);

        // Remove overlapping suggestions (keep higher confidence)
        let mut filtered = Vec::new();
        for suggestion in suggestions {
            let overlaps = filtered
                .iter()
                .any(|s: &ConversionSuggestion| ranges_overlap(&s.latex_range, &suggestion.latex_range));

            if !overlaps {
                filtered.push(suggestion);
            }
        }

        filtered
    }

    /// Extract a LaTeX command and its argument (if any).
    fn extract_latex_command(
        &self,
        source: &str,
        start: usize,
        mapping: &LatexMapping,
    ) -> (usize, String, String) {
        let command_end = start + mapping.pattern.len();

        // Check if there's a braced argument
        if command_end < source.len() && source.as_bytes()[command_end] == b'{' {
            // Find matching brace
            if let Some((arg_end, arg)) = self.extract_braced_arg(source, command_end) {
                let latex_text = &source[start..arg_end];

                // Build Typst replacement
                let typst_text = if mapping.replacement.ends_with('*')
                    || mapping.replacement.ends_with('_')
                    || mapping.replacement.ends_with('`')
                {
                    // Wrapping syntax
                    format!("{}{}{}", mapping.replacement, arg, mapping.replacement)
                } else if mapping.replacement.starts_with('#') {
                    // Function syntax
                    format!("{}[{}]", mapping.replacement, arg)
                } else if mapping.replacement == "@" || mapping.replacement == "<" {
                    // Citation/label syntax
                    format!("{}{}", mapping.replacement, arg)
                } else if mapping.replacement.ends_with(' ') {
                    // Heading syntax (= Title)
                    format!("{}{}", mapping.replacement, arg)
                } else {
                    // Other
                    format!("{}{}", mapping.replacement, arg)
                }
                ;

                return (arg_end, latex_text.to_string(), typst_text);
            }
        }

        // No argument - just the command
        (
            command_end,
            source[start..command_end].to_string(),
            mapping.replacement.to_string(),
        )
    }

    /// Extract a braced argument starting at the opening brace.
    fn extract_braced_arg(&self, source: &str, start: usize) -> Option<(usize, String)> {
        if source.as_bytes().get(start) != Some(&b'{') {
            return None;
        }

        let mut depth = 1;
        let mut pos = start + 1;
        let bytes = source.as_bytes();

        while pos < source.len() && depth > 0 {
            match bytes[pos] {
                b'{' => depth += 1,
                b'}' => depth -= 1,
                b'\\' => {
                    // Skip escaped character
                    pos += 1;
                }
                _ => {}
            }
            pos += 1;
        }

        if depth == 0 {
            let arg = &source[start + 1..pos - 1];
            Some((pos, arg.to_string()))
        } else {
            None
        }
    }

    /// Convert a LaTeX fragment to Typst.
    pub fn latex_to_typst(&self, latex: &str) -> ConversionResult {
        let suggestions = self.detect_latex(latex);

        if suggestions.is_empty() {
            // No LaTeX patterns found - return as-is
            return ConversionResult::new(latex.to_string())
                .with_confidence(Confidence::Manual)
                .with_warning("No LaTeX patterns detected");
        }

        // Apply conversions
        let mut result = String::new();
        let mut last_end = 0;
        let mut min_confidence = Confidence::Exact;

        for suggestion in &suggestions {
            // Copy text before this suggestion
            result.push_str(&latex[last_end..suggestion.latex_range.start]);

            // Apply the conversion
            result.push_str(&suggestion.typst_replacement);

            last_end = suggestion.latex_range.end;
            min_confidence = min_confidence.min(suggestion.confidence);
        }

        // Copy remaining text
        result.push_str(&latex[last_end..]);

        ConversionResult::new(result).with_confidence(min_confidence)
    }

    /// Convert a Typst document to LaTeX for export.
    ///
    /// This is a best-effort conversion for journal submission.
    pub fn typst_to_latex(&self, source: &str) -> Result<String, ConversionError> {
        let mut result = String::new();

        // Add LaTeX preamble
        result.push_str("\\documentclass{article}\n");
        result.push_str("\\usepackage{amsmath}\n");
        result.push_str("\\usepackage{amssymb}\n");
        result.push_str("\\usepackage{graphicx}\n");
        result.push_str("\\usepackage{hyperref}\n");
        result.push_str("\n\\begin{document}\n\n");

        // Convert content
        let converted = self.convert_typst_content(source)?;
        result.push_str(&converted);

        result.push_str("\n\\end{document}\n");

        Ok(result)
    }

    /// Convert Typst content to LaTeX (without preamble).
    fn convert_typst_content(&self, source: &str) -> Result<String, ConversionError> {
        let mut result = String::new();
        let mut chars = source.chars().peekable();
        let mut in_math = false;

        while let Some(c) = chars.next() {
            match c {
                // Headings
                '=' if !in_math && result.ends_with('\n') || result.is_empty() => {
                    let level = 1 + chars.clone().take_while(|&c| c == '=').count();
                    for _ in 1..level {
                        chars.next();
                    }
                    // Skip space after =
                    if chars.peek() == Some(&' ') {
                        chars.next();
                    }
                    // Read title until newline
                    let title: String = chars.by_ref().take_while(|&c| c != '\n').collect();

                    let cmd = match level {
                        1 => "section",
                        2 => "subsection",
                        3 => "subsubsection",
                        _ => "paragraph",
                    };
                    result.push_str(&format!("\\{}{{{}}}\\n", cmd, title.trim()));
                }

                // Math mode
                '$' => {
                    in_math = !in_math;
                    if in_math {
                        result.push_str("\\(");
                    } else {
                        result.push_str("\\)");
                    }
                }

                // Bold
                '*' if !in_math => {
                    let content: String = chars.by_ref().take_while(|&c| c != '*').collect();
                    result.push_str(&format!("\\textbf{{{}}}", content));
                }

                // Italic
                '_' if !in_math => {
                    let content: String = chars.by_ref().take_while(|&c| c != '_').collect();
                    result.push_str(&format!("\\textit{{{}}}", content));
                }

                // Code
                '`' => {
                    let content: String = chars.by_ref().take_while(|&c| c != '`').collect();
                    result.push_str(&format!("\\texttt{{{}}}", content));
                }

                // Citations
                '@' if !in_math => {
                    let key: String = chars
                        .by_ref()
                        .take_while(|&c| c.is_alphanumeric() || c == '_' || c == '-' || c == ':')
                        .collect();
                    result.push_str(&format!("\\cite{{{}}}", key));
                }

                // List items
                '-' if result.ends_with('\n') || result.is_empty() => {
                    if chars.peek() == Some(&' ') {
                        chars.next();
                        result.push_str("\\item ");
                    } else {
                        result.push('-');
                    }
                }

                // Typst functions
                '#' => {
                    let func: String = chars
                        .by_ref()
                        .take_while(|&c| c.is_alphanumeric() || c == '-')
                        .collect();

                    match func.as_str() {
                        "footnote" => {
                            // Skip [ and read content until ]
                            if chars.peek() == Some(&'[') {
                                chars.next();
                                let content: String =
                                    chars.by_ref().take_while(|&c| c != ']').collect();
                                result.push_str(&format!("\\footnote{{{}}}", content));
                            }
                        }
                        "underline" => {
                            if chars.peek() == Some(&'[') {
                                chars.next();
                                let content: String =
                                    chars.by_ref().take_while(|&c| c != ']').collect();
                                result.push_str(&format!("\\underline{{{}}}", content));
                            }
                        }
                        "smallcaps" => {
                            if chars.peek() == Some(&'[') {
                                chars.next();
                                let content: String =
                                    chars.by_ref().take_while(|&c| c != ']').collect();
                                result.push_str(&format!("\\textsc{{{}}}", content));
                            }
                        }
                        _ => {
                            // Unknown function - pass through with warning
                            result.push('#');
                            result.push_str(&func);
                        }
                    }
                }

                // Default - copy character
                _ => result.push(c),
            }
        }

        // Clean up some common issues
        let result = result
            .replace("\\n", "\n")
            .replace("\n\n\n", "\n\n");

        Ok(result)
    }

    /// Apply a list of suggestions to convert LaTeX to Typst.
    pub fn apply_suggestions(&self, source: &str, suggestions: &[ConversionSuggestion]) -> String {
        let mut result = String::new();
        let mut last_end = 0;

        for suggestion in suggestions {
            if suggestion.confidence >= self.auto_convert_threshold {
                result.push_str(&source[last_end..suggestion.latex_range.start]);
                result.push_str(&suggestion.typst_replacement);
                last_end = suggestion.latex_range.end;
            }
        }

        result.push_str(&source[last_end..]);
        result
    }
}

impl Default for LatexConverter {
    fn default() -> Self {
        Self::new()
    }
}

/// Error type for conversion failures.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversionError {
    /// Error message
    pub message: String,
    /// Position in source where error occurred
    pub position: Option<usize>,
    /// The problematic content
    pub context: Option<String>,
}

impl ConversionError {
    /// Create a new conversion error.
    #[allow(dead_code)]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            position: None,
            context: None,
        }
    }

    /// Create a conversion error with a position.
    #[allow(dead_code)]
    pub fn at_position(message: impl Into<String>, position: usize) -> Self {
        Self {
            message: message.into(),
            position: Some(position),
            context: None,
        }
    }
}

impl std::fmt::Display for ConversionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for ConversionError {}

/// Check if two ranges overlap.
fn ranges_overlap(a: &Range<usize>, b: &Range<usize>) -> bool {
    a.start < b.end && b.start < a.end
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_latex_positive() {
        let converter = LatexConverter::new();

        assert!(converter.is_latex(r"\section{Introduction}"));
        assert!(converter.is_latex(r"\begin{document}\section{Test}\end{document}"));
        assert!(converter.is_latex(r"\textbf{bold} and \textit{italic}"));
        assert!(converter.is_latex(r"\cite{smith2023} and \ref{fig:1}"));
    }

    #[test]
    fn test_is_latex_negative() {
        let converter = LatexConverter::new();

        assert!(!converter.is_latex("Hello, world!"));
        assert!(!converter.is_latex("= Heading\n\nParagraph text"));
        assert!(!converter.is_latex("$x + y = z$")); // Typst math, not LaTeX
    }

    #[test]
    fn test_detect_latex_section() {
        let converter = LatexConverter::new();
        let suggestions = converter.detect_latex(r"\section{Introduction}");

        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].typst_replacement, "= Introduction");
        assert_eq!(suggestions[0].confidence, Confidence::Exact);
    }

    #[test]
    fn test_detect_latex_formatting() {
        let converter = LatexConverter::new();
        let suggestions = converter.detect_latex(r"\textbf{bold} and \textit{italic}");

        assert_eq!(suggestions.len(), 2);
        assert_eq!(suggestions[0].typst_replacement, "*bold*");
        assert_eq!(suggestions[1].typst_replacement, "_italic_");
    }

    #[test]
    fn test_detect_latex_citation() {
        let converter = LatexConverter::new();
        let suggestions = converter.detect_latex(r"\cite{smith2023}");

        assert_eq!(suggestions.len(), 1);
        assert_eq!(suggestions[0].typst_replacement, "@smith2023");
    }

    #[test]
    fn test_latex_to_typst() {
        let converter = LatexConverter::new();
        let result = converter.latex_to_typst(r"\section{Hello}\textbf{world}");

        assert!(result.output.contains("= Hello"));
        assert!(result.output.contains("*world*"));
    }

    #[test]
    fn test_typst_to_latex_heading() {
        let converter = LatexConverter::new();
        let result = converter.typst_to_latex("= Introduction\n\nSome text.").unwrap();

        assert!(result.contains("\\documentclass{article}"));
        assert!(result.contains("\\section{Introduction}"));
        assert!(result.contains("Some text."));
    }

    #[test]
    fn test_typst_to_latex_formatting() {
        let converter = LatexConverter::new();
        let result = converter.convert_typst_content("*bold* and _italic_").unwrap();

        assert!(result.contains("\\textbf{bold}"));
        assert!(result.contains("\\textit{italic}"));
    }

    #[test]
    fn test_typst_to_latex_citation() {
        let converter = LatexConverter::new();
        let result = converter.convert_typst_content("See @smith2023 for details.").unwrap();

        assert!(result.contains("\\cite{smith2023}"));
    }

    #[test]
    fn test_confidence_ordering() {
        assert!(Confidence::Exact > Confidence::Equivalent);
        assert!(Confidence::Equivalent > Confidence::Approximate);
        assert!(Confidence::Approximate > Confidence::Manual);
    }

    #[test]
    fn test_confidence_safe_auto() {
        assert!(Confidence::Exact.is_safe_auto());
        assert!(Confidence::Equivalent.is_safe_auto());
        assert!(!Confidence::Approximate.is_safe_auto());
        assert!(!Confidence::Manual.is_safe_auto());
    }

    #[test]
    fn test_apply_suggestions_with_threshold() {
        let converter = LatexConverter::new().with_auto_convert_threshold(Confidence::Exact);
        let source = r"\textbf{bold}";
        let suggestions = converter.detect_latex(source);

        let result = converter.apply_suggestions(source, &suggestions);
        assert_eq!(result, "*bold*");
    }
}
