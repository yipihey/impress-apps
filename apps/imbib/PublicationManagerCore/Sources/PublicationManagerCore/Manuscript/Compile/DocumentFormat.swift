import Foundation

/// Discriminates between Typst and LaTeX document formats, providing
/// format-specific constants for editing, formatting, and citation insertion.
///
/// GUI-meld Phase 3: moved from the imprint app target into PublicationManagerCore
/// so the shared compile/edit stack (`ManuscriptCompileController`,
/// `SourceEditorView`) has a common format type in both imbib and imprint.
public enum DocumentFormat: String, CaseIterable, Codable, Sendable {
    case typst
    case latex

    public var fileExtension: String {
        switch self {
        case .typst: "typ"
        case .latex: "tex"
        }
    }

    public var mainFileName: String {
        switch self {
        case .typst: "main.typ"
        case .latex: "main.tex"
        }
    }

    public var displayName: String {
        switch self {
        case .typst: "Typst"
        case .latex: "LaTeX"
        }
    }

    public var commentPrefix: String {
        switch self {
        case .typst: "//"
        case .latex: "%"
        }
    }

    public var citationInsert: (prefix: String, suffix: String) {
        switch self {
        case .typst: ("@", "")
        case .latex: ("\\cite{", "}")
        }
    }

    public var boldWrap: (prefix: String, suffix: String) {
        switch self {
        case .typst: ("*", "*")
        case .latex: ("\\textbf{", "}")
        }
    }

    public var italicWrap: (prefix: String, suffix: String) {
        switch self {
        case .typst: ("_", "_")
        case .latex: ("\\textit{", "}")
        }
    }

    /// Default auto-compile debounce in milliseconds.
    /// LaTeX compilation is heavier, so use a longer debounce.
    public var defaultDebounceMs: Int {
        switch self {
        case .typst: 300
        case .latex: 1500
        }
    }

    /// Detect format from source content heuristics.
    public static func detect(from source: String) -> DocumentFormat {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\\documentclass") || trimmed.contains("\\begin{document}") {
            return .latex
        }
        return .typst
    }

    /// Detect format from a file extension string (without dot).
    public static func detect(fromExtension ext: String) -> DocumentFormat? {
        switch ext.lowercased() {
        case "tex", "latex": return .latex
        case "typ": return .typst
        default: return nil
        }
    }
}
