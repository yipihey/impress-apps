//! LaTeX character decoding
//!
//! Decodes LaTeX special characters and commands to Unicode.

use lazy_static::lazy_static;
use regex::Regex;

pub(crate) fn decode_latex_internal(input: String) -> String {
    let mut result = input;

    // Combine all patterns and sort by length (longest first) to avoid partial matches
    // E.g., "\leq" must be matched before "\l", "\'{\i}" before "\i"
    let all_patterns = ALL_PATTERNS.iter();

    for (pattern, replacement) in all_patterns {
        result = result.replace(pattern, replacement);
    }

    // Replace ~ (non-breaking space) only outside URLs
    result = replace_tilde_outside_urls(&result);

    // Remove remaining TeX commands (like \textrm, \textit, etc.)
    result = remove_tex_commands(&result);

    // Clean up extra braces
    result = clean_braces(&result);

    result
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn decode_latex(input: String) -> String {
    decode_latex_internal(input)
}

// ===== Accent Patterns =====

lazy_static! {
    static ref ACCENT_PATTERNS: Vec<(&'static str, &'static str)> = vec![
        // Umlaut (diaeresis)
        ("\\\"a", "ä"), ("\\\"A", "Ä"),
        ("\\\"e", "ë"), ("\\\"E", "Ë"),
        ("\\\"i", "ï"), ("\\\"I", "Ï"),
        ("\\\"o", "ö"), ("\\\"O", "Ö"),
        ("\\\"u", "ü"), ("\\\"U", "Ü"),
        ("\\\"y", "ÿ"), ("\\\"Y", "Ÿ"),
        ("\\\"{a}", "ä"), ("\\\"{A}", "Ä"),
        ("\\\"{e}", "ë"), ("\\\"{E}", "Ë"),
        ("\\\"{i}", "ï"), ("\\\"{I}", "Ï"),
        ("\\\"{o}", "ö"), ("\\\"{O}", "Ö"),
        ("\\\"{u}", "ü"), ("\\\"{U}", "Ü"),

        // Acute accent
        ("\\'a", "á"), ("\\'A", "Á"),
        ("\\'e", "é"), ("\\'E", "É"),
        ("\\'i", "í"), ("\\'I", "Í"),
        ("\\'o", "ó"), ("\\'O", "Ó"),
        ("\\'u", "ú"), ("\\'U", "Ú"),
        ("\\'y", "ý"), ("\\'Y", "Ý"),
        ("\\'{a}", "á"), ("\\'{A}", "Á"),
        ("\\'{e}", "é"), ("\\'{E}", "É"),
        ("\\'{i}", "í"), ("\\'{I}", "Í"),
        ("\\'{\\i}", "í"), // acute on dotless i
        ("\\'{o}", "ó"), ("\\'{O}", "Ó"),
        ("\\'{u}", "ú"), ("\\'{U}", "Ú"),

        // Grave accent
        ("\\`a", "à"), ("\\`A", "À"),
        ("\\`e", "è"), ("\\`E", "È"),
        ("\\`i", "ì"), ("\\`I", "Ì"),
        ("\\`o", "ò"), ("\\`O", "Ò"),
        ("\\`u", "ù"), ("\\`U", "Ù"),
        ("\\`{a}", "à"), ("\\`{A}", "À"),
        ("\\`{e}", "è"), ("\\`{E}", "È"),
        ("\\`{o}", "ò"), ("\\`{O}", "Ò"),
        ("\\`{u}", "ù"), ("\\`{U}", "Ù"),

        // Circumflex
        ("\\^a", "â"), ("\\^A", "Â"),
        ("\\^e", "ê"), ("\\^E", "Ê"),
        ("\\^i", "î"), ("\\^I", "Î"),
        ("\\^o", "ô"), ("\\^O", "Ô"),
        ("\\^u", "û"), ("\\^U", "Û"),
        ("\\^{a}", "â"), ("\\^{A}", "Â"),
        ("\\^{e}", "ê"), ("\\^{E}", "Ê"),
        ("\\^{o}", "ô"), ("\\^{O}", "Ô"),
        ("\\^{u}", "û"), ("\\^{U}", "Û"),

        // Tilde
        ("\\~a", "ã"), ("\\~A", "Ã"),
        ("\\~n", "ñ"), ("\\~N", "Ñ"),
        ("\\~o", "õ"), ("\\~O", "Õ"),
        ("\\~{a}", "ã"), ("\\~{A}", "Ã"),
        ("\\~{n}", "ñ"), ("\\~{N}", "Ñ"),
        ("\\~{o}", "õ"), ("\\~{O}", "Õ"),

        // Cedilla
        ("\\c c", "ç"), ("\\c C", "Ç"),
        ("\\c{c}", "ç"), ("\\c{C}", "Ç"),

        // Ring
        ("\\r a", "å"), ("\\r A", "Å"),
        ("\\r{a}", "å"), ("\\r{A}", "Å"),
        ("\\aa", "å"), ("\\AA", "Å"),

        // Caron (háček)
        ("\\v c", "č"), ("\\v C", "Č"),
        ("\\v s", "š"), ("\\v S", "Š"),
        ("\\v z", "ž"), ("\\v Z", "Ž"),
        ("\\v{c}", "č"), ("\\v{C}", "Č"),
        ("\\v{s}", "š"), ("\\v{S}", "Š"),
        ("\\v{z}", "ž"), ("\\v{Z}", "Ž"),

        // Breve
        ("\\u a", "ă"), ("\\u A", "Ă"),
        ("\\u{a}", "ă"), ("\\u{A}", "Ă"),

        // Macron
        ("\\=a", "ā"), ("\\=A", "Ā"),
        ("\\=e", "ē"), ("\\=E", "Ē"),
        ("\\=i", "ī"), ("\\=I", "Ī"),
        ("\\=o", "ō"), ("\\=O", "Ō"),
        ("\\=u", "ū"), ("\\=U", "Ū"),

        // Dot above
        ("\\.z", "ż"), ("\\.Z", "Ż"),
        ("\\.{z}", "ż"), ("\\.{Z}", "Ż"),

        // Ogonek
        ("\\k a", "ą"), ("\\k A", "Ą"),
        ("\\k e", "ę"), ("\\k E", "Ę"),
        ("\\k{a}", "ą"), ("\\k{A}", "Ą"),
        ("\\k{e}", "ę"), ("\\k{E}", "Ę"),

        // Stroke
        ("\\l", "ł"), ("\\L", "Ł"),
        ("\\o", "ø"), ("\\O", "Ø"),

        // Dotless i
        ("\\i", "ı"),
        ("{\\i}", "ı"),
    ];
}

// ===== Special Characters =====

lazy_static! {
    static ref SPECIAL_CHARACTERS: Vec<(&'static str, &'static str)> = vec![
        // Ligatures
        ("\\ae", "æ"), ("\\AE", "Æ"),
        ("\\oe", "œ"), ("\\OE", "Œ"),
        ("\\ss", "ß"),
        ("{\\ae}", "æ"), ("{\\AE}", "Æ"),
        ("{\\oe}", "œ"), ("{\\OE}", "Œ"),
        ("{\\ss}", "ß"),

        // Punctuation
        ("---", "—"),  // em dash
        ("--", "–"),   // en dash
        ("``", "\u{201C}"),   // left double quote "
        ("''", "\u{201D}"),   // right double quote "
        ("`", "\u{2018}"),    // left single quote '
        // ("~", " ") — handled separately in decode_latex_internal to avoid mangling URLs

        // Common symbols
        ("\\&", "&"),
        ("\\%", "%"),
        ("\\$", "$"),
        ("\\#", "#"),
        ("\\_", "_"),
        ("\\{", "{"),
        ("\\}", "}"),
        ("\\textasciitilde", "~"),
        ("\\textbackslash", "\\"),
        ("\\copyright", "©"),
        ("\\texttrademark", "™"),
        ("\\textregistered", "®"),
        ("\\pounds", "£"),
        ("\\euro", "€"),
        ("\\yen", "¥"),
        ("\\S", "§"),
        ("\\P", "¶"),
        ("\\dag", "†"),
        ("\\ddag", "‡"),
        ("\\textdagger", "†"),
        ("\\textdaggerdbl", "‡"),
        ("\\textbullet", "•"),
        ("\\ldots", "…"),
        ("\\dots", "…"),
        ("\\textellipsis", "…"),
    ];
}

// ===== Math Symbols =====

lazy_static! {
    static ref MATH_SYMBOLS: Vec<(&'static str, &'static str)> = vec![
        // Greek letters (lowercase)
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"),
        ("\\delta", "δ"), ("\\epsilon", "ε"), ("\\zeta", "ζ"),
        ("\\eta", "η"), ("\\theta", "θ"), ("\\iota", "ι"),
        ("\\kappa", "κ"), ("\\lambda", "λ"), ("\\mu", "μ"),
        ("\\nu", "ν"), ("\\xi", "ξ"), ("\\pi", "π"),
        ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\tau", "τ"),
        ("\\upsilon", "υ"), ("\\phi", "φ"), ("\\chi", "χ"),
        ("\\psi", "ψ"), ("\\omega", "ω"),

        // Greek letters (uppercase)
        ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"),
        ("\\Lambda", "Λ"), ("\\Xi", "Ξ"), ("\\Pi", "Π"),
        ("\\Sigma", "Σ"), ("\\Upsilon", "Υ"), ("\\Phi", "Φ"),
        ("\\Psi", "Ψ"), ("\\Omega", "Ω"),

        // Operators
        ("\\times", "×"), ("\\div", "÷"),
        ("\\pm", "±"), ("\\mp", "∓"),
        ("\\cdot", "·"), ("\\ast", "∗"),
        ("\\star", "⋆"), ("\\circ", "∘"),

        // Relations
        ("\\leq", "≤"), ("\\geq", "≥"),
        ("\\neq", "≠"), ("\\approx", "≈"),
        ("\\equiv", "≡"), ("\\sim", "∼"),
        ("\\propto", "∝"), ("\\ll", "≪"),
        ("\\gg", "≫"),

        // Set theory
        ("\\in", "∈"), ("\\notin", "∉"),
        ("\\subset", "⊂"), ("\\supset", "⊃"),
        ("\\subseteq", "⊆"), ("\\supseteq", "⊇"),
        ("\\cup", "∪"), ("\\cap", "∩"),
        ("\\emptyset", "∅"),

        // Arrows
        ("\\to", "→"), ("\\rightarrow", "→"),
        ("\\leftarrow", "←"), ("\\leftrightarrow", "↔"),
        ("\\Rightarrow", "⇒"), ("\\Leftarrow", "⇐"),
        ("\\Leftrightarrow", "⇔"),

        // Miscellaneous
        ("\\infty", "∞"), ("\\partial", "∂"),
        ("\\nabla", "∇"), ("\\forall", "∀"),
        ("\\exists", "∃"), ("\\neg", "¬"),
        ("\\wedge", "∧"), ("\\vee", "∨"),
        ("\\sum", "∑"), ("\\prod", "∏"),
        ("\\int", "∫"), ("\\sqrt", "√"),
    ];

    /// Combined patterns sorted by length (longest first) to avoid partial matches.
    /// E.g., "\leq" must match before "\l", "\'{\\i}" before "\\i"
    static ref ALL_PATTERNS: Vec<(&'static str, &'static str)> = {
        let mut patterns: Vec<(&str, &str)> = Vec::new();
        patterns.extend(ACCENT_PATTERNS.iter().copied());
        patterns.extend(SPECIAL_CHARACTERS.iter().copied());
        patterns.extend(MATH_SYMBOLS.iter().copied());
        // Sort by pattern length, longest first
        patterns.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
        patterns
    };
}

// ===== TeX Command Removal =====

lazy_static! {
    // Formatting commands - preserve content
    static ref FORMATTING_PATTERNS: Vec<Regex> = vec![
        Regex::new(r"\\textbf\{([^}]*)\}").unwrap(),
        Regex::new(r"\\textit\{([^}]*)\}").unwrap(),
        Regex::new(r"\\textrm\{([^}]*)\}").unwrap(),
        Regex::new(r"\\texttt\{([^}]*)\}").unwrap(),
        Regex::new(r"\\textsf\{([^}]*)\}").unwrap(),
        Regex::new(r"\\textsc\{([^}]*)\}").unwrap(),
        Regex::new(r"\\emph\{([^}]*)\}").unwrap(),
        Regex::new(r"\\underline\{([^}]*)\}").unwrap(),
        Regex::new(r"\\mbox\{([^}]*)\}").unwrap(),
        Regex::new(r"\\text\{([^}]*)\}").unwrap(),
        Regex::new(r"\\mathrm\{([^}]*)\}").unwrap(),
        Regex::new(r"\\mathit\{([^}]*)\}").unwrap(),
        Regex::new(r"\\mathbf\{([^}]*)\}").unwrap(),
    ];

    // Generic command pattern
    static ref GENERIC_COMMAND: Regex = Regex::new(r"\\[a-zA-Z]+\{([^}]*)\}").unwrap();

    // Brace cleaning patterns
    static ref EMPTY_BRACES: Regex = Regex::new(r"\{\}").unwrap();
    static ref SINGLE_CHAR_BRACES: Regex = Regex::new(r"\{([^{}])\}").unwrap();
}

/// Replace `~` with space only when not inside a URL (http://, https://, ftp://).
fn replace_tilde_outside_urls(input: &str) -> String {
    lazy_static! {
        static ref URL_RE: Regex = Regex::new(r"(?i)https?://\S+|ftp://\S+").unwrap();
    }
    let mut result = String::with_capacity(input.len());
    let mut last = 0;
    for m in URL_RE.find_iter(input) {
        // Process text before the URL: replace ~ with space
        result.push_str(&input[last..m.start()].replace('~', " "));
        // Keep the URL intact
        result.push_str(m.as_str());
        last = m.end();
    }
    // Process remaining text after last URL
    result.push_str(&input[last..].replace('~', " "));
    result
}

fn remove_tex_commands(input: &str) -> String {
    let mut result = input.to_string();

    // Remove formatting commands but keep content
    for pattern in FORMATTING_PATTERNS.iter() {
        result = pattern.replace_all(&result, "$1").to_string();
    }

    // Remove other unknown commands
    result = GENERIC_COMMAND.replace_all(&result, "$1").to_string();

    result
}

fn clean_braces(input: &str) -> String {
    let mut result = input.to_string();

    // Remove empty braces
    result = EMPTY_BRACES.replace_all(&result, "").to_string();

    // Remove single-character braces like {a} → a (but keep {DNA} etc.)
    result = SINGLE_CHAR_BRACES.replace_all(&result, "$1").to_string();

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_umlaut_decoding() {
        assert_eq!(decode_latex(r#"M\"uller"#.to_string()), "Müller");
        assert_eq!(decode_latex(r#"M\"{u}ller"#.to_string()), "Müller");
    }

    #[test]
    fn test_acute_accent() {
        assert_eq!(decode_latex(r#"caf\'e"#.to_string()), "café");
        assert_eq!(decode_latex(r#"caf\'{e}"#.to_string()), "café");
    }

    #[test]
    fn test_grave_accent() {
        assert_eq!(decode_latex(r#"\`a la carte"#.to_string()), "à la carte");
    }

    #[test]
    fn test_circumflex() {
        assert_eq!(decode_latex(r#"h\^otel"#.to_string()), "hôtel");
    }

    #[test]
    fn test_tilde() {
        assert_eq!(decode_latex(r#"ma\~nana"#.to_string()), "mañana");
    }

    #[test]
    fn test_cedilla() {
        assert_eq!(decode_latex(r#"gar\c con"#.to_string()), "garçon");
    }

    #[test]
    fn test_special_characters() {
        assert_eq!(decode_latex(r#"10\% off"#.to_string()), "10% off");
        assert_eq!(
            decode_latex(r#"Smith \& Jones"#.to_string()),
            "Smith & Jones"
        );
    }

    #[test]
    fn test_dashes() {
        assert_eq!(decode_latex("pages 1--10".to_string()), "pages 1–10");
        assert_eq!(decode_latex("the---as usual".to_string()), "the—as usual");
    }

    #[test]
    fn test_greek_letters() {
        assert_eq!(
            decode_latex(r#"\alpha particles"#.to_string()),
            "α particles"
        );
        assert_eq!(decode_latex(r#"\Gamma function"#.to_string()), "Γ function");
    }

    #[test]
    fn test_math_symbols() {
        assert_eq!(decode_latex(r#"a \times b"#.to_string()), "a × b");
        assert_eq!(decode_latex(r#"a \leq b"#.to_string()), "a ≤ b");
    }

    #[test]
    fn test_tex_command_removal() {
        assert_eq!(decode_latex(r#"\textbf{bold}"#.to_string()), "bold");
        assert_eq!(decode_latex(r#"\emph{italic}"#.to_string()), "italic");
    }

    #[test]
    fn test_brace_cleaning() {
        assert_eq!(decode_latex("{DNA}".to_string()), "{DNA}");
        assert_eq!(decode_latex("{a}".to_string()), "a");
        assert_eq!(decode_latex("test{}".to_string()), "test");
    }

    #[test]
    fn test_complex_example() {
        let input = r#"M\"uller, J. and Garc\'{\i}a, M."#;
        let expected = "Müller, J. and García, M.";
        assert_eq!(decode_latex(input.to_string()), expected);
    }
}
