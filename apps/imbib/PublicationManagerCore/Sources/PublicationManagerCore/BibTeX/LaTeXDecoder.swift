//
//  LaTeXDecoder.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - LaTeX Decoder

/// Decodes LaTeX special characters and commands to Unicode.
public enum LaTeXDecoder {

    // MARK: - Public API

    /// Decode LaTeX commands to Unicode
    public static func decode(_ input: String) -> String {
        var result = input

        // Decode accented characters (order matters - longer patterns first)
        for (pattern, replacement) in accentPatterns {
            result = result.replacingOccurrences(of: pattern, with: replacement)
        }

        // Decode special characters
        for (pattern, replacement) in specialCharacters {
            result = result.replacingOccurrences(of: pattern, with: replacement)
        }

        // Decode math symbols
        for (pattern, replacement) in mathSymbols {
            result = result.replacingOccurrences(of: pattern, with: replacement)
        }

        // Remove remaining TeX commands (like \textrm, \textit, etc.)
        result = removeTeXCommands(result)

        // Clean up extra braces
        result = cleanBraces(result)

        return result
    }

    // MARK: - Accent Patterns

    private static let accentPatterns: [(String, String)] = [
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
    ]

    // MARK: - Special Characters

    private static let specialCharacters: [(String, String)] = [
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
        ("~", " "),    // non-breaking space

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
    ]

    // MARK: - Math Symbols

    private static let mathSymbols: [(String, String)] = [
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
    ]

    // MARK: - TeX Command Removal

    private static func removeTeXCommands(_ input: String) -> String {
        var result = input

        // Remove common text formatting commands but keep content
        let formattingPatterns = [
            "\\\\textbf\\{([^}]*)\\}",
            "\\\\textit\\{([^}]*)\\}",
            "\\\\textrm\\{([^}]*)\\}",
            "\\\\texttt\\{([^}]*)\\}",
            "\\\\textsf\\{([^}]*)\\}",
            "\\\\textsc\\{([^}]*)\\}",
            "\\\\emph\\{([^}]*)\\}",
            "\\\\underline\\{([^}]*)\\}",
            "\\\\mbox\\{([^}]*)\\}",
            "\\\\text\\{([^}]*)\\}",
            "\\\\mathrm\\{([^}]*)\\}",
            "\\\\mathit\\{([^}]*)\\}",
            "\\\\mathbf\\{([^}]*)\\}",
        ]

        for pattern in formattingPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$1"
                )
            }
        }

        // Remove other unknown commands
        if let regex = try? NSRegularExpression(pattern: "\\\\[a-zA-Z]+\\{([^}]*)\\}") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        return result
    }

    // MARK: - Brace Cleaning

    private static func cleanBraces(_ input: String) -> String {
        var result = input

        // Remove empty braces
        result = result.replacingOccurrences(of: "{}", with: "")

        // Remove single-character braces like {a} → a (but keep {DNA} etc.)
        if let regex = try? NSRegularExpression(pattern: "\\{([^{}])\\}") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        return result
    }
}
