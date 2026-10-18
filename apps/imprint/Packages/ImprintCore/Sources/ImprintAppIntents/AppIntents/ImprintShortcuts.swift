import AppIntents
import Foundation
import ImprintCore

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
