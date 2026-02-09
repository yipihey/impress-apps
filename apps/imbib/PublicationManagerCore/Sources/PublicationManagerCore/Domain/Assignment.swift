//
//  Assignment.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDAssignment.
//

import Foundation
import ImbibRustCore

/// A reading assignment for a publication.
public struct Assignment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let assigneeName: String
    public let assignedByName: String?
    public let note: String?
    public let dateCreated: Date
    public let dueDate: Date?
    public let publicationID: UUID
    public let libraryID: UUID?

    public init(from row: AssignmentRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.assigneeName = row.assigneeName
        self.assignedByName = row.assignedByName
        self.note = row.note
        self.dateCreated = Date(timeIntervalSince1970: TimeInterval(row.dateCreated) / 1000.0)
        self.dueDate = row.dueDate.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        self.publicationID = UUID(uuidString: row.publicationId) ?? UUID()
        self.libraryID = row.libraryId.flatMap { UUID(uuidString: $0) }
    }

    /// Title of the assigned publication (looked up via RustStoreAdapter).
    @MainActor
    public var publicationTitle: String? {
        RustStoreAdapter.shared.getPublication(id: publicationID)?.title
    }
}
