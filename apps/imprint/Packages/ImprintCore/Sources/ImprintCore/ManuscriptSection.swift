//
//  ManuscriptSection.swift
//  ImprintCore
//
//  Swift-side value type for the `manuscript-section@1.0.0` schema.
//  Returned by `ImprintImpressStore`'s read methods.
//
//  The on-disk schema (crates/impress-core/src/schemas/manuscript_section.rs)
//  has these fields in `payload_json`:
//
//  | field        | type   | notes                                         |
//  |--------------|--------|-----------------------------------------------|
//  | title        | String | required — section heading                    |
//  | body         | String | Typst source; empty when content_hash is set  |
//  | section_type | String | e.g. "introduction", "methods"                |
//  | order_index  | Int    | zero-based position in the document           |
//  | word_count   | Int    | approximate                                   |
//  | document_id  | String | UUID string of the parent ImprintDocument     |
//  | content_hash | String | SHA-256 hex for bodies > 64 KiB               |
//
//  Sections whose body lives on disk at
//  `~/.local/share/impress/content/{content_hash}` have an empty inline
//  `body` in the payload. Callers of `ImprintImpressStore.loadSection`
//  get bodies already rehydrated — the gateway reads from disk on the
//  caller's behalf so no client has to know about the split.
//

import Foundation
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

/// A manuscript section stored in the shared impress-core database.
public struct ManuscriptSection: Sendable, Equatable, Identifiable {

    /// The item's UUID (also the SwiftUI identity).
    public let id: UUID

    /// The parent document UUID. `nil` for orphan sections (should not
    /// happen in practice but we don't enforce it at the type level).
    public let documentID: UUID?

    /// Section heading. Always present.
    public let title: String

    /// Typst (or LaTeX) source body. Already rehydrated — if the on-disk
    /// payload had a `content_hash`, the gateway has read the
    /// content-addressed file and put its contents here. `nil` means
    /// the body is missing from disk and the caller should treat the
    /// section as unreadable.
    public let body: String?

    /// Free-form section classification ("introduction", "methods", ...).
    public let sectionType: String?

    /// Zero-based position within the parent document.
    public let orderIndex: Int

    /// Approximate word count (stored at save time, not recomputed).
    public let wordCount: Int

    /// SHA-256 hex of the content-addressed body, if one exists.
    /// Exposed so callers can dedup by hash across documents if needed.
    public let contentHash: String?

    /// Item creation timestamp in milliseconds since epoch.
    public let createdAt: Date

    public init(
        id: UUID,
        documentID: UUID?,
        title: String,
        body: String?,
        sectionType: String?,
        orderIndex: Int,
        wordCount: Int,
        contentHash: String?,
        createdAt: Date
    ) {
        self.id = id
        self.documentID = documentID
        self.title = title
        self.body = body
        self.sectionType = sectionType
        self.orderIndex = orderIndex
        self.wordCount = wordCount
        self.contentHash = contentHash
        self.createdAt = createdAt
    }
}

// MARK: - SharedItemRow parsing

#if canImport(ImpressRustCore)
extension ManuscriptSection {

    /// Decode a `SharedItemRow` into a `ManuscriptSection`. Returns
    /// `nil` if the row's schema is wrong, its id is unparseable, or
    /// its payload JSON is malformed.
    ///
    /// Does NOT rehydrate the body — the caller (typically
    /// `ImprintImpressStore`) does that separately since body
    /// rehydration can be I/O-heavy and should not happen inside a
    /// JSON decode path.
    ///
    /// The `body` field will be populated with the inline value from
    /// the payload. Downstream code must check `contentHash` and
    /// replace `body` with the on-disk contents when needed.
    public init?(row: SharedItemRow) {
        guard row.schemaRef == "manuscript-section@1.0.0" else { return nil }
        guard let itemID = UUID(uuidString: row.id) else { return nil }

        guard let payloadData = row.payloadJson.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }

        let title = (raw["title"] as? String) ?? ""
        let inlineBody = raw["body"] as? String
        let sectionType = raw["section_type"] as? String
        let orderIndex = (raw["order_index"] as? Int) ?? 0
        let wordCount = (raw["word_count"] as? Int) ?? 0
        let documentIDStr = raw["document_id"] as? String
        let documentID = documentIDStr.flatMap(UUID.init(uuidString:))
        let contentHash = (raw["content_hash"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        self.init(
            id: itemID,
            documentID: documentID,
            title: title,
            body: inlineBody,
            sectionType: sectionType,
            orderIndex: orderIndex,
            wordCount: wordCount,
            contentHash: contentHash,
            createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
        )
    }
}
#endif
