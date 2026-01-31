//
//  MessageBubbleView.swift
//  impart (macOS)
//
//  Individual message display component.
//

import SwiftUI
import MessageManagerCore
#if os(macOS)
import AppKit
#endif

/// Displays a single message in the conversation.
struct MessageBubbleView: View {
    let message: ResearchMessage
    var onBranch: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            avatarView

            // Message content
            VStack(alignment: .leading, spacing: 6) {
                // Header
                HStack {
                    Text(message.senderDisplayName)
                        .font(.caption)
                        .fontWeight(.medium)

                    if let model = message.modelUsed {
                        Text(model)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    // Actions (shown on hover)
                    if isHovering {
                        HStack(spacing: 4) {
                            Button {
                                onBranch?()
                            } label: {
                                Image(systemName: "arrow.triangle.branch")
                            }
                            .buttonStyle(.borderless)
                            .help("Branch from here")

                            Button {
                                copyToClipboard()
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy to clipboard")
                        }
                        .foregroundStyle(.secondary)
                    }

                    Text(message.sentAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Artifact mentions (if any)
                if !message.mentionedArtifactURIs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.mentionedArtifactURIs, id: \.self) { uri in
                                ArtifactMentionPill(uri: uri)
                            }
                        }
                    }
                }

                // Content - rendered as rich markdown
                ChatMarkdownView(content: message.contentMarkdown)

                // Side conversation indicator
                if message.hasSideConversation, let sideId = message.sideConversationId {
                    HStack {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.purple)
                        Text("Has side conversation")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                    .padding(.vertical, 4)
                }

                // Metrics (for counsel messages)
                if message.isFromCounsel, let tokens = message.tokenCount {
                    HStack(spacing: 12) {
                        Label("\(tokens) tokens", systemImage: "number")

                        if let duration = message.processingDurationMs {
                            Label(formatDuration(duration), systemImage: "clock")
                        }

                        if !message.mentionedArtifactURIs.isEmpty {
                            Label("\(message.mentionedArtifactURIs.count) refs", systemImage: "link")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.contentMarkdown, forType: .string)
        #endif
    }

    private var avatarView: some View {
        Image(systemName: message.senderIconName)
            .font(.title2)
            .foregroundStyle(avatarColor)
            .frame(width: 32, height: 32)
            .background(avatarColor.opacity(0.15))
            .clipShape(Circle())
    }

    private var backgroundColor: Color {
        switch message.senderRole {
        case .human:
            return Color.accentColor.opacity(0.1)
        case .counsel:
            return Color.secondary.opacity(0.1)
        case .system:
            return Color.yellow.opacity(0.1)
        }
    }

    private var avatarColor: Color {
        switch message.senderRole {
        case .human:
            return .accentColor
        case .counsel:
            return .purple
        case .system:
            return .orange
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
    }
}

// MARK: - Artifact Mention Pill

private struct ArtifactMentionPill: View {
    let uri: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .font(.caption2)
            Text(shortDisplayName)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.blue.opacity(0.1))
        .foregroundStyle(.blue)
        .clipShape(Capsule())
    }

    private var shortDisplayName: String {
        // Extract display name from URI
        // e.g., "impress://imbib/papers/Fowler2012" -> "Fowler2012"
        uri.components(separatedBy: "/").last ?? uri
    }
}

#Preview {
    VStack(spacing: 16) {
        MessageBubbleView(message: ResearchMessage(
            conversationId: UUID(),
            sequence: 1,
            senderRole: .human,
            senderId: "user@example.com",
            contentMarkdown: "Let's discuss the surface code paper by Fowler et al. 2012."
        ))

        MessageBubbleView(message: ResearchMessage(
            conversationId: UUID(),
            sequence: 2,
            senderRole: .counsel,
            senderId: "counsel-opus4.5@impart.local",
            modelUsed: "opus4.5",
            contentMarkdown: "The Fowler et al. 2012 paper on surface codes is a foundational work in quantum error correction. It introduces the planar surface code architecture which has become one of the leading candidates for fault-tolerant quantum computing.",
            tokenCount: 156,
            processingDurationMs: 1200
        ))
    }
    .padding()
    .frame(width: 500)
}
