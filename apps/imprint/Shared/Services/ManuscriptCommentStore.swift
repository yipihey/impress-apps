//
//  ManuscriptCommentStore.swift
//  imprint
//
//  GUI-meld Phase 4: bridge between imprint's `CommentService` and imbib-core's
//  range-anchored comment store (`RustStoreAdapter`, schema `imbib/comment`).
//
//  Manuscript *bodies* live in the impress-core `SharedStore`
//  (`ManuscriptStoreAdapter`); manuscript *comments* live as `imbib/comment`
//  items in the imbib-core store, keyed by the manuscript's UUID as their
//  `parent_item_id`. The two stores share nothing but that UUID — a comment's
//  parent item need not exist in the imbib store.
//
//  This file is the ONLY place in the imprint target that imports
//  `PublicationManagerCore`/`ImbibRustCore` for comments. Confining it here is
//  deliberate: PMC exports a `Comment` type that would otherwise collide with
//  imprint's own `Comment` model everywhere the two are used together. The
//  bridge speaks only imprint-native primitives (`UUID`, `String`, byte ranges)
//  so `CommentService` never has to name a PMC type.
//

import Foundation
import PublicationManagerCore

enum ManuscriptCommentStore {

    // MARK: - Projected row

    /// A store comment row projected into imprint-native primitives. Anchor
    /// fields are non-nil only for range-anchored (root) comments.
    struct StoredComment: Equatable {
        var id: UUID
        var text: String
        var authorIdentifier: String?
        var authorDisplayName: String?
        var createdAt: Date
        var modifiedAt: Date
        var parentID: UUID?
        var anchorStart: Int64?
        var anchorEnd: Int64?
        var anchorText: String?
        var anchoredBodyHash: String?
    }

    /// Outcome of resolving a stored anchor against the current body. Mirrors
    /// `RangeAnchoredComments.Resolution` in imprint-local terms.
    enum Resolution: Equatable {
        case exact(byteRange: Range<Int>)
        case moved(byteRange: Range<Int>)
        case orphaned
    }

    // MARK: - Store I/O (all @MainActor — RustStoreAdapter is @MainActor)

    /// All comments (roots + replies) attached to a manuscript.
    @MainActor
    static func list(manuscriptID: UUID) -> [StoredComment] {
        RustStoreAdapter.shared
            .listCommentsForItem(itemId: manuscriptID)
            .map(project)
    }

    /// Create a range-anchored root comment. `byteRange` is a UTF-8 byte range
    /// into the manuscript body; `anchorText` is the covered snippet.
    @MainActor
    static func createAnchored(
        manuscriptID: UUID,
        text: String,
        authorIdentifier: String?,
        authorDisplayName: String?,
        byteRange: Range<Int>,
        anchorText: String,
        bodyHash: String
    ) -> StoredComment? {
        RustStoreAdapter.shared.createAnchoredComment(
            itemId: manuscriptID,
            text: text,
            authorIdentifier: authorIdentifier,
            authorDisplayName: authorDisplayName,
            anchorStart: byteRange.lowerBound,
            anchorEnd: byteRange.upperBound,
            anchorText: anchorText,
            anchoredBodyHash: bodyHash
        ).map(project)
    }

    /// Create a plain (un-anchored) comment — a reply, or a document-level note
    /// with no live range.
    @MainActor
    static func createPlain(
        manuscriptID: UUID,
        text: String,
        authorIdentifier: String?,
        authorDisplayName: String?,
        parentID: UUID?
    ) -> StoredComment? {
        RustStoreAdapter.shared.createCommentOnItem(
            itemId: manuscriptID,
            text: text,
            authorIdentifier: authorIdentifier,
            authorDisplayName: authorDisplayName,
            parentCommentId: parentID
        ).map(project)
    }

    /// Replace a comment's stored text (used for edits and the resolved/
    /// suggestion metadata envelope — see `CommentService`).
    @MainActor
    static func updateText(id: UUID, text: String) {
        RustStoreAdapter.shared.updateComment(id: id, text: text)
    }

    /// Persist a re-anchored range after a Moved resolution.
    @MainActor
    static func updateAnchor(id: UUID, byteRange: Range<Int>, bodyHash: String) {
        RustStoreAdapter.shared.updateCommentAnchor(
            commentId: id,
            anchorStart: byteRange.lowerBound,
            anchorEnd: byteRange.upperBound,
            anchoredBodyHash: bodyHash
        )
    }

    /// Delete a comment (and, by the store's item semantics, its replies are
    /// handled by the caller which deletes them explicitly).
    @MainActor
    static func delete(id: UUID) {
        RustStoreAdapter.shared.deleteComment(id)
    }

    // MARK: - Re-anchoring (pure)

    /// Resolve a stored anchor against `body`. Delegates to the shared Rust
    /// core via `RangeAnchoredComments` so macOS, iOS, and headless tests agree.
    static func resolve(
        anchorStart: Int64?,
        anchorEnd: Int64?,
        anchorText: String?,
        anchoredBodyHash: String?,
        body: String,
        currentBodyHash: String
    ) -> Resolution {
        switch RangeAnchoredComments.resolve(
            body: body,
            anchorStart: anchorStart,
            anchorEnd: anchorEnd,
            anchorText: anchorText,
            anchoredBodyHash: anchoredBodyHash,
            currentBodyHash: currentBodyHash
        ) {
        case .exact(let range): return .exact(byteRange: range)
        case .moved(let range): return .moved(byteRange: range)
        case .orphaned: return .orphaned
        }
    }

    // MARK: - Offset conversion

    /// Convert a UTF-16 `NSRange` (the editor / `TextRange` space) into a UTF-8
    /// byte range plus the covered snippet. Returns nil for an out-of-bounds or
    /// non-boundary range.
    static func byteRange(
        forNSRange nsRange: NSRange,
        in body: String
    ) -> (range: Range<Int>, snippet: String)? {
        guard let r = Range(nsRange, in: body) else { return nil }
        let startByte = body[body.startIndex..<r.lowerBound].utf8.count
        let endByte = body[body.startIndex..<r.upperBound].utf8.count
        return (startByte..<endByte, String(body[r]))
    }

    /// Convert a UTF-8 byte range back into a UTF-16 `NSRange` for the editor.
    static func nsRange(forByteRange byteRange: Range<Int>, in body: String) -> NSRange? {
        guard let strRange = RangeAnchoredComments.stringRange(
            ofByteRange: byteRange, in: body
        ) else { return nil }
        return NSRange(strRange, in: body)
    }

    // MARK: - Mapping

    private static func project(_ c: PublicationManagerCore.Comment) -> StoredComment {
        StoredComment(
            id: c.id,
            text: c.text,
            authorIdentifier: c.authorIdentifier,
            authorDisplayName: c.authorDisplayName,
            createdAt: c.dateCreated,
            modifiedAt: c.dateModified,
            parentID: c.parentCommentID,
            anchorStart: c.anchorStart,
            anchorEnd: c.anchorEnd,
            anchorText: c.anchorText,
            anchoredBodyHash: c.anchoredBodyHash
        )
    }
}
