import AppIntents
import Foundation

// MARK: - Export Format AppEnum

@available(macOS 14.0, *)
public enum ImploreExportFormat: String, AppEnum, Sendable {
    case png
    case svg
    case pdf
    case typst

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Export Format"
    }

    public static var caseDisplayRepresentations: [ImploreExportFormat: DisplayRepresentation] {
        [
            .png: "PNG",
            .svg: "SVG",
            .pdf: "PDF",
            .typst: "Typst"
        ]
    }
}

// MARK: - Intent Errors

@available(macOS 14.0, *)
public enum ImploreIntentError: Error, CustomLocalizedStringResourceConvertible {
    case automationDisabled
    case figureNotFound(String)
    case exportFailed(String)
    case datasetNotFound(String)
    case executionFailed(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .automationDisabled:
            return "Automation API is disabled. Enable it in Settings."
        case .figureNotFound(let id):
            return "Figure not found: \(id)"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .datasetNotFound(let name):
            return "Dataset not found: \(name)"
        case .executionFailed(let reason):
            return "Command failed: \(reason)"
        }
    }
}

// MARK: - Shortcuts Provider

@available(macOS 14.0, *)
public struct ImploreShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListFiguresIntent(),
            phrases: [
                "List my \(.applicationName) figures",
                "Show \(.applicationName) figures"
            ],
            shortTitle: "List Figures",
            systemImageName: "chart.xyaxis.line"
        )

        AppShortcut(
            intent: ExportFigureIntent(),
            phrases: [
                "Export \(.applicationName) figure",
                "Save figure from \(.applicationName)"
            ],
            shortTitle: "Export Figure",
            systemImageName: "square.and.arrow.up"
        )

        AppShortcut(
            intent: CreateFigureIntent(),
            phrases: [
                "Create figure in \(.applicationName)",
                "New visualization in \(.applicationName)"
            ],
            shortTitle: "New Figure",
            systemImageName: "plus.circle"
        )
    }
}
