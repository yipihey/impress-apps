//
//  CommentSectionView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import SwiftUI

// MARK: - Comment Section

/// Threaded comment section for any item (publications, artifacts, etc.).
///
/// Shows a flat list with indentation for replies, a text input field,
/// and author attribution per comment.
public struct CommentSectionView: View {
    let itemID: UUID
    let itemTitle: String?
    let libraryID: UUID?

    @State private var comments: [Comment] = []
    @State private var newCommentText = ""
    @State private var replyingTo: Comment?
    @State private var editingComment: Comment?
    @State private var editText = ""
    @State private var showDeleteConfirmation = false
    @State private var commentToDelete: Comment?
    @State private var participants: [ShareParticipant] = []
    @State private var showShareManagement = false

    /// Initialize with any item ID.
    public init(itemID: UUID, itemTitle: String? = nil, libraryID: UUID? = nil) {
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.libraryID = libraryID
    }

    /// Backward-compatible initializer for publication-specific usage.
    public init(publicationID: UUID) {
        self.itemID = publicationID
        self.itemTitle = nil
        self.libraryID = nil
    }

    private var topLevelComments: [Comment] {
        comments.filter { $0.parentCommentID == nil }
    }

    private func replies(for comment: Comment) -> [Comment] {
        comments.filter { $0.parentCommentID == comment.id }.sorted { $0.dateCreated < $1.dateCreated }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("Comments", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                if !comments.isEmpty {
                    Text("\(comments.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            // Participants bar
            participantsBar

            if comments.isEmpty {
                Text("No comments yet. Start a discussion.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Comment list
                ForEach(topLevelComments) { comment in
                    commentRow(comment, indent: 0)

                    // Replies
                    ForEach(replies(for: comment)) { reply in
                        commentRow(reply, indent: 1)
                    }
                }
            }

            // Input area
            commentInput
        }
        .onAppear {
            comments = RustStoreAdapter.shared.commentsForItem(itemID)
        }
        .task {
            if let libraryID {
                do {
                    participants = try await LibrarySharingService.shared.participants(for: libraryID)
                } catch {
                    // Not shared or CloudKit unavailable — that's fine
                    participants = []
                }
            }
        }
        .sheet(isPresented: $showShareManagement) {
            if let libraryID {
                ShareManagementView(libraryID: libraryID)
            }
        }
        .confirmationDialog(
            "Delete Comment?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let comment = commentToDelete {
                    RustStoreAdapter.shared.deleteComment(comment.id)
                    comments = RustStoreAdapter.shared.commentsForItem(itemID)
                    commentToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                commentToDelete = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Comment Row

    @ViewBuilder
    private func commentRow(_ comment: Comment, indent: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Author color dot
            if let author = comment.authorDisplayName {
                Circle()
                    .fill(Color(AnnotationPersistence.shared.authorColor(for: author).platformColor))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                // Author + date
                HStack(spacing: 6) {
                    Text(comment.authorDisplayName ?? "Unknown")
                        .font(.caption.bold())
                    Text(comment.dateCreated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if comment.dateModified > comment.dateCreated.addingTimeInterval(1) {
                        Text("(edited)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Comment text
                if editingComment?.id == comment.id {
                    HStack {
                        TextField("Edit comment", text: $editText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submitEdit(comment) }
                        Button("Save") { submitEdit(comment) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Cancel") { editingComment = nil }
                            .controlSize(.small)
                    }
                } else {
                    Text(comment.text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                // Actions
                if editingComment?.id != comment.id {
                    HStack(spacing: 12) {
                        Button("Reply") {
                            replyingTo = comment
                        }
                        .font(.caption)

                        // Only show edit/delete for own comments
                        if isOwnComment(comment) {
                            Button("Edit") {
                                editingComment = comment
                                editText = comment.text
                            }
                            .font(.caption)

                            Button("Delete") {
                                commentToDelete = comment
                                showDeleteConfirmation = true
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .padding(.leading, CGFloat(indent) * 24)
        .padding(.vertical, 4)
    }

    // MARK: - Comment Input

    private var commentInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let replying = replyingTo {
                HStack {
                    Text("Replying to \(replying.authorDisplayName ?? "comment")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField(
                    replyingTo != nil ? "Write a reply..." : "Add a comment...",
                    text: $newCommentText
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { postComment() }

                Button {
                    postComment()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Actions

    private func postComment() {
        let text = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        RustStoreAdapter.shared.addCommentToItem(
            text: text,
            itemID: itemID,
            parentCommentID: replyingTo?.id
        )

        comments = RustStoreAdapter.shared.commentsForItem(itemID)
        newCommentText = ""
        replyingTo = nil
    }

    private func submitEdit(_ comment: Comment) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        RustStoreAdapter.shared.editComment(comment.id, newText: text)
        comments = RustStoreAdapter.shared.commentsForItem(itemID)
        editingComment = nil
    }

    private func isOwnComment(_ comment: Comment) -> Bool {
        CommentService.shared.isOwnComment(comment)
    }

    // MARK: - Participants Bar

    @ViewBuilder
    private var participantsBar: some View {
        if !participants.isEmpty {
            HStack(spacing: 6) {
                // Participant initials
                ForEach(participants.prefix(5)) { participant in
                    Text(participant.initials)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(participant.isCurrentUser ? .blue : .gray)
                        .clipShape(Circle())
                        .help(participant.displayLabel)
                }

                if participants.count > 5 {
                    Text("+\(participants.count - 5)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("Shared")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Manage") {
                    showShareManagement = true
                }
                .font(.caption)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        } else if libraryID != nil {
            HStack(spacing: 4) {
                Image(systemName: "lock")
                    .font(.caption2)
                Text("Private — only visible on your devices")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Comment Badge

/// Small badge showing comment count for sidebar/list display
public struct CommentBadge: View {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                Text("\(count)")
                    .font(.caption2.bold())
            }
            .foregroundStyle(.blue)
        }
    }
}
