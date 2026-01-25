//
//  AppActionIntents.swift
//  PublicationManagerCore
//
//  General app action Siri Shortcuts intents.
//

import AppIntents
import Foundation

// MARK: - Export Format Enum for Intents

/// Export formats available via Shortcuts.
@available(iOS 16.0, macOS 13.0, *)
public enum ExportFormatOption: String, AppEnum {
    case bibtex = "bibtex"
    case ris = "ris"
    case csv = "csv"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Export Format"
    }

    public static var caseDisplayRepresentations: [ExportFormatOption: DisplayRepresentation] {
        [
            .bibtex: DisplayRepresentation(title: "BibTeX"),
            .ris: DisplayRepresentation(title: "RIS"),
            .csv: DisplayRepresentation(title: "CSV")
        ]
    }

    /// Convert to ExportFormat used by the automation system.
    var exportFormat: ExportFormat {
        switch self {
        case .bibtex: return .bibtex
        case .ris: return .ris
        case .csv: return .csv
        }
    }
}

// MARK: - Refresh Data Intent

/// Refresh/sync data from all sources.
@available(iOS 16.0, macOS 13.0, *)
public struct RefreshDataIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Refresh Data"

    public static var description = IntentDescription(
        "Refresh and sync data from all sources.",
        categoryName: "App"
    )

    public var automationCommand: AutomationCommand {
        .app(action: .refresh)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Export Library Intent

/// Export the library to a specified format.
@available(iOS 16.0, macOS 13.0, *)
public struct ExportLibraryIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Export Library"

    public static var description = IntentDescription(
        "Export your paper library to BibTeX, RIS, or CSV format.",
        categoryName: "App"
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Export library as \(\.$format)")
    }

    @Parameter(title: "Format", description: "The export format", default: .bibtex)
    public var format: ExportFormatOption

    public var automationCommand: AutomationCommand {
        .exportLibrary(libraryID: nil, format: format.exportFormat)
    }

    public init() {}

    public init(format: ExportFormatOption) {
        self.format = format
    }

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Toggle Sidebar Intent

/// Toggle the sidebar visibility.
@available(iOS 16.0, macOS 13.0, *)
public struct ToggleSidebarIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Toggle Sidebar"

    public static var description = IntentDescription(
        "Show or hide the sidebar.",
        categoryName: "App"
    )

    public var automationCommand: AutomationCommand {
        .app(action: .toggleSidebar)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Toggle Detail Pane Intent

/// Toggle the detail pane visibility.
@available(iOS 16.0, macOS 13.0, *)
public struct ToggleDetailPaneIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Toggle Detail Pane"

    public static var description = IntentDescription(
        "Show or hide the detail pane.",
        categoryName: "App"
    )

    public var automationCommand: AutomationCommand {
        .app(action: .toggleDetailPane)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Toggle Unread Filter Intent

/// Toggle the unread papers filter.
@available(iOS 16.0, macOS 13.0, *)
public struct ToggleUnreadFilterIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Toggle Unread Filter"

    public static var description = IntentDescription(
        "Toggle filtering to show only unread papers.",
        categoryName: "App"
    )

    public var automationCommand: AutomationCommand {
        .app(action: .toggleUnreadFilter)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Toggle PDF Filter Intent

/// Toggle the PDF availability filter.
@available(iOS 16.0, macOS 13.0, *)
public struct TogglePDFFilterIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Toggle PDF Filter"

    public static var description = IntentDescription(
        "Toggle filtering to show only papers with PDFs.",
        categoryName: "App"
    )

    public var automationCommand: AutomationCommand {
        .app(action: .togglePDFFilter)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Show Keyboard Shortcuts Intent

/// Show the keyboard shortcuts reference.
@available(iOS 16.0, macOS 13.0, *)
public struct ShowKeyboardShortcutsIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Show Keyboard Shortcuts"

    public static var description = IntentDescription(
        "Display the keyboard shortcuts reference.",
        categoryName: "App"
    )

    public static var openAppWhenRun: Bool = true

    public var automationCommand: AutomationCommand {
        .app(action: .showKeyboardShortcuts)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}
