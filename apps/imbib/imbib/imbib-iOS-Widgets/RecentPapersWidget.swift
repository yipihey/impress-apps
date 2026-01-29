//
//  RecentPapersWidget.swift
//  imbib-iOS-Widgets
//
//  Created by Claude on 2026-01-29.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct RecentPapersEntry: TimelineEntry {
    let date: Date
    let papers: [WidgetPaperItem]
    let configuration: RecentPapersConfigurationIntent
}

// Lightweight paper for this widget (to avoid duplicate type in same module)
struct WidgetPaperItem: Codable, Identifiable {
    let id: UUID
    let citeKey: String
    let title: String
    let authors: String
    let year: Int?
    let isRead: Bool
    let hasPDF: Bool
    let dateAdded: Date

    var shortAuthors: String {
        let parts = authors.components(separatedBy: " and ")
        if parts.count > 1 {
            return "\(parts[0]) et al."
        }
        return authors
    }

    var deepLinkURL: URL {
        URL(string: "imbib://paper/\(id.uuidString)")!
    }
}

// MARK: - Configuration Intent

struct RecentPapersConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Recent Papers"
    static var description = IntentDescription("Shows recently added papers.")

    @Parameter(title: "Show unread only", default: false)
    var unreadOnly: Bool
}

// MARK: - Timeline Provider

struct RecentPapersProvider: AppIntentTimelineProvider {

    private static let appGroupID = "group.com.imbib.app"

    func placeholder(in context: Context) -> RecentPapersEntry {
        RecentPapersEntry(
            date: Date(),
            papers: Self.samplePapers,
            configuration: RecentPapersConfigurationIntent()
        )
    }

    func snapshot(for configuration: RecentPapersConfigurationIntent, in context: Context) async -> RecentPapersEntry {
        let papers = loadRecentPapers(unreadOnly: configuration.unreadOnly)
        return RecentPapersEntry(
            date: Date(),
            papers: papers,
            configuration: configuration
        )
    }

    func timeline(for configuration: RecentPapersConfigurationIntent, in context: Context) async -> Timeline<RecentPapersEntry> {
        let papers = loadRecentPapers(unreadOnly: configuration.unreadOnly)
        let entry = RecentPapersEntry(
            date: Date(),
            papers: papers,
            configuration: configuration
        )

        // Refresh every 30 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func loadRecentPapers(unreadOnly: Bool) -> [WidgetPaperItem] {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: "widget.recentPapers") else {
            return []
        }

        // Decode as generic Codable array
        guard let papers = try? JSONDecoder().decode([WidgetPaperItem].self, from: data) else {
            return []
        }

        if unreadOnly {
            return papers.filter { !$0.isRead }
        }
        return papers
    }

    private static var samplePapers: [WidgetPaperItem] {
        [
            WidgetPaperItem(
                id: UUID(),
                citeKey: "Einstein1905",
                title: "On the Electrodynamics of Moving Bodies",
                authors: "Albert Einstein",
                year: 1905,
                isRead: false,
                hasPDF: true,
                dateAdded: Date()
            ),
            WidgetPaperItem(
                id: UUID(),
                citeKey: "Hawking1974",
                title: "Black hole explosions?",
                authors: "Stephen Hawking",
                year: 1974,
                isRead: true,
                hasPDF: true,
                dateAdded: Date()
            )
        ]
    }
}

// MARK: - Widget Views

struct RecentPapersWidgetEntryView: View {
    var entry: RecentPapersProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if entry.papers.isEmpty {
            emptyView
        } else {
            papersListView
        }
    }

    private var papersListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.blue)
                Text("Recent Papers")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)

            // Papers list
            ForEach(entry.papers.prefix(paperLimit)) { paper in
                Link(destination: paper.deepLinkURL) {
                    paperRow(paper)
                }
                .buttonStyle(.plain)

                if paper.id != entry.papers.prefix(paperLimit).last?.id {
                    Divider()
                        .padding(.vertical, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func paperRow(_ paper: WidgetPaperItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Unread indicator
            Circle()
                .fill(paper.isRead ? Color.clear : Color.blue)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(paper.title)
                    .font(.subheadline)
                    .lineLimit(family == .systemLarge ? 2 : 1)

                HStack {
                    Text(paper.shortAuthors)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let year = paper.year {
                        Text("(\(String(year)))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if paper.hasPDF {
                        Image(systemName: "doc.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No recent papers")
                .font(.headline)
            Text("Papers you add will appear here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var paperLimit: Int {
        switch family {
        case .systemMedium:
            return 3
        case .systemLarge:
            return 6
        default:
            return 2
        }
    }
}

// MARK: - Widget Configuration

struct RecentPapersWidget: Widget {
    let kind: String = "RecentPapersWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: RecentPapersConfigurationIntent.self,
            provider: RecentPapersProvider()
        ) { entry in
            RecentPapersWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Recent Papers")
        .description("Shows recently added papers from your library.")
        .supportedFamilies([
            .systemMedium,
            .systemLarge
        ])
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    RecentPapersWidget()
} timeline: {
    RecentPapersEntry(
        date: .now,
        papers: [
            WidgetPaperItem(
                id: UUID(),
                citeKey: "Einstein1905",
                title: "On the Electrodynamics of Moving Bodies",
                authors: "Albert Einstein",
                year: 1905,
                isRead: false,
                hasPDF: true,
                dateAdded: Date()
            ),
            WidgetPaperItem(
                id: UUID(),
                citeKey: "Hawking1974",
                title: "Black hole explosions?",
                authors: "Stephen Hawking",
                year: 1974,
                isRead: true,
                hasPDF: true,
                dateAdded: Date()
            )
        ],
        configuration: RecentPapersConfigurationIntent()
    )
}
