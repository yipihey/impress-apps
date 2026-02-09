//
//  SciXLibrary.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDSciXLibrary.
//

import Foundation
import ImbibRustCore

/// A remote SciX (ADS) library synced to the local store.
public struct SciXLibrary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let remoteID: String
    public let name: String
    public let description: String?
    public let isPublic: Bool
    public let lastSyncDate: Date?
    public let syncState: String
    public let permissionLevel: String
    public let ownerEmail: String?
    public let documentCount: Int
    public let publicationCount: Int
    public let sortOrder: Int

    public init(from row: SciXLibraryRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.remoteID = row.remoteId
        self.name = row.name
        self.description = row.description
        self.isPublic = row.isPublic
        self.lastSyncDate = row.lastSyncDate.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        self.syncState = row.syncState
        self.permissionLevel = row.permissionLevel
        self.ownerEmail = row.ownerEmail
        self.documentCount = Int(row.documentCount)
        self.publicationCount = Int(row.publicationCount)
        self.sortOrder = Int(row.sortOrder)
    }
}
