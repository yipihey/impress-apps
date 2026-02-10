//
//  SciXSyncManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import OSLog

/// Result of a push operation
public struct SciXPushResult: Sendable {
    public let changesApplied: Int
    public let errors: [SciXPushError]
    public let hadConflicts: Bool

    public var success: Bool {
        errors.isEmpty && !hadConflicts
    }
}

/// Error during push
public struct SciXPushError: Sendable {
    public let changeID: UUID
    public let action: String
    public let error: String
}

/// A detected conflict between local and remote state
public struct SciXSyncConflict: Sendable, Identifiable {
    public let id: UUID
    public let libraryID: String
    public let libraryName: String
    public let type: ConflictType
    public let description: String

    public enum ConflictType: Sendable {
        case paperRemovedLocally(bibcode: String)    // Paper removed locally but exists on server
        case paperRemovedRemotely(bibcode: String)   // Paper exists locally but removed from server
        case libraryDeleted                           // Library was deleted on server
    }
}

/// Actor-based manager for syncing SciX libraries between local cache and remote.
///
/// Handles:
/// - Pull: Fetching libraries and papers from SciX to local Rust store
/// - Push: Uploading pending local changes to SciX (with confirmation)
/// - Conflict detection: Identifying discrepancies between local and remote state
public actor SciXSyncManager {

    // MARK: - Singleton

    public static let shared = SciXSyncManager()

    // MARK: - Dependencies

    private let service: SciXLibraryService

    // MARK: - Initialization

    public init(service: SciXLibraryService = .shared) {
        self.service = service
    }

    // MARK: - Pull Operations

    /// Pull all libraries from SciX and update local cache
    public func pullLibraries() async throws -> [SciXLibrary] {
        Logger.scix.info("Pulling SciX libraries...")

        // Fetch from API
        let remoteLibraries = try await service.fetchLibraries()

        // Update local cache via RustStoreAdapter
        var updatedLibraries: [SciXLibrary] = []

        await MainActor.run {
            let store = RustStoreAdapter.shared

            for remote in remoteLibraries {
                // Find existing by remoteID or create new
                let existing = SciXLibraryRepository.shared.findLibrary(remoteID: remote.id)
                if let existing = existing {
                    // Update existing library fields
                    store.updateField(id: existing.id, field: "name", value: remote.name)
                    store.updateField(id: existing.id, field: "description", value: remote.description)
                    store.updateBoolField(id: existing.id, field: "is_public", value: remote.public)
                    store.updateField(id: existing.id, field: "permission_level", value: remote.permission)
                    store.updateField(id: existing.id, field: "owner_email", value: remote.owner)
                    store.updateIntField(id: existing.id, field: "document_count", value: Int64(remote.num_documents))
                    store.updateIntField(id: existing.id, field: "last_sync_date", value: Int64(Date().timeIntervalSince1970 * 1000))
                    if let refreshed = store.getScixLibrary(id: existing.id) {
                        updatedLibraries.append(refreshed)
                    }
                } else {
                    if let created = store.createScixLibrary(
                        remoteId: remote.id,
                        name: remote.name,
                        description: remote.description,
                        isPublic: remote.public,
                        permissionLevel: remote.permission,
                        ownerEmail: remote.owner
                    ) {
                        updatedLibraries.append(created)
                    }
                }
            }

            // Remove libraries that no longer exist on remote
            let remoteIDs = Set(remoteLibraries.map { $0.id })
            let allLocal = store.listScixLibraries()
            for local in allLocal {
                if !remoteIDs.contains(local.remoteID) {
                    Logger.scix.info("Removing deleted library: \(local.name)")
                    store.deleteItem(id: local.id)
                }
            }
        }

        Logger.scix.info("Pulled \(updatedLibraries.count) libraries")

        // Notify repository to reload
        await MainActor.run {
            SciXLibraryRepository.shared.loadLibraries()
        }

        return updatedLibraries
    }

    /// Pull papers for a specific library
    public func pullLibraryPapers(libraryID: String) async throws {
        Logger.scix.info("Pulling papers for library \(libraryID)...")

        // Fetch bibcodes from API
        let bibcodes = try await service.fetchLibraryBibcodes(id: libraryID)
        Logger.scix.info("Got \(bibcodes.count) bibcodes from SciX library")

        guard !bibcodes.isEmpty else {
            Logger.scix.debug("Library has no papers")
            return
        }

        // Log first few bibcodes for debugging
        let sampleBibcodes = bibcodes.prefix(5).joined(separator: ", ")
        Logger.scix.debug("Sample bibcodes: \(sampleBibcodes)")

        // Fetch paper details from ADS
        let papers = try await fetchPapersFromADS(bibcodes: bibcodes)
        Logger.scix.info("Fetched \(papers.count) papers from ADS for \(bibcodes.count) bibcodes")

        // Cache papers locally and link to library
        await MainActor.run {
            let store = RustStoreAdapter.shared

            guard let library = SciXLibraryRepository.shared.findLibrary(remoteID: libraryID) else {
                Logger.scix.error("Library not found: \(libraryID)")
                return
            }

            // Import papers via BibTeX and link to library
            var importedIDs: [UUID] = []
            for paper in papers {
                // Try to find existing by bibcode first
                if let bibcode = paper.bibcode {
                    let existing = store.findByBibcode(bibcode: bibcode)
                    if let first = existing.first {
                        importedIDs.append(first.id)
                        continue
                    }
                }

                // Try by DOI
                if let doi = paper.doi {
                    let existing = store.findByDoi(doi: doi)
                    if let first = existing.first {
                        importedIDs.append(first.id)
                        continue
                    }
                }

                // Create new publication via BibTeX import
                let bibtex = self.searchResultToBibTeX(paper)
                let defaultLib = store.getDefaultLibrary()
                if let libID = defaultLib?.id {
                    let ids = store.importBibTeX(bibtex, libraryId: libID)
                    importedIDs.append(contentsOf: ids)
                }
            }

            // Add all publications to the SciX library
            if !importedIDs.isEmpty {
                store.addToScixLibrary(publicationIds: importedIDs, scixLibraryId: library.id)
            }

            // Update library metadata
            store.updateIntField(id: library.id, field: "last_sync_date", value: Int64(Date().timeIntervalSince1970 * 1000))
            store.updateIntField(id: library.id, field: "document_count", value: Int64(papers.count))
            store.updateField(id: library.id, field: "sync_state", value: "synced")

            Logger.scix.info("Cached \(papers.count) papers for library \(libraryID)")
        }
    }

    // MARK: - Push Operations

    /// Push pending changes to SciX (placeholder — pending changes are now managed differently)
    public func pushPendingChanges(for libraryID: UUID) async throws -> SciXPushResult {
        // With Rust store, pending changes queue is not yet implemented
        // Return empty result for now
        return SciXPushResult(changesApplied: 0, errors: [], hadConflicts: false)
    }

    // MARK: - Conflict Detection

    /// Detect conflicts between local state and remote state
    public func detectConflicts(for libraryID: UUID) async throws -> [SciXSyncConflict] {
        let library = await MainActor.run {
            RustStoreAdapter.shared.getScixLibrary(id: libraryID)
        }

        guard let library = library else {
            return []
        }

        let remoteID = library.remoteID
        let libraryName = library.name

        // Fetch current remote state
        let remoteBibcodes: [String]
        do {
            remoteBibcodes = try await service.fetchLibraryBibcodes(id: remoteID)
        } catch SciXLibraryError.notFound {
            // Library was deleted on server
            return [SciXSyncConflict(
                id: UUID(),
                libraryID: remoteID,
                libraryName: libraryName,
                type: .libraryDeleted,
                description: "Library '\(libraryName)' was deleted on SciX"
            )]
        }

        // No pending changes queue in Rust store yet — return empty conflicts
        return []
    }

    // MARK: - Helper Methods

    /// Fetch paper details from ADS using bibcodes
    private func fetchPapersFromADS(bibcodes: [String]) async throws -> [SearchResult] {
        // Use ADSSource to fetch paper details
        guard !bibcodes.isEmpty else { return [] }

        // ADS query: identifier:"bibcode1" OR identifier:"bibcode2" OR ...
        let query = bibcodes
            .map { "identifier:\"\($0)\"" }
            .joined(separator: " OR ")

        let source = ADSSource()
        return try await source.search(query: query)
    }

    /// Convert a SearchResult to minimal BibTeX for import
    private nonisolated func searchResultToBibTeX(_ result: SearchResult) -> String {
        let firstAuthor = result.authors.first?
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? "Unknown"
        let year = result.year.map { String($0) } ?? "NoYear"
        let titleWord = result.title
            .components(separatedBy: .whitespaces)
            .first { $0.count > 3 } ?? "Paper"
        let citeKey = "\(firstAuthor)\(year)\(titleWord)"

        var fields: [String] = []
        fields.append("  title = {\(result.title)}")
        if !result.authors.isEmpty {
            fields.append("  author = {\(result.authors.joined(separator: " and "))}")
        }
        if let y = result.year {
            fields.append("  year = {\(y)}")
        }
        if let doi = result.doi {
            fields.append("  doi = {\(doi)}")
        }
        if let abstract = result.abstract {
            fields.append("  abstract = {\(abstract)}")
        }
        if let bibcode = result.bibcode {
            fields.append("  bibcode = {\(bibcode)}")
        }
        if let arxivID = result.arxivID {
            fields.append("  eprint = {\(arxivID)}")
        }

        return "@article{\(citeKey),\n\(fields.joined(separator: ",\n"))\n}"
    }
}
