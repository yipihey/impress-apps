//
//  AIStatusIndicator.swift
//  ImpressAI
//
//  Status indicator widget showing AI availability.
//

import SwiftUI

/// A compact status indicator showing AI availability.
///
/// Displays a sparkle icon with provider count when AI is available,
/// or an appropriate status icon otherwise.
public struct AIStatusIndicator: View {
    @Environment(\.aiAvailability) private var availability

    /// Style for the indicator display.
    public enum Style {
        /// Compact: just the icon
        case compact
        /// Standard: icon with provider count
        case standard
        /// Expanded: icon, count, and status text
        case expanded
    }

    private let style: Style
    private let showTooltip: Bool

    /// Creates a new AI status indicator.
    ///
    /// - Parameters:
    ///   - style: The display style.
    ///   - showTooltip: Whether to show a tooltip on hover.
    public init(style: Style = .standard, showTooltip: Bool = true) {
        self.style = style
        self.showTooltip = showTooltip
    }

    public var body: some View {
        Group {
            switch style {
            case .compact:
                compactView
            case .standard:
                standardView
            case .expanded:
                expandedView
            }
        }
        .help(showTooltip ? tooltipText : "")
    }

    // MARK: - Style Views

    private var compactView: some View {
        statusIcon
            .font(.system(size: 12))
    }

    private var standardView: some View {
        HStack(spacing: 4) {
            statusIcon
                .font(.system(size: 12))

            if case .available(let providers) = availability {
                Text("\(providers.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var expandedView: some View {
        HStack(spacing: 6) {
            statusIcon
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.caption)
                    .fontWeight(.medium)

                Text(statusSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Status Components

    @ViewBuilder
    private var statusIcon: some View {
        switch availability {
        case .available:
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating.speed(0.5))

        case .unavailable(let reason):
            Image(systemName: iconForReason(reason))
                .foregroundStyle(.secondary)

        case .checking:
            ProgressView()
                .controlSize(.mini)

        case .unknown:
            Image(systemName: "sparkles")
                .foregroundStyle(.tertiary)
        }
    }

    private func iconForReason(_ reason: AIUnavailableReason) -> String {
        switch reason {
        case .noCredentials:
            return "key"
        case .noProviders:
            return "exclamationmark.triangle"
        case .allProvidersFailed:
            return "wifi.slash"
        case .disabledByUser:
            return "sparkles.slash"
        case .custom:
            return "questionmark.circle"
        }
    }

    private var statusTitle: String {
        switch availability {
        case .available(let providers):
            return "AI Ready"
        case .unavailable:
            return "AI Unavailable"
        case .checking:
            return "Checking..."
        case .unknown:
            return "AI Status"
        }
    }

    private var statusSubtitle: String {
        switch availability {
        case .available(let providers):
            let count = providers.count
            return count == 1 ? "1 provider" : "\(count) providers"
        case .unavailable(let reason):
            return reason.description
        case .checking:
            return "Please wait"
        case .unknown:
            return "Not checked"
        }
    }

    private var tooltipText: String {
        switch availability {
        case .available(let providers):
            return "AI available: \(providers.joined(separator: ", "))"
        case .unavailable(let reason):
            return "AI unavailable: \(reason.description)"
        case .checking:
            return "Checking AI availability..."
        case .unknown:
            return "AI availability not checked"
        }
    }
}

// MARK: - Menu Bar Button

/// A button suitable for menu bars that shows AI status and opens settings.
public struct AIStatusMenuButton: View {
    @Environment(\.aiAvailability) private var availability

    private let action: () -> Void

    /// Creates a new AI status menu button.
    ///
    /// - Parameter action: Action to perform when tapped (typically opens settings).
    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            AIStatusIndicator(style: .standard)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar Item

/// A toolbar item that displays AI status.
public struct AIStatusToolbarContent: ToolbarContent {
    private let action: () -> Void

    /// Creates a new AI status toolbar content.
    ///
    /// - Parameter action: Action to perform when tapped.
    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            AIStatusMenuButton(action: action)
        }
    }
}

// MARK: - Preview

#Preview("AIStatusIndicator - Available") {
    VStack(spacing: 20) {
        AIStatusIndicator(style: .compact)
        AIStatusIndicator(style: .standard)
        AIStatusIndicator(style: .expanded)
    }
    .padding()
    .aiAvailability(.available(providers: ["anthropic", "openai"]))
}

#Preview("AIStatusIndicator - Unavailable") {
    VStack(spacing: 20) {
        AIStatusIndicator(style: .expanded)
            .aiAvailability(.unavailable(reason: .noCredentials))

        AIStatusIndicator(style: .expanded)
            .aiAvailability(.unavailable(reason: .noProviders))

        AIStatusIndicator(style: .expanded)
            .aiAvailability(.checking)
    }
    .padding()
}
