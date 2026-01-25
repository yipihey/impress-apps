//
//  DefaultLibrarySetManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation
import CoreData
import OSLog

// MARK: - Default Library Set Manager

/// Manages loading and exporting default library sets for onboarding.
///
/// On first launch (no existing libraries), the bundled default set is imported
/// to provide example libraries, smart searches, and collections for new users.
///
/// Development mode allows exporting the current state to JSON for version control.
@MainActor
public final class DefaultLibrarySetManager {

    // MARK: - Shared Instance

    public static let shared = DefaultLibrarySetManager()

    // MARK: - Dependencies

    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - First Launch Detection

    /// Check if this is the first launch (no existing libraries).
    public func isFirstLaunch() -> Bool {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.fetchLimit = 1

        do {
            let count = try context.count(for: request)
            return count == 0
        } catch {
            Logger.library.errorCapture("Failed to check library count: \(error.localizedDescription)", category: "onboarding")
            return false
        }
    }

    // MARK: - Load Default Set

    /// Load and import the default library set.
    ///
    /// This creates CDLibrary, CDSmartSearch, and CDCollection entities.
    /// Checks App Support first for user-customized version, falls back to bundled resource.
    public func loadDefaultSet() throws {
        Logger.library.infoCapture("Loading default library set", category: "onboarding")

        // Determine which JSON file to use
        let url: URL
        let fileManager = FileManager.default
        let appSupportURL = getAppSupportJSONURL()

        if fileManager.fileExists(atPath: appSupportURL.path) {
            Logger.library.infoCapture("Using customized DefaultLibrarySet.json from App Support", category: "onboarding")
            url = appSupportURL
        } else if let bundleURL = Bundle.main.url(forResource: "DefaultLibrarySet", withExtension: "json") {
            Logger.library.infoCapture("Using bundled DefaultLibrarySet.json", category: "onboarding")
            url = bundleURL
        } else {
            Logger.library.errorCapture("DefaultLibrarySet.json not found in bundle or App Support", category: "onboarding")
            throw DefaultLibrarySetError.bundleNotFound
        }

        // Load and decode
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Logger.library.errorCapture("Failed to read DefaultLibrarySet.json: \(error.localizedDescription)", category: "onboarding")
            throw DefaultLibrarySetError.decodingFailed(error)
        }

        let defaultSet: DefaultLibrarySet
        do {
            let decoder = JSONDecoder()
            defaultSet = try decoder.decode(DefaultLibrarySet.self, from: data)
        } catch {
            Logger.library.errorCapture("Failed to decode DefaultLibrarySet.json: \(error.localizedDescription)", category: "onboarding")
            throw DefaultLibrarySetError.decodingFailed(error)
        }

        Logger.library.infoCapture("Loaded default set v\(defaultSet.version) with \(defaultSet.libraries.count) libraries", category: "onboarding")

        // Import the set
        try importSet(defaultSet)
    }

    /// Import a DefaultLibrarySet into Core Data.
    private func importSet(_ set: DefaultLibrarySet) throws {
        let context = persistenceController.viewContext

        // Create libraries
        for (index, defaultLibrary) in set.libraries.enumerated() {
            // Create library
            let library = CDLibrary(context: context)
            library.id = UUID()
            library.name = defaultLibrary.name
            library.dateCreated = Date()
            library.isDefault = defaultLibrary.isDefault
            library.sortOrder = Int16(index)

            Logger.library.debugCapture("Creating library: \(defaultLibrary.name)", category: "onboarding")

            // Note: smartSearches in libraries are deprecated and ignored
            // Use top-level inboxFeeds instead

            // Create collections
            if let collections = defaultLibrary.collections {
                for defaultColl in collections {
                    let collection = CDCollection(context: context)
                    collection.id = UUID()
                    collection.name = defaultColl.name
                    collection.isSmartCollection = false
                    collection.isSmartSearchResults = false
                    collection.isSystemCollection = false
                    collection.library = library

                    Logger.library.debugCapture("  Created collection: \(defaultColl.name)", category: "onboarding")
                }
            }
        }

        // Import inbox feeds (these are stored in the Inbox library)
        if let inboxFeeds = set.inboxFeeds, !inboxFeeds.isEmpty {
            try importInboxFeeds(inboxFeeds, context: context)
        }

        // Save
        persistenceController.save()
        Logger.library.infoCapture("Successfully imported default library set", category: "onboarding")
    }

    /// Import inbox feeds into the Inbox library.
    private func importInboxFeeds(_ feeds: [DefaultInboxFeed], context: NSManagedObjectContext) throws {
        // Get or create the Inbox library
        let inboxLibrary = try getOrCreateInboxLibrary(context: context)

        for (index, defaultFeed) in feeds.enumerated() {
            let smartSearch = CDSmartSearch(context: context)
            smartSearch.id = UUID()
            smartSearch.name = defaultFeed.name
            smartSearch.query = defaultFeed.query
            smartSearch.sources = defaultFeed.sourceIDs
            smartSearch.dateCreated = Date()
            smartSearch.library = inboxLibrary
            smartSearch.order = Int16(index)
            smartSearch.feedsToInbox = true
            smartSearch.autoRefreshEnabled = true
            smartSearch.refreshIntervalSeconds = Int32(defaultFeed.refreshIntervalSeconds ?? 21600)
            smartSearch.maxResults = Int16(defaultFeed.maxResults ?? 100)

            // Create result collection for the feed
            // IMPORTANT: The collection must be associated with BOTH the smart search AND the library
            let resultCollection = CDCollection(context: context)
            resultCollection.id = UUID()
            resultCollection.name = defaultFeed.name
            resultCollection.isSmartSearchResults = true
            resultCollection.isSmartCollection = false
            resultCollection.smartSearch = smartSearch
            resultCollection.library = inboxLibrary  // This line was missing!
            smartSearch.resultCollection = resultCollection

            Logger.library.debugCapture("Created inbox feed: \(defaultFeed.name)", category: "onboarding")
        }
    }

    /// Get or create the Inbox library.
    private func getOrCreateInboxLibrary(context: NSManagedObjectContext) throws -> CDLibrary {
        // Check if Inbox already exists
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isInbox == YES")
        request.fetchLimit = 1

        if let existing = try context.fetch(request).first {
            return existing
        }

        // Create Inbox library
        let inbox = CDLibrary(context: context)
        inbox.id = UUID()
        inbox.name = "Inbox"
        inbox.dateCreated = Date()
        inbox.isInbox = true
        inbox.isDefault = false
        inbox.sortOrder = -1  // Inbox appears at top

        Logger.library.debugCapture("Created Inbox library for feeds", category: "onboarding")

        return inbox
    }

    // MARK: - Load Custom Set

    /// Load a custom default library set from a URL.
    ///
    /// This is used for testing and development to load custom configurations.
    public func loadCustomSet(from url: URL) throws {
        Logger.library.infoCapture("Loading custom library set from: \(url.lastPathComponent)", category: "onboarding")

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Logger.library.errorCapture("Failed to read custom library set: \(error.localizedDescription)", category: "onboarding")
            throw DefaultLibrarySetError.decodingFailed(error)
        }

        let customSet: DefaultLibrarySet
        do {
            let decoder = JSONDecoder()
            customSet = try decoder.decode(DefaultLibrarySet.self, from: data)
        } catch {
            Logger.library.errorCapture("Failed to decode custom library set: \(error.localizedDescription)", category: "onboarding")
            throw DefaultLibrarySetError.decodingFailed(error)
        }

        Logger.library.infoCapture("Loaded custom set v\(customSet.version) with \(customSet.libraries.count) libraries", category: "onboarding")

        // Import the set
        try importSet(customSet)
    }

    // MARK: - Export Current State (Development Mode)

    /// Export the current libraries and inbox feeds to JSON.
    ///
    /// This is used in development mode to update the bundled DefaultLibrarySet.json.
    public func exportCurrentAsDefaultSet(to url: URL) throws {
        Logger.library.infoCapture("Exporting current state to: \(url.lastPathComponent)", category: "onboarding")

        let defaultSet = try getCurrentAsDefaultSet()

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(defaultSet)
        } catch {
            Logger.library.errorCapture("Failed to encode default set: \(error.localizedDescription)", category: "onboarding")
            throw DefaultLibrarySetError.encodingFailed(error)
        }

        // Write to file
        do {
            try data.write(to: url)
            Logger.library.infoCapture("Successfully exported default set", category: "onboarding")
        } catch {
            Logger.library.errorCapture("Failed to write default set file: \(error.localizedDescription)", category: "onboarding")
            throw DefaultLibrarySetError.writeFailed(error)
        }
    }

    /// Get the URL of the bundled DefaultLibrarySet.json file.
    ///
    /// This returns the path within the app bundle's Resources folder.
    public func getBundledJSONURL() -> URL? {
        return Bundle.main.url(forResource: "DefaultLibrarySet", withExtension: "json")
    }

    /// Get the App Support directory URL for the JSON file.
    ///
    /// Returns ~/Library/Application Support/imbib/DefaultLibrarySet.json
    private func getAppSupportJSONURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("imbib/DefaultLibrarySet.json")
    }

    /// Load DefaultLibrarySet from JSON file for editing.
    ///
    /// Checks App Support first (user's saved edits), falls back to bundled resource.
    /// This is used by the editor to show what the JSON file contains, not Core Data state.
    public func loadDefaultSetFromJSON() throws -> DefaultLibrarySet {
        let fileManager = FileManager.default

        // Check App Support first (user's saved edits)
        let appSupportURL = getAppSupportJSONURL()
        if fileManager.fileExists(atPath: appSupportURL.path) {
            Logger.library.infoCapture("Loading DefaultLibrarySet.json from App Support for editing", category: "onboarding")
            let data = try Data(contentsOf: appSupportURL)
            return try JSONDecoder().decode(DefaultLibrarySet.self, from: data)
        }

        // Fall back to bundled resource
        guard let bundleURL = Bundle.main.url(forResource: "DefaultLibrarySet", withExtension: "json") else {
            throw DefaultLibrarySetError.bundleNotFound
        }

        Logger.library.infoCapture("Loading DefaultLibrarySet.json from bundle for editing", category: "onboarding")
        let data = try Data(contentsOf: bundleURL)
        return try JSONDecoder().decode(DefaultLibrarySet.self, from: data)
    }

    /// Save a DefaultLibrarySet to the bundled JSON file location.
    ///
    /// Note: This only works during development as the app bundle is read-only
    /// in production builds.
    public func saveToBundledJSON(_ set: DefaultLibrarySet) throws {
        // Get the source file path (for development, we need to find the original file)
        // In production, the bundle is read-only, so we use the app support directory
        let fileManager = FileManager.default

        // Try to find the source file in the project directory
        // This is a development-only feature
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("imbib")

        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let destinationURL = appSupportURL.appendingPathComponent("DefaultLibrarySet.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(set)
        try data.write(to: destinationURL)

        Logger.library.infoCapture("Saved default library set to: \(destinationURL.path)", category: "onboarding")
    }

    /// Get the current libraries and inbox feeds as a DefaultLibrarySet object.
    ///
    /// Useful for editing the default set in the UI before saving.
    public func getCurrentAsDefaultSet() throws -> DefaultLibrarySet {
        let context = persistenceController.viewContext

        // Fetch all libraries
        let libraryRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
        libraryRequest.sortDescriptors = [
            NSSortDescriptor(key: "sortOrder", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]

        let libraries: [CDLibrary]
        do {
            libraries = try context.fetch(libraryRequest)
        } catch {
            Logger.library.errorCapture("Failed to fetch libraries: \(error.localizedDescription)", category: "onboarding")
            throw DefaultLibrarySetError.encodingFailed(error)
        }

        // Build the export structure
        var defaultLibraries: [DefaultLibrary] = []
        var inboxFeeds: [DefaultInboxFeed] = []

        for library in libraries {
            // Handle Inbox library - extract feeds
            if library.isInbox {
                let feeds = (library.smartSearches ?? [])
                    .filter { $0.feedsToInbox }
                    .sorted { $0.order < $1.order }
                    .map { ss in
                        DefaultInboxFeed(
                            name: ss.name,
                            query: ss.query,
                            sourceIDs: ss.sources,
                            refreshIntervalSeconds: Int(ss.refreshIntervalSeconds),
                            maxResults: Int(ss.maxResults)
                        )
                    }
                inboxFeeds.append(contentsOf: feeds)
                continue
            }

            // Skip system libraries
            if library.isSystemLibrary {
                continue
            }

            // Export user-created collections (not smart search results, not system collections)
            let collections = (library.collections ?? [])
                .filter { !$0.isSmartSearchResults && !$0.isSystemCollection }
                .map { DefaultCollection(name: $0.name) }

            let defaultLibrary = DefaultLibrary(
                name: library.displayName,
                isDefault: library.isDefault,
                smartSearches: nil,  // Libraries no longer have smart searches
                collections: collections.isEmpty ? nil : collections
            )

            defaultLibraries.append(defaultLibrary)
        }

        return DefaultLibrarySet(
            version: 1,
            libraries: defaultLibraries,
            inboxFeeds: inboxFeeds.isEmpty ? nil : inboxFeeds
        )
    }

    /// Export the current libraries as a JSON string.
    ///
    /// Useful for copying to clipboard or displaying in UI.
    public func exportToJSONString() throws -> String {
        let defaultSet = try getCurrentAsDefaultSet()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(defaultSet)
        } catch {
            Logger.library.errorCapture("Failed to encode default set: \(error.localizedDescription)", category: "onboarding")
            throw DefaultLibrarySetError.encodingFailed(error)
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw DefaultLibrarySetError.encodingFailed(NSError(domain: "imbib", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to convert data to string"]))
        }

        return jsonString
    }
}
