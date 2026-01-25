//
//  CitationMetricsBadge.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI

// MARK: - Citation Metrics Badge

/// A badge displaying citation count with staleness indicator.
///
/// The badge color indicates how fresh the data is:
/// - Green: Updated within the last day
/// - Yellow: Updated 1-7 days ago
/// - Orange: Updated 7-30 days ago
/// - Red: Updated more than 30 days ago or never
///
/// ## Usage
///
/// ```swift
/// CitationMetricsBadge(
///     citationCount: 42,
///     enrichmentDate: someDate,
///     onRefresh: { await refreshData() }
/// )
/// ```
public struct CitationMetricsBadge: View {

    // MARK: - Properties

    /// The citation count to display (nil if not yet enriched)
    public let citationCount: Int?

    /// When the enrichment data was last updated (nil if never)
    public let enrichmentDate: Date?

    /// Action to refresh enrichment data
    public var onRefresh: (() async -> Void)?

    /// Whether a refresh is currently in progress
    @Binding public var isRefreshing: Bool

    // MARK: - Initialization

    public init(
        citationCount: Int?,
        enrichmentDate: Date?,
        isRefreshing: Binding<Bool> = .constant(false),
        onRefresh: (() async -> Void)? = nil
    ) {
        self.citationCount = citationCount
        self.enrichmentDate = enrichmentDate
        self._isRefreshing = isRefreshing
        self.onRefresh = onRefresh
    }

    // MARK: - Body

    public var body: some View {
        Button {
            Task {
                await onRefresh?()
            }
        } label: {
            HStack(spacing: 4) {
                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "quote.bubble")
                        .font(.caption2)
                }

                if let count = citationCount {
                    Text(formatCount(count))
                        .font(.caption)
                        .fontWeight(.medium)
                } else {
                    Text("--")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor.opacity(0.2))
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(onRefresh == nil || isRefreshing)
        .help(helpText)
    }

    // MARK: - Computed Properties

    /// Staleness level based on enrichment date
    private var stalenessLevel: StalenessLevel {
        StalenessLevel(from: enrichmentDate)
    }

    /// Background color based on staleness
    private var backgroundColor: Color {
        stalenessLevel.color
    }

    /// Foreground color for text
    private var foregroundColor: Color {
        switch stalenessLevel {
        case .fresh:
            return .green
        case .recent:
            return .yellow
        case .stale:
            return .orange
        case .veryStale, .neverEnriched:
            return .red
        }
    }

    /// Help text for tooltip
    private var helpText: String {
        if let date = enrichmentDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(for: date, relativeTo: Date())
            if let count = citationCount {
                return "\(count) citations (updated \(relative))"
            } else {
                return "Updated \(relative)"
            }
        } else {
            return "Never enriched - click to fetch citation data"
        }
    }

    // MARK: - Helpers

    /// Format large numbers with K/M suffixes
    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000.0
            return String(format: "%.1fM", millions)
        } else if count >= 10_000 {
            let thousands = Double(count) / 1_000.0
            return String(format: "%.0fK", thousands)
        } else if count >= 1_000 {
            let thousands = Double(count) / 1_000.0
            return String(format: "%.1fK", thousands)
        } else {
            return "\(count)"
        }
    }
}

// MARK: - Staleness Level

/// Represents how stale the enrichment data is.
public enum StalenessLevel: Sendable {
    /// Updated within the last day
    case fresh
    /// Updated 1-7 days ago
    case recent
    /// Updated 7-30 days ago
    case stale
    /// Updated more than 30 days ago
    case veryStale
    /// Never enriched
    case neverEnriched

    /// Initialize from an enrichment date
    public init(from date: Date?) {
        guard let date = date else {
            self = .neverEnriched
            return
        }

        let daysSinceUpdate = Calendar.current.dateComponents(
            [.day],
            from: date,
            to: Date()
        ).day ?? 0

        switch daysSinceUpdate {
        case ..<1:
            self = .fresh
        case 1..<7:
            self = .recent
        case 7..<30:
            self = .stale
        default:
            self = .veryStale
        }
    }

    /// Color associated with this staleness level
    public var color: Color {
        switch self {
        case .fresh:
            return .green
        case .recent:
            return .yellow
        case .stale:
            return .orange
        case .veryStale, .neverEnriched:
            return .red
        }
    }

    /// Human-readable description
    public var description: String {
        switch self {
        case .fresh:
            return "Fresh"
        case .recent:
            return "Recent"
        case .stale:
            return "Stale"
        case .veryStale:
            return "Very Stale"
        case .neverEnriched:
            return "Not Enriched"
        }
    }
}

// MARK: - Compact Citation Badge

/// A minimal citation count badge for tight spaces.
public struct CompactCitationBadge: View {

    public let citationCount: Int?
    public let enrichmentDate: Date?

    public init(citationCount: Int?, enrichmentDate: Date?) {
        self.citationCount = citationCount
        self.enrichmentDate = enrichmentDate
    }

    public var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 8))

            if let count = citationCount {
                Text(formatCompactCount(count))
                    .font(.system(size: 10, weight: .medium))
            }
        }
        .foregroundStyle(StalenessLevel(from: enrichmentDate).color)
    }

    private func formatCompactCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.0fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000.0)
        } else {
            return "\(count)"
        }
    }
}

// MARK: - Preview

#Preview("Citation Badge States") {
    VStack(spacing: 16) {
        // Fresh (today)
        CitationMetricsBadge(
            citationCount: 42,
            enrichmentDate: Date()
        )

        // Recent (3 days ago)
        CitationMetricsBadge(
            citationCount: 1500,
            enrichmentDate: Calendar.current.date(byAdding: .day, value: -3, to: Date())
        )

        // Stale (15 days ago)
        CitationMetricsBadge(
            citationCount: 98000,
            enrichmentDate: Calendar.current.date(byAdding: .day, value: -15, to: Date())
        )

        // Very Stale (60 days ago)
        CitationMetricsBadge(
            citationCount: 500000,
            enrichmentDate: Calendar.current.date(byAdding: .day, value: -60, to: Date())
        )

        // Never enriched
        CitationMetricsBadge(
            citationCount: nil,
            enrichmentDate: nil
        )

        Divider()

        // Compact versions
        HStack {
            CompactCitationBadge(citationCount: 42, enrichmentDate: Date())
            CompactCitationBadge(citationCount: 1500, enrichmentDate: nil)
            CompactCitationBadge(citationCount: 98000, enrichmentDate: Date())
        }
    }
    .padding()
}
