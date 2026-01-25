//
//  SciXSyncManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import CoreData
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
/// - Pull: Fetching libraries and papers from SciX to local Core Data cache
/// - Push: Uploading pending local changes to SciX (with confirmation)
/// - Conflict detection: Identifying discrepancies between local and remote state
public actor SciXSyncManager {

    // MARK: - Singleton

    public static let shared = SciXSyncManager()

    // MARK: - Dependencies

    private let service: SciXLibraryService
    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(
        service: SciXLibraryService = .shared,
        persistenceController: PersistenceController = .shared
    ) {
        self.service = service
        self.persistenceController = persistenceController
    }

    // MARK: - Pull Operations

    /// Pull all libraries from SciX and update local cache
    public func pullLibraries() async throws -> [CDSciXLibrary] {
        Logger.scix.info("Pulling SciX libraries...")

        // Fetch from API
        let remoteLibraries = try await service.fetchLibraries()

        // Update local cache
        let context = persistenceController.viewContext
        var updatedLibraries: [CDSciXLibrary] = []

        await context.perform {
            for remote in remoteLibraries {
                let local = self.findOrCreateLibrary(remoteID: remote.id, in: context)
                self.updateLibrary(local, from: remote)
                updatedLibraries.append(local)
            }

            // Remove libraries that no longer exist on remote
            let remoteIDs = Set(remoteLibraries.map { $0.id })
            self.removeDeletedLibraries(notIn: remoteIDs, context: context)

            do {
                try context.save()
            } catch {
                Logger.scix.error("Failed to save libraries: \(error)")
            }
        }

        Logger.scix.info("Pulled \(updatedLibraries.count) libraries")

        // Notify repository to reload from Core Data
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
        let context = persistenceController.viewContext
        await context.perform {
            guard let library = self.findLibrary(remoteID: libraryID, in: context) else {
                Logger.scix.error("Library not found: \(libraryID)")
                return
            }

            // Clear existing publications from library (we'll re-link them)
            library.publications = []

            for paper in papers {
                // Find or create publication
                let publication = self.findOrCreatePublication(from: paper, in: context)
                // Set relationship from both sides to ensure Core Data updates correctly
                if publication.scixLibraries == nil {
                    publication.scixLibraries = []
                }
                publication.scixLibraries?.insert(library)
                if library.publications == nil {
                    library.publications = []
                }
                library.publications?.insert(publication)
            }

            library.lastSyncDate = Date()
            library.syncState = CDSciXLibrary.SyncState.synced.rawValue
            library.documentCount = Int32(papers.count)

            do {
                try context.save()
                Logger.scix.info("Cached \(papers.count) papers for library \(libraryID)")
            } catch {
                Logger.scix.error("Failed to save papers: \(error)")
            }
        }
    }

    // MARK: - Push Operations

    /// Prepare pending changes for confirmation
    public func preparePush(for library: CDSciXLibrary) async -> [CDSciXPendingChange] {
        let context = persistenceController.viewContext
        var changes: [CDSciXPendingChange] = []

        await context.perform {
            changes = Array(library.pendingChanges ?? [])
                .sorted { $0.dateCreated < $1.dateCreated }
        }

        return changes
    }

    /// Push pending changes to SciX (after user confirmation)
    public func pushPendingChanges(for library: CDSciXLibrary) async throws -> SciXPushResult {
        let context = persistenceController.viewContext

        var remoteID: String = ""
        var changes: [CDSciXPendingChange] = []

        await context.perform {
            remoteID = library.remoteID
            changes = Array(library.pendingChanges ?? [])
                .sorted { $0.dateCreated < $1.dateCreated }
        }

        guard !changes.isEmpty else {
            return SciXPushResult(changesApplied: 0, errors: [], hadConflicts: false)
        }

        Logger.scix.info("Pushing \(changes.count) changes for library \(remoteID)")

        var errors: [SciXPushError] = []
        var applied = 0

        for change in changes {
            do {
                try await applyChange(change, libraryID: remoteID)
                applied += 1

                // Remove the change from Core Data
                await context.perform {
                    context.delete(change)
                }
            } catch {
                let pushError = SciXPushError(
                    changeID: change.id,
                    action: change.action,
                    error: error.localizedDescription
                )
                errors.append(pushError)
                Logger.scix.error("Failed to push change: \(error)")
            }
        }

        // Save context and update sync state
        await context.perform {
            library.syncState = errors.isEmpty
                ? CDSciXLibrary.SyncState.synced.rawValue
                : CDSciXLibrary.SyncState.error.rawValue

            do {
                try context.save()
            } catch {
                Logger.scix.error("Failed to save after push: \(error)")
            }
        }

        return SciXPushResult(
            changesApplied: applied,
            errors: errors,
            hadConflicts: false
        )
    }

    private func applyChange(_ change: CDSciXPendingChange, libraryID: String) async throws {
        switch change.actionEnum {
        case .add:
            let bibcodes = change.bibcodes
            guard !bibcodes.isEmpty else { return }
            _ = try await service.addDocuments(libraryID: libraryID, bibcodes: bibcodes)

        case .remove:
            let bibcodes = change.bibcodes
            guard !bibcodes.isEmpty else { return }
            _ = try await service.removeDocuments(libraryID: libraryID, bibcodes: bibcodes)

        case .updateMeta:
            guard let meta = change.metadata else { return }
            try await service.updateMetadata(
                libraryID: libraryID,
                name: meta.name,
                description: meta.description,
                isPublic: meta.isPublic
            )
        }
    }

    // MARK: - Conflict Detection

    /// Detect conflicts between local pending changes and remote state
    public func detectConflicts(for library: CDSciXLibrary) async throws -> [SciXSyncConflict] {
        var remoteID: String = ""
        var libraryName: String = ""
        var pendingRemoves: Set<String> = []

        let context = persistenceController.viewContext
        await context.perform {
            remoteID = library.remoteID
            libraryName = library.name

            // Get bibcodes scheduled for removal
            let changes = library.pendingChanges ?? []
            for change in changes where change.actionEnum == .remove {
                pendingRemoves.formUnion(change.bibcodes)
            }
        }

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

        let remoteSet = Set(remoteBibcodes)
        var conflicts: [SciXSyncConflict] = []

        // Check for papers we're trying to remove that don't exist remotely
        for bibcode in pendingRemoves {
            if !remoteSet.contains(bibcode) {
                conflicts.append(SciXSyncConflict(
                    id: UUID(),
                    libraryID: remoteID,
                    libraryName: libraryName,
                    type: .paperRemovedRemotely(bibcode: bibcode),
                    description: "Paper \(bibcode) was already removed from SciX"
                ))
            }
        }

        return conflicts
    }

    // MARK: - Helper Methods

    private func findOrCreateLibrary(remoteID: String, in context: NSManagedObjectContext) -> CDSciXLibrary {
        if let existing = findLibrary(remoteID: remoteID, in: context) {
            return existing
        }

        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = remoteID
        library.dateCreated = Date()
        library.syncState = CDSciXLibrary.SyncState.synced.rawValue
        library.permissionLevel = CDSciXLibrary.PermissionLevel.read.rawValue
        return library
    }

    private func findLibrary(remoteID: String, in context: NSManagedObjectContext) -> CDSciXLibrary? {
        let request = NSFetchRequest<CDSciXLibrary>(entityName: "SciXLibrary")
        request.predicate = NSPredicate(format: "remoteID == %@", remoteID)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func updateLibrary(_ library: CDSciXLibrary, from remote: SciXLibraryMetadata) {
        library.name = remote.name
        library.descriptionText = remote.description
        library.isPublic = remote.public
        library.permissionLevel = remote.permission
        library.ownerEmail = remote.owner
        library.documentCount = Int32(remote.num_documents)
        library.lastSyncDate = Date()

        // Only set to synced if no pending changes
        if library.pendingChanges?.isEmpty ?? true {
            library.syncState = CDSciXLibrary.SyncState.synced.rawValue
        }
    }

    private func removeDeletedLibraries(notIn remoteIDs: Set<String>, context: NSManagedObjectContext) {
        let request = NSFetchRequest<CDSciXLibrary>(entityName: "SciXLibrary")
        request.predicate = NSPredicate(format: "NOT (remoteID IN %@)", remoteIDs)

        do {
            let toDelete = try context.fetch(request)
            for library in toDelete {
                Logger.scix.info("Removing deleted library: \(library.name)")
                context.delete(library)
            }
        } catch {
            Logger.scix.error("Failed to remove deleted libraries: \(error)")
        }
    }

    /// Fetch paper details from ADS using bibcodes
    private func fetchPapersFromADS(bibcodes: [String]) async throws -> [SearchResult] {
        // Use ADSSource to fetch paper details
        // Build a query that searches for these specific bibcodes
        guard !bibcodes.isEmpty else { return [] }

        // ADS query: identifier:"bibcode1" OR identifier:"bibcode2" OR ...
        let query = bibcodes
            .map { "identifier:\"\($0)\"" }
            .joined(separator: " OR ")

        let source = ADSSource()
        return try await source.search(query: query)
    }

    private func findOrCreatePublication(from result: SearchResult, in context: NSManagedObjectContext) -> CDPublication {
        // Try to find existing by bibcode
        if let bibcode = result.bibcode {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "bibcodeNormalized == %@", bibcode.uppercased())
            request.fetchLimit = 1
            if let existing = try? context.fetch(request).first {
                return existing
            }
        }

        // Try to find by DOI
        if let doi = result.doi {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "doi == %@", doi)
            request.fetchLimit = 1
            if let existing = try? context.fetch(request).first {
                return existing
            }
        }

        // Create new publication
        let publication = CDPublication(context: context)
        publication.id = UUID()
        publication.citeKey = generateCiteKey(from: result)
        publication.entryType = "article"
        publication.title = result.title
        publication.year = Int16(result.year ?? 0)
        publication.doi = result.doi
        publication.abstract = result.abstract
        publication.dateAdded = Date()
        publication.dateModified = Date()
        publication.originalSourceID = result.sourceID
        publication.webURL = result.webURL?.absoluteString

        // Store authors
        var fields: [String: String] = [:]
        if !result.authors.isEmpty {
            fields["author"] = result.authors.joined(separator: " and ")
        }
        if let bibcode = result.bibcode {
            fields["bibcode"] = bibcode
            publication.bibcodeNormalized = bibcode.uppercased()
        }
        if let arxivID = result.arxivID {
            fields["eprint"] = arxivID
            publication.arxivIDNormalized = IdentifierExtractor.normalizeArXivID(arxivID)
        }
        publication.fields = fields

        // PDF links
        if let pdfURL = result.pdfURL {
            publication.addPDFLink(PDFLink(
                url: pdfURL,
                type: result.arxivID != nil ? .preprint : .publisher,
                sourceID: result.sourceID
            ))
        }

        return publication
    }

    private func generateCiteKey(from result: SearchResult) -> String {
        let firstAuthor = result.authors.first?
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? "Unknown"

        let year = result.year.map { String($0) } ?? "NoYear"

        let titleWord = result.title
            .components(separatedBy: .whitespaces)
            .first { $0.count > 3 } ?? "Paper"

        return "\(firstAuthor)\(year)\(titleWord)"
    }
}
