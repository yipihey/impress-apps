//
//  LibraryMigrationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-18.
//

import Foundation
import CoreData
import OSLog

// MARK: - Library Migration Service

/// Migrates libraries from local folder storage to iCloud-only container storage.
///
/// This service handles the transition from the old model (user-selected folders with
/// security-scoped bookmarks) to the new model (app container with CloudKit sync).
///
/// Migration process:
/// 1. Identify libraries with `bookmarkData` or explicit `bibFilePath`/`papersDirectoryPath`
/// 2. For each: resolve the old URL, copy PDFs to the container location
/// 3. Update `CDLinkedFile.relativePath` to reflect new location
/// 4. Clear deprecated attributes (`bookmarkData`, `bibFilePath`, `papersDirectoryPath`)
@MainActor
public final class LibraryMigrationService: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var isMigrating = false
    @Published public private(set) var migrationProgress: (current: Int, total: Int) = (0, 0)
    @Published public private(set) var lastError: Error?

    // MARK: - Dependencies

    private let persistenceController: PersistenceController
    private let fileManager = FileManager.default

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Migration Check

    /// Check if any libraries need migration from local storage to container storage.
    ///
    /// Returns `true` if any library has:
    /// - `bookmarkData` set (security-scoped bookmark for local folder)
    /// - `bibFilePath` pointing outside the app container
    /// - `papersDirectoryPath` pointing outside the app container
    public func needsMigration() -> Bool {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")

        do {
            let libraries = try context.fetch(request)
            return libraries.contains { libraryNeedsMigration($0) }
        } catch {
            Logger.library.errorCapture("Failed to check migration status: \(error.localizedDescription)", category: "migration")
            return false
        }
    }

    /// Get all libraries that need migration.
    public func librariesNeedingMigration() -> [CDLibrary] {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")

        do {
            let libraries = try context.fetch(request)
            return libraries.filter { libraryNeedsMigration($0) }
        } catch {
            Logger.library.errorCapture("Failed to fetch libraries for migration: \(error.localizedDescription)", category: "migration")
            return []
        }
    }

    /// Check if a specific library needs migration.
    private func libraryNeedsMigration(_ library: CDLibrary) -> Bool {
        // Has security-scoped bookmark (old local folder model)
        if library.bookmarkData != nil {
            return true
        }

        // Has explicit path that's outside the app container
        if let bibPath = library.bibFilePath, !isInAppContainer(bibPath) {
            return true
        }

        if let papersPath = library.papersDirectoryPath, !isInAppContainer(papersPath) {
            return true
        }

        return false
    }

    /// Check if a path is within the app's container (Application Support).
    private func isInAppContainer(_ path: String) -> Bool {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let appContainerPath = appSupportURL.appendingPathComponent("imbib").path
        return path.hasPrefix(appContainerPath)
    }

    // MARK: - Migration

    /// Migrate all local libraries to container-based storage.
    ///
    /// - Parameter progress: Optional callback for progress updates (current, total)
    /// - Throws: `MigrationError` if migration fails
    public func migrateLocalLibraries(progress: ((Int, Int) -> Void)? = nil) async throws {
        guard !isMigrating else {
            throw MigrationError.alreadyInProgress
        }

        isMigrating = true
        lastError = nil
        defer { isMigrating = false }

        let librariesToMigrate = librariesNeedingMigration()
        guard !librariesToMigrate.isEmpty else {
            Logger.library.infoCapture("No libraries need migration", category: "migration")
            return
        }

        Logger.library.infoCapture("Starting migration of \(librariesToMigrate.count) libraries", category: "migration")
        migrationProgress = (0, librariesToMigrate.count)

        for (index, library) in librariesToMigrate.enumerated() {
            do {
                try await migrateLibrary(library)
                migrationProgress = (index + 1, librariesToMigrate.count)
                progress?(index + 1, librariesToMigrate.count)
                Logger.library.infoCapture("Migrated library: \(library.displayName)", category: "migration")
            } catch {
                Logger.library.errorCapture("Failed to migrate library \(library.displayName): \(error.localizedDescription)", category: "migration")
                lastError = error
                throw error
            }
        }

        persistenceController.save()
        Logger.library.infoCapture("Migration complete: \(librariesToMigrate.count) libraries migrated", category: "migration")
    }

    /// Migrate a single library to container-based storage.
    private func migrateLibrary(_ library: CDLibrary) async throws {
        // Resolve the old papers directory
        let oldPapersURL = resolveOldPapersDirectory(for: library)

        // Get the new container-based papers URL
        let newPapersURL = library.papersContainerURL

        // Create the new papers directory
        try fileManager.createDirectory(at: newPapersURL, withIntermediateDirectories: true)

        // Copy PDF files if old directory exists
        if let oldURL = oldPapersURL, fileManager.fileExists(atPath: oldURL.path) {
            try copyFiles(from: oldURL, to: newPapersURL, for: library)
        }

        // Update linked file paths
        updateLinkedFilePaths(for: library)

        // Clear deprecated attributes
        library.bookmarkData = nil
        library.bibFilePath = nil
        library.papersDirectoryPath = nil
    }

    /// Resolve the old papers directory URL using bookmark or path.
    private func resolveOldPapersDirectory(for library: CDLibrary) -> URL? {
        #if os(macOS)
        // Try security-scoped bookmark first
        if let bookmarkData = library.bookmarkData {
            var isStale = false
            if let bibURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = bibURL.startAccessingSecurityScopedResource()
                defer { bibURL.stopAccessingSecurityScopedResource() }

                // Papers directory is next to .bib file
                return bibURL.deletingLastPathComponent().appendingPathComponent("Papers")
            }
        }
        #endif

        // Fall back to explicit paths
        if let papersPath = library.papersDirectoryPath {
            return URL(fileURLWithPath: papersPath)
        }

        if let bibPath = library.bibFilePath {
            return URL(fileURLWithPath: bibPath)
                .deletingLastPathComponent()
                .appendingPathComponent("Papers")
        }

        return nil
    }

    /// Copy files from old location to new container location.
    private func copyFiles(from source: URL, to destination: URL, for library: CDLibrary) throws {
        #if os(macOS)
        // Access the source with security scope if we have a bookmark
        var accessingSource = false
        if let bookmarkData = library.bookmarkData {
            var isStale = false
            if let bibURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                accessingSource = bibURL.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if accessingSource {
                source.deletingLastPathComponent().stopAccessingSecurityScopedResource()
            }
        }
        #endif

        let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)

        for fileURL in contents {
            let destinationURL = destination.appendingPathComponent(fileURL.lastPathComponent)

            // Skip if file already exists at destination
            if fileManager.fileExists(atPath: destinationURL.path) {
                Logger.library.debugCapture("File already exists, skipping: \(fileURL.lastPathComponent)", category: "migration")
                continue
            }

            try fileManager.copyItem(at: fileURL, to: destinationURL)
            Logger.library.debugCapture("Copied: \(fileURL.lastPathComponent)", category: "migration")
        }
    }

    /// Update linked file paths to use the new container location.
    private func updateLinkedFilePaths(for library: CDLibrary) {
        guard let publications = library.publications else { return }

        for publication in publications {
            guard let linkedFiles = publication.linkedFiles else { continue }

            for linkedFile in linkedFiles {
                // Update relative path to use Papers/ prefix (relative to container)
                let filename = linkedFile.filename
                let newRelativePath = "Papers/\(filename)"

                if linkedFile.relativePath != newRelativePath {
                    linkedFile.relativePath = newRelativePath
                    Logger.library.debugCapture("Updated path: \(filename)", category: "migration")
                }
            }
        }
    }
}

// MARK: - Migration Error

public enum MigrationError: LocalizedError {
    case alreadyInProgress
    case sourceNotAccessible(URL)
    case copyFailed(URL, Error)

    public var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "Migration is already in progress"
        case .sourceNotAccessible(let url):
            return "Cannot access source directory: \(url.lastPathComponent)"
        case .copyFailed(let url, let error):
            return "Failed to copy \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
