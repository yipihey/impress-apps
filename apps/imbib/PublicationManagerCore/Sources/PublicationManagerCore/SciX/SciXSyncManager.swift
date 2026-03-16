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
        Logger.scix.infoCapture("SciX sync: pulling library list...", category: "scix")

        // Fetch from API
        let remoteLibraries = try await service.fetchLibraries()

        // Update local cache via RustStoreAdapter
        var updatedLibraries: [SciXLibrary] = []

        await MainActor.run {
            let store = RustStoreAdapter.shared

            // Batch all mutations so only ONE .storeDidMutate notification fires
            // (without this, each updateField call triggers a full sidebar refresh
            //  including expensive flag-count queries — 7 × N libraries worth)
            store.beginBatchMutation()

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
                    // Do NOT set last_sync_date here — it should only be set by
                    // pullLibraryPapers() when papers are actually synced. Setting it
                    // during metadata-only sync prevents auto-refresh from triggering.
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
                    Logger.scix.infoCapture("SciX sync: removing deleted library: \(local.name)", category: "scix")
                    store.deleteItem(id: local.id)
                }
            }

            store.endBatchMutation()
        }

        Logger.scix.infoCapture("SciX sync: pulled \(updatedLibraries.count) libraries", category: "scix")

        // Notify repository to reload
        await MainActor.run {
            SciXLibraryRepository.shared.loadLibraries()
        }

        return updatedLibraries
    }

    /// Pull papers for a specific library
    public func pullLibraryPapers(libraryID: String) async throws {
        Logger.scix.infoCapture("SciX sync: pulling papers for library \(libraryID)", category: "scix")

        // Fetch bibcodes from API
        let bibcodes = try await service.fetchLibraryBibcodes(id: libraryID)
        Logger.scix.infoCapture("SciX sync: got \(bibcodes.count) bibcodes from library", category: "scix")

        guard !bibcodes.isEmpty else {
            Logger.scix.infoCapture("SciX sync: library has no papers, skipping", category: "scix")
            return
        }

        // Log first few bibcodes for debugging
        let sampleBibcodes = bibcodes.prefix(5).joined(separator: ", ")
        Logger.scix.infoCapture("SciX sync: sample bibcodes: \(sampleBibcodes)", category: "scix")

        // Fetch paper details from ADS
        let papers = try await fetchPapersFromADS(bibcodes: bibcodes)
        Logger.scix.infoCapture("SciX sync: fetched \(papers.count) papers from ADS for \(bibcodes.count) bibcodes", category: "scix")

        // Cache papers locally and link to library
        await MainActor.run {
            let store = RustStoreAdapter.shared

            guard let library = SciXLibraryRepository.shared.findLibrary(remoteID: libraryID) else {
                Logger.scix.errorCapture("SciX sync: library not found for remoteID \(libraryID)", category: "scix")
                return
            }

            Logger.scix.infoCapture("SciX sync: resolved library '\(library.name)' (id: \(library.id))", category: "scix")

            // Batch all mutations — single notification at end
            store.beginBatchMutation()

            // Resolve a library for importing new papers:
            // default library → first non-special library → inbox
            let importLibraryID: UUID? = {
                if let lib = store.getDefaultLibrary() { return lib.id }
                let allLibs = store.listLibraries()
                let regular = allLibs.first { !$0.isInbox && $0.name != "Dismissed" }
                if let lib = regular {
                    Logger.scix.infoCapture("SciX sync: no default library, using '\(lib.name)' for import", category: "scix")
                    return lib.id
                }
                if let inbox = store.getInboxLibrary() { return inbox.id }
                return nil
            }()

            // Import papers via BibTeX and link to library
            var importedIDs: [UUID] = []
            var foundByBibcode = 0
            var foundByDoi = 0
            var importedNew = 0
            var importFailed = 0

            for paper in papers {
                // Try to find existing by bibcode first
                if let bibcode = paper.bibcode {
                    let existing = store.findByBibcode(bibcode: bibcode)
                    if let first = existing.first {
                        importedIDs.append(first.id)
                        foundByBibcode += 1
                        continue
                    }
                }

                // Try by DOI
                if let doi = paper.doi {
                    let existing = store.findByDoi(doi: doi)
                    if let first = existing.first {
                        importedIDs.append(first.id)
                        foundByDoi += 1
                        continue
                    }
                }

                // Create new publication via BibTeX import
                if let libID = importLibraryID {
                    let bibtex = self.searchResultToBibTeX(paper)
                    let ids = store.importBibTeX(bibtex, libraryId: libID)
                    if ids.isEmpty {
                        importFailed += 1
                        Logger.scix.warningCapture("SciX sync: BibTeX import returned 0 IDs for '\(paper.title.prefix(60))'", category: "scix")
                    } else {
                        importedNew += ids.count
                        importedIDs.append(contentsOf: ids)
                    }
                } else {
                    importFailed += 1
                    if importedIDs.isEmpty && importFailed == 1 {
                        Logger.scix.errorCapture("SciX sync: no library available for import — all new papers will fail", category: "scix")
                    }
                }
            }

            Logger.scix.infoCapture("SciX sync: resolved \(importedIDs.count) papers — bibcode: \(foundByBibcode), doi: \(foundByDoi), new: \(importedNew), failed: \(importFailed)", category: "scix")

            // Add all publications to the SciX library
            if !importedIDs.isEmpty {
                Logger.scix.infoCapture("SciX sync: linking \(importedIDs.count) pubs to library \(library.id) (\(library.name))", category: "scix")
                store.addToScixLibrary(publicationIds: importedIDs, scixLibraryId: library.id)
            } else {
                Logger.scix.warningCapture("SciX sync: importedIDs is empty — no edges will be created", category: "scix")
            }

            // Update library metadata
            store.updateIntField(id: library.id, field: "last_sync_date", value: Int64(Date().timeIntervalSince1970 * 1000))
            store.updateIntField(id: library.id, field: "document_count", value: Int64(papers.count))
            store.updateField(id: library.id, field: "sync_state", value: "synced")

            store.endBatchMutation()

            // Verify edges were created
            if let updated = store.getScixLibrary(id: library.id) {
                let edgeCount = updated.publicationCount
                Logger.scix.infoCapture("SciX sync: VERIFY library '\(updated.name)' — documentCount=\(updated.documentCount), publicationCount(edges)=\(edgeCount)", category: "scix")
                if edgeCount == 0 && !importedIDs.isEmpty {
                    Logger.scix.errorCapture("SciX sync: BUG — linked \(importedIDs.count) pubs but publicationCount is 0! Edges not persisted.", category: "scix")
                }
            } else {
                Logger.scix.errorCapture("SciX sync: library \(libraryID) not found after sync", category: "scix")
            }
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

        let source = ADSSource(credentialManager: CredentialManager.shared)
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
