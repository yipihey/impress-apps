//
//  ChatBubble.swift
//  impart
//
//  Chat bubble view for message display in chat mode.
//

import SwiftUI

// MARK: - Chat Bubble

/// A chat-style message bubble.
struct ChatBubble: View {

    // MARK: - Properties

    /// Whether this message is from the current user (sent) or received.
    let isSent: Bool

    /// The message content.
    let content: String

    /// Sender name (only shown for received messages).
    let senderName: String?

    /// Timestamp for the message.
    let timestamp: Date

    /// Whether this message is from an AI agent.
    let isAgentMessage: Bool

    // MARK: - State

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Initializer

    init(
        isSent: Bool,
        content: String,
        senderName: String? = nil,
        timestamp: Date,
        isAgentMessage: Bool = false
    ) {
        self.isSent = isSent
        self.content = content
        self.senderName = senderName
        self.timestamp = timestamp
        self.isAgentMessage = isAgentMessage
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isSent {
                Spacer(minLength: 40)
            }

            VStack(alignment: isSent ? .trailing : .leading, spacing: 4) {
                // Sender name for received messages
                if !isSent, let name = senderName {
                    HStack(spacing: 4) {
                        if isAgentMessage {
                            Image(systemName: "brain.head.profile")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                        }
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Message bubble
                Text(content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(ChatBubbleShape(isSent: isSent))
                    .foregroundStyle(isSent ? .white : .primary)

                // Timestamp
                Text(formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isSent {
                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - Helpers

    private var bubbleBackground: some ShapeStyle {
        if isAgentMessage {
            return Color.purple.opacity(isSent ? 1.0 : 0.15)
        }
        return isSent
            ? Color.accentColor
            : (colorScheme == .dark ? Color.gray.opacity(0.3) : Color.gray.opacity(0.15))
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Chat Bubble Shape

/// Custom bubble shape with tail on one side.
struct ChatBubbleShape: Shape {
    let isSent: Bool

    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat = 16
        let tailSize: CGFloat = 6

        var path = Path()

        if isSent {
            // Sent: tail on right
            path.addRoundedRect(
                in: CGRect(x: 0, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
            )

            // Tail
            path.move(to: CGPoint(x: rect.width - tailSize, y: rect.height - 20))
            path.addCurve(
                to: CGPoint(x: rect.width, y: rect.height - 8),
                control1: CGPoint(x: rect.width - tailSize, y: rect.height - 12),
                control2: CGPoint(x: rect.width - 2, y: rect.height - 8)
            )
            path.addCurve(
                to: CGPoint(x: rect.width - tailSize, y: rect.height - 4),
                control1: CGPoint(x: rect.width - 4, y: rect.height - 2),
                control2: CGPoint(x: rect.width - tailSize, y: rect.height - 4)
            )
        } else {
            // Received: tail on left
            path.addRoundedRect(
                in: CGRect(x: tailSize, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
            )

            // Tail
            path.move(to: CGPoint(x: tailSize, y: rect.height - 20))
            path.addCurve(
                to: CGPoint(x: 0, y: rect.height - 8),
                control1: CGPoint(x: tailSize, y: rect.height - 12),
                control2: CGPoint(x: 2, y: rect.height - 8)
            )
            path.addCurve(
                to: CGPoint(x: tailSize, y: rect.height - 4),
                control1: CGPoint(x: 4, y: rect.height - 2),
                control2: CGPoint(x: tailSize, y: rect.height - 4)
            )
        }

        return path
    }
}

// MARK: - Message Group Header

/// Header showing date for a group of messages.
struct MessageGroupHeader: View {
    let date: Date

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(formattedDate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack { Divider() }
        }
        .padding(.vertical, 8)
    }

    private var formattedDate: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMMM d"
            return formatter.string(from: date)
        } else {
            formatter.dateFormat = "MMMM d, yyyy"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Typing Indicator

/// Animated typing indicator for agent responses.
struct TypingIndicator: View {
    @State private var animationPhase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever()
                        .delay(Double(index) * 0.15),
                        value: animationPhase
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.15))
        .clipShape(Capsule())
        .onAppear {
            withAnimation {
                animationPhase = 2
            }
        }
    }
}

// MARK: - Previews

#Preview("Sent Bubble") {
    VStack {
        ChatBubble(
            isSent: true,
            content: "This is a sent message that might be a bit longer to show wrapping.",
            timestamp: Date()
        )
        ChatBubble(
            isSent: false,
            content: "This is a received message.",
            senderName: "Alice",
            timestamp: Date().addingTimeInterval(-60)
        )
        ChatBubble(
            isSent: false,
            content: "This is a message from an AI agent.",
            senderName: "Counsel (Opus 4.5)",
            timestamp: Date().addingTimeInterval(-120),
            isAgentMessage: true
        )
    }
    .padding()
    .frame(width: 400)
}

#Preview("Typing Indicator") {
    TypingIndicator()
        .padding()
}
