//
//  AIAvailability.swift
//  ImpressAI
//
//  Environment system for checking AI availability status.
//

import SwiftUI

// MARK: - Availability Status

/// Describes the availability state of AI features.
public enum AIAvailabilityStatus: Equatable, Sendable {
    /// AI is available with configured providers.
    case available(providers: [String])

    /// AI is unavailable with a specific reason.
    case unavailable(reason: AIUnavailableReason)

    /// Currently checking availability.
    case checking

    /// Availability status is unknown (not yet checked).
    case unknown

    /// Whether AI features should be shown.
    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// The list of available provider IDs, if any.
    public var providerIds: [String] {
        if case .available(let providers) = self { return providers }
        return []
    }

    /// The number of available providers.
    public var providerCount: Int {
        providerIds.count
    }
}

/// Reasons why AI may be unavailable.
public enum AIUnavailableReason: Equatable, Sendable {
    /// No API keys configured.
    case noCredentials

    /// No providers registered.
    case noProviders

    /// All providers failed validation.
    case allProvidersFailed

    /// Feature is disabled by user preference.
    case disabledByUser

    /// Custom reason with description.
    case custom(String)

    /// Human-readable description of the reason.
    public var description: String {
        switch self {
        case .noCredentials:
            return "No API keys configured"
        case .noProviders:
            return "No AI providers available"
        case .allProvidersFailed:
            return "Unable to connect to AI providers"
        case .disabledByUser:
            return "AI features disabled"
        case .custom(let message):
            return message
        }
    }
}

// MARK: - Environment Key

/// Environment key for AI availability status.
private struct AIAvailabilityKey: EnvironmentKey {
    static let defaultValue: AIAvailabilityStatus = .unknown
}

public extension EnvironmentValues {
    /// The current AI availability status.
    var aiAvailability: AIAvailabilityStatus {
        get { self[AIAvailabilityKey.self] }
        set { self[AIAvailabilityKey.self] = newValue }
    }
}

// MARK: - Observable Availability Checker

/// Observable object that checks and maintains AI availability status.
@MainActor
@Observable
public final class AIAvailabilityChecker {

    /// Shared singleton instance.
    public static let shared = AIAvailabilityChecker()

    /// Current availability status.
    public private(set) var status: AIAvailabilityStatus = .unknown

    /// Whether AI features should be visible in UI.
    public var shouldShowAIFeatures: Bool {
        status.isAvailable
    }

    /// Whether AI is currently being checked.
    public var isChecking: Bool {
        if case .checking = status { return true }
        return false
    }

    private let providerManager: AIProviderManager
    private var checkTask: Task<Void, Never>?

    public init(providerManager: AIProviderManager = .shared) {
        self.providerManager = providerManager
    }

    /// Check AI availability.
    public func checkAvailability() async {
        status = .checking

        // Get all registered providers
        let allProviders = await providerManager.allProviders

        guard !allProviders.isEmpty else {
            status = .unavailable(reason: .noProviders)
            return
        }

        // Check which providers are ready
        var readyProviders: [String] = []

        for provider in allProviders {
            do {
                let providerStatus = try await provider.validate()
                if providerStatus.isReady {
                    readyProviders.append(provider.metadata.id)
                }
            } catch {
                // Provider failed validation, skip it
                continue
            }
        }

        if readyProviders.isEmpty {
            // Check if it's because of credentials or other reasons
            let hasAnyCredentials = await checkHasAnyCredentials()
            if !hasAnyCredentials {
                status = .unavailable(reason: .noCredentials)
            } else {
                status = .unavailable(reason: .allProvidersFailed)
            }
        } else {
            status = .available(providers: readyProviders)
        }
    }

    /// Start periodic availability checking.
    public func startMonitoring(interval: TimeInterval = 60) {
        stopMonitoring()

        checkTask = Task {
            while !Task.isCancelled {
                await checkAvailability()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stop periodic availability checking.
    public func stopMonitoring() {
        checkTask?.cancel()
        checkTask = nil
    }

    private func checkHasAnyCredentials() async -> Bool {
        let credentialStatus = await providerManager.credentialStatus()

        for info in credentialStatus {
            let hasValid = info.fieldStatus.values.contains { status in
                if case .valid = status { return true }
                return false
            }
            if hasValid { return true }
        }

        return false
    }
}

// MARK: - View Modifiers

/// View modifier that conditionally shows content based on AI availability.
public struct AIFeatureModifier: ViewModifier {
    @Environment(\.aiAvailability) private var availability

    let showWhenDisabled: Bool
    let unavailableContent: AnyView?

    public func body(content: Content) -> some View {
        if availability.isAvailable {
            content
        } else if showWhenDisabled, let unavailable = unavailableContent {
            unavailable
        } else if showWhenDisabled {
            content.opacity(0.5).disabled(true)
        }
        // When !showWhenDisabled and !isAvailable, show nothing
    }
}

public extension View {
    /// Conditionally shows this view based on AI availability.
    ///
    /// - Parameters:
    ///   - showWhenDisabled: If true, shows the view in disabled state when AI is unavailable.
    ///                       If false, hides the view entirely.
    ///   - unavailableContent: Optional alternative content to show when AI is unavailable.
    /// - Returns: A view that respects AI availability.
    func withAIFeatures(
        showWhenDisabled: Bool = false,
        @ViewBuilder unavailableContent: () -> some View = { EmptyView() }
    ) -> some View {
        modifier(AIFeatureModifier(
            showWhenDisabled: showWhenDisabled,
            unavailableContent: AnyView(unavailableContent())
        ))
    }

    /// Injects AI availability status into the environment.
    ///
    /// - Parameter status: The availability status to inject.
    /// - Returns: A view with AI availability in its environment.
    func aiAvailability(_ status: AIAvailabilityStatus) -> some View {
        environment(\.aiAvailability, status)
    }
}

// MARK: - Provider View Modifier

/// View modifier that provides AI availability from the checker.
public struct AIAvailabilityProviderModifier: ViewModifier {
    @State private var checker = AIAvailabilityChecker.shared

    public func body(content: Content) -> some View {
        content
            .environment(\.aiAvailability, checker.status)
            .task {
                await checker.checkAvailability()
            }
    }
}

public extension View {
    /// Automatically provides AI availability status from the shared checker.
    func withAIAvailabilityProvider() -> some View {
        modifier(AIAvailabilityProviderModifier())
    }
}
