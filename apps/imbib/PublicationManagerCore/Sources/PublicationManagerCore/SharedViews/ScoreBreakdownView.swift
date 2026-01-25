//
//  ScoreBreakdownView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI

// MARK: - Score Breakdown View (ADR-020)

/// Shows the detailed score breakdown for a publication.
///
/// Explains why a paper is ranked where it is, with all feature contributions visible.
/// Users can adjust weights or request "less/more like this" from this view.
public struct ScoreBreakdownView: View {

    // MARK: - Properties

    let publication: CDPublication
    @State private var breakdown: ScoreBreakdown?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    /// Callback when user requests "more like this"
    public var onMoreLikeThis: ((CDPublication) -> Void)?

    /// Callback when user requests "less like this"
    public var onLessLikeThis: ((CDPublication) -> Void)?

    /// Callback to open settings
    public var onOpenSettings: (() -> Void)?

    // MARK: - Initialization

    public init(
        publication: CDPublication,
        onMoreLikeThis: ((CDPublication) -> Void)? = nil,
        onLessLikeThis: ((CDPublication) -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.publication = publication
        self.onMoreLikeThis = onMoreLikeThis
        self.onLessLikeThis = onLessLikeThis
        self.onOpenSettings = onOpenSettings
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Paper info header
                    paperHeader

                    Divider()

                    // Overall score
                    overallScoreSection

                    // Feature contributions
                    if let breakdown = breakdown {
                        contributionsSection(breakdown)
                    }

                    // Quick actions
                    quickActionsSection
                }
                .padding()
            }
            .navigationTitle("Why This Ranking?")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        .task {
            await loadBreakdown()
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 450, minHeight: 500)
        #endif
    }

    // MARK: - Paper Header

    private var paperHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(publication.title ?? "Untitled")
                .font(.headline)
                .lineLimit(2)

            Text(publication.authorString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if publication.year > 0 {
                Text(String(publication.year))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Overall Score Section

    private var overallScoreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Relevance Score")
                    .font(.title3.bold())
                Spacer()
                if let breakdown = breakdown {
                    Text(String(format: "%.2f", breakdown.total))
                        .font(.title2.monospacedDigit().bold())
                        .foregroundStyle(scoreColor(breakdown.total))
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("Higher scores indicate papers more likely to interest you based on your activity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Contributions Section

    private func contributionsSection(_ breakdown: ScoreBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Score Breakdown")
                .font(.headline)

            if breakdown.components.isEmpty {
                Text("No significant signals detected for this paper.")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                // Positive contributions
                let positive = breakdown.components.filter { $0.isPositiveContribution }
                if !positive.isEmpty {
                    Text("Positive signals")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(positive) { component in
                        ScoreComponentRow(component: component)
                    }
                }

                // Negative contributions
                let negative = breakdown.components.filter { !$0.isPositiveContribution }
                if !negative.isEmpty {
                    Text("Negative signals")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    ForEach(negative) { component in
                        ScoreComponentRow(component: component)
                    }
                }
            }
        }
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Text("Quick Actions")
                .font(.headline)

            HStack(spacing: 16) {
                if let onMoreLikeThis = onMoreLikeThis {
                    Button {
                        onMoreLikeThis(publication)
                        dismiss()
                    } label: {
                        Label("More like this", systemImage: "hand.thumbsup")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let onLessLikeThis = onLessLikeThis {
                    Button {
                        onLessLikeThis(publication)
                        dismiss()
                    } label: {
                        Label("Less like this", systemImage: "hand.thumbsdown")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let onOpenSettings = onOpenSettings {
                Button {
                    onOpenSettings()
                    dismiss()
                } label: {
                    Label("Adjust weights in Settings...", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func loadBreakdown() async {
        isLoading = true
        breakdown = await RecommendationEngine.shared.scoreBreakdown(publication)
        isLoading = false
    }

    private func scoreColor(_ score: Double) -> Color {
        if score > 1.0 {
            return .green
        } else if score > 0.5 {
            return .blue
        } else if score > 0 {
            return .primary
        } else if score > -0.5 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Score Component Row

private struct ScoreComponentRow: View {
    let component: ScoreComponent

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.feature.displayName)
                    .font(.subheadline)
                Text(component.feature.featureDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Visual bar
            contributionBar

            // Numeric value
            Text(String(format: "%+.2f", component.contribution))
                .font(.caption.monospacedDigit())
                .foregroundStyle(component.isPositiveContribution ? .green : .red)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var contributionBar: some View {
        GeometryReader { geo in
            let maxWidth = geo.size.width
            let normalizedValue = min(abs(component.contribution), 1.0)
            let barWidth = normalizedValue * maxWidth

            HStack(spacing: 0) {
                if component.isPositiveContribution {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green.opacity(0.6))
                        .frame(width: barWidth, height: 8)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red.opacity(0.6))
                        .frame(width: barWidth, height: 8)
                    Spacer()
                }
            }
        }
        .frame(width: 60, height: 8)
    }
}

// MARK: - Serendipity Badge

/// Badge shown on papers that are serendipity slots.
public struct SerendipityBadge: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.caption2)
            Text("Discovery")
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.purple.opacity(0.2), in: Capsule())
        .foregroundStyle(.purple)
    }
}

#Preview {
    let context = PersistenceController.preview.viewContext
    let publication = context.performAndWait {
        let pub = CDPublication(context: context)
        pub.id = UUID()
        pub.title = "On the Electrodynamics of Moving Bodies"
        pub.citeKey = "Einstein1905"
        pub.year = 1905
        pub.fields = ["author": "Einstein, Albert"]
        return pub
    }

    return ScoreBreakdownView(
        publication: publication,
        onMoreLikeThis: { _ in },
        onLessLikeThis: { _ in }
    )
}
