//
//  EnrichmentProgressView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI

// MARK: - Enrichment Progress View

/// A view showing the progress of enrichment operations.
///
/// Displays:
/// - Current operation status
/// - Progress bar for batch operations
/// - Queue statistics
/// - Individual paper enrichment status
///
/// ## Usage
///
/// ```swift
/// EnrichmentProgressView(
///     state: enrichmentState,
///     onCancel: { cancelEnrichment() }
/// )
/// ```
public struct EnrichmentProgressView: View {

    // MARK: - Properties

    public let state: EnrichmentProgressState
    public var onCancel: (() -> Void)?

    // MARK: - Initialization

    public init(
        state: EnrichmentProgressState,
        onCancel: (() -> Void)? = nil
    ) {
        self.state = state
        self.onCancel = onCancel
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with status
            HStack {
                statusIcon
                Text(state.statusMessage)
                    .font(.headline)
                Spacer()
                if state.isActive, let onCancel = onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
            }

            // Progress bar (if applicable)
            if state.isActive, state.totalCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: state.progress)
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(state.completedCount) of \(state.totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let eta = state.estimatedTimeRemaining {
                            Text("~\(formatDuration(eta)) remaining")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Current operation
            if let current = state.currentOperation {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)

                    Text(current)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Error display
            if let error = state.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Statistics (when idle)
            if !state.isActive, state.statistics != nil {
                statisticsView
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusIcon: some View {
        switch state.status {
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .enriching:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var statisticsView: some View {
        if let stats = state.statistics {
            Divider()
            HStack(spacing: 16) {
                StatisticItem(
                    label: "Enriched",
                    value: "\(stats.totalEnriched)"
                )
                StatisticItem(
                    label: "Stale",
                    value: "\(stats.staleCount)"
                )
                StatisticItem(
                    label: "Never",
                    value: "\(stats.neverEnrichedCount)"
                )
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "\(minutes)m"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}

// MARK: - Statistic Item

private struct StatisticItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Enrichment Progress State

/// Represents the current state of enrichment operations.
public struct EnrichmentProgressState: Sendable {

    /// The current status
    public var status: EnrichmentStatus

    /// Number of completed items
    public var completedCount: Int

    /// Total number of items to process
    public var totalCount: Int

    /// Currently processing operation description
    public var currentOperation: String?

    /// Last error message
    public var lastError: String?

    /// Estimated time remaining in seconds
    public var estimatedTimeRemaining: TimeInterval?

    /// Library statistics
    public var statistics: EnrichmentStatistics?

    // MARK: - Computed Properties

    /// Progress value from 0 to 1
    public var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    /// Whether enrichment is currently active
    public var isActive: Bool {
        status == .enriching
    }

    /// Human-readable status message
    public var statusMessage: String {
        switch status {
        case .idle:
            return "Ready"
        case .enriching:
            if totalCount > 0 {
                return "Enriching \(completedCount)/\(totalCount)"
            } else {
                return "Enriching..."
            }
        case .paused:
            return "Paused"
        case .error:
            return "Error"
        case .completed:
            return "Completed"
        }
    }

    // MARK: - Initialization

    public init(
        status: EnrichmentStatus = .idle,
        completedCount: Int = 0,
        totalCount: Int = 0,
        currentOperation: String? = nil,
        lastError: String? = nil,
        estimatedTimeRemaining: TimeInterval? = nil,
        statistics: EnrichmentStatistics? = nil
    ) {
        self.status = status
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.currentOperation = currentOperation
        self.lastError = lastError
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.statistics = statistics
    }

    // MARK: - Factory Methods

    /// Create an idle state
    public static let idle = EnrichmentProgressState(status: .idle)

    /// Create an enriching state
    public static func enriching(
        completed: Int,
        total: Int,
        current: String? = nil
    ) -> EnrichmentProgressState {
        EnrichmentProgressState(
            status: .enriching,
            completedCount: completed,
            totalCount: total,
            currentOperation: current
        )
    }

    /// Create a completed state
    public static func completed(count: Int) -> EnrichmentProgressState {
        EnrichmentProgressState(
            status: .completed,
            completedCount: count,
            totalCount: count
        )
    }

    /// Create an error state
    public static func error(_ message: String) -> EnrichmentProgressState {
        EnrichmentProgressState(
            status: .error,
            lastError: message
        )
    }
}

// MARK: - Enrichment Status

/// The status of enrichment operations.
public enum EnrichmentStatus: String, Sendable {
    case idle
    case enriching
    case paused
    case error
    case completed
}

// MARK: - Enrichment Statistics

/// Statistics about the enrichment state of the library.
public struct EnrichmentStatistics: Sendable {
    public let totalEnriched: Int
    public let staleCount: Int
    public let neverEnrichedCount: Int

    public init(
        totalEnriched: Int,
        staleCount: Int,
        neverEnrichedCount: Int
    ) {
        self.totalEnriched = totalEnriched
        self.staleCount = staleCount
        self.neverEnrichedCount = neverEnrichedCount
    }
}

// MARK: - Compact Progress Indicator

/// A compact progress indicator for showing enrichment status inline.
public struct CompactEnrichmentProgress: View {

    public let state: EnrichmentProgressState

    public init(state: EnrichmentProgressState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            if state.isActive {
                ProgressView()
                    .scaleEffect(0.6)

                if state.totalCount > 0 {
                    Text("\(state.completedCount)/\(state.totalCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if state.status == .error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }
}

// MARK: - Single Paper Enrichment Indicator

/// Shows the enrichment state of a single paper.
public struct PaperEnrichmentIndicator: View {

    public enum EnrichmentState {
        case notEnriched
        case enriching
        case enriched(Date)
        case error(String)
    }

    public let enrichmentState: EnrichmentState
    public var onRefresh: (() async -> Void)?

    public init(state: EnrichmentState, onRefresh: (() async -> Void)? = nil) {
        self.enrichmentState = state
        self.onRefresh = onRefresh
    }

    @SwiftUI.State private var isRefreshing = false

    public var body: some View {
        Button {
            guard !isRefreshing else { return }
            Task {
                isRefreshing = true
                await onRefresh?()
                isRefreshing = false
            }
        } label: {
            content
        }
        .buttonStyle(.plain)
        .disabled(onRefresh == nil || isRefreshing)
    }

    @ViewBuilder
    private var content: some View {
        switch enrichmentState {
        case .notEnriched:
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("Not enriched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .enriching:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Enriching...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .enriched(let date):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Preview

#Preview("Progress View - Enriching") {
    EnrichmentProgressView(
        state: .enriching(completed: 25, total: 100, current: "Einstein (1905) - Electrodynamics...")
    )
    .padding()
}

#Preview("Progress View - Idle with Stats") {
    EnrichmentProgressView(
        state: EnrichmentProgressState(
            status: .idle,
            statistics: EnrichmentStatistics(
                totalEnriched: 150,
                staleCount: 12,
                neverEnrichedCount: 8
            )
        )
    )
    .padding()
}

#Preview("Compact Progress") {
    VStack(spacing: 20) {
        CompactEnrichmentProgress(state: .idle)
        CompactEnrichmentProgress(state: .enriching(completed: 5, total: 10))
        CompactEnrichmentProgress(state: .error("Network error"))
    }
    .padding()
}

#Preview("Paper Indicator") {
    VStack(alignment: .leading, spacing: 16) {
        PaperEnrichmentIndicator(state: .notEnriched)
        PaperEnrichmentIndicator(state: .enriching)
        PaperEnrichmentIndicator(state: .enriched(Date()))
        PaperEnrichmentIndicator(state: .error("Rate limited"))
    }
    .padding()
}
