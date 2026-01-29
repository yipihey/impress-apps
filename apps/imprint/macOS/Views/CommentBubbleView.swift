//
//  CommentBubbleView.swift
//  imprint
//
//  Inline comment indicator shown in the editor margin.
//  Click to show comment popover.
//

import SwiftUI

// MARK: - Comment Bubble View

/// A small bubble indicator shown in the editor margin for comments.
///
/// Features:
/// - Shows comment count at a location
/// - Color indicates resolved/unresolved state
/// - Click to expand popover
/// - Hover to preview
struct CommentBubbleView: View {
    let thread: CommentThread
    let onSelect: () -> Void
    let onResolve: () -> Void

    @State private var isHovering = false
    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            bubbleContent
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: $isShowingPopover, arrowEdge: .leading) {
            CommentPopoverView(
                thread: thread,
                onResolve: onResolve
            )
        }
        .help("\(thread.count) comment\(thread.count == 1 ? "" : "s")")
    }

    private var bubbleContent: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 4)
                .fill(bubbleColor)
                .frame(width: 20, height: 20)

            // Icon or count
            if thread.count > 1 {
                Text("\(thread.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: bubbleIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
            }
        }
        .scaleEffect(isHovering ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var bubbleColor: Color {
        if thread.isFullyResolved {
            return .green
        } else {
            return thread.rootComment.authorColor
        }
    }

    private var bubbleIcon: String {
        if thread.isFullyResolved {
            return "checkmark"
        } else {
            return "bubble.left.fill"
        }
    }
}

// MARK: - Comment Popover View

/// Popover showing comment thread details.
struct CommentPopoverView: View {
    let thread: CommentThread
    let onResolve: () -> Void

    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Comment")
                    .font(.headline)

                Spacer()

                if thread.isFullyResolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding()

            Divider()

            // Thread content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Root comment
                    CommentBubbleRow(comment: thread.rootComment)

                    // Replies
                    ForEach(thread.replies) { reply in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 2)

                            CommentBubbleRow(comment: reply)
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)

            Divider()

            // Actions
            HStack {
                if !thread.isFullyResolved {
                    Button("Resolve") {
                        onResolve()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Spacer()

                Button("View in Sidebar") {
                    NotificationCenter.default.post(
                        name: .navigateToComment,
                        object: thread.rootComment
                    )
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(width: 300)
    }
}

// MARK: - Comment Bubble Row

/// Single comment row in the bubble popover.
struct CommentBubbleRow: View {
    let comment: Comment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(comment.authorColor)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Text(String(comment.author.prefix(1)).uppercased())
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white)
                    )

                Text(comment.author)
                    .font(.caption)
                    .fontWeight(.medium)

                Spacer()

                Text(relativeTime(from: comment.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(comment.content)
                .font(.body)
                .foregroundStyle(comment.isResolved ? .secondary : .primary)
        }
    }

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
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

// MARK: - Comment Gutter View

/// View showing comment indicators in the editor gutter.
///
/// Place this alongside the text view to show comment bubbles
/// at the appropriate line positions.
struct CommentGutterView: View {
    var commentService: CommentService
    let lineHeight: CGFloat
    let topInset: CGFloat

    /// Maps line numbers to Y positions
    var linePositions: [Int: CGFloat] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Render comment bubbles at appropriate positions
            ForEach(commentService.threads) { thread in
                if let yPosition = yPosition(for: thread.textRange.start) {
                    CommentBubbleView(
                        thread: thread,
                        onSelect: {
                            commentService.navigateTo(thread.rootComment)
                        },
                        onResolve: {
                            commentService.resolve(thread.id)
                        }
                    )
                    .offset(x: 4, y: yPosition)
                }
            }
        }
        .frame(width: 28)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func yPosition(for characterPosition: Int) -> CGFloat? {
        // Simplified line calculation
        // In real implementation, this would use text layout info
        let lineNumber = characterPosition / 60 // Rough estimate
        return topInset + CGFloat(lineNumber) * lineHeight
    }
}

// MARK: - Text Highlight for Comments

/// Overlay view that highlights commented text regions.
struct CommentHighlightOverlay: View {
    var commentService: CommentService
    let textLayoutInfo: TextLayoutInfo

    var body: some View {
        ZStack {
            ForEach(commentService.threads) { thread in
                if let rect = textLayoutInfo.rect(
                    for: thread.textRange.start,
                    end: thread.textRange.end
                ) {
                    CommentHighlightRect(
                        rect: rect,
                        color: thread.rootComment.authorColor,
                        isResolved: thread.isFullyResolved,
                        isSelected: commentService.selectedCommentId == thread.id
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A single highlight rectangle for commented text.
struct CommentHighlightRect: View {
    let rect: CGRect
    let color: Color
    let isResolved: Bool
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(highlightColor)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            )
    }

    private var highlightColor: Color {
        if isResolved {
            return .green.opacity(0.1)
        } else {
            return color.opacity(0.15)
        }
    }

    private var borderColor: Color {
        if isSelected {
            return color
        } else if isResolved {
            return .green.opacity(0.3)
        } else {
            return color.opacity(0.3)
        }
    }
}

// MARK: - Preview

#Preview {
    let service = CommentService()

    let comment = service.addComment(
        content: "This needs revision.",
        at: TextRange(start: 0, end: 50)
    )
    let _ = service.addReply(to: comment.id, content: "I agree, let me fix it.")

    let thread = service.threads.first!

    return VStack {
        CommentBubbleView(
            thread: thread,
            onSelect: {},
            onResolve: {}
        )

        Divider()

        CommentPopoverView(
            thread: thread,
            onResolve: {}
        )
    }
    .padding()
}
