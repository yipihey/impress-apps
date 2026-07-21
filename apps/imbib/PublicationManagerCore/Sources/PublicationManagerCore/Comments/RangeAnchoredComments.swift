//
//  RangeAnchoredComments.swift
//  PublicationManagerCore
//
//  Pure-logic helper for range-anchored comments (GUI-meld Phase 4 groundwork).
//
//  A range-anchored comment stores UTF-8 *byte* offsets into an item's body
//  text, the snippet those offsets covered, and the body_content_hash the
//  range was valid against. When the body changes, the anchor is resolved
//  against the new body by the shared Rust core (`reanchor` in
//  crates/imbib-core/src/comments/anchor.rs) so macOS, iOS, and headless
//  tests all share one implementation. This file only adapts that call into
//  Swift-friendly types — no UI, no persistence.
//

import Foundation
import ImbibRustCore

/// Namespace for range-anchored comment logic.
public enum RangeAnchoredComments {

    /// Swift-friendly outcome of resolving a stored anchor against a body.
    public enum Resolution: Equatable, Sendable {
        /// The stored hash matches the current body: the stored byte range is
        /// valid as-is. `byteRange` is a UTF-8 byte range into the body.
        case exact(byteRange: Range<Int>)
        /// The body changed but the anchor snippet was found. When it occurs
        /// more than once, the occurrence closest to the original start wins.
        /// Persist the new range via `ImbibStore.updateCommentAnchor`.
        case moved(byteRange: Range<Int>)
        /// The snippet no longer occurs (or the comment has no anchor). The
        /// comment survives as a document-level comment without a range.
        case orphaned

        /// The resolved byte range, if any.
        public var byteRange: Range<Int>? {
            switch self {
            case .exact(let range), .moved(let range): return range
            case .orphaned: return nil
            }
        }

        /// True when the resolved range differs from the stored one and
        /// should be written back with `updateCommentAnchor`.
        public var needsPersistence: Bool {
            if case .moved = self { return true }
            return false
        }
    }

    /// Resolve a stored anchor against `body`.
    ///
    /// - Parameters:
    ///   - body: The current body text.
    ///   - anchorStart: Stored UTF-8 byte offset where the range starts.
    ///   - anchorEnd: Stored UTF-8 byte offset where the range ends (exclusive).
    ///   - anchorText: The snippet the range covered when anchored.
    ///   - anchoredBodyHash: The body_content_hash the range was valid against.
    ///   - currentBodyHash: The current body's content hash.
    /// - Returns: `.orphaned` when any anchor field is missing; otherwise the
    ///   Rust core's resolution (never traps, even on inconsistent offsets).
    public static func resolve(
        body: String,
        anchorStart: Int64?,
        anchorEnd: Int64?,
        anchorText: String?,
        anchoredBodyHash: String?,
        currentBodyHash: String
    ) -> Resolution {
        guard
            let anchorStart, anchorStart >= 0,
            let anchorEnd, anchorEnd >= 0,
            let anchorText, !anchorText.isEmpty,
            let anchoredBodyHash
        else {
            return .orphaned
        }

        let result = reanchorComment(
            body: body,
            anchorStart: UInt64(anchorStart),
            anchorEnd: UInt64(anchorEnd),
            anchorText: anchorText,
            hashMatches: anchoredBodyHash == currentBodyHash
        )

        switch result {
        case .exact(let start, let end):
            return .exact(byteRange: Int(start)..<Int(end))
        case .moved(let start, let end):
            return .moved(byteRange: Int(start)..<Int(end))
        case .orphaned:
            return .orphaned
        }
    }

    /// Resolve a comment row's stored anchor against `body`.
    ///
    /// Convenience over ``resolve(body:anchorStart:anchorEnd:anchorText:anchoredBodyHash:currentBodyHash:)``
    /// for rows returned by `ImbibStore.listCommentsForItem`.
    public static func resolve(
        comment: CommentRow,
        body: String,
        currentBodyHash: String
    ) -> Resolution {
        resolve(
            body: body,
            anchorStart: comment.anchorStart,
            anchorEnd: comment.anchorEnd,
            anchorText: comment.anchorText,
            anchoredBodyHash: comment.anchoredBodyHash,
            currentBodyHash: currentBodyHash
        )
    }

    /// Convert a resolved UTF-8 byte range into a `String` index range.
    ///
    /// Returns `nil` when the byte range is out of bounds or does not fall on
    /// UTF-8 sequence boundaries (defensive — ranges produced by `resolve`
    /// against the same `body` are always valid).
    public static func stringRange(
        ofByteRange byteRange: Range<Int>,
        in body: String
    ) -> Range<String.Index>? {
        let utf8 = body.utf8
        guard
            byteRange.lowerBound >= 0,
            byteRange.upperBound <= utf8.count,
            let start = utf8.index(
                utf8.startIndex, offsetBy: byteRange.lowerBound, limitedBy: utf8.endIndex
            ),
            let end = utf8.index(
                utf8.startIndex, offsetBy: byteRange.upperBound, limitedBy: utf8.endIndex
            ),
            let lower = start.samePosition(in: body),
            let upper = end.samePosition(in: body)
        else {
            return nil
        }
        return lower..<upper
    }
}
