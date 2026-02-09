//
//  Library.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDLibrary.
//

import Foundation
import ImbibRustCore

/// A bibliography library.
public struct LibraryModel: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let isDefault: Bool
    public let isInbox: Bool
    public let publicationCount: Int

    public init(from row: LibraryRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.name = row.name
        self.isDefault = row.isDefault
        self.isInbox = row.isInbox
        self.publicationCount = Int(row.publicationCount)
    }

    public init(id: UUID, name: String, isDefault: Bool = false, isInbox: Bool = false, publicationCount: Int = 0) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.isInbox = isInbox
        self.publicationCount = publicationCount
    }
}
