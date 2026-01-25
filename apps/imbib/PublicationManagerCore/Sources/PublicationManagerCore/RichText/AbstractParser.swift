//
//  AbstractParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation

// MARK: - Abstract Segment

/// A segment of parsed abstract content.
public enum AbstractSegment: Identifiable, Equatable {
    case text(String)
    case inlineMath(String)     // LaTeX for inline rendering
    case displayMath(String)    // LaTeX for display/block rendering

    public var id: String {
        switch self {
        case .text(let str): return "text:\(str.hashValue)"
        case .inlineMath(let latex): return "inline:\(latex.hashValue)"
        case .displayMath(let latex): return "display:\(latex.hashValue)"
        }
    }
}

// MARK: - Abstract Parser

/// Parses scientific abstracts into renderable segments.
///
/// Handles:
/// - MathML from ADS, CrossRef, etc. (converted to LaTeX)
/// - LaTeX expressions ($...$, $$...$$, \(...\), \[...\])
/// - HTML entities (&lt;, &amp;, etc.)
/// - HTML subscript/superscript tags (<sub>, <sup>)
///
/// Usage:
/// ```swift
/// let segments = AbstractParser.parse(abstract)
/// for segment in segments {
///     // Render each segment appropriately
/// }
/// ```
public enum AbstractParser {

    // MARK: - Public Interface

    /// Parse abstract text into segments for rendering.
    public static func parse(_ text: String) -> [AbstractSegment] {
        // Step 1: Normalize arXiv/JSON escaping (\\beta → \beta, \\[ → [, etc.)
        var processed = normalizeArXivEscaping(text)

        // Step 2: Convert MathML to LaTeX
        processed = MathMLToLaTeX.convert(processed)

        // Step 3: Decode HTML entities
        processed = decodeHTMLEntities(processed)

        // Step 4: Convert HTML sub/sup to LaTeX
        processed = convertHTMLSubSup(processed)

        // Step 5: Parse into segments (text vs math)
        return parseSegments(processed)
    }

    /// Check if text contains math content.
    public static func containsMath(_ text: String) -> Bool {
        text.contains("$") ||
        text.contains("\\(") ||
        text.contains("\\[") ||
        text.contains("<mml:") ||
        text.contains("<inline-formula")
    }

    // MARK: - ArXiv Escaping Normalization

    /// Normalize arXiv/JSON-style double-escaping to proper LaTeX.
    ///
    /// ArXiv abstracts from API responses often have:
    /// - `\\beta` instead of `\beta` (JSON escaping)
    /// - `\[` for literal brackets inside `$...$`
    /// - `\_` for underscores
    /// - `\\,` for thin spaces
    ///
    /// This function normalizes these to standard LaTeX.
    private static func normalizeArXivEscaping(_ text: String) -> String {
        var result = text

        // First, process math regions to handle \[ and \] as literal brackets inside $...$
        // We need to be careful: \[ and \] at the TOP level are display math delimiters,
        // but inside $...$ they should be literal brackets.
        result = normalizeBracketsInMathMode(result)

        // Common LaTeX commands that get double-escaped in JSON
        // Convert \\command to \command
        let latexCommands = [
            "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
            "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma",
            "tau", "upsilon", "phi", "chi", "psi", "omega",
            "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta",
            "Iota", "Kappa", "Lambda", "Mu", "Nu", "Xi", "Pi", "Rho", "Sigma",
            "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega",
            "pm", "mp", "times", "div", "cdot", "ast", "star", "circ", "bullet",
            "oplus", "otimes", "odot", "oslash", "ominus",
            "le", "ge", "leq", "geq", "ll", "gg", "subset", "supset", "subseteq", "supseteq",
            "in", "notin", "ni", "forall", "exists", "neg", "land", "lor",
            "cap", "cup", "setminus", "emptyset", "varnothing",
            "equiv", "sim", "simeq", "approx", "cong", "neq", "ne", "propto", "doteq",
            "infty", "nabla", "partial", "prime",
            "sum", "prod", "int", "oint", "iint", "iiint",
            "lim", "sup", "inf", "max", "min", "arg", "det", "dim", "ker", "hom",
            "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
            "sinh", "cosh", "tanh", "coth", "log", "ln", "exp", "lg",
            "sqrt", "frac", "tfrac", "dfrac", "binom", "tbinom", "dbinom",
            "overline", "underline", "widehat", "widetilde", "hat", "tilde", "bar", "vec", "dot", "ddot",
            "left", "right", "big", "Big", "bigg", "Bigg",
            "text", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathbb", "mathfrak",
            "hspace", "vspace", "quad", "qquad", "hfill", "vfill",
            "over", "atop", "above", "choose",
            "to", "rightarrow", "leftarrow", "Rightarrow", "Leftarrow", "leftrightarrow", "Leftrightarrow",
            "uparrow", "downarrow", "Uparrow", "Downarrow",
            "cdots", "ldots", "vdots", "ddots",
        ]

        for cmd in latexCommands {
            // Replace \\cmd with \cmd (but not \\\cmd which would be escaped backslash + cmd)
            // Use word boundary to avoid partial matches
            result = result.replacingOccurrences(
                of: "\\\\\(cmd)(?![a-zA-Z])",
                with: "\\\(cmd)",
                options: .regularExpression
            )
        }

        // Handle spacing commands: \\, \\; \\: \\! \\ (space)
        result = result.replacingOccurrences(of: "\\\\,", with: "\\,")
        result = result.replacingOccurrences(of: "\\\\;", with: "\\;")
        result = result.replacingOccurrences(of: "\\\\:", with: "\\:")
        result = result.replacingOccurrences(of: "\\\\!", with: "\\!")
        result = result.replacingOccurrences(of: "\\\\ ", with: "\\ ")

        // Handle escaped underscore: \_ → _ (in math mode, _ is already subscript)
        result = result.replacingOccurrences(of: "\\_", with: "_")

        // Handle escaped braces: \\{ → \{ and \\} → \}
        result = result.replacingOccurrences(of: "\\\\{", with: "\\{")
        result = result.replacingOccurrences(of: "\\\\}", with: "\\}")

        return result
    }

    /// Convert \[ and \] to literal brackets when inside $...$ math regions.
    private static func normalizeBracketsInMathMode(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        var inMathMode = false

        while index < text.endIndex {
            // Check for $$ (display math delimiter)
            if text[index...].hasPrefix("$$") {
                result.append(contentsOf: "$$")
                index = text.index(index, offsetBy: 2)
                continue
            }

            // Check for $ (toggle inline math mode)
            if text[index] == "$" {
                inMathMode.toggle()
                result.append("$")
                index = text.index(after: index)
                continue
            }

            // If in math mode, convert \[ and \] to [ and ]
            if inMathMode {
                if text[index...].hasPrefix("\\[") {
                    result.append("[")
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                if text[index...].hasPrefix("\\]") {
                    result.append("]")
                    index = text.index(index, offsetBy: 2)
                    continue
                }
            }

            result.append(text[index])
            index = text.index(after: index)
        }

        return result
    }

    // MARK: - HTML Entity Decoding

    private static let htmlEntities: [String: String] = [
        "&lt;": "<",
        "&gt;": ">",
        "&amp;": "&",
        "&nbsp;": " ",
        "&quot;": "\"",
        "&apos;": "'",
        "&ndash;": "–",
        "&mdash;": "—",
        "&times;": "×",
        "&divide;": "÷",
        "&plusmn;": "±",
        "&deg;": "°",
        "&micro;": "µ",
        "&alpha;": "α",
        "&beta;": "β",
        "&gamma;": "γ",
        "&delta;": "δ",
        "&epsilon;": "ε",
        "&theta;": "θ",
        "&lambda;": "λ",
        "&mu;": "μ",
        "&pi;": "π",
        "&sigma;": "σ",
        "&omega;": "ω",
        "&infin;": "∞",
        "&sum;": "∑",
        "&prod;": "∏",
        "&radic;": "√",
        "&prop;": "∝",
        "&asymp;": "≈",
        "&ne;": "≠",
        "&le;": "≤",
        "&ge;": "≥",
        "&sub;": "⊂",
        "&sup;": "⊃",
        "&isin;": "∈",
        "&notin;": "∉",
        "&empty;": "∅",
        "&nabla;": "∇",
        "&part;": "∂",
        "&int;": "∫",
    ]

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        // Named entities
        for (entity, replacement) in htmlEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric entities (&#123; or &#x1F;)
        // Decimal: &#123;
        let decimalPattern = "&#(\\d+);"
        if let regex = try? NSRegularExpression(pattern: decimalPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result),
                   let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(String(result[codeRange])),
                   let scalar = Unicode.Scalar(codePoint) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }

        // Hex: &#x1F;
        let hexPattern = "&#x([0-9A-Fa-f]+);"
        if let regex = try? NSRegularExpression(pattern: hexPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result),
                   let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(String(result[codeRange]), radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }

        return result
    }

    // MARK: - HTML Sub/Sup Conversion

    private static func convertHTMLSubSup(_ text: String) -> String {
        var result = text

        // Convert <sub>x</sub> to _x or _{x}
        let subPattern = "<sub>([^<]+)</sub>"
        if let regex = try? NSRegularExpression(pattern: subPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result),
                   let contentRange = Range(match.range(at: 1), in: result) {
                    let content = String(result[contentRange])
                    let replacement = content.count == 1 ? "_\(content)" : "_{\\text{\(content)}}"
                    result.replaceSubrange(fullRange, with: replacement)
                }
            }
        }

        // Convert <sup>x</sup> to ^x or ^{x}
        let supPattern = "<sup>([^<]+)</sup>"
        if let regex = try? NSRegularExpression(pattern: supPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: result),
                   let contentRange = Range(match.range(at: 1), in: result) {
                    let content = String(result[contentRange])
                    let replacement = content.count == 1 ? "^\(content)" : "^{\\text{\(content)}}"
                    result.replaceSubrange(fullRange, with: replacement)
                }
            }
        }

        return result
    }

    // MARK: - Segment Parsing

    private static func parseSegments(_ text: String) -> [AbstractSegment] {
        var segments: [AbstractSegment] = []
        var currentText = ""
        var index = text.startIndex

        while index < text.endIndex {
            // Check for display math $$...$$ first
            if text[index...].hasPrefix("$$") {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }

                let mathStart = text.index(index, offsetBy: 2)
                if let mathEnd = text[mathStart...].range(of: "$$")?.lowerBound {
                    let latex = String(text[mathStart..<mathEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !latex.isEmpty {
                        segments.append(.displayMath(latex))
                    }
                    index = text.index(mathEnd, offsetBy: 2)
                    continue
                }
            }

            // Check for display math \[...\]
            if text[index...].hasPrefix("\\[") {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }

                let mathStart = text.index(index, offsetBy: 2)
                if let mathEnd = text[mathStart...].range(of: "\\]")?.lowerBound {
                    let latex = String(text[mathStart..<mathEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !latex.isEmpty {
                        segments.append(.displayMath(latex))
                    }
                    index = text.index(mathEnd, offsetBy: 2)
                    continue
                }
            }

            // Check for inline math $...$ (not $$)
            if text[index] == "$" {
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex && text[nextIndex] != "$" {
                    if !currentText.isEmpty {
                        segments.append(.text(currentText))
                        currentText = ""
                    }

                    if let mathEnd = text[nextIndex...].firstIndex(of: "$") {
                        let latex = String(text[nextIndex..<mathEnd])
                        // Validate: not empty, no unmatched newlines
                        if !latex.isEmpty && !latex.contains("\n\n") {
                            segments.append(.inlineMath(latex))
                            index = text.index(after: mathEnd)
                            continue
                        }
                    }
                }
            }

            // Check for inline math \(...\)
            if text[index...].hasPrefix("\\(") {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }

                let mathStart = text.index(index, offsetBy: 2)
                if let mathEnd = text[mathStart...].range(of: "\\)")?.lowerBound {
                    let latex = String(text[mathStart..<mathEnd])
                    if !latex.isEmpty {
                        segments.append(.inlineMath(latex))
                    }
                    index = text.index(mathEnd, offsetBy: 2)
                    continue
                }
            }

            // Regular character
            currentText.append(text[index])
            index = text.index(after: index)
        }

        // Add remaining text
        if !currentText.isEmpty {
            segments.append(.text(currentText))
        }

        return segments
    }
}

// MARK: - MathML to LaTeX Converter

/// Converts MathML to LaTeX for rendering with SwiftMath.
public enum MathMLToLaTeX {

    /// Convert text containing MathML to text with LaTeX.
    public static func convert(_ text: String) -> String {
        var result = text

        // Process <inline-formula>...</inline-formula> tags
        result = processInlineFormulas(result)

        // Process standalone <mml:math>...</mml:math> tags
        result = processStandaloneMathML(result)

        return result
    }

    // MARK: - Formula Processing

    private static func processInlineFormulas(_ text: String) -> String {
        var result = text
        let pattern = "<inline-formula[^>]*>(.*?)</inline-formula>"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return result
        }

        let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else {
                continue
            }

            let mathMLContent = String(result[contentRange])
            let latex = convertMathMLToLaTeX(mathMLContent)
            // Wrap in inline math delimiters
            result.replaceSubrange(fullRange, with: "$\(latex)$")
        }

        return result
    }

    private static func processStandaloneMathML(_ text: String) -> String {
        var result = text
        let pattern = "<mml:math[^>]*>(.*?)</mml:math>"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return result
        }

        let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else {
                continue
            }

            let mathMLContent = String(result[contentRange])
            let latex = convertMathMLToLaTeX(mathMLContent)
            // Wrap in inline math delimiters
            result.replaceSubrange(fullRange, with: "$\(latex)$")
        }

        return result
    }

    // MARK: - MathML Element Conversion

    private static func convertMathMLToLaTeX(_ content: String) -> String {
        var result = content

        // Convert msup to LaTeX superscript
        result = convertMsup(result)

        // Convert msub to LaTeX subscript
        result = convertMsub(result)

        // Convert mfrac to LaTeX fraction
        result = convertMfrac(result)

        // Convert msqrt to LaTeX sqrt
        result = convertMsqrt(result)

        // Strip remaining MathML tags
        result = stripMathMLTags(result)

        // Normalize whitespace
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespaces)

        return result
    }

    private static func convertMsup(_ text: String) -> String {
        var result = text
        let pattern = "<mml:msup[^>]*>(.*?)</mml:msup>"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return result
        }

        var matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))

        while !matches.isEmpty {
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let contentRange = Range(match.range(at: 1), in: result) else {
                    continue
                }

                let innerContent = String(result[contentRange])
                let parts = extractTwoChildren(innerContent)
                let base = stripMathMLTags(parts.0)
                let exponent = stripMathMLTags(parts.1)
                result.replaceSubrange(fullRange, with: "{\(base)}^{\(exponent)}")
            }

            matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
        }

        return result
    }

    private static func convertMsub(_ text: String) -> String {
        var result = text
        let pattern = "<mml:msub[^>]*>(.*?)</mml:msub>"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return result
        }

        var matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))

        while !matches.isEmpty {
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let contentRange = Range(match.range(at: 1), in: result) else {
                    continue
                }

                let innerContent = String(result[contentRange])
                let parts = extractTwoChildren(innerContent)
                let base = stripMathMLTags(parts.0)
                let sub = stripMathMLTags(parts.1)
                result.replaceSubrange(fullRange, with: "{\(base)}_{\(sub)}")
            }

            matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
        }

        return result
    }

    private static func convertMfrac(_ text: String) -> String {
        var result = text
        let pattern = "<mml:mfrac[^>]*>(.*?)</mml:mfrac>"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return result
        }

        let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else {
                continue
            }

            let innerContent = String(result[contentRange])
            let parts = extractTwoChildren(innerContent)
            let numerator = stripMathMLTags(parts.0)
            let denominator = stripMathMLTags(parts.1)
            result.replaceSubrange(fullRange, with: "\\frac{\(numerator)}{\(denominator)}")
        }

        return result
    }

    private static func convertMsqrt(_ text: String) -> String {
        var result = text
        let pattern = "<mml:msqrt[^>]*>(.*?)</mml:msqrt>"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return result
        }

        let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else {
                continue
            }

            let innerContent = String(result[contentRange])
            let content = stripMathMLTags(innerContent)
            result.replaceSubrange(fullRange, with: "\\sqrt{\(content)}")
        }

        return result
    }

    // MARK: - Helpers

    /// Extract two child elements from MathML content
    private static func extractTwoChildren(_ content: String) -> (String, String) {
        let children = extractTopLevelElements(content)
        if children.count >= 2 {
            return (children[0], children[1])
        } else if children.count == 1 {
            return (children[0], "")
        }
        return (content, "")
    }

    /// Extract top-level MathML elements (simplified version)
    private static func extractTopLevelElements(_ content: String) -> [String] {
        var elements: [String] = []
        var depth = 0
        var currentStart: String.Index?
        var i = content.startIndex

        while i < content.endIndex {
            if content[i] == "<" {
                let rest = String(content[i...])

                // Opening tag
                if let match = rest.range(of: #"^<mml:[a-z]+[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                    if depth == 0 {
                        currentStart = i
                    }
                    depth += 1
                    i = content.index(i, offsetBy: content.distance(from: rest.startIndex, to: match.upperBound))
                    continue
                }

                // Closing tag
                if let match = rest.range(of: #"^</mml:[a-z]+>"#, options: [.regularExpression, .caseInsensitive]) {
                    depth -= 1
                    let tagEnd = content.index(i, offsetBy: content.distance(from: rest.startIndex, to: match.upperBound))
                    if depth == 0, let start = currentStart {
                        elements.append(String(content[start..<tagEnd]))
                        currentStart = nil
                    }
                    i = tagEnd
                    continue
                }
            }

            i = content.index(after: i)
        }

        if elements.isEmpty {
            return [content.trimmingCharacters(in: .whitespaces)]
        }

        return elements
    }

    /// Strip all MathML tags
    private static func stripMathMLTags(_ text: String) -> String {
        var result = text
        let tagPattern = "</?mml:[a-z]+[^>]*>"
        if let regex = try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
