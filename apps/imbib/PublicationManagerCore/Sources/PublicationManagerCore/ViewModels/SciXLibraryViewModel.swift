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
    public private(set) var libraries: [CDSciXLibrary] = []

    /// Currently selected library (for detail view)
    public var selectedLibrary: CDSciXLibrary?

    /// Whether a sync operation is in progress
    public private(set) var isLoading = false

    /// Error from last operation
    public private(set) var lastError: SciXLibraryError?

    /// Show push confirmation sheet
    public var showPushConfirmation = false

    /// Pending changes for confirmation (populated before push)
    public private(set) var pendingPushChanges: [CDSciXPendingChange] = []

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
    public func refreshLibraryPapers(_ library: CDSciXLibrary) async {
        isLoading = true
        lastError = nil

        do {
            try await syncManager.pullLibraryPapers(libraryID: library.remoteID)
            // Repository updates are automatic via Core Data
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
    public func selectLibrary(_ library: CDSciXLibrary?, loadPapers: Bool = true) async {
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

    /// Add papers to a library
    public func addPapers(_ publications: [CDPublication], to library: CDSciXLibrary) {
        repository.addPublications(publications, to: library)
        libraries = repository.libraries
    }

    /// Remove papers from a library
    public func removePapers(_ publications: [CDPublication], from library: CDSciXLibrary) {
        repository.removePublications(publications, from: library)
        libraries = repository.libraries
    }

    // MARK: - Update Metadata

    /// Update library metadata
    public func updateMetadata(
        library: CDSciXLibrary,
        name: String? = nil,
        description: String? = nil,
        isPublic: Bool? = nil
    ) {
        repository.queueMetadataUpdate(
            library: library,
            name: name,
            description: description,
            isPublic: isPublic
        )
        libraries = repository.libraries
    }

    // MARK: - Push/Sync

    /// Prepare pending changes for push confirmation
    public func preparePush(for library: CDSciXLibrary) async {
        isLoading = true

        pendingPushChanges = await syncManager.preparePush(for: library)

        // Check for conflicts
        do {
            conflicts = try await syncManager.detectConflicts(for: library)
        } catch {
            conflicts = []
            Logger.scix.error("Conflict detection failed: \(error)")
        }

        isLoading = false
        showPushConfirmation = !pendingPushChanges.isEmpty
    }

    /// Confirm and execute push
    public func confirmPush(for library: CDSciXLibrary) async {
        isLoading = true
        showPushConfirmation = false

        do {
            lastPushResult = try await syncManager.pushPendingChanges(for: library)
            pendingPushChanges = []
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
        pendingPushChanges = []
        conflicts = []
    }

    /// Discard a specific pending change
    public func discardChange(_ change: CDSciXPendingChange) {
        repository.discardChange(change)
        pendingPushChanges = pendingPushChanges.filter { $0.id != change.id }
    }

    // MARK: - Delete Library

    /// Delete a library (local cache and optionally remote)
    public func deleteLibrary(_ library: CDSciXLibrary, deleteRemote: Bool = false) async throws {
        if deleteRemote {
            guard library.permissionLevelEnum == .owner else {
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

        repository.deleteLibrary(library)
        libraries = repository.libraries
    }

    // MARK: - Permissions

    /// Fetch permissions for a library
    public func fetchPermissions(for library: CDSciXLibrary) async throws -> [SciXPermission] {
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
        for library: CDSciXLibrary,
        email: String,
        level: CDSciXLibrary.PermissionLevel
    ) async throws {
        guard library.canManagePermissions else {
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
    public func transferOwnership(for library: CDSciXLibrary, toEmail: String) async throws {
        guard library.permissionLevelEnum == .owner else {
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
    public var hasAnyPendingChanges: Bool {
        libraries.contains { $0.hasPendingChanges }
    }

    /// Count of libraries with pending changes
    public var pendingChangesCount: Int {
        libraries.filter { $0.hasPendingChanges }.count
    }

    /// Clear error state
    public func clearError() {
        lastError = nil
    }
}
