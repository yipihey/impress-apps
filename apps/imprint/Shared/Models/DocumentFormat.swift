import Foundation

/// Discriminates between Typst and LaTeX document formats, providing
/// format-specific constants for editing, formatting, and citation insertion.
enum DocumentFormat: String, CaseIterable, Codable, Sendable {
    case typst
    case latex

    var fileExtension: String {
        switch self {
        case .typst: "typ"
        case .latex: "tex"
        }
    }

    var mainFileName: String {
        switch self {
        case .typst: "main.typ"
        case .latex: "main.tex"
        }
    }

    var displayName: String {
        switch self {
        case .typst: "Typst"
        case .latex: "LaTeX"
        }
    }

    var commentPrefix: String {
        switch self {
        case .typst: "//"
        case .latex: "%"
        }
    }

    var citationInsert: (prefix: String, suffix: String) {
        switch self {
        case .typst: ("@", "")
        case .latex: ("\\cite{", "}")
        }
    }

    var boldWrap: (prefix: String, suffix: String) {
        switch self {
        case .typst: ("*", "*")
        case .latex: ("\\textbf{", "}")
        }
    }

    var italicWrap: (prefix: String, suffix: String) {
        switch self {
        case .typst: ("_", "_")
        case .latex: ("\\textit{", "}")
        }
    }

    /// Default auto-compile debounce in milliseconds.
    /// LaTeX compilation is heavier, so use a longer debounce.
    var defaultDebounceMs: Int {
        switch self {
        case .typst: 300
        case .latex: 1500
        }
    }

    /// Detect format from source content heuristics.
    static func detect(from source: String) -> DocumentFormat {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\\documentclass") || trimmed.contains("\\begin{document}") {
            return .latex
        }
        return .typst
    }

    /// Detect format from a file extension string (without dot).
    static func detect(fromExtension ext: String) -> DocumentFormat? {
        switch ext.lowercased() {
        case "tex", "latex": return .latex
        case "typ": return .typst
        default: return nil
        }
    }
}
