//
//  CollaboratorAvatarsView.swift
//  imprint
//
//  Shows connected collaborators as colored avatars in the toolbar.
//  Provides quick access to collaborator list and connection status.
//

import SwiftUI

// MARK: - Collaborator Avatars View

/// Toolbar view showing connected collaborators as colored avatar circles.
///
/// Features:
/// - Stacked avatar circles for each connected collaborator
/// - Click to show collaborator list popover
/// - Connection status indicator
/// - Colored rings matching collaborator cursor colors
struct CollaboratorAvatarsView: View {
    private var collaborationService = CollaborationService.shared

    @State private var isShowingPopover = false
    @State private var isHovering = false

    /// Maximum avatars to show before "+N" indicator
    private let maxVisibleAvatars = 4

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            HStack(spacing: -8) {
                // Connection status dot
                connectionStatusDot

                // Avatar stack
                if collaborationService.collaborators.isEmpty {
                    emptyStateLabel
                } else {
                    avatarStack
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            CollaboratorListPopover()
        }
        .help(helpText)
        .accessibilityIdentifier("toolbar.collaborators")
    }

    // MARK: - Connection Status Dot

    private var connectionStatusDot: some View {
        Circle()
            .fill(collaborationService.connectionStatus.color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1)
            )
    }

    // MARK: - Empty State

    private var emptyStateLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)

            if collaborationService.isConnected {
                Text("Just you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
    }

    // MARK: - Avatar Stack

    private var avatarStack: some View {
        HStack(spacing: -6) {
            ForEach(Array(collaborationService.collaborators.prefix(maxVisibleAvatars).enumerated()), id: \.element.id) { index, collaborator in
                CollaboratorAvatar(collaborator: collaborator)
                    .zIndex(Double(maxVisibleAvatars - index))
            }

            // Overflow indicator
            if collaborationService.collaborators.count > maxVisibleAvatars {
                overflowIndicator
            }
        }
        .padding(.leading, 8)
    }

    private var overflowIndicator: some View {
        let overflow = collaborationService.collaborators.count - maxVisibleAvatars
        return ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 24, height: 24)

            Text("+\(overflow)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .overlay(
            Circle()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var helpText: String {
        let count = collaborationService.collaborators.count
        switch count {
        case 0:
            return collaborationService.isConnected ? "No other collaborators" : "Not connected"
        case 1:
            return "1 collaborator online"
        default:
            return "\(count) collaborators online"
        }
    }
}

// MARK: - Collaborator Avatar

/// Single collaborator avatar circle.
struct CollaboratorAvatar: View {
    let collaborator: CollaboratorPresence

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(collaborator.color.opacity(0.2))
                .frame(width: 24, height: 24)

            // Initials
            Text(initials)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(collaborator.color)
        }
        .overlay(
            Circle()
                .stroke(collaborator.color, lineWidth: 2)
        )
        .overlay(
            // Online indicator
            Circle()
                .fill(collaborator.isOnline ? .green : .gray)
                .frame(width: 8, height: 8)
                .offset(x: 8, y: 8),
            alignment: .bottomTrailing
        )
        .accessibilityLabel(collaborator.displayName)
    }

    private var initials: String {
        let parts = collaborator.displayName.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        } else if let first = parts.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }
}

// MARK: - Collaborator List Popover

/// Popover showing detailed list of collaborators.
struct CollaboratorListPopover: View {
    private var collaborationService = CollaborationService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Collaborators")
                    .font(.headline)

                Spacer()

                connectionStatusBadge
            }
            .padding()

            Divider()

            // Collaborator list
            if collaborationService.collaborators.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(collaborationService.collaborators) { collaborator in
                            CollaboratorRow(collaborator: collaborator)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer with connection controls
            footer
        }
        .frame(width: 280)
    }

    private var connectionStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(collaborationService.connectionStatus.color)
                .frame(width: 8, height: 8)

            Text(collaborationService.connectionStatus.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("No other collaborators")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Share this document to collaborate in real-time")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack {
            if collaborationService.isConnected {
                Button("Disconnect") {
                    collaborationService.disconnect()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            } else {
                Button("Connect") {
                    Task {
                        await collaborationService.connect(documentId: "current-doc")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Spacer()

            Button {
                NotificationCenter.default.post(name: .shareDocument, object: nil)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }
}

// MARK: - Collaborator Row

/// Row in the collaborator list showing details.
struct CollaboratorRow: View {
    let collaborator: CollaboratorPresence

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            CollaboratorAvatar(collaborator: collaborator)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(collaborator.displayName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let position = collaborator.cursorPosition {
                        Text("Line \(lineNumber(for: position))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if collaborator.selection != nil {
                        Text("(selecting)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Last active
            Text(relativeTime(from: collaborator.lastActive))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.clear)
        .contentShape(Rectangle())
    }

    private func lineNumber(for position: Int) -> Int {
        // Simplified line number calculation
        // In real implementation, this would use the document text
        return max(1, position / 40)
    }

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        }
    }
}

// MARK: - Preview

#Preview {
    HStack {
        CollaboratorAvatarsView()
    }
    .padding()
    .onAppear {
        Task {
            await CollaborationService.shared.connect(documentId: "demo")
        }
    }
}
