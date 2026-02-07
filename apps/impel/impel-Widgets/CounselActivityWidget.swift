import WidgetKit
import SwiftUI

// MARK: - Data Models

struct CounselActivityEntry: TimelineEntry {
    let date: Date
    let activeThreadCount: Int
    let pendingEscalations: Int
    let lastActivityDescription: String
    let isConnected: Bool

    static var placeholder: CounselActivityEntry {
        CounselActivityEntry(
            date: Date(),
            activeThreadCount: 3,
            pendingEscalations: 1,
            lastActivityDescription: "Literature Review: LLM Reasoning",
            isConnected: true
        )
    }

    static var empty: CounselActivityEntry {
        CounselActivityEntry(
            date: Date(),
            activeThreadCount: 0,
            pendingEscalations: 0,
            lastActivityDescription: "No active threads",
            isConnected: false
        )
    }
}

// MARK: - Timeline Provider

struct CounselActivityProvider: TimelineProvider {
    func placeholder(in context: Context) -> CounselActivityEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CounselActivityEntry) -> Void) {
        completion(.placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CounselActivityEntry>) -> Void) {
        let defaults = UserDefaults(suiteName: "group.com.impress.suite")

        let activeThreads = defaults?.integer(forKey: "widget.impel.activeThreadCount") ?? 0
        let escalations = defaults?.integer(forKey: "widget.impel.pendingEscalations") ?? 0
        let lastActivity = defaults?.string(forKey: "widget.impel.lastActivity") ?? "No active threads"
        let connected = defaults?.bool(forKey: "widget.impel.isConnected") ?? false

        let entry = CounselActivityEntry(
            date: Date(),
            activeThreadCount: activeThreads,
            pendingEscalations: escalations,
            lastActivityDescription: lastActivity,
            isConnected: connected
        )

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget View

struct CounselActivityWidgetView: View {
    let entry: CounselActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(entry.isConnected ? .green : .secondary)
                Text("Counsel")
                    .font(.headline)
                Spacer()
                if entry.pendingEscalations > 0 {
                    Label("\(entry.pendingEscalations)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Text("\(entry.activeThreadCount) active threads")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !entry.lastActivityDescription.isEmpty {
                Text(entry.lastActivityDescription)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Widget Definition

struct CounselActivityWidget: Widget {
    let kind = "CounselActivityWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CounselActivityProvider()) { entry in
            CounselActivityWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Counsel Activity")
        .description("Shows active counsel threads and escalations.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
