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

        // Resolve library ID on MainActor (quick lookup)
        let libraryInfo: (id: UUID, name: String, importLibraryID: UUID?)? = await MainActor.run {
            let store = RustStoreAdapter.shared
            guard let library = SciXLibraryRepository.shared.findLibrary(remoteID: libraryID) else {
                Logger.scix.errorCapture("SciX sync: library not found for remoteID \(libraryID)", category: "scix")
                return nil
            }

            let importLibID: UUID? = {
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

            return (library.id, library.name, importLibID)
        }

        guard let info = libraryInfo else { return }

        Logger.scix.infoCapture("SciX sync: resolved library '\(info.name)' (id: \(info.id))", category: "scix")

        // Do all heavy work (find-by-identifier, BibTeX import) off the main thread
        let store = await MainActor.run { RustStoreAdapter.shared }
        let capturedPapers = papers
        let capturedInfo = info

        let importResult: (importedIDs: [UUID], foundByBibcode: Int, foundByDoi: Int, importedNew: Int, importFailed: Int) = await Task.detached(priority: .userInitiated) {
            // Batch-resolve existing papers by identifiers (single query)
            let allBibcodes = capturedPapers.compactMap(\.bibcode)
            let allDois = capturedPapers.compactMap(\.doi)
            let existingByIdentifier = store.findByIdentifiersBatchBackground(
                dois: allDois,
                arxivIds: [],
                bibcodes: allBibcodes
            )

            // Build lookup maps for O(1) matching
            var bibcodeMap: [String: UUID] = [:]
            var doiMap: [String: UUID] = [:]
            for pub in existingByIdentifier {
                if let bc = pub.bibcode, !bc.isEmpty { bibcodeMap[bc] = pub.id }
                if let doi = pub.doi, !doi.isEmpty { doiMap[doi] = pub.id }
            }

            var importedIDs: [UUID] = []
            var foundByBibcode = 0
            var foundByDoi = 0
            var importedNew = 0
            var importFailed = 0

            for paper in capturedPapers {
                // Try to find existing by bibcode
                if let bibcode = paper.bibcode, let existingID = bibcodeMap[bibcode] {
                    importedIDs.append(existingID)
                    foundByBibcode += 1
                    continue
                }

                // Try by DOI
                if let doi = paper.doi, let existingID = doiMap[doi] {
                    importedIDs.append(existingID)
                    foundByDoi += 1
                    continue
                }

                // Create new publication via BibTeX import (off main thread)
                if let libID = capturedInfo.importLibraryID {
                    let bibtex = self.searchResultToBibTeX(paper)
                    let ids = store.importBibTeXBackground(bibtex, libraryId: libID)
                    if ids.isEmpty {
                        importFailed += 1
                    } else {
                        importedNew += ids.count
                        importedIDs.append(contentsOf: ids)
                    }
                } else {
                    importFailed += 1
                }
            }

            return (importedIDs, foundByBibcode, foundByDoi, importedNew, importFailed)
        }.value

        Logger.scix.infoCapture("SciX sync: resolved \(importResult.importedIDs.count) papers — bibcode: \(importResult.foundByBibcode), doi: \(importResult.foundByDoi), new: \(importResult.importedNew), failed: \(importResult.importFailed)", category: "scix")

        // Final step: link to SciX library and update metadata (brief MainActor hop)
        await MainActor.run {
            let store = RustStoreAdapter.shared

            store.beginBatchMutation()

            if !importResult.importedIDs.isEmpty {
                Logger.scix.infoCapture("SciX sync: linking \(importResult.importedIDs.count) pubs to library \(info.id) (\(info.name))", category: "scix")
                store.addToScixLibrary(publicationIds: importResult.importedIDs, scixLibraryId: info.id)
            } else {
                Logger.scix.warningCapture("SciX sync: importedIDs is empty — no edges will be created", category: "scix")
            }

            store.updateIntField(id: info.id, field: "last_sync_date", value: Int64(Date().timeIntervalSince1970 * 1000))
            store.updateIntField(id: info.id, field: "document_count", value: Int64(papers.count))
            store.updateField(id: info.id, field: "sync_state", value: "synced")

            store.endBatchMutation()

            // Verify edges were created
            if let updated = store.getScixLibrary(id: info.id) {
                let edgeCount = updated.publicationCount
                Logger.scix.infoCapture("SciX sync: VERIFY library '\(updated.name)' — documentCount=\(updated.documentCount), publicationCount(edges)=\(edgeCount)", category: "scix")
                if edgeCount == 0 && !importResult.importedIDs.isEmpty {
                    Logger.scix.errorCapture("SciX sync: BUG — linked \(importResult.importedIDs.count) pubs but publicationCount is 0! Edges not persisted.", category: "scix")
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

    /// Fetch paper details from ADS using bibcodes.
    /// Batches into chunks of 50 to avoid ADS query length limits.
    private func fetchPapersFromADS(bibcodes: [String]) async throws -> [SearchResult] {
        guard !bibcodes.isEmpty else { return [] }

        let source = ADSSource(credentialManager: CredentialManager.shared)
        let chunkSize = 50
        var allResults: [SearchResult] = []

        for chunk in stride(from: 0, to: bibcodes.count, by: chunkSize) {
            let end = min(chunk + chunkSize, bibcodes.count)
            let batch = Array(bibcodes[chunk..<end])

            let query = batch
                .map { "identifier:\"\($0)\"" }
                .joined(separator: " OR ")

            let results = try await source.search(query: query)
            allResults.append(contentsOf: results)

            Logger.scix.debug("SciX sync: fetched batch \(chunk/chunkSize + 1) — \(results.count) papers for \(batch.count) bibcodes")
        }

        return allResults
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
