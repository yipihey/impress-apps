//
//  ProgressViews.swift
//  ImpressProgress
//
//  SwiftUI views for displaying research progress.
//

import SwiftUI

// MARK: - Progress Card

/// A compact card showing reading progress.
public struct ProgressCard: View {
    let summary: ProgressSummary

    public init(summary: ProgressSummary) {
        self.summary = summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Reading Progress")
                    .font(.headline)
                Spacer()
                if summary.currentStreak > 0 {
                    streakBadge
                }
            }

            // Stats grid
            HStack(spacing: 16) {
                statItem(value: summary.papersThisWeek, label: "This Week")
                Divider()
                    .frame(height: 30)
                statItem(value: summary.papersThisMonth, label: "This Month")
                Divider()
                    .frame(height: 30)
                statItem(value: summary.totalPapersRead, label: "Total")
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var streakBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .foregroundStyle(.orange)
            Text("\(summary.currentStreak)")
                .fontWeight(.medium)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.orange.opacity(0.15))
        .clipShape(Capsule())
    }

    private func statItem(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.semibold)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Streak Display

/// A minimal streak indicator for toolbars.
public struct StreakIndicator: View {
    let days: Int

    public init(days: Int) {
        self.days = days
    }

    public var body: some View {
        if days > 0 {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(days >= 7 ? .orange : .secondary)
                Text("\(days)d")
            }
            .font(.caption)
            .help("Reading streak: \(days) day\(days == 1 ? "" : "s")")
        }
    }
}

// MARK: - Milestone Toast

/// A toast notification for milestone achievements.
public struct MilestoneToast: View {
    let milestone: Milestone
    let onDismiss: () -> Void

    @State private var appeared = false

    public init(milestone: Milestone, onDismiss: @escaping () -> Void) {
        self.milestone = milestone
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            milestoneIcon
                .font(.title2)
                .symbolEffect(.bounce, value: appeared)

            VStack(alignment: .leading, spacing: 2) {
                Text("Milestone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(milestone.message)
                    .font(.callout)
                    .fontWeight(.medium)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
        .onAppear {
            appeared = true
        }
    }

    @ViewBuilder
    private var milestoneIcon: some View {
        switch milestone.type {
        case .papersRead:
            Image(systemName: "book.fill")
                .foregroundStyle(.blue)
        case .readingStreak:
            Image(systemName: "flame.fill")
                .foregroundStyle(.orange)
        case .writingMilestone:
            Image(systemName: "pencil.line")
                .foregroundStyle(.purple)
        case .annotationsMade:
            Image(systemName: "highlighter")
                .foregroundStyle(.yellow)
        case .citationsAdded:
            Image(systemName: "quote.bubble.fill")
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Trend Sparkline

/// A minimal sparkline showing papers read over time.
public struct TrendSparkline: View {
    let data: [(date: Date, count: Int)]
    let color: Color

    public init(data: [(date: Date, count: Int)], color: Color = .blue) {
        self.data = data
        self.color = color
    }

    public var body: some View {
        GeometryReader { geometry in
            let maxCount = max(data.map(\.count).max() ?? 1, 1)
            let width = geometry.size.width
            let height = geometry.size.height
            let stepX = width / CGFloat(max(data.count - 1, 1))

            Path { path in
                guard !data.isEmpty else { return }

                let points = data.enumerated().map { index, item in
                    CGPoint(
                        x: CGFloat(index) * stepX,
                        y: height - (CGFloat(item.count) / CGFloat(maxCount)) * height
                    )
                }

                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Fill gradient
            Path { path in
                guard !data.isEmpty else { return }

                let points = data.enumerated().map { index, item in
                    CGPoint(
                        x: CGFloat(index) * stepX,
                        y: height - (CGFloat(item.count) / CGFloat(maxCount)) * height
                    )
                }

                path.move(to: CGPoint(x: 0, y: height))
                for point in points {
                    path.addLine(to: point)
                }
                path.addLine(to: CGPoint(x: width, y: height))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.3), color.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
}

// MARK: - Progress Summary View

/// Full progress summary view for settings or dashboard.
public struct ProgressSummaryView: View {
    @State private var progressService = ProgressService.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Reading stats card
            ProgressCard(summary: progressService.summary)

            // 14-day trend
            VStack(alignment: .leading, spacing: 8) {
                Text("Last 14 Days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TrendSparkline(data: progressService.papersTrend(days: 14))
                    .frame(height: 60)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .clipShape(.rect(cornerRadius: 12))

            // Recent milestones
            if !progressService.summary.recentMilestones.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Milestones")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(progressService.summary.recentMilestones) { milestone in
                        HStack {
                            milestoneIcon(for: milestone.type)
                            Text(milestone.message)
                                .font(.callout)
                            Spacer()
                            Text(milestone.achievedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .clipShape(.rect(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func milestoneIcon(for type: MilestoneType) -> some View {
        switch type {
        case .papersRead:
            Image(systemName: "book.fill")
                .foregroundStyle(.blue)
        case .readingStreak:
            Image(systemName: "flame.fill")
                .foregroundStyle(.orange)
        case .writingMilestone:
            Image(systemName: "pencil.line")
                .foregroundStyle(.purple)
        case .annotationsMade:
            Image(systemName: "highlighter")
                .foregroundStyle(.yellow)
        case .citationsAdded:
            Image(systemName: "quote.bubble.fill")
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Previews

#Preview("Progress Card") {
    ProgressCard(summary: ProgressSummary(
        currentStreak: 7,
        longestStreak: 14,
        totalPapersRead: 127,
        papersThisWeek: 12,
        papersThisMonth: 45
    ))
    .padding()
}

#Preview("Streak Indicator") {
    HStack(spacing: 20) {
        StreakIndicator(days: 0)
        StreakIndicator(days: 3)
        StreakIndicator(days: 7)
        StreakIndicator(days: 30)
    }
    .padding()
}

#Preview("Milestone Toast") {
    MilestoneToast(
        milestone: Milestone(
            type: .papersRead,
            value: 100,
            message: "100 papers read"
        ),
        onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("Trend Sparkline") {
    TrendSparkline(data: [
        (Date().addingTimeInterval(-86400 * 6), 3),
        (Date().addingTimeInterval(-86400 * 5), 5),
        (Date().addingTimeInterval(-86400 * 4), 2),
        (Date().addingTimeInterval(-86400 * 3), 8),
        (Date().addingTimeInterval(-86400 * 2), 4),
        (Date().addingTimeInterval(-86400 * 1), 6),
        (Date(), 3)
    ])
    .frame(width: 200, height: 60)
    .padding()
}
