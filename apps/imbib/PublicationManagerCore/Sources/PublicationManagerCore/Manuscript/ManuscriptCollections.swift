//
//  ManuscriptCollections.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
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

    private let store = RustStoreAdapter.shared

    // MARK: - Initialization

    private init() {}

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

    /// Fetch all manuscripts from the library.
    /// Manuscripts are identified by having _manuscript_status in their fields.
    public func fetchAllManuscripts(in libraryID: UUID? = nil) -> [PublicationRowData] {
        // Search for publications with _manuscript_status field
        let allPubs: [PublicationRowData]
        if let libraryID = libraryID {
            allPubs = store.queryPublications(parentId: libraryID, sort: "modified", ascending: false)
        } else {
            // Get all libraries and query each
            let libraries = store.listLibraries()
            allPubs = libraries.flatMap { store.queryPublications(parentId: $0.id, sort: "modified", ascending: false) }
        }

        // Filter to manuscripts by checking detail fields
        return allPubs.filter { pub in
            guard let detail = store.getPublicationDetail(id: pub.id) else { return false }
            return detail.fields["_manuscript_status"] != nil
        }
    }

    /// Fetch manuscripts by status
    public func fetchManuscripts(
        status: ManuscriptStatus,
        in libraryID: UUID? = nil
    ) -> [PublicationRowData] {
        fetchAllManuscripts(in: libraryID).filter { pub in
            guard let detail = store.getPublicationDetail(id: pub.id) else { return false }
            return detail.fields["_manuscript_status"] == status.rawValue
        }
    }

    /// Fetch active manuscripts (drafting, submitted, under review, revision)
    public func fetchActiveManuscripts(in libraryID: UUID? = nil) -> [PublicationRowData] {
        fetchAllManuscripts(in: libraryID).filter { pub in
            guard let detail = store.getPublicationDetail(id: pub.id),
                  let statusStr = detail.fields["_manuscript_status"],
                  let status = ManuscriptStatus(rawValue: statusStr) else { return false }
            return status.isActive
        }
    }

    /// Fetch completed manuscripts (accepted, published)
    public func fetchCompletedManuscripts(in libraryID: UUID? = nil) -> [PublicationRowData] {
        fetchAllManuscripts(in: libraryID).filter { pub in
            guard let detail = store.getPublicationDetail(id: pub.id),
                  let statusStr = detail.fields["_manuscript_status"],
                  let status = ManuscriptStatus(rawValue: statusStr) else { return false }
            return status.isCompleted
        }
    }

    // MARK: - Manuscript Statistics

    /// Statistics about manuscripts in a library
    public struct ManuscriptStats {
        public let total: Int
        public let active: Int
        public let completed: Int
        public let byStatus: [ManuscriptStatus: Int]

        @MainActor public init(manuscripts: [PublicationRowData], store: RustStoreAdapter) {
            self.total = manuscripts.count

            var activeCnt = 0
            var completedCnt = 0
            var statusCounts: [ManuscriptStatus: Int] = [:]

            for manuscript in manuscripts {
                if let detail = store.getPublicationDetail(id: manuscript.id),
                   let statusStr = detail.fields["_manuscript_status"],
                   let status = ManuscriptStatus(rawValue: statusStr) {
                    statusCounts[status, default: 0] += 1
                    if status.isActive { activeCnt += 1 }
                    if status.isCompleted { completedCnt += 1 }
                }
            }

            self.active = activeCnt
            self.completed = completedCnt
            self.byStatus = statusCounts
        }
    }

    /// Get manuscript statistics for a library
    public func getStats(for libraryID: UUID? = nil) -> ManuscriptStats {
        ManuscriptStats(manuscripts: fetchAllManuscripts(in: libraryID), store: store)
    }

    // MARK: - Citation Intelligence

    /// Parse cited publication IDs from fields dictionary
    public static func parseCitedIDs(from fields: [String: String]) -> Set<UUID> {
        guard let idsJSON = fields["_cited_publication_ids"],
              let data = idsJSON.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids.compactMap { UUID(uuidString: $0) })
    }

    /// Encode cited publication IDs to JSON string
    public static func encodeCitedIDs(_ ids: Set<UUID>) -> String {
        let strings = ids.map(\.uuidString)
        guard let data = try? JSONEncoder().encode(strings),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Find publications cited by this manuscript
    public func fetchCitedPublications(for manuscriptID: UUID) -> [PublicationRowData] {
        guard let detail = store.getPublicationDetail(id: manuscriptID) else { return [] }
        let citedIDs = Self.parseCitedIDs(from: detail.fields)
        guard !citedIDs.isEmpty else { return [] }

        return citedIDs.compactMap { store.getPublication(id: $0) }
    }

    /// Find manuscripts that cite a given publication
    public func fetchManuscriptsCiting(_ publicationID: UUID) -> [PublicationRowData] {
        let allManuscripts = fetchAllManuscripts()
        return allManuscripts.filter { manuscript in
            guard let detail = store.getPublicationDetail(id: manuscript.id) else { return false }
            let citedIDs = Self.parseCitedIDs(from: detail.fields)
            return citedIDs.contains(publicationID)
        }
    }

    /// Find publications that are read but never cited in any manuscript
    public func fetchUncitedPublications(in libraryID: UUID? = nil) -> [PublicationRowData] {
        let manuscripts = fetchAllManuscripts(in: libraryID)
        let allCitedIDs = Set(manuscripts.flatMap { manuscript -> Set<UUID> in
            guard let detail = store.getPublicationDetail(id: manuscript.id) else { return [] }
            return Self.parseCitedIDs(from: detail.fields)
        })

        // Get read publications that are not manuscripts and not cited
        let readPubs: [PublicationRowData]
        if let libraryID = libraryID {
            readPubs = store.queryPublications(parentId: libraryID, sort: "modified", ascending: false)
        } else {
            let libraries = store.listLibraries()
            readPubs = libraries.flatMap { store.queryPublications(parentId: $0.id, sort: "modified", ascending: false) }
        }

        return readPubs.filter { pub in
            guard pub.isRead else { return false }
            // Exclude manuscripts themselves
            if let detail = store.getPublicationDetail(id: pub.id),
               detail.fields["_manuscript_status"] != nil {
                return false
            }
            return !allCitedIDs.contains(pub.id)
        }
    }

    /// Find publications cited in multiple manuscripts
    public func fetchMultiplyCitedPublications(in libraryID: UUID? = nil) -> [(publication: PublicationRowData, citingManuscripts: [PublicationRowData])] {
        let manuscripts = fetchAllManuscripts(in: libraryID)

        // Build citation count map
        var citationMap: [UUID: [PublicationRowData]] = [:]
        for manuscript in manuscripts {
            guard let detail = store.getPublicationDetail(id: manuscript.id) else { continue }
            let citedIDs = Self.parseCitedIDs(from: detail.fields)
            for citedID in citedIDs {
                citationMap[citedID, default: []].append(manuscript)
            }
        }

        // Filter to those cited more than once
        let multiCited = citationMap.filter { $0.value.count > 1 }

        // Fetch the publications
        return multiCited.compactMap { id, citing in
            guard let pub = store.getPublication(id: id) else { return nil }
            return (publication: pub, citingManuscripts: citing)
        }.sorted { $0.citingManuscripts.count > $1.citingManuscripts.count }
    }
}

// MARK: - Manuscript Filtering Extension

public extension Array where Element == PublicationRowData {

    /// Sort by date modified (newest first) — used as a generic sort for manuscripts
    func sortedByManuscriptStatus() -> [PublicationRowData] {
        sorted { lhs, rhs in
            lhs.dateModified > rhs.dateModified
        }
    }
}
