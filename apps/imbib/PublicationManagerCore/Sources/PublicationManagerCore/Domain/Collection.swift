//
//  Collection.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDCollection.
//

import Foundation
import ImbibRustCore

/// A publication collection (manual or smart).
public struct CollectionModel: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?
    public let isSmart: Bool
    public let publicationCount: Int
    public let sortOrder: Int

    public init(from row: CollectionRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.name = row.name
        self.parentID = row.parentId.flatMap { UUID(uuidString: $0) }
        self.isSmart = row.isSmart
        self.publicationCount = Int(row.publicationCount)
        self.sortOrder = Int(row.sortOrder)
    }

    public init(id: UUID, name: String, parentID: UUID? = nil, isSmart: Bool = false, publicationCount: Int = 0, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.isSmart = isSmart
        self.publicationCount = publicationCount
        self.sortOrder = sortOrder
    }
}
