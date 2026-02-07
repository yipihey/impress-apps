import AppIntents
import Foundation

// MARK: - Export Format AppEnum

@available(macOS 14.0, iOS 17.0, *)
public enum ImprintExportFormat: String, AppEnum, Sendable {
    case typst
    case latex
    case markdown
    case text

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Export Format"
    }

    public static var caseDisplayRepresentations: [ImprintExportFormat: DisplayRepresentation] {
        [
            .typst: "Typst",
            .latex: "LaTeX",
            .markdown: "Markdown",
            .text: "Plain Text"
        ]
    }
}

// MARK: - Intent Errors

@available(macOS 14.0, iOS 17.0, *)
public enum ImprintIntentError: Error, CustomLocalizedStringResourceConvertible {
    case automationDisabled
    case documentNotFound(String)
    case compilationFailed(String)
    case executionFailed(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .automationDisabled:
            return "Automation API is disabled. Enable it in Settings."
        case .documentNotFound(let id):
            return "Document not found: \(id)"
        case .compilationFailed(let reason):
            return "Compilation failed: \(reason)"
        case .executionFailed(let reason):
            return "Command failed: \(reason)"
        }
    }
}

// MARK: - Shortcuts Provider

@available(macOS 14.0, iOS 17.0, *)
public struct ImprintShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListDocumentsIntent(),
            phrases: [
                "List my \(.applicationName) documents",
                "Show \(.applicationName) documents"
            ],
            shortTitle: "List Documents",
            systemImageName: "doc.text"
        )

        AppShortcut(
            intent: CreateDocumentIntent(),
            phrases: [
                "Create a new \(.applicationName) document",
                "New document in \(.applicationName)"
            ],
            shortTitle: "New Document",
            systemImageName: "doc.badge.plus"
        )

        AppShortcut(
            intent: CompileDocumentIntent(),
            phrases: [
                "Compile \(.applicationName) document",
                "Build PDF in \(.applicationName)"
            ],
            shortTitle: "Compile to PDF",
            systemImageName: "doc.richtext"
        )

        AppShortcut(
            intent: InsertCitationIntent(),
            phrases: [
                "Insert citation in \(.applicationName)",
                "Add citation to \(.applicationName) document"
            ],
            shortTitle: "Insert Citation",
            systemImageName: "quote.opening"
        )
    }
}
