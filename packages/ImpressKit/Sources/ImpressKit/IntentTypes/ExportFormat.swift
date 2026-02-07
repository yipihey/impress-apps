import AppIntents

/// Shared export format enum used across Impress suite App Intents.
@available(macOS 14.0, iOS 17.0, *)
public enum ExportFormat: String, AppEnum, Sendable {
    case typst
    case latex
    case markdown
    case text
    case bibtex
    case ris

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Export Format"
    }

    public static var caseDisplayRepresentations: [ExportFormat: DisplayRepresentation] {
        [
            .typst: "Typst",
            .latex: "LaTeX",
            .markdown: "Markdown",
            .text: "Plain Text",
            .bibtex: "BibTeX",
            .ris: "RIS"
        ]
    }
}
