//
//  InboxIntents.swift
//  PublicationManagerCore
//
//  Inbox-related Siri Shortcuts intents.
//

import AppIntents
import Foundation

// MARK: - Keep Inbox Item Intent

/// Keep the current inbox item to the library.
@available(iOS 16.0, macOS 13.0, *)
public struct KeepInboxItemIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Keep Inbox Item"

    public static var description = IntentDescription(
        "Keep the current inbox item to your library.",
        categoryName: "Inbox"
    )

    public var automationCommand: AutomationCommand {
        .inbox(action: .keep)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Dismiss Inbox Item Intent

/// Dismiss the current inbox item.
@available(iOS 16.0, macOS 13.0, *)
public struct DismissInboxItemIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Dismiss Inbox Item"

    public static var description = IntentDescription(
        "Dismiss the current inbox item without archiving.",
        categoryName: "Inbox"
    )

    public var automationCommand: AutomationCommand {
        .inbox(action: .dismiss)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Toggle Star Intent

/// Toggle the star status of the current inbox item.
@available(iOS 16.0, macOS 13.0, *)
public struct ToggleStarIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Toggle Star"

    public static var description = IntentDescription(
        "Toggle the star status of the current inbox item.",
        categoryName: "Inbox"
    )

    public var automationCommand: AutomationCommand {
        .inbox(action: .toggleStar)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Mark Inbox Read Intent

/// Mark the current inbox item as read.
@available(iOS 16.0, macOS 13.0, *)
public struct MarkInboxReadIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Mark Inbox Item Read"

    public static var description = IntentDescription(
        "Mark the current inbox item as read.",
        categoryName: "Inbox"
    )

    public var automationCommand: AutomationCommand {
        .inbox(action: .markRead)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Mark Inbox Unread Intent

/// Mark the current inbox item as unread.
@available(iOS 16.0, macOS 13.0, *)
public struct MarkInboxUnreadIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Mark Inbox Item Unread"

    public static var description = IntentDescription(
        "Mark the current inbox item as unread.",
        categoryName: "Inbox"
    )

    public var automationCommand: AutomationCommand {
        .inbox(action: .markUnread)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Next Inbox Item Intent

/// Go to the next inbox item.
@available(iOS 16.0, macOS 13.0, *)
public struct NextInboxItemIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Next Inbox Item"

    public static var description = IntentDescription(
        "Go to the next item in the inbox.",
        categoryName: "Inbox"
    )

    public var automationCommand: AutomationCommand {
        .inbox(action: .next)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Previous Inbox Item Intent

/// Go to the previous inbox item.
@available(iOS 16.0, macOS 13.0, *)
public struct PreviousInboxItemIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Previous Inbox Item"

    public static var description = IntentDescription(
        "Go to the previous item in the inbox.",
        categoryName: "Inbox"
    )

    public var automationCommand: AutomationCommand {
        .inbox(action: .previous)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Open Inbox Item Intent

/// Open the current inbox item.
@available(iOS 16.0, macOS 13.0, *)
public struct OpenInboxItemIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Open Inbox Item"

    public static var description = IntentDescription(
        "Open the current inbox item in detail view.",
        categoryName: "Inbox"
    )

    public static var openAppWhenRun: Bool = true

    public var automationCommand: AutomationCommand {
        .inbox(action: .open)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}
