//
//  ActivityFeedView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import SwiftUI
import CoreData

// MARK: - Activity Feed View

/// Chronological activity feed for a shared library.
///
/// Shows content-level events (papers added, annotations made, comments posted)
/// grouped by date. No personal behavior tracking.
public struct ActivityFeedView: View {
    let library: CDLibrary

    @State private var activities: [CDActivityRecord] = []

    public init(library: CDLibrary) {
        self.library = library
    }

    public var body: some View {
        Group {
            if activities.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "clock",
                    description: Text("Activity will appear here as collaborators add papers, annotations, and comments.")
                )
            } else {
                List {
                    ForEach(groupedActivities, id: \.key) { date, records in
                        Section {
                            ForEach(records) { record in
                                ActivityRow(record: record)
                            }
                        } header: {
                            Text(date, style: .date)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Activity")
        .onAppear {
            activities = ActivityFeedService.shared.recentActivity(in: library, limit: 100)
        }
        .onReceive(NotificationCenter.default.publisher(for: .activityFeedUpdated)) { notification in
            if let lib = notification.object as? CDLibrary, lib.id == library.id {
                activities = ActivityFeedService.shared.recentActivity(in: library, limit: 100)
            }
        }
    }

    /// Group activities by calendar date
    private var groupedActivities: [(key: Date, value: [CDActivityRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: activities) { record in
            calendar.startOfDay(for: record.date)
        }
        return grouped.sorted { $0.key > $1.key }
    }
}

// MARK: - Activity Row

struct ActivityRow: View {
    let record: CDActivityRecord

    var body: some View {
        HStack(spacing: 10) {
            // Activity type icon
            Image(systemName: record.typeEnum?.icon ?? "circle")
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                // Main description
                Text(record.formattedDescription)
                    .font(.subheadline)
                    .lineLimit(2)

                // Detail if present
                if let detail = record.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Relative time
                Text(record.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        switch record.typeEnum {
        case .added: return .green
        case .removed: return .red
        case .annotated: return .yellow
        case .commented: return .blue
        case .organized: return .purple
        case .none: return .secondary
        }
    }
}

// MARK: - Activity Badge

/// Badge showing unread activity count for sidebar display.
public struct ActivityBadge: View {
    let library: CDLibrary
    @State private var count: Int = 0

    /// Date of last viewed activity (stored per-library in UserDefaults)
    private var lastViewedKey: String {
        "activityLastViewed_\(library.id.uuidString)"
    }

    private var lastViewedDate: Date {
        let timestamp = UserDefaults.standard.double(forKey: lastViewedKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : Date.distantPast
    }

    public init(library: CDLibrary) {
        self.library = library
    }

    public var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue)
                .clipShape(Capsule())
        }
    }

    /// Mark activity as viewed (call when user opens the feed)
    public func markAsViewed() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastViewedKey)
        count = 0
    }
}
