//
//  SciXLibraryViewModel.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import Combine
import OSLog

/// ViewModel for managing SciX online libraries.
/// Coordinates between UI, repository, sync manager, and API service.
@MainActor
@Observable
public final class SciXLibraryViewModel {

    // MARK: - Published State

    /// All cached SciX libraries
    public private(set) var libraries: [SciXLibrary] = []

    /// Currently selected library (for detail view)
    public var selectedLibrary: SciXLibrary?

    /// Whether a sync operation is in progress
    public private(set) var isLoading = false

    /// Error from last operation
    public private(set) var lastError: SciXLibraryError?

    /// Show push confirmation sheet
    public var showPushConfirmation = false

    /// Result of last push (for displaying success/failure)
    public private(set) var lastPushResult: SciXPushResult?

    /// Detected conflicts (populated before push)
    public private(set) var conflicts: [SciXSyncConflict] = []

    // MARK: - Dependencies

    private let repository: SciXLibraryRepository
    private let syncManager: SciXSyncManager
    private let service: SciXLibraryService

    // MARK: - Initialization

    public init(
        repository: SciXLibraryRepository = .shared,
        syncManager: SciXSyncManager = .shared,
        service: SciXLibraryService = .shared
    ) {
        self.repository = repository
        self.syncManager = syncManager
        self.service = service
        self.libraries = repository.libraries
    }

    // MARK: - Refresh

    /// Refresh libraries from SciX server
    public func refresh() async {
        isLoading = true
        lastError = nil

        do {
            let _ = try await syncManager.pullLibraries()
            libraries = repository.libraries
            Logger.scix.info("Refreshed \(self.libraries.count) libraries")
        } catch let error as SciXLibraryError {
            lastError = error
            Logger.scix.error("Refresh failed: \(error.localizedDescription)")
        } catch {
            lastError = .networkError(error)
            Logger.scix.error("Refresh failed: \(error)")
        }

        isLoading = false
    }

    /// Refresh papers for a specific library
    public func refreshLibraryPapers(_ library: SciXLibrary) async {
        isLoading = true
        lastError = nil

        do {
            try await syncManager.pullLibraryPapers(libraryID: library.remoteID)
            Logger.scix.info("Refreshed papers for \(library.name)")
        } catch let error as SciXLibraryError {
            lastError = error
            Logger.scix.error("Refresh papers failed: \(error.localizedDescription)")
        } catch {
            lastError = .networkError(error)
            Logger.scix.error("Refresh papers failed: \(error)")
        }

        isLoading = false
    }

    // MARK: - Library Selection

    /// Select a library and optionally load its papers
    public func selectLibrary(_ library: SciXLibrary?, loadPapers: Bool = true) async {
        selectedLibrary = library

        guard let library = library, loadPapers else { return }

        // Check if we need to refresh papers (e.g., first time or stale)
        let needsRefresh = library.lastSyncDate == nil ||
            Date().timeIntervalSince(library.lastSyncDate ?? .distantPast) > 300 // 5 minutes

        if needsRefresh {
            await refreshLibraryPapers(library)
        }
    }

    // MARK: - Create Library

    /// Create a new SciX library
    public func createLibrary(
        name: String,
        description: String? = nil,
        isPublic: Bool = false,
        bibcodes: [String]? = nil
    ) async throws {
        isLoading = true
        lastError = nil

        do {
            let response = try await service.createLibrary(
                name: name,
                description: description,
                isPublic: isPublic,
                bibcodes: bibcodes
            )

            // Add to local cache
            let library = repository.upsertFromRemote(SciXLibraryMetadata(
                id: response.id,
                name: response.name,
                description: response.description,
                permission: "owner",
                num_documents: bibcodes?.count ?? 0,
                date_created: ISO8601DateFormatter().string(from: Date()),
                date_last_modified: ISO8601DateFormatter().string(from: Date()),
                public: isPublic,
                owner: nil
            ))

            libraries = repository.libraries
            selectedLibrary = library

            Logger.scix.info("Created library: \(name)")
        } catch let error as SciXLibraryError {
            lastError = error
            throw error
        } catch {
            lastError = .networkError(error)
            throw SciXLibraryError.networkError(error)
        }

        isLoading = false
    }

    // MARK: - Add/Remove Papers

    /// Add papers to a library by publication IDs
    public func addPapers(_ publicationIDs: [UUID], to library: SciXLibrary) {
        repository.addPublications(publicationIDs, to: library.id)
        libraries = repository.libraries
    }

    /// Remove papers from a library by publication IDs
    public func removePapers(_ publicationIDs: [UUID], from library: SciXLibrary) {
        repository.removePublications(publicationIDs, from: library.id)
        libraries = repository.libraries
    }

    // MARK: - Update Metadata

    /// Update library metadata directly via RustStoreAdapter
    public func updateMetadata(
        library: SciXLibrary,
        name: String? = nil,
        description: String? = nil,
        isPublic: Bool? = nil
    ) {
        let store = RustStoreAdapter.shared
        if let name = name {
            store.updateField(id: library.id, field: "name", value: name)
        }
        if let description = description {
            store.updateField(id: library.id, field: "description", value: description)
        }
        if let isPublic = isPublic {
            store.updateBoolField(id: library.id, field: "isPublic", value: isPublic)
        }
        libraries = repository.libraries
    }

    // MARK: - Push/Sync

    /// Prepare pending changes for push confirmation.
    /// With the Rust store, push is simplified -- no pending change queue.
    public func preparePush(for library: SciXLibrary) async {
        isLoading = true

        // Check for conflicts
        do {
            conflicts = try await syncManager.detectConflicts(for: library.id)
        } catch {
            conflicts = []
            Logger.scix.error("Conflict detection failed: \(error)")
        }

        isLoading = false
        showPushConfirmation = !conflicts.isEmpty
    }

    /// Confirm and execute push
    public func confirmPush(for library: SciXLibrary) async {
        isLoading = true
        showPushConfirmation = false

        do {
            lastPushResult = try await syncManager.pushPendingChanges(for: library.id)
            conflicts = []
            libraries = repository.libraries

            Logger.scix.info("Push completed: \(self.lastPushResult?.changesApplied ?? 0) changes applied")
        } catch let error as SciXLibraryError {
            lastError = error
            Logger.scix.error("Push failed: \(error.localizedDescription)")
        } catch {
            lastError = .networkError(error)
            Logger.scix.error("Push failed: \(error)")
        }

        isLoading = false
    }

    /// Cancel push and discard pending changes
    public func cancelPush() {
        showPushConfirmation = false
        conflicts = []
    }

    // MARK: - Delete Library

    /// Delete a library (local cache and optionally remote)
    public func deleteLibrary(_ library: SciXLibrary, deleteRemote: Bool = false) async throws {
        if deleteRemote {
            guard SciXPermissionLevel(rawValue: library.permissionLevel) == .owner else {
                throw SciXLibraryError.forbidden
            }

            isLoading = true
            do {
                try await service.deleteLibrary(id: library.remoteID)
            } catch let error as SciXLibraryError {
                isLoading = false
                lastError = error
                throw error
            } catch {
                isLoading = false
                lastError = .networkError(error)
                throw SciXLibraryError.networkError(error)
            }
            isLoading = false
        }

        // Clear selection if we're deleting the selected library
        if selectedLibrary?.id == library.id {
            selectedLibrary = nil
        }

        repository.deleteLibrary(id: library.id)
        libraries = repository.libraries
    }

    // MARK: - Permissions

    /// Fetch permissions for a library
    public func fetchPermissions(for library: SciXLibrary) async throws -> [SciXPermission] {
        isLoading = true
        defer { isLoading = false }

        do {
            return try await service.fetchPermissions(libraryID: library.remoteID)
        } catch let error as SciXLibraryError {
            lastError = error
            throw error
        } catch {
            lastError = .networkError(error)
            throw SciXLibraryError.networkError(error)
        }
    }

    /// Set permission for a user on a library
    public func setPermission(
        for library: SciXLibrary,
        email: String,
        level: SciXPermissionLevel
    ) async throws {
        let canManage = SciXPermissionLevel(rawValue: library.permissionLevel) == .owner ||
                        SciXPermissionLevel(rawValue: library.permissionLevel) == .admin
        guard canManage else {
            throw SciXLibraryError.forbidden
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await service.setPermission(libraryID: library.remoteID, email: email, permission: level)
            Logger.scix.info("Set permission \(level.rawValue) for \(email)")
        } catch let error as SciXLibraryError {
            lastError = error
            throw error
        } catch {
            lastError = .networkError(error)
            throw SciXLibraryError.networkError(error)
        }
    }

    /// Transfer library ownership
    public func transferOwnership(for library: SciXLibrary, toEmail: String) async throws {
        guard SciXPermissionLevel(rawValue: library.permissionLevel) == .owner else {
            throw SciXLibraryError.forbidden
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await service.transferOwnership(libraryID: library.remoteID, toEmail: toEmail)
            // Refresh to get updated permission
            await refresh()
            Logger.scix.info("Transferred ownership to \(toEmail)")
        } catch let error as SciXLibraryError {
            lastError = error
            throw error
        } catch {
            lastError = .networkError(error)
            throw SciXLibraryError.networkError(error)
        }
    }

    // MARK: - Helpers

    /// Whether there are any pending changes across all libraries
    /// With Rust store, pending changes are not tracked per-library.
    public var hasAnyPendingChanges: Bool {
        false
    }

    /// Count of libraries with pending changes
    public var pendingChangesCount: Int {
        0
    }

    /// Clear error state
    public func clearError() {
        lastError = nil
    }
}
