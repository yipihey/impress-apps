import Foundation

/// The manuscript source formats the suite understands, providing
/// format-specific constants for editing, preview, and citation insertion.
///
/// GUI-meld Phase 3: moved from the imprint app target into PublicationManagerCore
/// so the shared compile/edit stack (`ManuscriptCompileController`,
/// `SourceEditorView`) has a common format type in both imbib and imprint.
///
/// The allowed set is mirrored in Rust
/// (`impress_core::manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS`, exported as
/// `supportedManuscriptFormats()`); a unit test asserts parity.
public enum DocumentFormat: String, CaseIterable, Codable, Sendable {
    case typst
    case latex
    case markdown
    case plaintext

    /// How the non-source pane renders this format.
    public enum PreviewKind: Sendable {
        /// Compile the source (Typst in-process / LaTeX via tectonic) to PDF.
        case compiledPDF
        /// Render the live source with MarkdownUI — no compile step.
        case renderedMarkdown
        /// No rendered state (plain text) — the Preview tab is hidden.
        case none
    }

    public var previewKind: PreviewKind {
        switch self {
        case .typst, .latex: .compiledPDF
        case .markdown: .renderedMarkdown
        case .plaintext: .none
        }
    }

    public var fileExtension: String {
        switch self {
        case .typst: "typ"
        case .latex: "tex"
        case .markdown: "md"
        case .plaintext: "txt"
        }
    }

    public var mainFileName: String {
        "main.\(fileExtension)"
    }

    public var displayName: String {
        switch self {
        case .typst: "Typst"
        case .latex: "LaTeX"
        case .markdown: "Markdown"
        case .plaintext: "Plain Text"
        }
    }

    /// Line-comment prefix; nil disables comment toggling (Markdown has no
    /// line comments; plain text has no syntax at all).
    public var commentPrefix: String? {
        switch self {
        case .typst: "//"
        case .latex: "%"
        case .markdown, .plaintext: nil
        }
    }

    /// Citation insertion delimiters; nil disables citation insert.
    /// Markdown uses the pandoc `@key` convention.
    public var citationInsert: (prefix: String, suffix: String)? {
        switch self {
        case .typst: ("@", "")
        case .latex: ("\\cite{", "}")
        case .markdown: ("@", "")
        case .plaintext: nil
        }
    }

    /// Bold wrapping; nil disables the Bold command.
    public var boldWrap: (prefix: String, suffix: String)? {
        switch self {
        case .typst: ("*", "*")
        case .latex: ("\\textbf{", "}")
        case .markdown: ("**", "**")
        case .plaintext: nil
        }
    }

    /// Italic wrapping; nil disables the Italic command.
    public var italicWrap: (prefix: String, suffix: String)? {
        switch self {
        case .typst: ("_", "_")
        case .latex: ("\\textit{", "}")
        case .markdown: ("_", "_")
        case .plaintext: nil
        }
    }

    /// Default auto-compile/preview debounce in milliseconds.
    /// LaTeX compilation is heavy; Markdown re-renders are cheap.
    public var defaultDebounceMs: Int {
        switch self {
        case .typst: 300
        case .latex: 1500
        case .markdown: 200
        case .plaintext: 0
        }
    }

    /// Detect format from source content heuristics, optionally using the
    /// manuscript title as a hint (titles are often file names: "ADR-11.md").
    ///
    /// Used as the fallback when a stored `format` is missing or unrecognized —
    /// blindly assuming Typst there sends Markdown bodies into the Typst
    /// compiler, whose first complaint is `expected expression` on `# Heading`.
    public static func detect(from source: String, title: String? = nil) -> DocumentFormat {
        // 1. Title extension hint — cheapest and most reliable when present.
        if let title,
           let dot = title.lastIndex(of: "."),
           case let ext = String(title[title.index(after: dot)...]),
           !ext.isEmpty,
           let byExtension = detect(fromExtension: ext) {
            return byExtension
        }

        // 2. Content markers.
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\\documentclass") || trimmed.contains("\\begin{document}") {
            return .latex
        }
        if looksLikeMarkdown(trimmed) {
            return .markdown
        }
        return .typst
    }

    /// Markdown markers that are NOT valid Typst: an ATX heading (`# ` — in
    /// Typst `#` starts code mode, so `#` + space is a syntax error), a fenced
    /// code block, or a setext-style `---` front-matter fence.
    private static func looksLikeMarkdown(_ source: String) -> Bool {
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(200) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { return true }
            guard line.hasPrefix("#") else { continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") { return true }
        }
        return false
    }

    /// Detect format from a file extension string (without dot).
    public static func detect(fromExtension ext: String) -> DocumentFormat? {
        switch ext.lowercased() {
        case "tex", "latex": return .latex
        case "typ": return .typst
        case "md", "markdown", "mdown": return .markdown
        case "txt", "text": return .plaintext
        default: return nil
        }
    }
}
