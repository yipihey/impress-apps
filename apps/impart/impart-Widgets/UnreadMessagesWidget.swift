import WidgetKit
import SwiftUI

// MARK: - Data Models

struct UnreadMessagesEntry: TimelineEntry {
    let date: Date
    let unreadCount: Int
    let latestSubject: String
    let latestSender: String
    let latestPreview: String

    static var placeholder: UnreadMessagesEntry {
        UnreadMessagesEntry(
            date: Date(),
            unreadCount: 5,
            latestSubject: "Re: Paper draft review",
            latestSender: "Dr. Smith",
            latestPreview: "I've reviewed the latest version and have some comments on section 3..."
        )
    }

    static var empty: UnreadMessagesEntry {
        UnreadMessagesEntry(
            date: Date(),
            unreadCount: 0,
            latestSubject: "",
            latestSender: "",
            latestPreview: "No unread messages"
        )
    }
}

// MARK: - Timeline Provider

struct UnreadMessagesProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnreadMessagesEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadMessagesEntry) -> Void) {
        completion(.placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadMessagesEntry>) -> Void) {
        let defaults = UserDefaults(suiteName: "group.com.impress.suite")

        let unreadCount = defaults?.integer(forKey: "widget.impart.unreadCount") ?? 0
        let latestSubject = defaults?.string(forKey: "widget.impart.latestSubject") ?? ""
        let latestSender = defaults?.string(forKey: "widget.impart.latestSender") ?? ""
        let latestPreview = defaults?.string(forKey: "widget.impart.latestPreview") ?? "No unread messages"

        let entry = UnreadMessagesEntry(
            date: Date(),
            unreadCount: unreadCount,
            latestSubject: latestSubject,
            latestSender: latestSender,
            latestPreview: latestPreview
        )

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget View

struct UnreadMessagesWidgetView: View {
    let entry: UnreadMessagesEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(entry.unreadCount > 0 ? .blue : .secondary)
                Text("\(entry.unreadCount) unread")
                    .font(.headline)
                Spacer()
            }

            if family != .systemSmall, !entry.latestSubject.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.latestSubject)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(entry.latestSender)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(entry.latestPreview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding()
    }
}

// MARK: - Widget Definition

struct UnreadMessagesWidget: Widget {
    let kind = "UnreadMessagesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UnreadMessagesProvider()) { entry in
            UnreadMessagesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Unread Messages")
        .description("Shows unread message count and latest message preview.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
