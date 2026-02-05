//
//  AssignmentService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import Foundation
import CoreData
import OSLog
#if canImport(UIKit)
import UIKit
#endif

#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - Assignment Service

/// Service for managing reading suggestions in shared libraries.
///
/// Assignments are lightweight suggestions ("please read this") with no
/// completion tracking. They record who suggested what to whom, with an
/// optional note and due date. There is no read receipt or status field
/// — an assignment is a suggestion, not surveillance.
@MainActor
public final class AssignmentService {

    public static let shared = AssignmentService()

    private let persistenceController: PersistenceController

    private init() {
        self.persistenceController = .shared
    }

    /// Initialize with custom persistence controller (for testing).
    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    // MARK: - CRUD

    /// Suggest a publication to a participant.
    ///
    /// - Parameters:
    ///   - publication: The paper to suggest
    ///   - assigneeName: Display name of the person to suggest it to
    ///   - library: The shared library context
    ///   - note: Optional note ("For Friday's meeting")
    ///   - dueDate: Optional informational due date
    /// - Returns: The created assignment
    @discardableResult
    public func suggest(
        publication: CDPublication,
        to assigneeName: String,
        in library: CDLibrary,
        note: String? = nil,
        dueDate: Date? = nil
    ) throws -> CDAssignment {
        let context = persistenceController.viewContext

        let assignment = CDAssignment(context: context)
        assignment.id = UUID()
        assignment.assigneeName = assigneeName
        assignment.assignedByName = resolveCurrentUserName(in: library)
        assignment.note = note
        assignment.dateCreated = Date()
        assignment.dueDate = dueDate
        assignment.publication = publication
        assignment.library = library

        try context.save()

        // Record activity
        try? ActivityFeedService.shared.recordActivity(
            type: .organized,
            actorName: assignment.assignedByName,
            targetTitle: publication.title,
            targetID: publication.id,
            detail: "Suggested to \(assigneeName)",
            in: library
        )

        Logger.sync.info("Created assignment: '\(publication.citeKey)' suggested to '\(assigneeName)'")

        return assignment
    }

    /// Remove an assignment.
    public func remove(_ assignment: CDAssignment) throws {
        let context = persistenceController.viewContext
        context.delete(assignment)
        try context.save()
    }

    // MARK: - Queries

    /// Get all assignments in a library.
    public func assignments(in library: CDLibrary) -> [CDAssignment] {
        (library.assignments ?? [])
            .sorted { $0.dateCreated > $1.dateCreated }
    }

    /// Get assignments for a specific publication.
    public func assignments(for publication: CDPublication) -> [CDAssignment] {
        (publication.assignments ?? [])
            .sorted { $0.dateCreated > $1.dateCreated }
    }

    /// Get assignments for the current user in a library.
    public func myAssignments(in library: CDLibrary) -> [CDAssignment] {
        let myName = resolveCurrentUserName(in: library)
        return assignments(in: library).filter { $0.assigneeName == myName }
    }

    /// Total assignment count for a library.
    public func assignmentCount(in library: CDLibrary) -> Int {
        library.assignments?.count ?? 0
    }

    // MARK: - Participant Names

    /// Get participant names for assignment picker.
    public func participantNames(in library: CDLibrary) -> [String] {
        #if canImport(CloudKit)
        guard let share = PersistenceController.shared.share(for: library) else {
            return []
        }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default

        return share.participants.compactMap { participant -> String? in
            // Skip the current user (you don't suggest to yourself)
            if participant == share.currentUserParticipant { return nil }

            if let nameComponents = participant.userIdentity.nameComponents {
                let name = formatter.string(from: nameComponents)
                if !name.isEmpty { return name }
            }
            return participant.userIdentity.lookupInfo?.emailAddress
                ?? participant.userIdentity.lookupInfo?.phoneNumber
        }.sorted()
        #else
        return []
        #endif
    }

    // MARK: - Helpers

    /// Resolve the current user's display name from CloudKit.
    private func resolveCurrentUserName(in library: CDLibrary) -> String {
        #if canImport(CloudKit)
        if let share = PersistenceController.shared.share(for: library),
           let participant = share.currentUserParticipant,
           let nameComponents = participant.userIdentity.nameComponents {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .default
            let name = formatter.string(from: nameComponents)
            if !name.isEmpty { return name }
        }
        #endif

        #if os(macOS)
        return Host.current().localizedName ?? "Me"
        #else
        return UIDevice.current.name
        #endif
    }
}
