//
//  DismissedPaper.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDDismissedPaper.
//

import Foundation
import ImbibRustCore

/// A paper explicitly dismissed from the inbox.
public struct DismissedPaper: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let doi: String?
    public let arxivID: String?
    public let bibcode: String?
    public let dateDismissed: Date

    public init(from row: DismissedPaperRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.doi = row.doi
        self.arxivID = row.arxivId
        self.bibcode = row.bibcode
        self.dateDismissed = Date(timeIntervalSince1970: TimeInterval(row.dateDismissed) / 1000.0)
    }
}
