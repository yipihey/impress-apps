//
//  MessageRow.swift
//  impart (Shared)
//
//  Cross-platform message row for mail-style lists.
//

import SwiftUI

// MARK: - Message Row

/// Cross-platform message row for displaying in lists.
/// Works on both macOS and iOS with platform-appropriate styling.
public struct MessageRow: View {
    let message: DisplayMessage

    public init(message: DisplayMessage) {
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Unread indicator
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            // Message content
            VStack(alignment: .leading, spacing: 2) {
                // Header row: From + Date
                HStack {
                    Text(message.from)
                        .font(.headline)
                        .fontWeight(message.isRead ? .regular : .semibold)
                        .lineLimit(1)

                    Spacer()

                    if message.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }

                    Text(message.displayDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Subject with attachment and thread indicators
                HStack(spacing: 4) {
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(message.subject)
                        .font(.subheadline)
                        .fontWeight(message.isRead ? .regular : .medium)
                        .lineLimit(1)

                    if message.isThread {
                        Text("(\(message.threadCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Snippet
                Text(message.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Compact Message Row

/// Compact message row for dense lists.
public struct CompactMessageRow: View {
    let message: DisplayMessage

    public init(message: DisplayMessage) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Unread indicator
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 6, height: 6)

            // From
            Text(message.from)
                .font(.subheadline)
                .fontWeight(message.isRead ? .regular : .semibold)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            // Subject
            Text(message.subject)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            // Indicators
            if message.hasAttachments {
                Image(systemName: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if message.isStarred {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            // Date
            Text(message.displayDate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview("Message Row") {
    List(DisplayMessage.samples) { message in
        MessageRow(message: message)
    }
    .listStyle(.plain)
}

#Preview("Compact Row") {
    List(DisplayMessage.samples) { message in
        CompactMessageRow(message: message)
    }
    .listStyle(.plain)
}
