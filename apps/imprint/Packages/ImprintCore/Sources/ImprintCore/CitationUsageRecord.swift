//
//  CitationUsageRecord.swift
//  ImprintCore
//
//  Swift-side value type for `citation-usage@1.0.0` records written by
//  `CitationUsageTracker`. Consumed by `ImprintImpressStore.listCitationUsages`
//  and by imbib's future "papers cited in your manuscripts" surface.
//

import Foundation
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

/// One record of "section X cites paper Y".
public struct CitationUsageRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let citeKey: String
    public let sectionID: UUID
    public let documentID: UUID?
    /// imbib publication UUID, when the tracker has resolved the key.
    /// Empty string is normalized to `nil` so callers don't have to
    /// check for empty strings everywhere.
    public let paperID: UUID?
    public let firstCited: Date?
    public let lastSeen: Date?

    public init(
        id: UUID,
        citeKey: String,
        sectionID: UUID,
        documentID: UUID?,
        paperID: UUID?,
        firstCited: Date?,
        lastSeen: Date?
    ) {
        self.id = id
        self.citeKey = citeKey
        self.sectionID = sectionID
        self.documentID = documentID
        self.paperID = paperID
        self.firstCited = firstCited
        self.lastSeen = lastSeen
    }
}

#if canImport(ImpressRustCore)
extension CitationUsageRecord {
    public init?(row: SharedItemRow) {
        guard row.schemaRef == "citation-usage@1.0.0" else { return nil }
        guard let itemID = UUID(uuidString: row.id) else { return nil }
        guard let data = row.payloadJson.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let citeKey = (raw["cite_key"] as? String) ?? ""
        guard !citeKey.isEmpty else { return nil }

        guard let sectionIDString = raw["section_id"] as? String,
              let sectionID = UUID(uuidString: sectionIDString) else { return nil }

        let documentID = (raw["document_id"] as? String).flatMap(UUID.init(uuidString:))
        let paperID = (raw["paper_id"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            .flatMap(UUID.init(uuidString:))

        let formatter = ISO8601DateFormatter()
        let firstCited = (raw["first_cited"] as? String).flatMap { formatter.date(from: $0) }
        let lastSeen = (raw["last_seen"] as? String).flatMap { formatter.date(from: $0) }

        self.init(
            id: itemID,
            citeKey: citeKey,
            sectionID: sectionID,
            documentID: documentID,
            paperID: paperID,
            firstCited: firstCited,
            lastSeen: lastSeen
        )
    }
}
#endif
