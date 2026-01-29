//
//  LibraryManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData
import OSLog

#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif

// MARK: - Library Manager

/// Manages multiple publication libraries.
///
/// Each library represents a separate .bib file and associated PDF collection.
/// Libraries can be opened, closed, and switched between. The active library
/// determines which publications and smart searches are shown.
@MainActor
@Observable
public final class LibraryManager {

    // MARK: - Published State

    /// All known libraries (excludes system libraries like Exploration)
    public private(set) var libraries: [CDLibrary] = []

    /// Currently active library
    public private(set) var activeLibrary: CDLibrary?

    /// The Exploration system library (for references/citations exploration)
    public private(set) var explorationLibrary: CDLibrary?

    /// Recently opened libraries (for menu)
    public var recentLibraries: [CDLibrary] {
        libraries
            .filter { $0.dateLastOpened != nil }
            .sorted { ($0.dateLastOpened ?? .distantPast) > ($1.dateLastOpened ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Dependencies

    private let persistenceController: PersistenceController

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

    /// Observer for reset notifications
    private var resetObserver: (any NSObjectProtocol)?

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
        setupCloudKitObserver()
        setupResetObserver()
        loadLibraries()

        // Load default library set if none exist (first run)
        if libraries.isEmpty {
            Logger.library.infoCapture("No libraries found, loading default set", category: "library")
            do {
                try DefaultLibrarySetManager.shared.loadDefaultSet()
                loadLibraries()  // Reload after import
            } catch {
                // Fallback: create empty library if default set fails
                Logger.library.warningCapture("Failed to load default set, creating fallback library: \(error.localizedDescription)", category: "library")
                _ = createLibrary(name: "My Library")
            }
        }
    }

    // MARK: - CloudKit Sync

    /// Set up observer for CloudKit remote changes
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

    /// Set up observer for reset notifications
    private func setupResetObserver() {
        resetObserver = NotificationCenter.default.addObserver(
            forName: .appDidResetToFirstRun,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidateCaches()
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

    // MARK: - Library Loading

    /// Load all libraries from Core Data
    public func loadLibraries() {
        // Prevent re-entrant reloads
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        // Clean up local-only libraries that synced from other devices
        cleanupForeignLocalOnlyLibraries()

        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.sortDescriptors = [
            NSSortDescriptor(key: "sortOrder", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]

        do {
            let allLibraries = try persistenceController.viewContext.fetch(request)

            // Separate system libraries from user libraries
            // Exclude local-only libraries from other devices (shouldn't exist after cleanup, but be safe)
            libraries = allLibraries.filter { !$0.isSystemLibrary && !($0.isLocalOnly && $0.deviceIdentifier != Self.currentDeviceIdentifier) }

            // Find exploration library for THIS device only
            explorationLibrary = allLibraries.first {
                $0.isSystemLibrary &&
                $0.name == "Exploration" &&
                $0.deviceIdentifier == Self.currentDeviceIdentifier
            }

            // Only log when count changes to reduce noise
            if libraries.count != previousLibraryCount {
                Logger.library.infoCapture("Libraries: \(libraries.count) (was \(previousLibraryCount))", category: "library")
                previousLibraryCount = libraries.count
            }

            // Set active to default library if not set
            if activeLibrary == nil {
                activeLibrary = libraries.first { $0.isDefault } ?? libraries.first
                if let active = activeLibrary {
                    Logger.library.infoCapture("Set active library: \(active.displayName)", category: "library")
                }
            }
        } catch {
            Logger.library.errorCapture("Failed to load libraries: \(error.localizedDescription)", category: "library")
            libraries = []
        }
    }

    /// Invalidate all cached state after a reset.
    ///
    /// Call this after `FirstRunManager.resetToFirstRun()` to clear stale references
    /// before the app restarts or re-initializes.
    public func invalidateCaches() {
        Logger.library.infoCapture("Invalidating LibraryManager caches", category: "library")
        libraries = []
        activeLibrary = nil
        explorationLibrary = nil
        previousLibraryCount = -1
    }

    // MARK: - Library Management

    /// Create a new library with iCloud storage.
    ///
    /// Libraries are stored in the app container and synced via CloudKit.
    /// This eliminates sandbox complexity from user-selected folders.
    ///
    /// - Parameter name: Display name for the library
    /// - Returns: The created CDLibrary entity
    @discardableResult
    public func createLibrary(name: String) -> CDLibrary {
        Logger.library.infoCapture("Creating library: \(name)", category: "library")

        let context = persistenceController.viewContext

        let library = CDLibrary(context: context)
        library.id = UUID()
        library.name = name
        library.dateCreated = Date()
        library.isDefault = libraries.isEmpty  // First library is default

        // Create the Papers directory in the app container
        let papersURL = library.papersContainerURL
        do {
            try FileManager.default.createDirectory(at: papersURL, withIntermediateDirectories: true)
            Logger.library.debugCapture("Created Papers directory: \(papersURL.path)", category: "library")
        } catch {
            Logger.library.warningCapture("Failed to create Papers directory: \(error.localizedDescription)", category: "library")
        }

        persistenceController.save()
        loadLibraries()

        Logger.library.infoCapture("Created library '\(name)' with ID: \(library.id)", category: "library")
        return library
    }

    /// Legacy method for backward compatibility.
    @available(*, deprecated, message: "Use createLibrary(name:) instead - local folder storage is no longer supported")
    @discardableResult
    public func createLibrary(
        name: String,
        bibFileURL: URL?,
        papersDirectoryURL: URL?
    ) -> CDLibrary {
        // Ignore file URLs and just create a container-based library
        return createLibrary(name: name)
    }

    /// Set the active library
    public func setActive(_ library: CDLibrary) {
        Logger.library.infoCapture("Switching to library: \(library.displayName)", category: "library")

        library.dateLastOpened = Date()
        activeLibrary = library
        persistenceController.save()

        // Post notification for UI updates
        NotificationCenter.default.post(name: .activeLibraryChanged, object: library)
    }

    /// Close a library (remove from list but don't delete data)
    public func closeLibrary(_ library: CDLibrary) {
        Logger.library.infoCapture("Closing library: \(library.displayName)", category: "library")

        if activeLibrary?.id == library.id {
            // Switch to another library
            activeLibrary = libraries.first { $0.id != library.id }
            if let newActive = activeLibrary {
                Logger.library.debugCapture("Switched to library: \(newActive.displayName)", category: "library")
            }
        }

        persistenceController.viewContext.delete(library)
        persistenceController.save()
        loadLibraries()
    }

    /// Delete a library and optionally its files.
    ///
    /// With iCloud-only storage, files are stored in the app container under
    /// `Libraries/{UUID}/`. Setting `deleteFiles: true` removes this directory.
    public func deleteLibrary(_ library: CDLibrary, deleteFiles: Bool = false) throws {
        Logger.library.warningCapture("Deleting library: \(library.displayName), deleteFiles: \(deleteFiles)", category: "library")

        if deleteFiles {
            // Delete the library's container directory (includes Papers/)
            let containerURL = library.containerURL
            if FileManager.default.fileExists(atPath: containerURL.path) {
                try? FileManager.default.removeItem(at: containerURL)
                Logger.library.debugCapture("Deleted library container: \(containerURL.path)", category: "library")
            }
        }

        closeLibrary(library)
    }

    /// Set a library as the default
    public func setDefault(_ library: CDLibrary) {
        Logger.library.infoCapture("Setting default library: \(library.displayName)", category: "library")

        // Clear existing default
        for lib in libraries {
            lib.isDefault = (lib.id == library.id)
        }
        persistenceController.save()
    }

    /// Rename a library
    public func rename(_ library: CDLibrary, to name: String) {
        Logger.library.infoCapture("Renaming library '\(library.displayName)' to '\(name)'", category: "library")
        library.name = name
        persistenceController.save()
    }

    /// Reorder libraries (for drag-and-drop in sidebar)
    public func moveLibraries(from indices: IndexSet, to destination: Int) {
        Logger.library.infoCapture("Moving libraries from \(indices) to \(destination)", category: "library")

        var reordered = libraries
        reordered.move(fromOffsets: indices, toOffset: destination)

        // Update sortOrder for all libraries
        for (index, library) in reordered.enumerated() {
            library.sortOrder = Int16(index)
        }

        libraries = reordered
        persistenceController.save()
    }

    // MARK: - Library Lookup

    /// Find a library by ID
    public func find(id: UUID) -> CDLibrary? {
        libraries.first { $0.id == id }
    }

    /// Get the default library, creating one if needed
    public func getOrCreateDefaultLibrary() -> CDLibrary {
        if let defaultLib = libraries.first(where: { $0.isDefault }) {
            return defaultLib
        }

        if let firstLib = libraries.first {
            firstLib.isDefault = true
            persistenceController.save()
            return firstLib
        }

        // Create a default library
        return createLibrary(name: "My Library")
    }

    // MARK: - Save Library (Inbox Triage)

    /// Get or create the Save library for Inbox triage.
    ///
    /// The Save library is used by the "S" keyboard shortcut in the Inbox.
    /// If a user-configured save library is set in preferences, that library is used.
    /// Otherwise, if no save library exists, one is created automatically on first use.
    @discardableResult
    public func getOrCreateSaveLibrary() -> CDLibrary {
        // Check if user has configured a specific save library (synced across devices)
        if let configuredID = SyncedSettingsStore.shared.string(forKey: .inboxSaveLibraryID),
           let uuid = UUID(uuidString: configuredID),
           let configuredLibrary = libraries.first(where: { $0.id == uuid && !$0.isDeleted }) {
            Logger.library.debugCapture("Using user-configured save library: \(configuredLibrary.displayName)", category: "library")
            return configuredLibrary
        }

        // Return existing save library if available (validate it's not deleted)
        if let saveLib = libraries.first(where: { $0.isSaveLibrary && !$0.isDeleted }) {
            return saveLib
        }

        // Query database directly to avoid stale cache issues
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isSaveLibrary == YES")
        request.fetchLimit = 1

        if let existingSave = try? context.fetch(request).first {
            Logger.library.debugCapture("Found existing Save library in database", category: "library")
            loadLibraries()  // Refresh cache
            return existingSave
        }

        // Create new Save library
        Logger.library.infoCapture("Creating Save library for Inbox triage", category: "library")

        let library = CDLibrary(context: context)
        library.id = UUID()
        library.name = "Save"
        library.isSaveLibrary = true
        library.isDefault = false
        library.dateCreated = Date()
        library.sortOrder = Int16(libraries.count)  // After existing libraries

        persistenceController.save()
        loadLibraries()

        Logger.library.infoCapture("Created Save library with ID: \(library.id)", category: "library")
        return library
    }

    /// Get the Save library (for UI display purposes)
    public var saveLibrary: CDLibrary? {
        libraries.first { $0.isSaveLibrary }
    }

    // MARK: - Dismissed Library (Inbox Triage)

    /// Get or create the Dismissed library for Inbox triage.
    ///
    /// The Dismissed library is used by the "D" keyboard shortcut in the Inbox.
    /// Papers moved here are considered "dismissed" but not deleted.
    /// If no dismissed library exists, one is created automatically on first use.
    @discardableResult
    public func getOrCreateDismissedLibrary() -> CDLibrary {
        // Return existing dismissed library if available
        if let dismissedLib = dismissedLibrary {
            return dismissedLib
        }

        // Create new Dismissed library
        Logger.library.infoCapture("Creating Dismissed library for Inbox triage", category: "library")

        let context = persistenceController.viewContext
        let library = CDLibrary(context: context)
        library.id = UUID()
        library.name = "Dismissed"
        library.isDismissedLibrary = true
        library.isDefault = false
        library.dateCreated = Date()
        library.sortOrder = Int16.max - 1  // Near the bottom (before Exploration)

        persistenceController.save()
        loadLibraries()

        Logger.library.infoCapture("Created Dismissed library with ID: \(library.id)", category: "library")
        return library
    }

    /// Get the Dismissed library (for UI display purposes)
    public var dismissedLibrary: CDLibrary? {
        libraries.first { $0.isDismissedLibrary }
    }

    /// Empty the Dismissed library (permanently delete all papers)
    public func emptyDismissedLibrary() {
        guard let dismissed = dismissedLibrary else { return }

        Logger.library.warningCapture("Emptying Dismissed library", category: "library")

        let context = persistenceController.viewContext

        // Delete all publications that are ONLY in the Dismissed library
        if let publications = dismissed.publications {
            for pub in publications {
                let otherLibraries = (pub.libraries ?? []).filter { !$0.isDismissedLibrary }
                if otherLibraries.isEmpty {
                    // Paper is only in Dismissed - delete it
                    context.delete(pub)
                } else {
                    // Paper is in other libraries - just remove from Dismissed
                    pub.removeFromLibrary(dismissed)
                }
            }
        }

        persistenceController.save()
        loadLibraries()
    }

    // MARK: - Last Search Collection (ADR-016)

    /// Get or create the "Last Search" collection for the active library.
    ///
    /// This is a system collection that holds ad-hoc search results. Each library
    /// has its own "Last Search" collection. Results are replaced on each new search.
    public func getOrCreateLastSearchCollection() -> CDCollection? {
        guard let library = activeLibrary else {
            Logger.library.warningCapture("No active library for Last Search collection", category: "library")
            return nil
        }

        // Return existing collection if available
        if let collection = library.lastSearchCollection {
            return collection
        }

        // Create new Last Search collection
        Logger.library.infoCapture("Creating Last Search collection for: \(library.displayName)", category: "library")

        let context = persistenceController.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = "Last Search"
        collection.isSystemCollection = true
        collection.isSmartSearchResults = false
        collection.isSmartCollection = false
        collection.owningLibrary = library
        library.lastSearchCollection = collection

        persistenceController.save()

        return collection
    }

    /// Clear the Last Search collection (remove papers only in this collection)
    public func clearLastSearchCollection() {
        guard let collection = activeLibrary?.lastSearchCollection else { return }

        Logger.library.debugCapture("Clearing Last Search collection", category: "library")

        let context = persistenceController.viewContext

        // Get publications only in this collection
        guard let publications = collection.publications else { return }

        for pub in publications {
            // Check if this paper is ONLY in Last Search (not in other collections/smart searches)
            let otherCollections = (pub.collections ?? []).filter { $0.id != collection.id }
            if otherCollections.isEmpty {
                // Paper is only in Last Search - delete it
                context.delete(pub)
            }
        }

        // Clear the collection's publication set
        collection.publications = []
        persistenceController.save()
    }

    // MARK: - Exploration Library

    /// Get or create the Exploration system library.
    ///
    /// This is a system library that holds exploration results (references/citations).
    /// Collections in this library are created when exploring a paper's references or citations.
    ///
    /// **Note:** Exploration libraries are local-only and do not sync via CloudKit.
    /// Each device maintains its own exploration library independently.
    @discardableResult
    public func getOrCreateExplorationLibrary() -> CDLibrary {
        // Return existing if available (must match this device)
        if let lib = explorationLibrary,
           lib.deviceIdentifier == Self.currentDeviceIdentifier {
            return lib
        }

        // Check for existing exploration library for this device
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(
            format: "isSystemLibrary == YES AND name == %@ AND deviceIdentifier == %@",
            "Exploration",
            Self.currentDeviceIdentifier
        )
        request.fetchLimit = 1

        if let existing = try? context.fetch(request).first {
            explorationLibrary = existing
            return existing
        }

        // Create new Exploration library for this device
        Logger.library.infoCapture("Creating Exploration system library (local-only)", category: "library")

        let library = CDLibrary(context: context)
        library.id = UUID()
        library.name = "Exploration"
        library.isSystemLibrary = true
        library.isDefault = false
        library.dateCreated = Date()
        library.sortOrder = Int16.max  // Always at the end
        library.isLocalOnly = true
        library.deviceIdentifier = Self.currentDeviceIdentifier

        persistenceController.save()

        explorationLibrary = library
        return library
    }

    /// Unique identifier for the current device.
    ///
    /// Used to distinguish local-only libraries (like Exploration) from those
    /// that may have synced from other devices via CloudKit.
    private static var currentDeviceIdentifier: String {
        #if os(iOS)
        // Use vendor identifier on iOS (persists across app reinstalls for same vendor)
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            return vendorID
        }
        return UIDevice.current.name
        #else
        // Use hardware UUID on macOS
        if let uuid = getMacHardwareUUID() {
            return uuid
        }
        return Host.current().localizedName ?? "unknown-mac"
        #endif
    }

    #if os(macOS)
    /// Get the hardware UUID on macOS.
    private static func getMacHardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0,
              let serialNumberAsCFString = IORegistryEntryCreateCFProperty(
                  platformExpert,
                  kIOPlatformUUIDKey as CFString,
                  kCFAllocatorDefault,
                  0
              )?.takeUnretainedValue() as? String else {
            return nil
        }
        return serialNumberAsCFString
    }
    #endif

    // MARK: - Local-Only Cleanup

    /// Clean up local-only libraries that synced from other devices.
    ///
    /// When CloudKit syncs, local-only libraries (like Exploration) from other devices
    /// may appear in the local database. This method deletes them since they're not
    /// relevant to the current device.
    ///
    /// Call this on app launch and after CloudKit sync notifications.
    public func cleanupForeignLocalOnlyLibraries() {
        let context = persistenceController.viewContext

        // Find local-only libraries that don't belong to this device
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(
            format: "isLocalOnly == YES AND deviceIdentifier != %@",
            Self.currentDeviceIdentifier
        )

        do {
            let foreignLibraries = try context.fetch(request)

            if foreignLibraries.isEmpty {
                return
            }

            Logger.library.infoCapture(
                "Cleaning up \(foreignLibraries.count) local-only libraries from other devices",
                category: "library"
            )

            for library in foreignLibraries {
                // Delete all associated data
                deleteLibraryContents(library)
                context.delete(library)
            }

            persistenceController.save()
        } catch {
            Logger.library.errorCapture(
                "Failed to cleanup foreign local-only libraries: \(error.localizedDescription)",
                category: "library"
            )
        }
    }

    /// Delete all contents of a library (collections, smart searches, publications).
    private func deleteLibraryContents(_ library: CDLibrary) {
        let context = persistenceController.viewContext

        // Delete smart searches
        if let smartSearches = library.smartSearches {
            for search in smartSearches {
                if let collection = search.resultCollection {
                    context.delete(collection)
                }
                context.delete(search)
            }
        }

        // Delete collections and orphaned publications
        if let collections = library.collections {
            for collection in collections {
                if let publications = collection.publications {
                    for pub in publications {
                        // Only delete if not in any other library
                        let otherLibraries = (pub.libraries ?? []).filter { $0.id != library.id }
                        if otherLibraries.isEmpty {
                            context.delete(pub)
                        }
                    }
                }
                context.delete(collection)
            }
        }

        // Delete any remaining publications only in this library
        if let publications = library.publications {
            for pub in publications {
                let otherLibraries = (pub.libraries ?? []).filter { $0.id != library.id }
                if otherLibraries.isEmpty {
                    context.delete(pub)
                }
            }
        }
    }

    /// Delete all collections in the Exploration library
    public func clearExplorationLibrary() {
        guard let library = explorationLibrary else { return }

        Logger.library.infoCapture("Clearing Exploration library", category: "library")

        let context = persistenceController.viewContext

        // Delete all collections and their papers
        if let collections = library.collections {
            for collection in collections {
                // Delete papers that are only in exploration collections
                if let publications = collection.publications {
                    for pub in publications {
                        let otherCollections = (pub.collections ?? []).filter {
                            $0.library?.isSystemLibrary != true
                        }
                        if otherCollections.isEmpty {
                            context.delete(pub)
                        }
                    }
                }
                context.delete(collection)
            }
        }

        persistenceController.save()
    }

    /// Delete a specific exploration collection
    public func deleteExplorationCollection(_ collection: CDCollection) {
        guard collection.library?.isSystemLibrary == true else {
            Logger.library.warningCapture("Attempted to delete non-exploration collection", category: "library")
            return
        }

        Logger.library.infoCapture("Deleting exploration collection: \(collection.name)", category: "library")

        let context = persistenceController.viewContext

        // Delete papers that are only in this exploration collection
        if let publications = collection.publications {
            for pub in publications {
                let otherCollections = (pub.collections ?? []).filter { $0.id != collection.id }
                if otherCollections.isEmpty {
                    context.delete(pub)
                }
            }
        }

        // Delete child collections recursively
        if let children = collection.childCollections {
            for child in children {
                deleteExplorationCollection(child)
            }
        }

        context.delete(collection)
        persistenceController.save()
    }

    // MARK: - BibTeX Export

    /// Export a library to BibTeX format.
    ///
    /// Exports all publications in the library to a .bib file at the specified URL.
    /// This allows users to share their library with BibDesk and other tools.
    ///
    /// - Parameters:
    ///   - library: The library to export
    ///   - url: The destination URL for the .bib file
    /// - Throws: `LibraryError.notFound` if library has no publications, or file system errors
    public func exportToBibTeX(_ library: CDLibrary, to url: URL) throws {
        Logger.library.infoCapture("Exporting library '\(library.displayName)' to BibTeX", category: "library")

        guard let publications = library.publications, !publications.isEmpty else {
            Logger.library.warningCapture("No publications to export", category: "library")
            throw LibraryError.notFound(library.id)
        }

        // Convert to BibTeX entries
        let entries = publications.map { $0.toBibTeXEntry() }

        // Export using BibTeXExporter
        let exporter = BibTeXExporter()
        let content = exporter.export(entries)

        // Write to file
        try content.write(to: url, atomically: true, encoding: .utf8)

        Logger.library.infoCapture("Exported \(entries.count) entries to: \(url.lastPathComponent)", category: "library")
    }
}

// MARK: - Library Error

public enum LibraryError: LocalizedError {
    case accessDenied(URL)
    case notFound(UUID)
    case invalidBibFile(URL)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let url):
            return "Access denied to \(url.lastPathComponent)"
        case .notFound(let id):
            return "Library not found: \(id)"
        case .invalidBibFile(let url):
            return "Invalid BibTeX file: \(url.lastPathComponent)"
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let activeLibraryChanged = Notification.Name("activeLibraryChanged")
}

// MARK: - Library Definition (Sendable snapshot)

/// A Sendable snapshot of a library for use in async contexts
public struct LibraryDefinition: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let bibFilePath: String?
    public let papersDirectoryPath: String?
    public let dateCreated: Date
    public let dateLastOpened: Date?
    public let isDefault: Bool

    public init(from entity: CDLibrary) {
        self.id = entity.id
        self.name = entity.displayName
        self.bibFilePath = entity.bibFilePath
        self.papersDirectoryPath = entity.papersDirectoryPath
        self.dateCreated = entity.dateCreated
        self.dateLastOpened = entity.dateLastOpened
        self.isDefault = entity.isDefault
    }
}
