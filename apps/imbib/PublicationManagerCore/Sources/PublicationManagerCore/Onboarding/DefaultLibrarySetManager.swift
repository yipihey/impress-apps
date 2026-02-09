//
//  DefaultLibrarySetManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation
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

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - Initialization

    public init() {}

    // MARK: - First Launch Detection

    /// Check if this is the first launch (no existing libraries).
    public func isFirstLaunch() -> Bool {
        let libraries = store.listLibraries()
        return libraries.isEmpty
    }

    // MARK: - Load Default Set

    /// Load and import the default library set.
    ///
    /// This creates libraries, smart searches, and collections via RustStoreAdapter.
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
        importSet(defaultSet)
    }

    /// Import a DefaultLibrarySet into the Rust store.
    private func importSet(_ set: DefaultLibrarySet) {
        // Create libraries
        for defaultLibrary in set.libraries {
            // Create library
            guard let library = store.createLibrary(name: defaultLibrary.name) else {
                Logger.library.errorCapture("Failed to create library: \(defaultLibrary.name)", category: "onboarding")
                continue
            }

            if defaultLibrary.isDefault {
                store.setLibraryDefault(id: library.id)
            }

            Logger.library.debugCapture("Creating library: \(defaultLibrary.name)", category: "onboarding")

            // Create collections
            if let collections = defaultLibrary.collections {
                for defaultColl in collections {
                    _ = store.createCollection(name: defaultColl.name, libraryId: library.id)
                    Logger.library.debugCapture("  Created collection: \(defaultColl.name)", category: "onboarding")
                }
            }
        }

        // Import inbox feeds (these are stored in the Inbox library)
        if let inboxFeeds = set.inboxFeeds, !inboxFeeds.isEmpty {
            importInboxFeeds(inboxFeeds)
        }

        Logger.library.infoCapture("Successfully imported default library set", category: "onboarding")
    }

    /// Import inbox feeds into the Inbox library.
    private func importInboxFeeds(_ feeds: [DefaultInboxFeed]) {
        // Get or create the Inbox library
        let inboxLibrary: LibraryModel
        if let existing = store.getInboxLibrary() {
            inboxLibrary = existing
        } else if let created = store.createInboxLibrary(name: "Inbox") {
            inboxLibrary = created
        } else {
            Logger.library.errorCapture("Failed to create Inbox library for feeds", category: "onboarding")
            return
        }

        for defaultFeed in feeds {
            let sourceIdsJson: String?
            if !defaultFeed.sourceIDs.isEmpty {
                sourceIdsJson = try? String(data: JSONEncoder().encode(defaultFeed.sourceIDs), encoding: .utf8)
            } else {
                sourceIdsJson = nil
            }

            _ = store.createSmartSearch(
                name: defaultFeed.name,
                query: defaultFeed.query,
                libraryId: inboxLibrary.id,
                sourceIdsJson: sourceIdsJson,
                maxResults: Int64(defaultFeed.maxResults ?? 100),
                feedsToInbox: true,
                autoRefreshEnabled: true,
                refreshIntervalSeconds: Int64(defaultFeed.refreshIntervalSeconds ?? 21600)
            )

            Logger.library.debugCapture("Created inbox feed: \(defaultFeed.name)", category: "onboarding")
        }
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
        importSet(customSet)
    }

    // MARK: - Export Current State (Development Mode)

    /// Export the current libraries and inbox feeds to JSON.
    ///
    /// This is used in development mode to update the bundled DefaultLibrarySet.json.
    public func exportCurrentAsDefaultSet(to url: URL) throws {
        Logger.library.infoCapture("Exporting current state to: \(url.lastPathComponent)", category: "onboarding")

        let defaultSet = getCurrentAsDefaultSet()

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
    /// This is used by the editor to show what the JSON file contains, not store state.
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

    /// Save a DefaultLibrarySet to the App Support JSON file location.
    public func saveToBundledJSON(_ set: DefaultLibrarySet) throws {
        let fileManager = FileManager.default

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
    public func getCurrentAsDefaultSet() -> DefaultLibrarySet {
        let libraries = store.listLibraries()

        // Build the export structure
        var defaultLibraries: [DefaultLibrary] = []
        var inboxFeeds: [DefaultInboxFeed] = []

        for library in libraries {
            // Handle Inbox library - extract feeds
            if library.isInbox {
                let smartSearches = store.listSmartSearches(libraryId: library.id)
                let feeds = smartSearches
                    .filter { $0.feedsToInbox }
                    .map { ss in
                        DefaultInboxFeed(
                            name: ss.name,
                            query: ss.query,
                            sourceIDs: ss.sourceIDs,
                            refreshIntervalSeconds: Int(ss.refreshIntervalSeconds),
                            maxResults: Int(ss.maxResults)
                        )
                    }
                inboxFeeds.append(contentsOf: feeds)
                continue
            }

            // Export user-created collections
            let collections = store.listCollections(libraryId: library.id)
                .map { DefaultCollection(name: $0.name) }

            let defaultLibrary = DefaultLibrary(
                name: library.name,
                isDefault: library.isDefault,
                smartSearches: nil,
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
        let defaultSet = getCurrentAsDefaultSet()

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
