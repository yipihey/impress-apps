//
//  QueryAssistanceView.swift
//  PublicationManagerCore
//
//  SwiftUI view component for displaying query validation feedback
//  and result count previews.
//

import SwiftUI

// MARK: - Query Assistance View

/// Displays validation issues and result count preview for a search query.
///
/// This view shows:
/// - Validation errors, warnings, and hints
/// - Suggestions for fixing issues
/// - Live result count preview with appropriate coloring
public struct QueryAssistanceView: View {

    // MARK: - Properties

    @Bindable private var viewModel: QueryAssistanceViewModel

    /// Whether to show the preview count badge
    private let showPreview: Bool

    /// Whether to show hints (lowest severity)
    private let showHints: Bool

    /// Maximum number of issues to display
    private let maxIssues: Int

    // MARK: - Initialization

    public init(
        viewModel: QueryAssistanceViewModel,
        showPreview: Bool = true,
        showHints: Bool = false,
        maxIssues: Int = 3
    ) {
        self.viewModel = viewModel
        self.showPreview = showPreview
        self.showHints = showHints
        self.maxIssues = maxIssues
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Validation issues
            if !viewModel.isEmpty {
                issuesSection
            }

            // Preview count
            if showPreview && shouldShowPreview {
                previewSection
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.state.validationResult?.issues.count)
    }

    // MARK: - Issues Section

    @ViewBuilder
    private var issuesSection: some View {
        let issuesToShow = filteredIssues.prefix(maxIssues)

        if !issuesToShow.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(issuesToShow)) { issue in
                    IssueRowView(issue: issue) { suggestion in
                        viewModel.applySuggestion(suggestion)
                    }
                }

                if filteredIssues.count > maxIssues {
                    Text("+ \(filteredIssues.count - maxIssues) more issues")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filteredIssues: [QueryValidationIssue] {
        var issues = viewModel.issues
        if !showHints {
            issues = issues.filter { $0.severity != .hint }
        }
        return issues
    }

    // MARK: - Preview Section

    @ViewBuilder
    private var previewSection: some View {
        HStack(spacing: 6) {
            if viewModel.isFetchingPreview {
                ProgressView()
                    .controlSize(.small)
                Text("Checking results...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let count = viewModel.previewCount {
                PreviewCountBadge(count: count)
            }
        }
    }

    private var shouldShowPreview: Bool {
        viewModel.isFetchingPreview || viewModel.previewCount != nil
    }
}

// MARK: - Issue Row View

struct IssueRowView: View {
    let issue: QueryValidationIssue
    let onApplySuggestion: (QuerySuggestion) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Severity icon
            Image(systemName: issue.iconName)
                .font(.caption)
                .foregroundStyle(severityColor)

            VStack(alignment: .leading, spacing: 2) {
                // Message
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.primary)

                // Suggestions
                if !issue.suggestions.isEmpty {
                    ForEach(issue.suggestions) { suggestion in
                        Button {
                            onApplySuggestion(suggestion)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "lightbulb.fill")
                                    .font(.caption2)
                                Text(suggestion.description)
                                    .font(.caption2)
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(severityBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var severityColor: Color {
        switch issue.severity {
        case .error: return .red
        case .warning: return .orange
        case .hint: return .blue
        }
    }

    private var severityBackground: Color {
        switch issue.severity {
        case .error: return .red.opacity(0.1)
        case .warning: return .orange.opacity(0.1)
        case .hint: return .blue.opacity(0.05)
        }
    }
}

// MARK: - Preview Count Badge

struct PreviewCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption)
            Text(formattedCount)
                .font(.caption.monospacedDigit())
            Text("results")
                .font(.caption)
        }
        .foregroundStyle(countColor)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(countColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var formattedCount: String {
        if count >= 1_000_000 {
            return "\(count / 1_000_000)M+"
        } else if count >= 1_000 {
            return "\(count / 1_000)K+"
        }
        return NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    private var iconName: String {
        switch category {
        case .noResults: return "exclamationmark.triangle"
        case .good: return "checkmark.circle"
        case .tooMany: return "info.circle"
        }
    }

    private var countColor: Color {
        switch category {
        case .noResults: return .orange
        case .good: return .green
        case .tooMany: return .blue
        }
    }

    private var category: PreviewCategory {
        switch count {
        case 0: return .noResults
        case 1...10_000: return .good
        default: return .tooMany
        }
    }
}

// MARK: - Compact Query Assistance View

/// A more compact version for inline display in search fields.
public struct CompactQueryAssistanceView: View {

    @Bindable private var viewModel: QueryAssistanceViewModel

    public init(viewModel: QueryAssistanceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            if viewModel.hasErrors {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            } else if viewModel.hasWarnings {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if viewModel.isFetchingPreview {
                ProgressView()
                    .controlSize(.small)
            } else if let count = viewModel.previewCount {
                HStack(spacing: 2) {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                    Image(systemName: "doc.text")
                        .font(.caption2)
                }
                .foregroundStyle(countColor(for: count))
            }
        }
    }

    private func countColor(for count: Int) -> Color {
        switch count {
        case 0: return .orange
        case 1...10_000: return .green
        default: return .blue
        }
    }
}

// MARK: - Preview Provider

#if DEBUG
#Preview("Query Assistance View") {
    VStack(spacing: 20) {
        // This would need actual viewModel setup in a real preview
        Text("Preview placeholder")
    }
    .padding()
}
#endif
