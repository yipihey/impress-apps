import WidgetKit
import SwiftUI

// MARK: - Data Models

struct SuiteStatusEntry: TimelineEntry {
    let date: Date
    let apps: [AppStatus]

    struct AppStatus: Identifiable {
        let id: String
        let name: String
        let isRunning: Bool
        let iconName: String
    }

    static var placeholder: SuiteStatusEntry {
        SuiteStatusEntry(date: Date(), apps: [
            AppStatus(id: "imbib", name: "imbib", isRunning: true, iconName: "book"),
            AppStatus(id: "imprint", name: "imprint", isRunning: true, iconName: "doc.text"),
            AppStatus(id: "implore", name: "implore", isRunning: false, iconName: "chart.xyaxis.line"),
            AppStatus(id: "impel", name: "impel", isRunning: true, iconName: "brain"),
            AppStatus(id: "impart", name: "impart", isRunning: false, iconName: "envelope"),
        ])
    }
}

// MARK: - Timeline Provider

struct SuiteStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> SuiteStatusEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SuiteStatusEntry) -> Void) {
        completion(.placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SuiteStatusEntry>) -> Void) {
        let defaults = UserDefaults(suiteName: "group.com.impress.suite")

        let appConfigs: [(id: String, name: String, icon: String)] = [
            ("imbib", "imbib", "book"),
            ("imprint", "imprint", "doc.text"),
            ("implore", "implore", "chart.xyaxis.line"),
            ("impel", "impel", "brain"),
            ("impart", "impart", "envelope"),
        ]

        let apps = appConfigs.map { config in
            let isRunning = defaults?.bool(forKey: "widget.suite.\(config.id).running") ?? false
            return SuiteStatusEntry.AppStatus(
                id: config.id,
                name: config.name,
                isRunning: isRunning,
                iconName: config.icon
            )
        }

        let entry = SuiteStatusEntry(date: Date(), apps: apps)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget View

struct SuiteStatusWidgetView: View {
    let entry: SuiteStatusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Impress Suite")
                .font(.headline)

            ForEach(entry.apps) { app in
                HStack(spacing: 6) {
                    Image(systemName: app.iconName)
                        .frame(width: 16)
                        .foregroundStyle(app.isRunning ? .green : .secondary)
                    Text(app.name)
                        .font(.caption)
                    Spacer()
                    Circle()
                        .fill(app.isRunning ? .green : .secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding()
    }
}

// MARK: - Widget Definition

struct SuiteStatusWidget: Widget {
    let kind = "SuiteStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SuiteStatusProvider()) { entry in
            SuiteStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Suite Status")
        .description("Shows which Impress suite apps are running.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
