//
//  InboxCountWidget.swift
//  imbib-iOS-Widgets
//
//  Created by Claude on 2026-01-29.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct InboxCountEntry: TimelineEntry {
    let date: Date
    let unreadCount: Int
    let totalCount: Int
    let configuration: ConfigurationAppIntent
}

// MARK: - Configuration Intent

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Inbox Count"
    static var description = IntentDescription("Shows unread papers in your inbox.")
}

// MARK: - Timeline Provider

struct InboxCountProvider: AppIntentTimelineProvider {

    private static let appGroupID = "group.com.imbib.app"

    func placeholder(in context: Context) -> InboxCountEntry {
        InboxCountEntry(date: Date(), unreadCount: 3, totalCount: 10, configuration: ConfigurationAppIntent())
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> InboxCountEntry {
        let stats = loadInboxStats()
        return InboxCountEntry(
            date: Date(),
            unreadCount: stats?.unreadCount ?? 0,
            totalCount: stats?.totalCount ?? 0,
            configuration: configuration
        )
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<InboxCountEntry> {
        let stats = loadInboxStats()
        let entry = InboxCountEntry(
            date: Date(),
            unreadCount: stats?.unreadCount ?? 0,
            totalCount: stats?.totalCount ?? 0,
            configuration: configuration
        )

        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func loadInboxStats() -> WidgetInboxStats? {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let data = defaults.data(forKey: "widget.inboxStats") else {
            return nil
        }
        return try? JSONDecoder().decode(WidgetInboxStats.self, from: data)
    }
}

// MARK: - Widget Views

struct InboxCountWidgetEntryView: View {
    var entry: InboxCountProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .systemSmall:
            smallView
        default:
            smallView
        }
    }

    // Lock screen circular widget
    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 2) {
                Image(systemName: "tray.full.fill")
                    .font(.title3)
                Text("\(entry.unreadCount)")
                    .font(.headline)
                    .fontWeight(.bold)
            }
        }
    }

    // Lock screen rectangular widget
    private var rectangularView: some View {
        HStack {
            Image(systemName: "tray.full.fill")
                .font(.title2)
            VStack(alignment: .leading) {
                Text("\(entry.unreadCount) unread")
                    .font(.headline)
                Text("of \(entry.totalCount) papers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Home screen small widget
    private var smallView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .font(.largeTitle)
                .foregroundStyle(.blue)

            Text("\(entry.unreadCount)")
                .font(.system(size: 44, weight: .bold, design: .rounded))

            Text("unread papers")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Configuration

struct InboxCountWidget: Widget {
    let kind: String = "InboxCountWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ConfigurationAppIntent.self,
            provider: InboxCountProvider()
        ) { entry in
            InboxCountWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Inbox Count")
        .description("Shows unread papers in your inbox.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

// MARK: - Shared Types (from PublicationManagerCore)

struct WidgetInboxStats: Codable {
    let unreadCount: Int
    let totalCount: Int
    let lastUpdateDate: Date
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    InboxCountWidget()
} timeline: {
    InboxCountEntry(date: .now, unreadCount: 5, totalCount: 12, configuration: ConfigurationAppIntent())
    InboxCountEntry(date: .now, unreadCount: 0, totalCount: 12, configuration: ConfigurationAppIntent())
}
