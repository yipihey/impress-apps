//
//  CommentsSidebarView.swift
//  imprint
//
//  Sidebar panel displaying document comments.
//  Supports filtering, navigation, and inline replies.
//

import SwiftUI

// MARK: - Comments Sidebar View

/// Sidebar panel showing all comments in the document.
///
/// Features:
/// - Filter by resolved/unresolved/mine
/// - Sort by position/date
/// - Click to navigate to comment location
/// - Inline reply support
/// - Resolve/unresolve actions
struct CommentsSidebarView: View {
    @ObservedObject var commentService: CommentService
    let onNavigateToRange: (TextRange) -> Void

    @State private var newCommentText = ""
    @State private var replyingTo: UUID?
    @State private var replyText = ""
    @State private var editingComment: UUID?
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Filter bar
            filterBar

            Divider()

            // Comments list
            if commentService.filteredThreads.isEmpty {
                emptyState
            } else {
                commentsList
            }
        }
        .frame(width: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.orange)
            Text("Comments")
                .font(.headline)

            Spacer()

            // Counts
            if commentService.unresolvedCount > 0 {
                Text("\(commentService.unresolvedCount) open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding()
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack {
            // Filter picker
            Picker("Filter", selection: $commentService.filter) {
                ForEach(CommentFilter.allCases) { filter in
                    Label(filter.displayName, systemImage: filter.iconName)
                        .tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Spacer()

            // Sort picker
            Menu {
                ForEach(CommentSort.allCases) { sort in
                    Button(sort.displayName) {
                        commentService.sortOrder = sort
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .help("Sort comments")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "bubble.left")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(emptyStateText)
                .font(.body)
                .foregroundStyle(.secondary)

            Text(emptyStateHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }

    private var emptyStateText: String {
        switch commentService.filter {
        case .all: return "No comments yet"
        case .unresolved: return "No open comments"
        case .resolved: return "No resolved comments"
        case .mine: return "No comments from you"
        }
    }

    private var emptyStateHint: String {
        switch commentService.filter {
        case .all: return "Select text and press Cmd+Shift+C to add a comment"
        case .unresolved, .resolved, .mine: return "Try changing the filter"
        }
    }

    // MARK: - Comments List

    private var commentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(commentService.filteredThreads) { thread in
                        CommentThreadView(
                            thread: thread,
                            isSelected: commentService.selectedCommentId == thread.id,
                            replyingTo: $replyingTo,
                            replyText: $replyText,
                            editingComment: $editingComment,
                            editText: $editText,
                            onNavigate: {
                                onNavigateToRange(thread.textRange)
                            },
                            onResolve: {
                                commentService.resolve(thread.id)
                            },
                            onUnresolve: {
                                commentService.unresolve(thread.id)
                            },
                            onDelete: {
                                commentService.deleteComment(thread.id)
                            },
                            onSubmitReply: {
                                if !replyText.isEmpty {
                                    commentService.addReply(to: thread.id, content: replyText)
                                    replyText = ""
                                    replyingTo = nil
                                }
                            },
                            onSaveEdit: { id in
                                if !editText.isEmpty {
                                    commentService.updateComment(id, content: editText)
                                    editText = ""
                                    editingComment = nil
                                }
                            }
                        )
                        .id(thread.id)

                        Divider()
                    }
                }
            }
            .onChange(of: commentService.selectedCommentId) { _, newId in
                if let id = newId {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Comment Thread View

/// View for a single comment thread (root + replies).
struct CommentThreadView: View {
    let thread: CommentThread
    let isSelected: Bool
    @Binding var replyingTo: UUID?
    @Binding var replyText: String
    @Binding var editingComment: UUID?
    @Binding var editText: String
    let onNavigate: () -> Void
    let onResolve: () -> Void
    let onUnresolve: () -> Void
    let onDelete: () -> Void
    let onSubmitReply: () -> Void
    let onSaveEdit: (UUID) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Root comment
            CommentRowView(
                comment: thread.rootComment,
                isEditing: editingComment == thread.rootComment.id,
                editText: $editText,
                onStartEdit: {
                    editingComment = thread.rootComment.id
                    editText = thread.rootComment.content
                },
                onSaveEdit: { onSaveEdit(thread.rootComment.id) },
                onCancelEdit: {
                    editingComment = nil
                    editText = ""
                }
            )
            .padding()

            // Replies
            if !thread.replies.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(thread.replies) { reply in
                        CommentRowView(
                            comment: reply,
                            isEditing: editingComment == reply.id,
                            editText: $editText,
                            isReply: true,
                            onStartEdit: {
                                editingComment = reply.id
                                editText = reply.content
                            },
                            onSaveEdit: { onSaveEdit(reply.id) },
                            onCancelEdit: {
                                editingComment = nil
                                editText = ""
                            }
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.leading, 24)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }

            // Reply input
            if replyingTo == thread.id {
                replyInput
            }

            // Action bar
            actionBar
        }
        .background(backgroundColor)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onNavigate()
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.1)
        } else if isHovering {
            return Color(nsColor: .controlBackgroundColor).opacity(0.5)
        }
        return Color.clear
    }

    private var replyInput: some View {
        HStack {
            TextField("Write a reply...", text: $replyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit {
                    onSubmitReply()
                }

            Button {
                onSubmitReply()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.plain)
            .disabled(replyText.isEmpty)

            Button {
                replyingTo = nil
                replyText = ""
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                replyingTo = thread.id
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()

            if thread.rootComment.isResolved {
                Button {
                    onUnresolve()
                } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    onResolve()
                } label: {
                    Label("Resolve", systemImage: "checkmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Menu {
                Button("Edit", action: {
                    editingComment = thread.rootComment.id
                    editText = thread.rootComment.content
                })
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Comment Row View

/// View for a single comment within a thread.
struct CommentRowView: View {
    let comment: Comment
    let isEditing: Bool
    @Binding var editText: String
    var isReply: Bool = false
    let onStartEdit: () -> Void
    let onSaveEdit: () -> Void
    let onCancelEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Author line
            HStack {
                Circle()
                    .fill(comment.authorColor)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text(String(comment.author.prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                    )

                Text(comment.author)
                    .font(.caption)
                    .fontWeight(.medium)

                Spacer()

                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if comment.isResolved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            // Content
            if isEditing {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("Edit comment...", text: $editText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)

                    HStack {
                        Button("Cancel") {
                            onCancelEdit()
                        }
                        .buttonStyle(.borderless)

                        Button("Save") {
                            onSaveEdit()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            } else {
                Text(comment.content)
                    .font(.body)
                    .foregroundStyle(comment.isResolved ? .secondary : .primary)
                    .onTapGesture(count: 2) {
                        onStartEdit()
                    }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let service = CommentService()

    // Add some demo comments
    let _ = service.addComment(
        content: "This paragraph needs more detail about the methodology.",
        at: TextRange(start: 100, end: 150)
    )

    let comment2 = service.addComment(
        content: "Great introduction! Consider adding a hook.",
        at: TextRange(start: 0, end: 50)
    )
    service.resolve(comment2.id)

    return CommentsSidebarView(
        commentService: service,
        onNavigateToRange: { _ in }
    )
}
