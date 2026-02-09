//
//  SciXLibraryRepository.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import OSLog

/// Repository for managing SciX library entities.
/// Thin wrapper around RustStoreAdapter — all CRUD is delegated to the Rust store.
@MainActor
@Observable
public final class SciXLibraryRepository {

    // MARK: - Singleton

    public static let shared = SciXLibraryRepository()

    // MARK: - Properties

    public private(set) var libraries: [SciXLibrary] = []

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

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - Initialization

    public init() {
        setupCloudKitObserver()
        loadLibraries()
    }

    // MARK: - CloudKit Sync

    /// Set up observer for CloudKit remote changes to trigger reload
    private func setupCloudKitObserver() {
        cloudKitObserver = NotificationCenter.default.addObserver(
            forName: .rustStoreDidMutate,
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

    /// Load all cached SciX libraries from the Rust store
    public func loadLibraries() {
        // Prevent re-entrant reloads
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        libraries = store.listScixLibraries()

        // Only log when count changes to reduce noise
        if libraries.count != previousLibraryCount {
            Logger.scix.debug("SciX libraries: \(self.libraries.count) (was \(self.previousLibraryCount))")
            previousLibraryCount = libraries.count
        }
    }

    /// Find a library by remote ID
    public func findLibrary(remoteID: String) -> SciXLibrary? {
        libraries.first { $0.remoteID == remoteID }
    }

    /// Find a library by UUID
    public func findLibrary(id: UUID) -> SciXLibrary? {
        libraries.first { $0.id == id }
    }

    // MARK: - Cache Operations

    /// Update or create a library from remote metadata
    @discardableResult
    public func upsertFromRemote(_ metadata: SciXLibraryMetadata) -> SciXLibrary? {
        if let existing = findLibrary(remoteID: metadata.id) {
            // Update existing — use store field updates
            store.updateField(id: existing.id, field: "name", value: metadata.name)
            store.updateField(id: existing.id, field: "description", value: metadata.description)
            store.updateBoolField(id: existing.id, field: "isPublic", value: metadata.public)
            store.updateField(id: existing.id, field: "permissionLevel", value: metadata.permission)
            store.updateField(id: existing.id, field: "ownerEmail", value: metadata.owner)
            store.updateIntField(id: existing.id, field: "documentCount", value: Int64(metadata.num_documents))
            store.updateIntField(id: existing.id, field: "lastSyncDate", value: Int64(Date().timeIntervalSince1970 * 1000))
            loadLibraries()
            return findLibrary(remoteID: metadata.id)
        } else {
            // Create new
            let library = store.createScixLibrary(
                remoteId: metadata.id,
                name: metadata.name,
                description: metadata.description,
                isPublic: metadata.public,
                permissionLevel: metadata.permission,
                ownerEmail: metadata.owner
            )
            loadLibraries()
            return library
        }
    }

    /// Cache publication IDs for a library by adding them to the SciX library
    public func cachePapers(_ publicationIDs: [UUID], forLibraryID libraryID: UUID) {
        store.addToScixLibrary(publicationIds: publicationIDs, scixLibraryId: libraryID)
        loadLibraries()
    }

    /// Delete a library from local cache
    public func deleteLibrary(id: UUID) {
        store.deleteItem(id: id)
        loadLibraries()
    }

    // MARK: - Library Operations

    /// Add publications to a SciX library
    public func addPublications(_ publicationIDs: [UUID], to libraryID: UUID) {
        guard !publicationIDs.isEmpty else { return }
        store.addToScixLibrary(publicationIds: publicationIDs, scixLibraryId: libraryID)
    }

    /// Remove publications from a SciX library (by deleting and re-adding remaining)
    public func removePublications(_ publicationIDs: [UUID], from libraryID: UUID) {
        guard !publicationIDs.isEmpty else { return }
        // Remove by deleting association — the store handles this
        for pubID in publicationIDs {
            store.removeFromCollection(publicationIds: [pubID], collectionId: libraryID)
        }
    }

    /// Update library sort order
    public func updateSortOrder(_ orderedLibraries: [SciXLibrary]) {
        for (index, library) in orderedLibraries.enumerated() {
            store.updateIntField(id: library.id, field: "sortOrder", value: Int64(index))
        }
        loadLibraries()
    }
}
