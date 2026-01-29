//
//  OnboardingManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation
import OSLog

// MARK: - Onboarding Step

/// Steps in the onboarding flow.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case libraryProxy = 0
    case databasePreference = 1
    case adsAPIKey = 2
    case complete = 3

    public var title: String {
        switch self {
        case .libraryProxy:
            return "Library Proxy"
        case .databasePreference:
            return "Database"
        case .adsAPIKey:
            return "ADS API Key"
        case .complete:
            return "All Set!"
        }
    }

    /// Returns the next step, or nil if this is the last step.
    public var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    /// Returns the previous step, or nil if this is the first step.
    public var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }

    /// Total number of configuration steps (excluding completion).
    public static var configurationStepCount: Int {
        return allCases.count - 1  // Exclude .complete
    }
}

// MARK: - Preferred Database

/// The user's preferred database choice from onboarding.
public enum PreferredDatabase: Sendable {
    case openAlex
    case ads
}

// MARK: - Onboarding Manager

/// Manages the onboarding flow state.
///
/// Tracks whether onboarding should be shown, the current step,
/// and persists completion state to iCloud via SyncedSettingsStore.
@MainActor
@Observable
public final class OnboardingManager {

    // MARK: - Shared Instance

    public static let shared = OnboardingManager()

    // MARK: - Observable State

    /// The current step in the onboarding flow.
    public var currentStep: OnboardingStep = .libraryProxy

    /// The user's preferred database choice from onboarding.
    public var preferredDatabase: PreferredDatabase = .openAlex

    /// Force show onboarding even if already completed (set via --show-welcome-screen flag).
    /// This allows showing the welcome screen without resetting any data.
    /// Note: This is nonisolated static so it can be set during app init before MainActor is available.
    public nonisolated(unsafe) static var forceShowOnboarding: Bool = false

    // MARK: - Constants

    /// Current onboarding version. Increment to re-show onboarding for existing users.
    private static let currentVersion = 1

    // MARK: - Computed Properties

    /// Whether the onboarding sheet should be shown.
    ///
    /// Returns `true` if the user hasn't completed the current onboarding version,
    /// or if `forceShowOnboarding` is set (via --show-welcome-screen flag).
    public var shouldShowOnboarding: Bool {
        if Self.forceShowOnboarding {
            return true
        }
        let completedVersion = SyncedSettingsStore.shared.int(forKey: .onboardingCompletedVersion) ?? 0
        return completedVersion < Self.currentVersion
    }

    /// Whether the ADS API key has already been configured.
    public var hasADSAPIKey: Bool {
        // Check synchronously by querying the keychain
        // Note: CredentialManager is an actor, but we can check via a cached method
        // For now, we'll assume not configured and let the view check asynchronously
        return false
    }

    // MARK: - Actions

    /// Move to the next step in the onboarding flow.
    public func nextStep() {
        if let next = currentStep.next {
            currentStep = next
            Logger.library.infoCapture("Onboarding moved to step: \(next.title)", category: "onboarding")
        }
    }

    /// Move to the previous step in the onboarding flow.
    public func previousStep() {
        if let previous = currentStep.previous {
            currentStep = previous
            Logger.library.infoCapture("Onboarding moved back to step: \(previous.title)", category: "onboarding")
        }
    }

    /// Mark onboarding as complete and persist the completion state.
    public func completeOnboarding() {
        SyncedSettingsStore.shared.set(Self.currentVersion, forKey: .onboardingCompletedVersion)
        Self.forceShowOnboarding = false  // Clear force flag if it was set
        currentStep = .libraryProxy  // Reset for potential future re-runs
        Logger.library.infoCapture("Onboarding completed (version \(Self.currentVersion))", category: "onboarding")
    }

    /// Reset the onboarding state (for testing).
    public func reset() {
        SyncedSettingsStore.shared.remove(forKey: .onboardingCompletedVersion)
        Self.forceShowOnboarding = false
        currentStep = .libraryProxy
        preferredDatabase = .openAlex
        Logger.library.infoCapture("Onboarding state reset", category: "onboarding")
    }

    /// Skip to the completion step (user chose to skip all).
    public func skipAll() {
        currentStep = .complete
        Logger.library.infoCapture("User skipped all onboarding steps", category: "onboarding")
    }
}
