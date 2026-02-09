//
//  MutedItem.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDMutedItem.
//

import Foundation
import ImbibRustCore

/// An author, venue, or category muted from the inbox.
public struct MutedItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let muteType: String
    public let value: String
    public let dateAdded: Date

    public init(from row: MutedItemRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.muteType = row.muteType
        self.value = row.value
        self.dateAdded = Date(timeIntervalSince1970: TimeInterval(row.dateAdded) / 1000.0)
    }
}
