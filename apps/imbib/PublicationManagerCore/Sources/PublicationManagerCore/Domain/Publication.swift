//
//  Publication.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDPublication. Wraps Rust PublicationDetail.
//

import Foundation
import ImbibRustCore
import ImpressFTUI

/// Full publication detail — the complete data model for detail views and editing.
/// This replaces CDPublication for all non-list uses.
public struct PublicationModel: Identifiable, Hashable, Sendable {

    public let id: UUID
    public let citeKey: String
    public let entryType: String
    public let fields: [String: String]
    public let isRead: Bool
    public let isStarred: Bool
    public let flag: PublicationFlag?
    public let tags: [TagDisplayData]
    public let authors: [AuthorModel]
    public let dateAdded: Date
    public let dateModified: Date
    public let linkedFiles: [LinkedFileModel]
    public let citationCount: Int
    public let referenceCount: Int
    public let rawBibTeX: String?
    public let collectionIDs: [UUID]
    public let libraryIDs: [UUID]

    // MARK: - Computed Properties

    public var title: String { fields["title"] ?? "Untitled" }
    public var doi: String? { fields["doi"] }
    public var arxivID: String? { fields["arxiv_id"] }
    public var bibcode: String? { fields["bibcode"] }
    public var pmid: String? { fields["pmid"] }
    public var abstract: String? { fields["abstract_text"] }
    public var journal: String? { fields["journal"] }
    public var year: Int? { fields["year"].flatMap(Int.init) }
    public var note: String? { fields["note"] }
    public var url: String? { fields["url"] }
    public var volume: String? { fields["volume"] }
    public var number: String? { fields["number"] }
    public var pages: String? { fields["pages"] }
    public var publisher: String? { fields["publisher"] }
    public var booktitle: String? { fields["booktitle"] }

    public var authorString: String {
        fields["author_text"] ?? authors.map(\.displayName).joined(separator: ", ")
    }

    public var hasDownloadedPDF: Bool {
        linkedFiles.contains { $0.isPDF && $0.isLocallyMaterialized }
    }

    // MARK: - Initialization

    public init(from detail: PublicationDetail) {
        self.id = UUID(uuidString: detail.id) ?? UUID()
        self.citeKey = detail.citeKey
        self.entryType = detail.entryType
        self.fields = detail.fields
        self.isRead = detail.isRead
        self.isStarred = detail.isStarred

        if let colorName = detail.flagColor,
           let flagColor = FlagColor(rawValue: colorName) {
            let flagStyle = detail.flagStyle.flatMap { FlagStyle(rawValue: $0) } ?? .solid
            let flagLength = detail.flagLength.flatMap { FlagLength(rawValue: $0) } ?? .full
            self.flag = PublicationFlag(color: flagColor, style: flagStyle, length: flagLength)
        } else {
            self.flag = nil
        }

        self.tags = detail.tags.map { tag in
            TagDisplayData(
                id: UUID(),
                path: tag.path,
                leaf: tag.leafName,
                colorLight: tag.colorLight,
                colorDark: tag.colorDark
            )
        }

        self.authors = detail.authors.map { AuthorModel(from: $0) }
        self.dateAdded = Date(timeIntervalSince1970: TimeInterval(detail.dateAdded) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(detail.dateModified) / 1000.0)
        self.linkedFiles = detail.linkedFiles.map { LinkedFileModel(from: $0) }
        self.citationCount = Int(detail.citationCount)
        self.referenceCount = Int(detail.referenceCount)
        self.rawBibTeX = detail.rawBibtex
        self.collectionIDs = detail.collections.compactMap { UUID(uuidString: $0) }
        self.libraryIDs = detail.libraries.compactMap { UUID(uuidString: $0) }
    }
}
