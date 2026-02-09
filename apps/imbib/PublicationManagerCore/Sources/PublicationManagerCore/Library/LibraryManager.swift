//
//  LibraryManager.swift
//  PublicationManagerCore
//
//  Manages multiple publication libraries via the Rust store.
//

import Foundation
import OSLog

#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif

// MARK: - Library Manager

/// Manages multiple publication libraries.
///
/// Each library represents a separate bibliography collection.
/// Libraries can be created, deleted, and switched between.
@MainActor
@Observable
public final class LibraryManager {

    // MARK: - Published State

    /// All user libraries
    public private(set) var libraries: [LibraryModel] = []

    /// ID of the currently active library
    public var activeLibraryID: UUID? {
        didSet {
            if let id = activeLibraryID {
                UserDefaults.standard.set(id.uuidString, forKey: "activeLibraryID")
            }
        }
    }

    /// Currently active library (computed from ID)
    public var activeLibrary: LibraryModel? {
        guard let id = activeLibraryID else { return nil }
        return libraries.first { $0.id == id }
    }

    /// Recently opened libraries
    public var recentLibraries: [LibraryModel] {
        let recentIDs = UserDefaults.standard.stringArray(forKey: "recentLibraryIDs") ?? []
        return recentIDs.compactMap { idStr in
            guard let uuid = UUID(uuidString: idStr) else { return nil }
            return libraries.first { $0.id == uuid }
        }.prefix(5).map { $0 }
    }

    // MARK: - Special Libraries

    /// ID of the Save library for Inbox triage
    private var saveLibraryID: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: "saveLibraryID") else { return nil }
            return UUID(uuidString: str)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: "saveLibraryID")
        }
    }

    /// ID of the Dismissed library for Inbox triage
    private var dismissedLibraryID: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: "dismissedLibraryID") else { return nil }
            return UUID(uuidString: str)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: "dismissedLibraryID")
        }
    }

    /// ID of the Exploration system library
    private var explorationLibraryID: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: "explorationLibraryID") else { return nil }
            return UUID(uuidString: str)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: "explorationLibraryID")
        }
    }

    /// The Save library
    public var saveLibrary: LibraryModel? {
        guard let id = saveLibraryID else { return nil }
        return libraries.first { $0.id == id }
    }

    /// The Dismissed library
    public var dismissedLibrary: LibraryModel? {
        guard let id = dismissedLibraryID else { return nil }
        return libraries.first { $0.id == id }
    }

    /// The Exploration system library
    public var explorationLibrary: LibraryModel? {
        guard let id = explorationLibraryID else { return nil }
        return libraries.first { $0.id == id }
    }

    // MARK: - Dependencies

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    /// Track previous library count to avoid redundant logging
    private var previousLibraryCount: Int = -1

    /// Flag to prevent re-entrant reloads
    private var isReloading: Bool = false

    // MARK: - Initialization

    public init() {
        loadLibraries()

        // Load default library set if none exist (first run)
        if libraries.isEmpty {
            Logger.library.infoCapture("No libraries found, loading default set", category: "library")
            do {
                try DefaultLibrarySetManager.shared.loadDefaultSet()
                loadLibraries()
            } catch {
                Logger.library.warningCapture("Failed to load default set, creating fallback library: \(error.localizedDescription)", category: "library")
                _ = createLibrary(name: "My Library")
            }
        }

        // Restore active library from UserDefaults
        if let savedID = UserDefaults.standard.string(forKey: "activeLibraryID"),
           let uuid = UUID(uuidString: savedID),
           libraries.contains(where: { $0.id == uuid }) {
            activeLibraryID = uuid
        }

        // Fallback: use default or first library
        if activeLibraryID == nil {
            activeLibraryID = libraries.first(where: { $0.isDefault })?.id ?? libraries.first?.id
            if let active = activeLibrary {
                Logger.library.infoCapture("Set active library: \(active.name)", category: "library")
            }
        }
    }

    /// Legacy initializer for compatibility — ignores persistenceController.
    public convenience init(persistenceController: Any) {
        self.init()
    }

    // MARK: - Library Loading

    /// Load all libraries from the Rust store
    public func loadLibraries() {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        libraries = store.listLibraries()

        let count = libraries.count
        if count != previousLibraryCount {
            Logger.library.infoCapture("Libraries: \(count)", category: "library")
            previousLibraryCount = count
        }
    }

    /// Invalidate all cached state after a reset.
    public func invalidateCaches() {
        Logger.library.infoCapture("Invalidating LibraryManager caches", category: "library")
        libraries = []
        activeLibraryID = nil
        previousLibraryCount = -1
    }

    // MARK: - Library Management

    /// Create a new library.
    @discardableResult
    public func createLibrary(name: String) -> LibraryModel? {
        Logger.library.infoCapture("Creating library: \(name)", category: "library")

        guard let library = store.createLibrary(name: name) else {
            Logger.library.errorCapture("Failed to create library: \(name)", category: "library")
            return nil
        }

        // Set as default if first library
        if libraries.isEmpty {
            store.setLibraryDefault(id: library.id)
        }

        loadLibraries()
        Logger.library.infoCapture("Created library '\(name)' with ID: \(library.id)", category: "library")
        return library
    }

    /// Set the active library by ID
    public func setActive(id: UUID) {
        guard let library = libraries.first(where: { $0.id == id }) else { return }
        Logger.library.infoCapture("Switching to library: \(library.name)", category: "library")

        activeLibraryID = id

        // Track in recent list
        var recents = UserDefaults.standard.stringArray(forKey: "recentLibraryIDs") ?? []
        recents.removeAll { $0 == id.uuidString }
        recents.insert(id.uuidString, at: 0)
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        UserDefaults.standard.set(recents, forKey: "recentLibraryIDs")

        NotificationCenter.default.post(name: .activeLibraryChanged, object: id)
    }

    /// Set the active library
    public func setActive(_ library: LibraryModel) {
        setActive(id: library.id)
    }

    /// Close a library (remove from list but don't delete data)
    public func closeLibrary(id: UUID) {
        Logger.library.infoCapture("Closing library: \(id)", category: "library")

        if activeLibraryID == id {
            activeLibraryID = libraries.first { $0.id != id }?.id
        }

        store.deleteLibrary(id: id)
        loadLibraries()
    }

    /// Delete a library and optionally its files.
    public func deleteLibrary(id: UUID, deleteFiles: Bool = false) throws {
        Logger.library.warningCapture("Deleting library: \(id), deleteFiles: \(deleteFiles)", category: "library")

        if deleteFiles {
            let containerURL = Self.containerURL(for: id)
            if FileManager.default.fileExists(atPath: containerURL.path) {
                try? FileManager.default.removeItem(at: containerURL)
                Logger.library.debugCapture("Deleted library container: \(containerURL.path)", category: "library")
            }
        }

        closeLibrary(id: id)
    }

    /// Set a library as the default
    public func setDefault(id: UUID) {
        Logger.library.infoCapture("Setting default library: \(id)", category: "library")
        store.setLibraryDefault(id: id)
        loadLibraries()
    }

    /// Set a library as the default
    public func setDefault(_ library: LibraryModel) {
        setDefault(id: library.id)
    }

    /// Rename a library
    public func rename(id: UUID, to name: String) {
        Logger.library.infoCapture("Renaming library to '\(name)'", category: "library")
        store.updateField(id: id, field: "name", value: name)
        loadLibraries()
    }

    /// Reorder libraries
    public func moveLibraries(from indices: IndexSet, to destination: Int) {
        Logger.library.infoCapture("Moving libraries from \(indices) to \(destination)", category: "library")
        var reordered = libraries
        reordered.move(fromOffsets: indices, toOffset: destination)
        for (index, library) in reordered.enumerated() {
            store.updateIntField(id: library.id, field: "sort_order", value: Int64(index))
        }
        libraries = reordered
    }

    // MARK: - Library Lookup

    /// Find a library by ID
    public func find(id: UUID) -> LibraryModel? {
        libraries.first { $0.id == id } ?? store.getLibrary(id: id)
    }

    /// Get the default library, creating one if needed
    public func getOrCreateDefaultLibrary() -> LibraryModel {
        if let defaultLib = libraries.first(where: { $0.isDefault }) {
            return defaultLib
        }
        if let firstLib = libraries.first {
            store.setLibraryDefault(id: firstLib.id)
            loadLibraries()
            return firstLib
        }
        return createLibrary(name: "My Library")!
    }

    // MARK: - Save Library (Inbox Triage)

    /// Get or create the Save library for Inbox triage.
    @discardableResult
    public func getOrCreateSaveLibrary() -> LibraryModel {
        // Check user-configured save library
        if let configuredID = SyncedSettingsStore.shared.string(forKey: .inboxSaveLibraryID),
           let uuid = UUID(uuidString: configuredID),
           let lib = libraries.first(where: { $0.id == uuid }) {
            return lib
        }

        // Return cached save library
        if let lib = saveLibrary {
            return lib
        }

        // Create new Save library
        Logger.library.infoCapture("Creating Save library for Inbox triage", category: "library")
        guard let lib = store.createLibrary(name: "Save") else {
            return getOrCreateDefaultLibrary()
        }
        saveLibraryID = lib.id
        loadLibraries()
        return lib
    }

    // MARK: - Dismissed Library (Inbox Triage)

    /// Get or create the Dismissed library for Inbox triage.
    @discardableResult
    public func getOrCreateDismissedLibrary() -> LibraryModel {
        if let lib = dismissedLibrary {
            return lib
        }

        Logger.library.infoCapture("Creating Dismissed library for Inbox triage", category: "library")
        guard let lib = store.createLibrary(name: "Dismissed") else {
            return getOrCreateDefaultLibrary()
        }
        dismissedLibraryID = lib.id
        loadLibraries()
        return lib
    }

    /// Empty the Dismissed library
    public func emptyDismissedLibrary() {
        guard let id = dismissedLibraryID else { return }
        Logger.library.warningCapture("Emptying Dismissed library", category: "library")

        let pubs = store.queryPublications(parentId: id, sort: "created", ascending: false, limit: nil, offset: nil)
        if !pubs.isEmpty {
            store.deletePublications(ids: pubs.map(\.id))
        }
        loadLibraries()
    }

    // MARK: - Last Search Collection

    /// Get or create the "Last Search" collection for the active library.
    public func getOrCreateLastSearchCollection() -> CollectionModel? {
        guard let libID = activeLibraryID else {
            Logger.library.warningCapture("No active library for Last Search collection", category: "library")
            return nil
        }

        let collections = store.listCollections(libraryId: libID)
        if let existing = collections.first(where: { $0.name == "Last Search" }) {
            return existing
        }

        Logger.library.infoCapture("Creating Last Search collection", category: "library")
        return store.createCollection(name: "Last Search", libraryId: libID, isSmart: false)
    }

    /// Clear the Last Search collection
    public func clearLastSearchCollection() {
        guard let libID = activeLibraryID else { return }

        let collections = store.listCollections(libraryId: libID)
        guard let collection = collections.first(where: { $0.name == "Last Search" }) else { return }

        Logger.library.debugCapture("Clearing Last Search collection", category: "library")

        let members = store.listCollectionMembers(collectionId: collection.id, sort: "created", ascending: false, limit: nil, offset: nil)
        if !members.isEmpty {
            store.removeFromCollection(publicationIds: members.map(\.id), collectionId: collection.id)
        }
    }

    // MARK: - Exploration Library

    /// Get or create the Exploration system library.
    @discardableResult
    public func getOrCreateExplorationLibrary() -> LibraryModel {
        if let lib = explorationLibrary {
            return lib
        }

        // Look for existing by name
        if let existing = libraries.first(where: { $0.name == "Exploration" }) {
            explorationLibraryID = existing.id
            return existing
        }

        Logger.library.infoCapture("Creating Exploration system library", category: "library")
        guard let lib = store.createLibrary(name: "Exploration") else {
            return getOrCreateDefaultLibrary()
        }
        explorationLibraryID = lib.id
        loadLibraries()
        return lib
    }

    /// Clear all collections in the Exploration library
    public func clearExplorationLibrary() {
        guard let libID = explorationLibraryID else { return }
        Logger.library.infoCapture("Clearing Exploration library", category: "library")

        let collections = store.listCollections(libraryId: libID)
        for collection in collections {
            let members = store.listCollectionMembers(collectionId: collection.id, sort: "created", ascending: false, limit: nil, offset: nil)
            if !members.isEmpty {
                store.deletePublications(ids: members.map(\.id))
            }
            store.deleteItem(id: collection.id)
        }
    }

    /// Delete exploration collections older than specified days.
    public func cleanupExplorationCollections(olderThanDays days: Int?) {
        guard let days = days else { return }
        guard let libID = explorationLibraryID else { return }

        if days == 0 {
            clearExplorationLibrary()
            return
        }

        // Without dateCreated on CollectionModel, clean up all exploration collections
        // when any cleanup is requested (date-based filtering not available yet)
        let collections = store.listCollections(libraryId: libID)
        if !collections.isEmpty {
            for collection in collections {
                deleteExplorationCollection(id: collection.id)
            }
            Logger.library.infoCapture("Cleaned up \(collections.count) exploration collection(s)", category: "library")
        }
    }

    /// Delete a specific exploration collection
    public func deleteExplorationCollection(id: UUID) {
        Logger.library.infoCapture("Deleting exploration collection: \(id)", category: "library")
        let members = store.listCollectionMembers(collectionId: id, sort: "created", ascending: false, limit: nil, offset: nil)
        if !members.isEmpty {
            store.deletePublications(ids: members.map(\.id))
        }
        store.deleteItem(id: id)
    }

    // MARK: - BibTeX Export

    /// Export a library to BibTeX format.
    public func exportToBibTeX(libraryId: UUID, to url: URL) throws {
        Logger.library.infoCapture("Exporting library to BibTeX", category: "library")
        let content = store.exportAllBibTeX(libraryId: libraryId)
        guard !content.isEmpty else {
            throw LibraryError.notFound(libraryId)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        Logger.library.infoCapture("Exported to: \(url.lastPathComponent)", category: "library")
    }

    // MARK: - Container URLs

    /// Container URL for a library's files.
    public static func containerURL(for libraryId: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("imbib/Libraries/\(libraryId.uuidString)", isDirectory: true)
    }

    /// Papers container URL for a library.
    public static func papersContainerURL(for libraryId: UUID) -> URL {
        containerURL(for: libraryId).appendingPathComponent("Papers", isDirectory: true)
    }

    /// Unique identifier for the current device.
    public static var currentDeviceIdentifier: String {
        #if os(iOS)
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            return vendorID
        }
        return UIDevice.current.name
        #else
        if let uuid = getMacHardwareUUID() {
            return uuid
        }
        return Host.current().localizedName ?? "unknown-mac"
        #endif
    }

    #if os(macOS)
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

// MARK: - Library Definition (Sendable snapshot — alias for LibraryModel)

/// A Sendable snapshot of a library for use in async contexts.
public typealias LibraryDefinition = LibraryModel
