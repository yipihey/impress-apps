//
//  ManuscriptCollections.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData
import OSLog

// MARK: - Manuscript Collection Manager (ADR-021)

/// Manages manuscript-related collections and filtering.
///
/// Provides predefined smart collections for organizing manuscripts
/// by status, venue, and other criteria.
@MainActor
public final class ManuscriptCollectionManager {

    // MARK: - Singleton

    public static let shared = ManuscriptCollectionManager()

    // MARK: - Properties

    private let persistenceController: PersistenceController

    // MARK: - Initialization

    private init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Collection Definitions

    /// Predefined manuscript collection definitions
    public enum ManuscriptCollectionType: String, CaseIterable {
        case allManuscripts = "manuscripts:all"
        case active = "manuscripts:active"
        case completed = "manuscripts:completed"
        case drafting = "manuscripts:drafting"
        case submitted = "manuscripts:submitted"
        case underReview = "manuscripts:under_review"
        case inRevision = "manuscripts:revision"
        case accepted = "manuscripts:accepted"
        case published = "manuscripts:published"

        /// Display name for sidebar
        public var displayName: String {
            switch self {
            case .allManuscripts: return "My Manuscripts"
            case .active: return "Active"
            case .completed: return "Completed"
            case .drafting: return "Drafting"
            case .submitted: return "Submitted"
            case .underReview: return "Under Review"
            case .inRevision: return "In Revision"
            case .accepted: return "Accepted"
            case .published: return "Published"
            }
        }

        /// SF Symbol for collection icon
        public var systemImage: String {
            switch self {
            case .allManuscripts: return "doc.text"
            case .active: return "pencil.circle"
            case .completed: return "checkmark.circle"
            case .drafting: return "pencil"
            case .submitted: return "paperplane"
            case .underReview: return "eye"
            case .inRevision: return "arrow.triangle.2.circlepath"
            case .accepted: return "checkmark.seal"
            case .published: return "book.closed"
            }
        }

        /// Whether this collection should be shown at top level
        public var isTopLevel: Bool {
            switch self {
            case .allManuscripts, .active, .completed:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Fetch Manuscripts

    /// Fetch all manuscripts from the library
    public func fetchAllManuscripts(in library: CDLibrary? = nil) -> [CDPublication] {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")

        // Manuscripts are identified by having _manuscript_status in rawFields
        // We use CONTAINS because rawFields is a JSON string
        var predicates: [NSPredicate] = [
            NSPredicate(format: "rawFields CONTAINS %@", "\"_manuscript_status\"")
        ]

        if let library = library {
            predicates.append(NSPredicate(format: "ANY libraries == %@", library))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "dateModified", ascending: false)
        ]

        do {
            return try context.fetch(request)
        } catch {
            Logger.library.errorCapture("Failed to fetch manuscripts: \(error.localizedDescription)", category: "manuscript")
            return []
        }
    }

    /// Fetch manuscripts by status
    public func fetchManuscripts(
        status: ManuscriptStatus,
        in library: CDLibrary? = nil
    ) -> [CDPublication] {
        fetchAllManuscripts(in: library).filter { $0.manuscriptStatus == status }
    }

    /// Fetch active manuscripts (drafting, submitted, under review, revision)
    public func fetchActiveManuscripts(in library: CDLibrary? = nil) -> [CDPublication] {
        fetchAllManuscripts(in: library).filter { $0.manuscriptStatus?.isActive ?? false }
    }

    /// Fetch completed manuscripts (accepted, published)
    public func fetchCompletedManuscripts(in library: CDLibrary? = nil) -> [CDPublication] {
        fetchAllManuscripts(in: library).filter { $0.manuscriptStatus?.isCompleted ?? false }
    }

    // MARK: - Manuscript Statistics

    /// Statistics about manuscripts in a library
    public struct ManuscriptStats {
        public let total: Int
        public let active: Int
        public let completed: Int
        public let byStatus: [ManuscriptStatus: Int]

        public init(manuscripts: [CDPublication]) {
            self.total = manuscripts.count
            self.active = manuscripts.filter { $0.manuscriptStatus?.isActive ?? false }.count
            self.completed = manuscripts.filter { $0.manuscriptStatus?.isCompleted ?? false }.count

            var statusCounts: [ManuscriptStatus: Int] = [:]
            for manuscript in manuscripts {
                if let status = manuscript.manuscriptStatus {
                    statusCounts[status, default: 0] += 1
                }
            }
            self.byStatus = statusCounts
        }
    }

    /// Get manuscript statistics for a library
    public func getStats(for library: CDLibrary? = nil) -> ManuscriptStats {
        ManuscriptStats(manuscripts: fetchAllManuscripts(in: library))
    }

    // MARK: - Citation Intelligence

    /// Find publications cited by this manuscript
    public func fetchCitedPublications(for manuscript: CDPublication) -> [CDPublication] {
        let context = persistenceController.viewContext
        let citedIDs = manuscript.citedPublicationIDs

        guard !citedIDs.isEmpty else { return [] }

        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id IN %@", citedIDs)
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]

        do {
            return try context.fetch(request)
        } catch {
            Logger.library.errorCapture("Failed to fetch cited publications: \(error.localizedDescription)", category: "manuscript")
            return []
        }
    }

    /// Find manuscripts that cite a given publication
    public func fetchManuscriptsCiting(_ publication: CDPublication) -> [CDPublication] {
        let allManuscripts = fetchAllManuscripts()
        return allManuscripts.filter { $0.cites(publication) }
    }

    /// Find publications that are read but never cited in any manuscript
    public func fetchUncitedPublications(in library: CDLibrary? = nil) -> [CDPublication] {
        let manuscripts = fetchAllManuscripts(in: library)
        let allCitedIDs = Set(manuscripts.flatMap { $0.citedPublicationIDs })

        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")

        var predicates: [NSPredicate] = [
            // Has been read
            NSPredicate(format: "isRead == YES"),
            // Is not a manuscript itself
            NSPredicate(format: "NOT rawFields CONTAINS %@", "\"_manuscript_status\"")
        ]

        if let library = library {
            predicates.append(NSPredicate(format: "ANY libraries == %@", library))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "dateRead", ascending: false)]

        do {
            let readPubs = try context.fetch(request)
            // Filter out those that ARE cited
            return readPubs.filter { !allCitedIDs.contains($0.id) }
        } catch {
            Logger.library.errorCapture("Failed to fetch uncited publications: \(error.localizedDescription)", category: "manuscript")
            return []
        }
    }

    /// Find publications cited in multiple manuscripts
    public func fetchMultiplyCitedPublications(in library: CDLibrary? = nil) -> [(publication: CDPublication, citingManuscripts: [CDPublication])] {
        let manuscripts = fetchAllManuscripts(in: library)

        // Build citation count map
        var citationMap: [UUID: [CDPublication]] = [:]
        for manuscript in manuscripts {
            for citedID in manuscript.citedPublicationIDs {
                citationMap[citedID, default: []].append(manuscript)
            }
        }

        // Filter to those cited more than once
        let multiCited = citationMap.filter { $0.value.count > 1 }

        // Fetch the publications
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id IN %@", Array(multiCited.keys))

        do {
            let publications = try context.fetch(request)
            return publications.compactMap { pub in
                guard let citing = multiCited[pub.id] else { return nil }
                return (publication: pub, citingManuscripts: citing)
            }.sorted { $0.citingManuscripts.count > $1.citingManuscripts.count }
        } catch {
            Logger.library.errorCapture("Failed to fetch multiply-cited publications: \(error.localizedDescription)", category: "manuscript")
            return []
        }
    }
}

// MARK: - Manuscript Filtering Extension

public extension Array where Element == CDPublication {

    /// Filter to only manuscripts
    var manuscripts: [CDPublication] {
        filter { $0.isManuscript }
    }

    /// Filter to active manuscripts
    var activeManuscripts: [CDPublication] {
        filter { $0.isActiveManuscript }
    }

    /// Filter to completed manuscripts
    var completedManuscripts: [CDPublication] {
        filter { $0.isCompletedManuscript }
    }

    /// Filter by manuscript status
    func manuscripts(with status: ManuscriptStatus) -> [CDPublication] {
        filter { $0.manuscriptStatus == status }
    }

    /// Filter by submission venue
    func manuscripts(venue: String) -> [CDPublication] {
        filter { $0.submissionVenue?.localizedCaseInsensitiveContains(venue) ?? false }
    }

    /// Sort by manuscript status (active first, then by status order)
    func sortedByManuscriptStatus() -> [CDPublication] {
        sorted { lhs, rhs in
            let lhsOrder = lhs.manuscriptStatus?.sortOrder ?? 999
            let rhsOrder = rhs.manuscriptStatus?.sortOrder ?? 999
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.dateModified > rhs.dateModified
        }
    }
}
