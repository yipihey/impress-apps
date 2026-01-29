//
//  SciXLibraryRepository.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import CoreData
import OSLog

/// Repository for managing SciX library entities in Core Data.
/// Provides local cache operations and queues changes for sync.
@MainActor
@Observable
public final class SciXLibraryRepository {

    // MARK: - Singleton

    public static let shared = SciXLibraryRepository()

    // MARK: - Properties

    private let context: NSManagedObjectContext

    public private(set) var libraries: [CDSciXLibrary] = []

    /// Observer for CloudKit remote change notifications
    private var cloudKitObserver: (any NSObjectProtocol)?

    /// Debounce task for CloudKit change handling
    private var debounceTask: Task<Void, Never>?

    /// Last time we reloaded libraries (for debouncing)
    private var lastReloadTime: Date = .distantPast

    /// Track previous library count to avoid redundant logging
    private var previousLibraryCount: Int = -1

    /// Flag to prevent re-entrant reloads
    private var isReloading: Bool = false

    // MARK: - Initialization

    public init(context: NSManagedObjectContext? = nil) {
        self.context = context ?? PersistenceController.shared.viewContext
        setupCloudKitObserver()
        loadLibraries()
    }

    // MARK: - CloudKit Sync

    /// Set up observer for CloudKit remote changes to trigger deduplication
    private func setupCloudKitObserver() {
        cloudKitObserver = NotificationCenter.default.addObserver(
            forName: .cloudKitDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleReload()
            }
        }
    }

    /// Schedule a reload with debouncing (max once per 0.5 seconds)
    private func scheduleReload() {
        // Cancel any pending reload
        debounceTask?.cancel()

        // If we reloaded recently, debounce
        let timeSinceLastReload = Date().timeIntervalSince(lastReloadTime)
        if timeSinceLastReload < 0.5 {
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self.loadLibraries()
                self.lastReloadTime = Date()
            }
        } else {
            // Reload immediately
            loadLibraries()
            lastReloadTime = Date()
        }
    }

    /// Remove the CloudKit observer when no longer needed
    public func removeObserver() {
        if let observer = cloudKitObserver {
            NotificationCenter.default.removeObserver(observer)
            cloudKitObserver = nil
        }
    }

    // MARK: - Loading

    /// Load all cached SciX libraries from Core Data
    public func loadLibraries() {
        // Prevent re-entrant reloads
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        let request = NSFetchRequest<CDSciXLibrary>(entityName: "SciXLibrary")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \CDSciXLibrary.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \CDSciXLibrary.name, ascending: true)
        ]

        do {
            var fetched = try context.fetch(request)

            // Deduplicate by remoteID (CloudKit may sync duplicates from multiple devices)
            fetched = deduplicateByRemoteID(fetched)

            libraries = fetched

            // Only log when count changes to reduce noise
            if libraries.count != previousLibraryCount {
                Logger.scix.debug("SciX libraries: \(self.libraries.count) (was \(self.previousLibraryCount))")
                previousLibraryCount = libraries.count
            }
        } catch {
            Logger.scix.error("Failed to load SciX libraries: \(error)")
            libraries = []
        }
    }

    /// Deduplicate libraries by remoteID, keeping the most recently synced one.
    ///
    /// When CloudKit syncs CDSciXLibrary entities between devices, duplicates can occur
    /// because each device creates entries independently based on the ADS remoteID.
    /// This method identifies duplicates and deletes all but the most recent one.
    private func deduplicateByRemoteID(_ libraries: [CDSciXLibrary]) -> [CDSciXLibrary] {
        // Group libraries by remoteID
        var groupedByRemoteID: [String: [CDSciXLibrary]] = [:]
        for library in libraries {
            let remoteID = library.remoteID
            groupedByRemoteID[remoteID, default: []].append(library)
        }

        var result: [CDSciXLibrary] = []
        var didDeleteDuplicates = false

        for (remoteID, group) in groupedByRemoteID {
            if group.count == 1 {
                // No duplicates for this remoteID
                result.append(group[0])
            } else {
                // Multiple libraries with same remoteID - keep the one with most recent lastSyncDate
                // If no sync date, prefer the one with pending changes, or the oldest dateCreated
                let sorted = group.sorted { lib1, lib2 in
                    // Priority 1: Has pending changes (keep local edits)
                    let hasChanges1 = !(lib1.pendingChanges?.isEmpty ?? true)
                    let hasChanges2 = !(lib2.pendingChanges?.isEmpty ?? true)
                    if hasChanges1 != hasChanges2 {
                        return hasChanges1  // Prefer one with pending changes
                    }

                    // Priority 2: Most recent sync date
                    if let date1 = lib1.lastSyncDate, let date2 = lib2.lastSyncDate {
                        return date1 > date2
                    } else if lib1.lastSyncDate != nil {
                        return true
                    } else if lib2.lastSyncDate != nil {
                        return false
                    }

                    // Priority 3: Oldest dateCreated (was created first)
                    return lib1.dateCreated < lib2.dateCreated
                }

                // Keep the first (best) one
                let keeper = sorted[0]
                result.append(keeper)

                // Delete the rest
                for duplicate in sorted.dropFirst() {
                    Logger.scix.info("Deleting duplicate SciX library: '\(duplicate.name)' (remoteID: \(remoteID), keeping library with UUID: \(keeper.id))")

                    // Move any publications from duplicate to keeper
                    if let publications = duplicate.publications {
                        for publication in publications {
                            publication.scixLibraries?.remove(duplicate)
                            publication.scixLibraries?.insert(keeper)
                        }
                    }

                    // Move any pending changes from duplicate to keeper (merge)
                    if let pendingChanges = duplicate.pendingChanges {
                        for change in pendingChanges {
                            change.library = keeper
                        }
                    }

                    context.delete(duplicate)
                    didDeleteDuplicates = true
                }
            }
        }

        // Save if we deleted duplicates
        if didDeleteDuplicates {
            save()
            Logger.scix.info("Deduplicated SciX libraries, removed \(libraries.count - result.count) duplicates")
        }

        // Re-sort by sortOrder and name
        return result.sorted { lib1, lib2 in
            if lib1.sortOrder != lib2.sortOrder {
                return lib1.sortOrder < lib2.sortOrder
            }
            return (lib1.name) < (lib2.name)
        }
    }

    /// Find a library by remote ID
    public func findLibrary(remoteID: String) -> CDSciXLibrary? {
        libraries.first { $0.remoteID == remoteID }
    }

    /// Find a library by UUID
    public func findLibrary(id: UUID) -> CDSciXLibrary? {
        libraries.first { $0.id == id }
    }

    // MARK: - Cache Operations

    /// Update or create a library from remote metadata
    public func upsertFromRemote(_ metadata: SciXLibraryMetadata) -> CDSciXLibrary {
        let library = findLibrary(remoteID: metadata.id) ?? createLibrary(remoteID: metadata.id)

        library.name = metadata.name
        library.descriptionText = metadata.description
        library.isPublic = metadata.public
        library.permissionLevel = metadata.permission
        library.ownerEmail = metadata.owner
        library.documentCount = Int32(metadata.num_documents)
        library.lastSyncDate = Date()

        // Only set to synced if no pending changes
        if library.pendingChanges?.isEmpty ?? true {
            library.syncState = CDSciXLibrary.SyncState.synced.rawValue
        }

        save()
        loadLibraries()
        return library
    }

    /// Create a new library entity (before syncing to remote)
    public func createLibrary(remoteID: String) -> CDSciXLibrary {
        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = remoteID
        library.name = ""
        library.dateCreated = Date()
        library.syncState = CDSciXLibrary.SyncState.synced.rawValue
        library.permissionLevel = CDSciXLibrary.PermissionLevel.owner.rawValue
        library.sortOrder = Int16(libraries.count)
        return library
    }

    /// Cache publications for a library
    public func cachePapers(_ publications: [CDPublication], forLibrary library: CDSciXLibrary) {
        // Clear existing publications from this library
        library.publications = []

        // Add publications to library
        for publication in publications {
            var scixLibs = publication.scixLibraries ?? []
            scixLibs.insert(library)
            publication.scixLibraries = scixLibs
        }

        library.documentCount = Int32(publications.count)
        library.lastSyncDate = Date()
        library.syncState = CDSciXLibrary.SyncState.synced.rawValue

        save()
    }

    /// Delete a library from local cache
    public func deleteLibrary(_ library: CDSciXLibrary) {
        // Remove library association from publications (don't delete the publications)
        if let publications = library.publications {
            for publication in publications {
                publication.scixLibraries?.remove(library)
            }
        }

        context.delete(library)
        save()
        loadLibraries()
    }

    // MARK: - Pending Changes Queue

    /// Queue adding documents to a library (for later sync)
    public func queueAddDocuments(library: CDSciXLibrary, bibcodes: [String]) {
        guard library.canEdit else {
            Logger.scix.warning("Cannot add to read-only library")
            return
        }

        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.action = CDSciXPendingChange.Action.add.rawValue
        change.bibcodes = bibcodes
        change.dateCreated = Date()
        change.library = library

        library.syncState = CDSciXLibrary.SyncState.pending.rawValue

        save()
    }

    /// Queue removing documents from a library (for later sync)
    public func queueRemoveDocuments(library: CDSciXLibrary, bibcodes: [String]) {
        guard library.canEdit else {
            Logger.scix.warning("Cannot remove from read-only library")
            return
        }

        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.action = CDSciXPendingChange.Action.remove.rawValue
        change.bibcodes = bibcodes
        change.dateCreated = Date()
        change.library = library

        library.syncState = CDSciXLibrary.SyncState.pending.rawValue

        save()
    }

    /// Queue metadata update for a library (for later sync)
    public func queueMetadataUpdate(
        library: CDSciXLibrary,
        name: String? = nil,
        description: String? = nil,
        isPublic: Bool? = nil
    ) {
        guard library.canEdit else {
            Logger.scix.warning("Cannot update read-only library")
            return
        }

        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.action = CDSciXPendingChange.Action.updateMeta.rawValue
        change.metadata = CDSciXPendingChange.MetadataUpdate(
            name: name,
            description: description,
            isPublic: isPublic
        )
        change.dateCreated = Date()
        change.library = library

        library.syncState = CDSciXLibrary.SyncState.pending.rawValue

        // Apply changes locally immediately (optimistic update)
        if let name = name {
            library.name = name
        }
        if let description = description {
            library.descriptionText = description
        }
        if let isPublic = isPublic {
            library.isPublic = isPublic
        }

        save()
        loadLibraries()
    }

    /// Get all pending changes for a library
    public func getPendingChanges(for library: CDSciXLibrary) -> [CDSciXPendingChange] {
        Array(library.pendingChanges ?? [])
            .sorted { $0.dateCreated < $1.dateCreated }
    }

    /// Clear pending changes after successful sync
    public func clearPendingChanges(for library: CDSciXLibrary) {
        guard let changes = library.pendingChanges else { return }

        for change in changes {
            context.delete(change)
        }

        library.syncState = CDSciXLibrary.SyncState.synced.rawValue
        save()
    }

    /// Discard a specific pending change (revert local change)
    public func discardChange(_ change: CDSciXPendingChange) {
        guard let library = change.library else {
            context.delete(change)
            save()
            return
        }

        // Revert local changes if it was a metadata update
        if change.actionEnum == .updateMeta {
            // We'd need to reload from server to fully revert
            // For now just mark as needing sync
            library.syncState = CDSciXLibrary.SyncState.pending.rawValue
        }

        context.delete(change)

        // If no more pending changes, mark as synced
        if library.pendingChanges?.isEmpty ?? true {
            library.syncState = CDSciXLibrary.SyncState.synced.rawValue
        }

        save()
    }

    // MARK: - Library Operations

    /// Add publications to a SciX library (queues for sync)
    public func addPublications(_ publications: [CDPublication], to library: CDSciXLibrary) {
        let bibcodes = publications.compactMap { $0.bibcode }
        guard !bibcodes.isEmpty else { return }

        // Add locally
        for publication in publications {
            var scixLibs = publication.scixLibraries ?? []
            scixLibs.insert(library)
            publication.scixLibraries = scixLibs
        }

        // Queue for sync
        queueAddDocuments(library: library, bibcodes: bibcodes)
    }

    /// Remove publications from a SciX library (queues for sync)
    public func removePublications(_ publications: [CDPublication], from library: CDSciXLibrary) {
        let bibcodes = publications.compactMap { $0.bibcode }
        guard !bibcodes.isEmpty else { return }

        // Remove locally
        for publication in publications {
            publication.scixLibraries?.remove(library)
        }

        // Queue for sync
        queueRemoveDocuments(library: library, bibcodes: bibcodes)
    }

    /// Update library sort order
    public func updateSortOrder(_ orderedLibraries: [CDSciXLibrary]) {
        for (index, library) in orderedLibraries.enumerated() {
            library.sortOrder = Int16(index)
        }
        save()
        loadLibraries()
    }

    // MARK: - Save

    private func save() {
        guard context.hasChanges else { return }

        do {
            try context.save()
        } catch {
            Logger.scix.error("Failed to save SciX library changes: \(error)")
        }
    }
}
