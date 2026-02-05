//
//  CommentSectionView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import SwiftUI
import CoreData

// MARK: - Comment Section

/// Threaded comment section for publications in shared libraries.
///
/// Shows a flat list with indentation for replies, a text input field,
/// and author attribution per comment.
public struct CommentSectionView: View {
    let publication: CDPublication

    @State private var newCommentText = ""
    @State private var replyingTo: CDComment?
    @State private var editingComment: CDComment?
    @State private var editText = ""
    @State private var showDeleteConfirmation = false
    @State private var commentToDelete: CDComment?

    @Environment(\.managedObjectContext) private var viewContext

    public init(publication: CDPublication) {
        self.publication = publication
    }

    private var allComments: [CDComment] {
        (publication.comments ?? []).sorted { $0.dateCreated < $1.dateCreated }
    }

    private var topLevelComments: [CDComment] {
        allComments.filter { $0.isTopLevel }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("Comments", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                if !allComments.isEmpty {
                    Text("\(allComments.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            if allComments.isEmpty {
                Text("No comments yet. Start a discussion about this paper.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Comment list
                ForEach(topLevelComments) { comment in
                    commentRow(comment, indent: 0)

                    // Replies
                    ForEach(comment.replies(from: allComments)) { reply in
                        commentRow(reply, indent: 1)
                    }
                }
            }

            // Input area
            commentInput
        }
        .confirmationDialog(
            "Delete Comment?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let comment = commentToDelete {
                    try? CommentService.shared.deleteComment(comment)
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
    private func commentRow(_ comment: CDComment, indent: Int) -> some View {
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

        try? CommentService.shared.addComment(
            text: text,
            to: publication,
            parentCommentID: replyingTo?.id
        )

        newCommentText = ""
        replyingTo = nil
    }

    private func submitEdit(_ comment: CDComment) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try? CommentService.shared.editComment(comment, newText: text)
        editingComment = nil
    }

    private func isOwnComment(_ comment: CDComment) -> Bool {
        #if os(macOS)
        let currentName = Host.current().localizedName ?? ""
        #else
        let currentName = UIDevice.current.name
        #endif
        return comment.authorDisplayName == currentName
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
