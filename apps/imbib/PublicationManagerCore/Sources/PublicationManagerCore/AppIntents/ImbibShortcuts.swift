//
//  ImbibShortcuts.swift
//  PublicationManagerCore
//
//  Provides Siri Shortcuts and Shortcuts app integration for imbib.
//  Uses the existing automation infrastructure (URLSchemeHandler) to execute commands.
//

import AppIntents
import Foundation

// MARK: - Intent Error

/// Errors that can occur during intent execution.
@available(iOS 16.0, macOS 13.0, *)
public enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case automationDisabled
    case executionFailed(String)
    case invalidParameter(String)
    case paperNotFound(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .automationDisabled:
            return "Automation API is disabled. Enable it in Settings > General."
        case .executionFailed(let reason):
            return "Command failed: \(reason)"
        case .invalidParameter(let param):
            return "Invalid parameter: \(param)"
        case .paperNotFound(let citeKey):
            return "Paper not found: \(citeKey)"
        }
    }
}

// MARK: - Automation Intent Protocol

/// Protocol for intents that execute via the automation infrastructure.
@available(iOS 16.0, macOS 13.0, *)
public protocol AutomationIntent: AppIntent {
    /// The automation command to execute.
    var automationCommand: AutomationCommand { get }
}

@available(iOS 16.0, macOS 13.0, *)
public extension AutomationIntent {
    /// Execute the automation command via URLSchemeHandler.
    func performAutomation() async throws -> some IntentResult {
        // Check if automation is enabled
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        // Execute the command
        let result = await URLSchemeHandler.shared.execute(automationCommand)

        if result.success {
            return .result()
        } else {
            throw IntentError.executionFailed(result.error ?? "Unknown error")
        }
    }
}

// MARK: - App Shortcuts Provider

/// Provides shortcuts that appear in the Shortcuts app and can be invoked via Siri.
/// ADR-018: Enhanced with data-returning intents.
@available(iOS 16.0, macOS 13.0, *)
public struct ImbibShortcuts: AppShortcutsProvider {

    public static var appShortcuts: [AppShortcut] {
        // Search Papers - phrases can't use String parameter interpolation
        // User will be prompted for query after invoking the shortcut
        AppShortcut(
            intent: SearchPapersIntent(),
            phrases: [
                "Search \(.applicationName) for papers",
                "Find papers in \(.applicationName)",
                "Search papers with \(.applicationName)"
            ],
            shortTitle: "Search Papers",
            systemImageName: "magnifyingglass"
        )

        // Search Library
        AppShortcut(
            intent: SearchLibraryIntent(),
            phrases: [
                "Search my \(.applicationName) library",
                "Find papers in my \(.applicationName) library"
            ],
            shortTitle: "Search Library",
            systemImageName: "book.closed"
        )

        // Add Paper by DOI - user will be prompted for DOI
        AppShortcut(
            intent: AddPaperByDOIIntent(),
            phrases: [
                "Add paper by DOI to \(.applicationName)",
                "Import DOI to \(.applicationName)"
            ],
            shortTitle: "Add by DOI",
            systemImageName: "plus.circle"
        )

        // Add Paper by arXiv - user will be prompted for arXiv ID
        AppShortcut(
            intent: AddPaperByArXivIntent(),
            phrases: [
                "Add arXiv paper to \(.applicationName)",
                "Import arXiv paper to \(.applicationName)"
            ],
            shortTitle: "Add by arXiv",
            systemImageName: "plus.circle"
        )

        // Show Inbox
        AppShortcut(
            intent: ShowInboxIntent(),
            phrases: [
                "Show my \(.applicationName) inbox",
                "Open \(.applicationName) inbox",
                "Check \(.applicationName) inbox"
            ],
            shortTitle: "Show Inbox",
            systemImageName: "tray"
        )

        // Show Library
        AppShortcut(
            intent: ShowLibraryIntent(),
            phrases: [
                "Show my \(.applicationName) library",
                "Open \(.applicationName) library",
                "Show my papers in \(.applicationName)"
            ],
            shortTitle: "Show Library",
            systemImageName: "books.vertical"
        )

        // Mark All Read
        AppShortcut(
            intent: MarkAllReadIntent(),
            phrases: [
                "Mark all papers as read in \(.applicationName)",
                "Mark everything read in \(.applicationName)"
            ],
            shortTitle: "Mark All Read",
            systemImageName: "checkmark.circle"
        )

        // Refresh Data
        AppShortcut(
            intent: RefreshDataIntent(),
            phrases: [
                "Refresh \(.applicationName)",
                "Sync \(.applicationName)",
                "Update \(.applicationName) data"
            ],
            shortTitle: "Refresh",
            systemImageName: "arrow.clockwise"
        )
    }
}
