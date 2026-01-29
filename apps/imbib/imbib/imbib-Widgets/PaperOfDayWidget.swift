//
//  PaperOfDayWidget.swift
//  imbib-Widgets (macOS)
//
//  Created by Claude on 2026-01-29.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct PaperOfDayEntry: TimelineEntry {
    let date: Date
    let paper: WidgetPaper?
    let reason: String?
    let configuration: PaperOfDayConfigurationIntent
}

// MARK: - Configuration Intent

struct PaperOfDayConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Paper of the Day"
    static var description = IntentDescription("Shows a featured paper from your inbox.")
}

// MARK: - Timeline Provider

struct PaperOfDayProvider: AppIntentTimelineProvider {

    private static let appGroupID = "group.com.imbib.app"

    func placeholder(in context: Context) -> PaperOfDayEntry {
        PaperOfDayEntry(
            date: Date(),
            paper: WidgetPaper(
                id: UUID(),
                citeKey: "Einstein1905",
                title: "On the Electrodynamics of Moving Bodies",
                authors: "Albert Einstein",
                year: 1905,
                isRead: false,
                hasPDF: true,
                dateAdded: Date()
            ),
            reason: "Featured paper",
            configuration: PaperOfDayConfigurationIntent()
        )
    }

    func snapshot(for configuration: PaperOfDayConfigurationIntent, in context: Context) async -> PaperOfDayEntry {
        let potd = loadPaperOfDay()
        return PaperOfDayEntry(
            date: Date(),
            paper: potd?.paper,
            reason: potd?.reason,
            configuration: configuration
        )
    }

    func timeline(for configuration: PaperOfDayConfigurationIntent, in context: Context) async -> Timeline<PaperOfDayEntry> {
        let potd = loadPaperOfDay()
        let entry = PaperOfDayEntry(
            date: Date(),
            paper: potd?.paper,
            reason: potd?.reason,
            configuration: configuration
        )

        // Refresh at midnight for new paper of day
        let tomorrow = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        return Timeline(entries: [entry], policy: .after(tomorrow))
    }

    private func loadPaperOfDay() -> WidgetPaperOfDay? {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: "widget.paperOfDay") else {
            return nil
        }
        let potd = try? JSONDecoder().decode(WidgetPaperOfDay.self, from: data)
        if let potd = potd, !Calendar.current.isDateInToday(potd.date) {
            return nil
        }
        return potd
    }
}

// MARK: - Widget Views

struct PaperOfDayWidgetEntryView: View {
    var entry: PaperOfDayProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if let paper = entry.paper {
            paperView(paper)
        } else {
            emptyView
        }
    }

    private func paperView(_ paper: WidgetPaper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text(entry.reason ?? "Featured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if paper.hasPDF {
                    Image(systemName: "doc.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Title
            Text(paper.title)
                .font(.headline)
                .lineLimit(family == .systemMedium ? 2 : 3)

            // Authors
            Text(paper.shortAuthors)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Year
            if let year = paper.year {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(paper.deepLinkURL)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "star")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No paper today")
                .font(.headline)
            Text("Add papers to your inbox")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Configuration

struct PaperOfDayWidget: Widget {
    let kind: String = "PaperOfDayWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: PaperOfDayConfigurationIntent.self,
            provider: PaperOfDayProvider()
        ) { entry in
            PaperOfDayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Paper of the Day")
        .description("Shows a featured paper from your inbox.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Shared Types

struct WidgetPaper: Codable {
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

struct WidgetPaperOfDay: Codable {
    let paper: WidgetPaper
    let reason: String
    let date: Date
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    PaperOfDayWidget()
} timeline: {
    PaperOfDayEntry(
        date: .now,
        paper: WidgetPaper(
            id: UUID(),
            citeKey: "Einstein1905",
            title: "On the Electrodynamics of Moving Bodies",
            authors: "Albert Einstein",
            year: 1905,
            isRead: false,
            hasPDF: true,
            dateAdded: Date()
        ),
        reason: "Unread addition",
        configuration: PaperOfDayConfigurationIntent()
    )
}
