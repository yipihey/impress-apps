//
//  PaperIntents.swift
//  PublicationManagerCore
//
//  Paper action Siri Shortcuts intents.
//

import AppIntents
import Foundation

// MARK: - Toggle Read Status Intent

/// Toggle the read status of selected papers.
@available(iOS 16.0, macOS 13.0, *)
public struct ToggleReadStatusIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Toggle Read Status"

    public static var description = IntentDescription(
        "Toggle the read/unread status of selected papers.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .toggleRead)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Mark All Read Intent

/// Mark all papers as read.
@available(iOS 16.0, macOS 13.0, *)
public struct MarkAllReadIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Mark All as Read"

    public static var description = IntentDescription(
        "Mark all papers in the current view as read.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .markAllRead)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Mark Selected Read Intent

/// Mark selected papers as read.
@available(iOS 16.0, macOS 13.0, *)
public struct MarkSelectedReadIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Mark as Read"

    public static var description = IntentDescription(
        "Mark selected papers as read.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .markRead)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Mark Selected Unread Intent

/// Mark selected papers as unread.
@available(iOS 16.0, macOS 13.0, *)
public struct MarkSelectedUnreadIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Mark as Unread"

    public static var description = IntentDescription(
        "Mark selected papers as unread.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .markUnread)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Copy BibTeX Intent

/// Copy BibTeX for selected papers.
@available(iOS 16.0, macOS 13.0, *)
public struct CopyBibTeXIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Copy BibTeX"

    public static var description = IntentDescription(
        "Copy BibTeX entries for selected papers to the clipboard.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .copy)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Copy Citation Intent

/// Copy citation for selected papers.
@available(iOS 16.0, macOS 13.0, *)
public struct CopyCitationIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Copy Citation"

    public static var description = IntentDescription(
        "Copy formatted citation for selected papers.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .copyAsCitation)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Copy Identifier Intent

/// Copy identifiers (DOI, arXiv ID) for selected papers.
@available(iOS 16.0, macOS 13.0, *)
public struct CopyIdentifierIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Copy Identifier"

    public static var description = IntentDescription(
        "Copy DOI or arXiv ID for selected papers.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .copyIdentifier)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Open Selected Papers Intent

/// Open the selected papers.
@available(iOS 16.0, macOS 13.0, *)
public struct OpenSelectedPapersIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Open Selected Papers"

    public static var description = IntentDescription(
        "Open the selected papers in the detail view.",
        categoryName: "Papers"
    )

    public static var openAppWhenRun: Bool = true

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .open)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Delete Selected Papers Intent

/// Delete selected papers.
@available(iOS 16.0, macOS 13.0, *)
public struct DeleteSelectedPapersIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Delete Selected Papers"

    public static var description = IntentDescription(
        "Delete the selected papers from your library.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .delete)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Keep Selected Papers Intent

/// Keep selected papers to the library.
@available(iOS 16.0, macOS 13.0, *)
public struct KeepSelectedPapersIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Keep to Library"

    public static var description = IntentDescription(
        "Keep selected papers from inbox to your library.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .keep)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Share Papers Intent

/// Share selected papers.
@available(iOS 16.0, macOS 13.0, *)
public struct SharePapersIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Share Papers"

    public static var description = IntentDescription(
        "Share selected papers via the share sheet.",
        categoryName: "Papers"
    )

    public var automationCommand: AutomationCommand {
        .selectedPapers(action: .share)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}
