//
//  PresenceAvatarView.swift
//  ImpressPresence
//
//  SwiftUI views for displaying collaborator presence.
//

import SwiftUI

// MARK: - Presence Avatar

/// A circular avatar showing a collaborator's initials and status.
public struct PresenceAvatarView: View {
    let presence: PresenceInfo
    let size: CGFloat

    public init(presence: PresenceInfo, size: CGFloat = 32) {
        self.presence = presence
        self.size = size
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Avatar circle
            Circle()
                .fill(avatarColor)
                .frame(width: size, height: size)
                .overlay {
                    Text(presence.initials)
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.white)
                }

            // Online indicator
            if presence.isActive {
                Circle()
                    .fill(Color.green)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay {
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    }
            }
        }
        .help(presence.userName + (presence.currentActivity.map { "\n\($0.description)" } ?? ""))
    }

    private var avatarColor: Color {
        // Generate consistent color from user ID
        let hash = presence.id.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }
}

// MARK: - Collaborator Stack

/// A horizontal stack of collaborator avatars with overflow handling.
public struct CollaboratorStackView: View {
    let collaborators: [PresenceInfo]
    let maxVisible: Int
    let avatarSize: CGFloat

    public init(collaborators: [PresenceInfo], maxVisible: Int = 4, avatarSize: CGFloat = 28) {
        self.collaborators = collaborators
        self.maxVisible = maxVisible
        self.avatarSize = avatarSize
    }

    public var body: some View {
        HStack(spacing: -avatarSize * 0.3) {
            ForEach(visibleCollaborators) { presence in
                PresenceAvatarView(presence: presence, size: avatarSize)
            }

            if overflowCount > 0 {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: avatarSize, height: avatarSize)
                    .overlay {
                        Text("+\(overflowCount)")
                            .font(.system(size: avatarSize * 0.35, weight: .medium))
                            .foregroundStyle(.white)
                    }
            }
        }
    }

    private var visibleCollaborators: [PresenceInfo] {
        Array(collaborators.prefix(maxVisible))
    }

    private var overflowCount: Int {
        max(0, collaborators.count - maxVisible)
    }
}

// MARK: - Collaborator List

/// A vertical list showing all collaborators with their activity.
public struct CollaboratorListView: View {
    let collaborators: [PresenceInfo]

    public init(collaborators: [PresenceInfo]) {
        self.collaborators = collaborators
    }

    public var body: some View {
        List(collaborators) { presence in
            CollaboratorRow(presence: presence)
        }
        .listStyle(.plain)
        .overlay {
            if collaborators.isEmpty {
                ContentUnavailableView(
                    "No Collaborators Online",
                    systemImage: "person.3",
                    description: Text("Collaborators will appear here when they're active.")
                )
            }
        }
    }
}

// MARK: - Collaborator Row

/// A row showing a single collaborator's presence.
public struct CollaboratorRow: View {
    let presence: PresenceInfo

    public init(presence: PresenceInfo) {
        self.presence = presence
    }

    public var body: some View {
        HStack(spacing: 12) {
            PresenceAvatarView(presence: presence, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(presence.userName)
                    .font(.headline)

                if let activity = presence.currentActivity {
                    Text(activity.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if presence.isActive {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text(timeAgo(presence.lastUpdated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

// MARK: - Presence Indicator

/// A small dot indicator showing presence status.
public struct PresenceIndicator: View {
    let isActive: Bool

    public init(isActive: Bool) {
        self.isActive = isActive
    }

    public var body: some View {
        Circle()
            .fill(isActive ? Color.green : Color.gray)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Toolbar Presence View

/// A view suitable for toolbar placement showing collaborator count.
public struct ToolbarPresenceView: View {
    @Environment(PresenceService.self) private var presenceService

    public init() {}

    public var body: some View {
        if !presenceService.collaborators.isEmpty {
            HStack(spacing: 4) {
                CollaboratorStackView(
                    collaborators: presenceService.collaborators,
                    maxVisible: 3,
                    avatarSize: 24
                )

                if presenceService.collaborators.count == 1 {
                    Text(presenceService.collaborators[0].userName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
        }
    }
}

// MARK: - Preview

#Preview("Avatar") {
    HStack(spacing: 20) {
        PresenceAvatarView(
            presence: PresenceInfo(
                id: "1",
                userName: "Alice Smith",
                currentActivity: .reading(itemId: "paper1", itemTitle: "Attention Is All You Need")
            ),
            size: 40
        )

        PresenceAvatarView(
            presence: PresenceInfo(
                id: "2",
                userName: "Bob Jones",
                currentActivity: .editing(itemId: "doc1", itemTitle: "Research Notes"),
                lastUpdated: Date().addingTimeInterval(-600)
            ),
            size: 40
        )
    }
    .padding()
}

#Preview("Stack") {
    CollaboratorStackView(
        collaborators: [
            PresenceInfo(id: "1", userName: "Alice Smith"),
            PresenceInfo(id: "2", userName: "Bob Jones"),
            PresenceInfo(id: "3", userName: "Carol Davis"),
            PresenceInfo(id: "4", userName: "Dan Wilson"),
            PresenceInfo(id: "5", userName: "Eve Brown"),
        ]
    )
    .padding()
}

#Preview("List") {
    CollaboratorListView(
        collaborators: [
            PresenceInfo(
                id: "1",
                userName: "Alice Smith",
                currentActivity: .reading(itemId: "p1", itemTitle: "Attention Is All You Need")
            ),
            PresenceInfo(
                id: "2",
                userName: "Bob Jones",
                currentActivity: .editing(itemId: "d1", itemTitle: "Research Notes")
            ),
            PresenceInfo(
                id: "3",
                userName: "Carol Davis",
                currentActivity: .browsing(location: "Library")
            ),
        ]
    )
    .frame(width: 300, height: 200)
}
