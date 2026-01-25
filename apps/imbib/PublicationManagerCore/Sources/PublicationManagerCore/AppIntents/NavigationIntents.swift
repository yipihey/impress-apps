//
//  NavigationIntents.swift
//  PublicationManagerCore
//
//  Navigation-related Siri Shortcuts intents.
//

import AppIntents
import Foundation

// MARK: - Show Inbox Intent

/// Navigate to the inbox view.
@available(iOS 16.0, macOS 13.0, *)
public struct ShowInboxIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Show Inbox"

    public static var description = IntentDescription(
        "Open your imbib inbox to review new papers.",
        categoryName: "Navigation"
    )

    public static var openAppWhenRun: Bool = true

    public var automationCommand: AutomationCommand {
        .navigate(target: .inbox)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Show Library Intent

/// Navigate to the library view.
@available(iOS 16.0, macOS 13.0, *)
public struct ShowLibraryIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Show Library"

    public static var description = IntentDescription(
        "Open your imbib paper library.",
        categoryName: "Navigation"
    )

    public static var openAppWhenRun: Bool = true

    public var automationCommand: AutomationCommand {
        .navigate(target: .library)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Show PDF Tab Intent

/// Navigate to the PDF tab of the current paper.
@available(iOS 16.0, macOS 13.0, *)
public struct ShowPDFTabIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Show PDF"

    public static var description = IntentDescription(
        "Show the PDF tab for the current paper.",
        categoryName: "Navigation"
    )

    public static var openAppWhenRun: Bool = true

    public var automationCommand: AutomationCommand {
        .navigate(target: .pdfTab)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Show BibTeX Tab Intent

/// Navigate to the BibTeX tab of the current paper.
@available(iOS 16.0, macOS 13.0, *)
public struct ShowBibTeXTabIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Show BibTeX"

    public static var description = IntentDescription(
        "Show the BibTeX tab for the current paper.",
        categoryName: "Navigation"
    )

    public static var openAppWhenRun: Bool = true

    public var automationCommand: AutomationCommand {
        .navigate(target: .bibtexTab)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Show Notes Tab Intent

/// Navigate to the notes tab of the current paper.
@available(iOS 16.0, macOS 13.0, *)
public struct ShowNotesTabIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Show Notes"

    public static var description = IntentDescription(
        "Show the notes tab for the current paper.",
        categoryName: "Navigation"
    )

    public static var openAppWhenRun: Bool = true

    public var automationCommand: AutomationCommand {
        .navigate(target: .notesTab)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Focus Intents

/// Focus the sidebar.
@available(iOS 16.0, macOS 13.0, *)
public struct FocusSidebarIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Focus Sidebar"

    public static var description = IntentDescription(
        "Focus the sidebar navigation.",
        categoryName: "Focus"
    )

    public var automationCommand: AutomationCommand {
        .focus(target: .sidebar)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

/// Focus the paper list.
@available(iOS 16.0, macOS 13.0, *)
public struct FocusListIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Focus Paper List"

    public static var description = IntentDescription(
        "Focus the paper list view.",
        categoryName: "Focus"
    )

    public var automationCommand: AutomationCommand {
        .focus(target: .list)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

/// Focus the detail view.
@available(iOS 16.0, macOS 13.0, *)
public struct FocusDetailIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Focus Detail View"

    public static var description = IntentDescription(
        "Focus the paper detail view.",
        categoryName: "Focus"
    )

    public var automationCommand: AutomationCommand {
        .focus(target: .detail)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

/// Focus the search field.
@available(iOS 16.0, macOS 13.0, *)
public struct FocusSearchFieldIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Focus Search Field"

    public static var description = IntentDescription(
        "Focus the search input field.",
        categoryName: "Focus"
    )

    public var automationCommand: AutomationCommand {
        .focus(target: .search)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}
