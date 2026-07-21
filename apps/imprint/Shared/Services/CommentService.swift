//
//  CommentService.swift
//  imprint
//
//  Service for managing document comments.
//
//  GUI-meld Phase 4: comments are now **store-backed**. Each comment is an
//  `imbib/comment` item in the imbib-core store (via `ManuscriptCommentStore`),
//  keyed by the manuscript's UUID as its `parent_item_id`. Root comments carry
//  their text range as a UTF-8 byte anchor (`anchor_start`/`anchor_end`/
//  `anchor_text`) stamped with the manuscript's `body_content_hash`; on every
//  body change the anchors are re-resolved against the new body (Exact / Moved /
//  Orphaned) by the shared Rust core. `comments` stays an in-memory mirror so
//  the views and HTTP router keep their existing synchronous read model.
//
//  imprint-specific fields the `imbib/comment` schema has no column for —
//  `isResolved` and `proposedText` — ride in a compact, invisible metadata
//  trailer appended to the stored text (see `encodeText`/`decodeText`). This
//  keeps the change Swift-only (no schema field, no FFI regeneration). The agent
//  author id round-trips through the store's `author_identifier` (`agent:<id>`).
//

import Foundation
import SwiftUI
import Combine
import ImpressLogging
import OSLog

// MARK: - Comment Service

/// Service for managing comments attached to a document.
///
/// Features:
/// - CRUD operations for comments, persisted to the store
/// - Threaded comment organization
/// - Filter by resolved/unresolved/author
/// - Range re-anchoring when the document body is edited
@MainActor @Observable
public final class CommentService {

    // MARK: - Published State

    /// All comments in the document (in-memory mirror of the store).
    public private(set) var comments: [Comment] = []

    /// Current filter for display
    public var filter: CommentFilter = .all

    /// Current sort order
    public var sortOrder: CommentSort = .position

    /// Currently selected comment (for navigation)
    public var selectedCommentId: UUID?

    // MARK: - Store binding

    /// The manuscript this service persists comments for. `nil` until
    /// `attach(manuscriptID:body:)` is called (e.g. a `#Preview` instance).
    private var manuscriptID: UUID?

    /// Latest known manuscript body — the offset space anchors resolve against.
    /// Kept in sync via `attach` and `syncBody`.
    private var currentBody: String = ""

    /// Debounced task that persists Moved anchors after the body settles.
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    // MARK: - Private State

    /// Current user's author ID
    private let localAuthorId: String

    /// Current user's display name
    @ObservationIgnored @AppStorage("collaboration.displayName") private var localDisplayName: String = NSFullUserName()

    // MARK: - Computed Properties

    /// Comments organized into threads
    public var threads: [CommentThread] {
        let rootComments = comments.filter { $0.parentId == nil }
        return rootComments.map { root in
            let replies = comments.filter { $0.parentId == root.id }
                .sorted { $0.createdAt < $1.createdAt }
            return CommentThread(rootComment: root, replies: replies)
        }
    }

    /// Filtered and sorted threads
    public var filteredThreads: [CommentThread] {
        var result = threads

        // Apply filter
        switch filter {
        case .all:
            break
        case .unresolved:
            result = result.filter { !$0.rootComment.isResolved }
        case .resolved:
            result = result.filter { $0.rootComment.isResolved }
        case .mine:
            result = result.filter { $0.rootComment.authorId == localAuthorId }
        }

        // Apply sort. Orphaned comments (no live range) sort last under
        // .position so they don't jump to the top of the document.
        switch sortOrder {
        case .position:
            result.sort { a, b in
                let ap = a.rootComment.isOrphaned ? Int.max : a.textRange.start
                let bp = b.rootComment.isOrphaned ? Int.max : b.textRange.start
                return ap < bp
            }
        case .newest:
            result.sort { $0.lastActivity > $1.lastActivity }
        case .oldest:
            result.sort { $0.lastActivity < $1.lastActivity }
        }

        return result
    }

    /// Count of unresolved comments
    public var unresolvedCount: Int {
        comments.filter { !$0.isResolved && $0.parentId == nil }.count
    }

    /// Count of resolved comments
    public var resolvedCount: Int {
        comments.filter { $0.isResolved && $0.parentId == nil }.count
    }

    // MARK: - Initialization

    public init(authorId: String? = nil) {
        self.localAuthorId = authorId ?? UUID().uuidString
    }

    // MARK: - Store attachment

    /// Bind this service to a manuscript and load its comments from the store.
    /// Called once the manuscript UUID is known (see `ContentView`'s `.task`,
    /// where `document.id` == the manuscript's store id under the store-first
    /// editor).
    public func attach(manuscriptID: UUID, body: String) {
        self.manuscriptID = manuscriptID
        self.currentBody = body
        reload(persistMoved: true)
        Logger.comments.infoCapture(
            "Attached CommentService to manuscript \(manuscriptID) — loaded \(self.comments.count) comments",
            category: "comments"
        )
    }

    /// Re-resolve all comment ranges against a new manuscript body. Replaces
    /// the old raw `adjustRanges` shifting: the anchor snippet + hash let the
    /// shared core recover Exact / Moved / Orphaned positions. In-memory ranges
    /// update immediately; Moved anchors are persisted on a short debounce so a
    /// burst of keystrokes does not hammer the store.
    public func syncBody(_ body: String) {
        guard manuscriptID != nil else { return }
        currentBody = body
        reload(persistMoved: false)

        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.persistMovedAnchors() }
        }
    }

    // MARK: - CRUD Operations

    /// Add a new comment at the given text range.
    @discardableResult
    public func addComment(
        content: String,
        at range: TextRange,
        parentId: UUID? = nil,
        proposedText: String? = nil,
        authorAgentId: String? = nil,
        authorName: String? = nil
    ) -> Comment {
        let displayedAuthor: String
        let authorIdentifier: String
        if let agentId = authorAgentId, !agentId.isEmpty {
            displayedAuthor = authorName ?? "agent:\(agentId)"
            authorIdentifier = "agent:\(agentId)"
        } else {
            displayedAuthor = authorName ?? localDisplayName
            authorIdentifier = localAuthorId
        }

        let storedText = Self.encodeText(content: content, isResolved: false, proposedText: proposedText)

        var stored: ManuscriptCommentStore.StoredComment?
        var resolvedRange = range
        var orphaned = false

        if let manuscriptID {
            if let parentId {
                // Reply — inherits the parent's range, no anchor of its own.
                stored = ManuscriptCommentStore.createPlain(
                    manuscriptID: manuscriptID,
                    text: storedText,
                    authorIdentifier: authorIdentifier,
                    authorDisplayName: displayedAuthor,
                    parentID: parentId
                )
                if let parent = comments.first(where: { $0.id == parentId }) {
                    resolvedRange = parent.textRange
                    orphaned = parent.isOrphaned
                }
            } else if let anchor = ManuscriptCommentStore.byteRange(forNSRange: range.nsRange, in: currentBody),
                      !anchor.snippet.isEmpty {
                // Root comment on a live selection → range-anchored.
                stored = ManuscriptCommentStore.createAnchored(
                    manuscriptID: manuscriptID,
                    text: storedText,
                    authorIdentifier: authorIdentifier,
                    authorDisplayName: displayedAuthor,
                    byteRange: anchor.range,
                    anchorText: anchor.snippet,
                    bodyHash: ManuscriptStoreAdapter.bodyContentHash(currentBody)
                )
            } else {
                // Empty/degenerate selection → document-level note.
                stored = ManuscriptCommentStore.createPlain(
                    manuscriptID: manuscriptID,
                    text: storedText,
                    authorIdentifier: authorIdentifier,
                    authorDisplayName: displayedAuthor,
                    parentID: nil
                )
            }
        }

        // Use the store-assigned id so later lookups (HTTP router, resolve,
        // delete) address the same persisted row. Fall back to a local id if
        // the service is not attached or the write failed.
        let comment = Comment(
            id: stored?.id ?? UUID(),
            author: displayedAuthor,
            authorId: authorIdentifier,
            content: content,
            textRange: resolvedRange,
            createdAt: stored?.createdAt ?? Date(),
            modifiedAt: stored?.modifiedAt ?? Date(),
            isResolved: false,
            parentId: parentId,
            proposedText: proposedText,
            authorAgentId: authorAgentId,
            isOrphaned: orphaned
        )

        comments.append(comment)
        if stored == nil {
            Logger.comments.warningCapture(
                "addComment persisted nowhere (attached=\(self.manuscriptID != nil)) — kept in-memory only",
                category: "comments"
            )
        }
        Logger.comments.infoCapture(
            "Added comment \(comment.id) at \(range.start)-\(range.end) suggestion=\(proposedText != nil) agent=\(authorAgentId ?? "-")",
            category: "comments"
        )
        return comment
    }

    /// Update an existing comment's content.
    public func updateComment(_ id: UUID, content: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            Logger.comments.warningCapture("Comment \(id) not found for update", category: "comments")
            return
        }
        comments[index].content = content
        comments[index].modifiedAt = Date()
        persistText(comments[index])
        Logger.comments.infoCapture("Updated comment \(id)", category: "comments")
    }

    /// Delete a comment and its replies.
    public func deleteComment(_ id: UUID) {
        // Delete replies first
        let replyIds = comments.filter { $0.parentId == id }.map { $0.id }
        for replyId in replyIds {
            deleteComment(replyId)
        }

        if manuscriptID != nil {
            ManuscriptCommentStore.delete(id: id)
        }
        comments.removeAll { $0.id == id }
        Logger.comments.infoCapture("Deleted comment \(id)", category: "comments")

        if selectedCommentId == id {
            selectedCommentId = nil
        }
    }

    /// Toggle the resolved state of a comment.
    public func toggleResolved(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            return
        }
        comments[index].isResolved.toggle()
        comments[index].modifiedAt = Date()
        persistText(comments[index])
        Logger.comments.infoCapture("Toggled resolved state for \(id): \(self.comments[index].isResolved)", category: "comments")
    }

    /// Resolve a comment and optionally all its replies.
    public func resolve(_ id: UUID, includeReplies: Bool = true) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            return
        }
        comments[index].isResolved = true
        comments[index].modifiedAt = Date()
        persistText(comments[index])

        if includeReplies {
            for i in comments.indices where comments[i].parentId == id {
                comments[i].isResolved = true
                comments[i].modifiedAt = Date()
                persistText(comments[i])
            }
        }
        Logger.comments.infoCapture("Resolved comment \(id)", category: "comments")
    }

    /// Unresolve a comment (reopen it).
    public func unresolve(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            return
        }
        comments[index].isResolved = false
        comments[index].modifiedAt = Date()
        persistText(comments[index])
        Logger.comments.infoCapture("Unresolved comment \(id)", category: "comments")
    }

    /// Add a reply to an existing comment.
    @discardableResult
    public func addReply(to parentId: UUID, content: String) -> Comment? {
        guard let parent = comments.first(where: { $0.id == parentId }) else {
            Logger.comments.warningCapture("Parent comment \(parentId) not found", category: "comments")
            return nil
        }
        // Route through addComment so persistence + id assignment are unified.
        let reply = addComment(content: content, at: parent.textRange, parentId: parentId)
        Logger.comments.infoCapture("Added reply \(reply.id) to \(parentId)", category: "comments")
        return reply
    }

    // MARK: - Navigation

    /// Navigate to a comment (select and scroll to it).
    public func navigateTo(_ comment: Comment) {
        selectedCommentId = comment.id
        NotificationCenter.default.post(
            name: .navigateToComment,
            object: comment
        )
    }

    /// Get the comment at a given text position.
    public func comment(at position: Int) -> Comment? {
        comments.first { comment in
            !comment.isOrphaned
                && comment.textRange.start <= position
                && position <= comment.textRange.end
        }
    }

    /// Get all comments overlapping a given range.
    public func commentsOverlapping(_ range: TextRange) -> [Comment] {
        comments.filter { comment in
            !comment.isOrphaned
                && comment.textRange.start < range.end
                && range.start < comment.textRange.end
        }
    }

    /// Update the `proposedText` on a suggestion comment. A `nil` value
    /// clears the suggestion (turning it back into a plain comment).
    public func updateProposedText(_ id: UUID, proposedText: String?) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[index].proposedText = proposedText
        comments[index].modifiedAt = Date()
        persistText(comments[index])
    }

    // MARK: - Document Sync

    /// Adjust all comment ranges after a text edit.
    ///
    /// Legacy in-memory shift, retained for source compatibility. The
    /// store-backed path is `syncBody(_:)`, which re-resolves anchors against
    /// the whole new body; prefer it.
    public func adjustRanges(forEditAt position: Int, lengthDelta: Int) {
        for i in comments.indices {
            comments[i].textRange.adjustForEdit(at: position, lengthDelta: lengthDelta)
        }
    }

    /// Clear the in-memory mirror (does not delete stored comments).
    public func clear() {
        comments.removeAll()
        selectedCommentId = nil
        Logger.comments.infoCapture("Cleared comment mirror", category: "comments")
    }

    // MARK: - Import/Export

    /// Export comments to a human-readable format.
    public func exportToText() -> String {
        var lines: [String] = []
        lines.append("# Comments Export")
        lines.append("Generated: \(Date().formatted())")
        lines.append("")

        for thread in filteredThreads {
            lines.append("---")
            let where_ = thread.rootComment.isOrphaned ? "orphaned" : "position \(thread.textRange.start)"
            lines.append("[\(thread.rootComment.isResolved ? "RESOLVED" : "OPEN")] @ \(where_)")
            lines.append("\(thread.rootComment.author) (\(thread.rootComment.createdAt.formatted())):")
            lines.append(thread.rootComment.content)

            for reply in thread.replies {
                lines.append("")
                lines.append("  ↳ \(reply.author) (\(reply.createdAt.formatted())):")
                lines.append("    \(reply.content)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Loading & re-anchoring

    /// Re-load `comments` from the store, resolving each root comment's anchor
    /// against `currentBody`. Replies inherit their parent's resolved range.
    private func reload(persistMoved: Bool) {
        guard let manuscriptID else { return }
        let rows = ManuscriptCommentStore.list(manuscriptID: manuscriptID)
        let body = currentBody
        let currentHash = ManuscriptStoreAdapter.bodyContentHash(body)

        var built: [Comment] = []
        var rangeByID: [UUID: (range: TextRange, orphaned: Bool)] = [:]
        pendingMoved.removeAll()

        // Roots first (they own the anchors).
        for s in rows where s.parentID == nil {
            let resolution = ManuscriptCommentStore.resolve(
                anchorStart: s.anchorStart,
                anchorEnd: s.anchorEnd,
                anchorText: s.anchorText,
                anchoredBodyHash: s.anchoredBodyHash,
                body: body,
                currentBodyHash: currentHash
            )
            var range = TextRange(start: 0, end: 0)
            var orphaned = false
            switch resolution {
            case .exact(let byteRange), .moved(let byteRange):
                if let ns = ManuscriptCommentStore.nsRange(forByteRange: byteRange, in: body) {
                    range = TextRange(nsRange: ns)
                    if case .moved = resolution { pendingMoved.append((s.id, byteRange)) }
                } else {
                    orphaned = true
                }
            case .orphaned:
                // Only a comment that *had* an anchor snippet but can no longer
                // be located is "orphaned" (its text was edited away). A row
                // with no anchor is a document-level note by design.
                orphaned = (s.anchorText != nil)
            }
            rangeByID[s.id] = (range, orphaned)
            built.append(makeComment(from: s, textRange: range, isOrphaned: orphaned))
        }

        // Replies inherit the parent's resolved range.
        for s in rows where s.parentID != nil {
            let parent = s.parentID.flatMap { rangeByID[$0] }
            built.append(makeComment(
                from: s,
                textRange: parent?.range ?? TextRange(start: 0, end: 0),
                isOrphaned: parent?.orphaned ?? false
            ))
        }

        comments = built
        if persistMoved { persistMovedAnchors() }
    }

    /// Moved anchors discovered by the most recent `reload`, awaiting persist.
    @ObservationIgnored private var pendingMoved: [(id: UUID, byteRange: Range<Int>)] = []

    /// Write back any Moved anchors so their stored offsets + hash match the
    /// current body (making the next resolve an Exact hit).
    private func persistMovedAnchors() {
        guard manuscriptID != nil, !pendingMoved.isEmpty else { return }
        let hash = ManuscriptStoreAdapter.bodyContentHash(currentBody)
        let moved = pendingMoved
        pendingMoved.removeAll()
        for m in moved {
            ManuscriptCommentStore.updateAnchor(id: m.id, byteRange: m.byteRange, bodyHash: hash)
        }
        Logger.comments.infoCapture("Persisted \(moved.count) re-anchored comment range(s)", category: "comments")
    }

    /// Persist a comment's text (content + resolved/suggestion metadata) to the
    /// store. No-op when unattached.
    private func persistText(_ comment: Comment) {
        guard manuscriptID != nil else { return }
        let text = Self.encodeText(
            content: comment.content,
            isResolved: comment.isResolved,
            proposedText: comment.proposedText
        )
        ManuscriptCommentStore.updateText(id: comment.id, text: text)
    }

    /// Build an imprint `Comment` from a stored row + a resolved range.
    private func makeComment(
        from s: ManuscriptCommentStore.StoredComment,
        textRange: TextRange,
        isOrphaned: Bool
    ) -> Comment {
        let decoded = Self.decodeText(s.text)
        let agentId: String? = s.authorIdentifier.flatMap {
            $0.hasPrefix("agent:") ? String($0.dropFirst("agent:".count)) : nil
        }
        return Comment(
            id: s.id,
            author: s.authorDisplayName ?? "Unknown",
            authorId: s.authorIdentifier ?? "",
            content: decoded.content,
            textRange: textRange,
            createdAt: s.createdAt,
            modifiedAt: s.modifiedAt,
            isResolved: decoded.isResolved,
            parentId: s.parentID,
            proposedText: decoded.proposedText,
            authorAgentId: agentId,
            isOrphaned: isOrphaned
        )
    }

    // MARK: - Metadata envelope

    /// Invisible sentinel separating a comment's user content from its imprint
    /// metadata trailer. Uses two U+2063 INVISIBLE SEPARATORs — practically
    /// never present in manuscript comment prose.
    private static let metaSentinel = "\u{2063}\u{2063}imprint-meta:"

    private struct Meta: Codable {
        var r: Bool          // isResolved
        var p: String?       // proposedText
    }

    /// Encode content + metadata into the stored text. Plain, unresolved
    /// comments store their content verbatim (no trailer).
    static func encodeText(content: String, isResolved: Bool, proposedText: String?) -> String {
        guard isResolved || proposedText != nil else { return content }
        let meta = Meta(r: isResolved, p: proposedText)
        guard let data = try? JSONEncoder().encode(meta) else { return content }
        return content + metaSentinel + data.base64EncodedString()
    }

    /// Decode stored text back into content + metadata.
    static func decodeText(_ stored: String) -> (content: String, isResolved: Bool, proposedText: String?) {
        guard let sep = stored.range(of: metaSentinel) else {
            return (stored, false, nil)
        }
        let content = String(stored[..<sep.lowerBound])
        let b64 = String(stored[sep.upperBound...])
        guard let data = Data(base64Encoded: b64),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            return (content, false, nil)
        }
        return (content, meta.r, meta.p)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when user should navigate to a comment
    static let navigateToComment = Notification.Name("navigateToComment")
    // Note: addCommentAtSelection and toggleCommentsSidebar are defined in ImprintApp.swift
}
