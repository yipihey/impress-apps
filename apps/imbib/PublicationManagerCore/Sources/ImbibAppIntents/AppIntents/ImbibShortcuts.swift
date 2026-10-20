//
//  ImbibShortcuts.swift
//  PublicationManagerCore
//
//  Provides Siri Shortcuts and Shortcuts app integration for imbib.
//  Uses the existing automation infrastructure (URLSchemeHandler) to execute commands.
//

import AppIntents
import Foundation
import PublicationManagerCore

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
