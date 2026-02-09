//
//  AssignmentService.swift
//  PublicationManagerCore
//
//  Service for managing reading suggestions in shared libraries.
//

import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Assignment Service

/// Service for managing reading suggestions in shared libraries.
///
/// Assignments are lightweight suggestions ("please read this") with no
/// completion tracking. They record who suggested what to whom, with an
/// optional note and due date. There is no read receipt or status field
/// -- an assignment is a suggestion, not surveillance.
@MainActor
public final class AssignmentService {

    public static let shared = AssignmentService()

    private let store: RustStoreAdapter

    private init() {
        self.store = .shared
    }

    // MARK: - CRUD

    /// Suggest a publication to a participant.
    ///
    /// - Parameters:
    ///   - publicationID: The paper to suggest
    ///   - assigneeName: Display name of the person to suggest it to
    ///   - libraryID: The shared library context (for activity recording)
    ///   - note: Optional note ("For Friday's meeting")
    ///   - dueDate: Optional informational due date
    /// - Returns: The created assignment
    @discardableResult
    public func suggest(
        publicationID: UUID,
        to assigneeName: String,
        in libraryID: UUID,
        note: String? = nil,
        dueDate: Date? = nil
    ) -> Assignment? {
        let assignedByName = resolveCurrentUserName()
        let dueDateEpoch: Int64? = dueDate.map { Int64($0.timeIntervalSince1970 * 1000) }

        let assignment = store.createAssignment(
            publicationId: publicationID,
            assigneeName: assigneeName,
            assignedByName: assignedByName,
            note: note,
            dueDate: dueDateEpoch
        )

        // Record activity
        if let assignment {
            let pub = store.getPublication(id: publicationID)
            ActivityFeedService.shared.recordActivity(
                type: .organized,
                actorName: assignedByName,
                targetTitle: pub?.title,
                targetID: publicationID,
                detail: "Suggested to \(assigneeName)",
                in: libraryID
            )

            Logger.sync.info("Created assignment: suggested to '\(assigneeName)'")
        }

        return assignment
    }

    /// Remove an assignment.
    public func remove(_ assignmentID: UUID) {
        store.deleteItem(id: assignmentID)
    }

    // MARK: - Queries

    /// Get all assignments for a publication.
    public func assignments(for publicationID: UUID) -> [Assignment] {
        store.listAssignments(publicationId: publicationID)
    }

    /// Get assignments for the current user from the full list.
    public func myAssignments(from assignments: [Assignment]) -> [Assignment] {
        let myName = resolveCurrentUserName()
        return assignments.filter { $0.assigneeName == myName }
    }

    // MARK: - Helpers

    /// Resolve the current user's display name.
    private func resolveCurrentUserName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Me"
        #else
        return UIDevice.current.name
        #endif
    }
}
