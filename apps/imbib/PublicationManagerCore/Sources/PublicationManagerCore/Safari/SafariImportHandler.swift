//
//  SafariImportHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-11.
//

import Foundation
import OSLog
import CoreData

/// Handles imports from the Safari extension via App Groups.
///
/// The Safari extension queues items to UserDefaults in the shared app group.
/// This handler processes the queue, fetches full metadata from appropriate sources,
/// and creates publications in the database.
public actor SafariImportHandler {

    // MARK: - Singleton

    public static let shared = SafariImportHandler()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.imbib", category: "safari-import")
    private let appGroupID = "group.com.imbib.app"

    /// Lazily initialized to defer App Group access until actually needed.
    /// This prevents the "access data from other apps" dialog at startup.
    private var _defaults: UserDefaults??  // Double optional: nil = not yet tried, .some(nil) = tried and failed
    private var defaults: UserDefaults? {
        if let cached = _defaults { return cached }
        let d = UserDefaults(suiteName: appGroupID)
        _defaults = d
        if d == nil {
            logger.error("Failed to access App Group: \(self.appGroupID)")
        }
        return d
    }

    private var isProcessing = false

    // Keys for App Group UserDefaults
    private enum Keys {
        static let importQueue = "safariImportQueue"
        static let smartSearchQueue = "safariSmartSearchQueue"
        static let knownIdentifiers = "knownIdentifiers"
        static let availableLibraries = "availableLibraries"
    }

    // MARK: - Initialization

    private init() {
        // Don't access App Group here - defer until first use
    }

    // MARK: - Queue Processing

    /// Process any pending Safari imports.
    /// Call this on app launch and when receiving Darwin notifications.
    public func processPendingImports() async {
        guard !isProcessing else {
            logger.debug("Already processing imports, skipping")
            return
        }

        guard let defaults = defaults else {
            logger.error("App Group not available")
            return
        }

        guard let queue = defaults.array(forKey: Keys.importQueue) as? [[String: Any]], !queue.isEmpty else {
            logger.debug("No pending Safari imports")
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        logger.info("Processing \(queue.count) Safari import(s)")

        var processed = 0
        var failed = 0

        for item in queue {
            do {
                try await processImportItem(item)
                processed += 1
            } catch {
                logger.error("Safari import failed: \(error.localizedDescription)")
                failed += 1
            }
        }

        // Clear processed queue
        defaults.removeObject(forKey: Keys.importQueue)
        defaults.synchronize()

        logger.info("Safari import complete: \(processed) succeeded, \(failed) failed")
    }

    /// Process any pending smart search creation requests from the Safari extension.
    /// Creates smart searches in the Exploration library and auto-executes them.
    public func processPendingSmartSearches() async {
        guard let defaults = defaults else {
            logger.error("App Group not available")
            return
        }

        guard let queue = defaults.array(forKey: Keys.smartSearchQueue) as? [[String: Any]], !queue.isEmpty else {
            logger.debug("No pending Safari smart searches")
            return
        }

        logger.info("Processing \(queue.count) Safari smart search request(s)")

        var processed = 0
        var failed = 0

        for item in queue {
            do {
                try await processSmartSearchItem(item)
                processed += 1
            } catch {
                logger.error("Safari smart search creation failed: \(error.localizedDescription)")
                failed += 1
            }
        }

        // Clear processed queue
        defaults.removeObject(forKey: Keys.smartSearchQueue)
        defaults.synchronize()

        logger.info("Safari smart search processing complete: \(processed) succeeded, \(failed) failed")
    }

    /// Process a single smart search creation request.
    private func processSmartSearchItem(_ item: [String: Any]) async throws {
        guard let query = item["query"] as? String, !query.isEmpty else {
            throw SafariImportError.missingSourceType  // Reuse error for missing query
        }

        let name = item["name"] as? String ?? "Search: \(String(query.prefix(40)))"
        let sourceID = item["sourceID"] as? String ?? "ads"

        logger.info("Creating smart search: \(name) with query: \(query)")

        // Get the exploration library
        let explorationLibrary = await getOrCreateExplorationLibrary()

        // Create the smart search in exploration library
        let smartSearch = await MainActor.run {
            SmartSearchRepository.shared.create(
                name: name,
                query: query,
                sourceIDs: [sourceID],
                library: explorationLibrary,
                maxResults: 100
            )
        }

        // Create source manager for search execution
        let sourceManager = SourceManager()
        await sourceManager.registerBuiltInSources()

        // Auto-execute the search to populate results
        let provider = SmartSearchProvider(
            from: smartSearch,
            sourceManager: sourceManager,
            repository: PublicationRepository()
        )

        do {
            try await provider.refresh()
            await MainActor.run {
                SmartSearchRepository.shared.markExecuted(smartSearch)
            }
            logger.info("Auto-executed smart search '\(name)' successfully")
        } catch {
            logger.warning("Auto-execute failed for '\(name)': \(error.localizedDescription)")
            // Don't rethrow - the search was created, it can be refreshed later
        }

        // Notify sidebar to refresh and navigate to the new search
        await MainActor.run {
            NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
            NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
        }

        logger.info("Created smart search '\(name)' in Exploration library")
    }

    /// Get or create the exploration library (app-level, not user library)
    private func getOrCreateExplorationLibrary() async -> CDLibrary {
        return await MainActor.run {
            let manager = LibraryManager()
            return manager.getOrCreateExplorationLibrary()
        }
    }

    /// Process a single import item.
    /// This is called by the Safari extension queue processor and by the URL scheme handler
    /// for Chrome/Firefox/Edge browser extension imports.
    public func processImportItem(_ item: [String: Any]) async throws {
        guard let sourceType = item["sourceType"] as? String else {
            throw SafariImportError.missingSourceType
        }

        let title = item["title"] as? String ?? "unknown"
        logger.info("Processing: \(title) (source: \(sourceType))")

        switch sourceType {
        case "ads":
            try await importFromADS(item)
        case "arxiv":
            try await importFromArXiv(item)
        case "doi":
            try await importFromDOI(item)
        case "pubmed":
            try await importFromPubMed(item)
        case "embedded":
            try await importFromEmbedded(item)
        default:
            throw SafariImportError.unknownSourceType(sourceType)
        }
    }

    // MARK: - Source-Specific Import

    private func importFromADS(_ item: [String: Any]) async throws {
        guard let bibcode = item["bibcode"] as? String, !bibcode.isEmpty else {
            // Fall back to embedded metadata if no bibcode
            try await importFromEmbedded(item)
            return
        }

        let source = ADSSource()
        let results = try await source.search(query: "bibcode:\(bibcode)", maxResults: 1)

        guard let result = results.first else {
            throw SafariImportError.notFound("ADS bibcode: \(bibcode)")
        }

        let entry = try await source.fetchBibTeX(for: result)
        try await createPublication(from: entry, item: item)
    }

    private func importFromArXiv(_ item: [String: Any]) async throws {
        guard let arxivID = item["arxivID"] as? String, !arxivID.isEmpty else {
            try await importFromEmbedded(item)
            return
        }

        // Normalize arXiv ID (remove version)
        let normalizedID = arxivID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)

        let source = ArXivSource()
        let results = try await source.search(query: "id:\(normalizedID)", maxResults: 1)

        guard let result = results.first else {
            throw SafariImportError.notFound("arXiv: \(arxivID)")
        }

        let entry = try await source.fetchBibTeX(for: result)
        try await createPublication(from: entry, item: item)
    }

    private func importFromDOI(_ item: [String: Any]) async throws {
        guard let doi = item["doi"] as? String, !doi.isEmpty else {
            try await importFromEmbedded(item)
            return
        }

        // Use ADS to resolve DOIs - it can search by DOI
        let source = ADSSource()
        let results = try await source.search(query: "doi:\(doi)", maxResults: 1)

        guard let result = results.first else {
            // DOI not found in ADS, fall back to embedded metadata
            try await importFromEmbedded(item)
            return
        }

        let entry = try await source.fetchBibTeX(for: result)
        try await createPublication(from: entry, item: item)
    }

    private func importFromPubMed(_ item: [String: Any]) async throws {
        // If we have a DOI, try ADS lookup
        if let doi = item["doi"] as? String, !doi.isEmpty {
            try await importFromDOI(item)
            return
        }

        // Otherwise fall back to embedded metadata
        // (PubMed source integration can be added later)
        try await importFromEmbedded(item)
    }

    private func importFromEmbedded(_ item: [String: Any]) async throws {
        // Build BibTeX entry directly from extracted metadata
        var fields: [String: String] = [:]

        if let title = item["title"] as? String, !title.isEmpty {
            fields["title"] = title
        }

        if let authors = item["authors"] as? [String], !authors.isEmpty {
            fields["author"] = authors.joined(separator: " and ")
        }

        if let year = item["year"] as? String, !year.isEmpty {
            fields["year"] = year
        }

        if let journal = item["journal"] as? String, !journal.isEmpty {
            fields["journal"] = journal
        }

        if let volume = item["volume"] as? String, !volume.isEmpty {
            fields["volume"] = volume
        }

        if let pages = item["pages"] as? String, !pages.isEmpty {
            fields["pages"] = pages
        }

        if let doi = item["doi"] as? String, !doi.isEmpty {
            fields["doi"] = doi
        }

        if let abstract = item["abstract"] as? String, !abstract.isEmpty {
            fields["abstract"] = abstract
        }

        if let arxivID = item["arxivID"] as? String, !arxivID.isEmpty {
            fields["eprint"] = arxivID
            fields["archiveprefix"] = "arXiv"
        }

        if let pdfURL = item["pdfURL"] as? String, !pdfURL.isEmpty {
            fields["url"] = pdfURL
        }

        // Generate cite key using fields dictionary
        let citeKey = CiteKeyGenerator().generate(from: fields)

        // Determine entry type (article by default)
        let entryType = "article"

        let entry = BibTeXEntry(citeKey: citeKey, entryType: entryType, fields: fields)
        try await createPublication(from: entry, item: item)
    }

    // MARK: - Publication Creation

    private func createPublication(from entry: BibTeXEntry, item: [String: Any]) async throws {
        let repository = PublicationRepository()

        // Get target library if specified
        let libraryID = (item["libraryId"] as? String).flatMap { UUID(uuidString: $0) }
        let library = await findLibrary(id: libraryID)

        // Note: Duplicate detection is handled by the extension via known identifiers cache.
        // If needed, additional deduplication can be done here using findExistingByIdentifiers.

        // Create publication
        let publication = await repository.create(from: entry, in: library, processLinkedFiles: false)

        // Update known identifiers cache for future duplicate detection
        updateKnownIdentifiers(from: entry)

        logger.info("Created publication: \(publication.citeKey)")
    }

    private func findLibrary(id: UUID?) async -> CDLibrary? {
        guard let id = id else { return nil }

        let context = PersistenceController.shared.viewContext
        return await MainActor.run {
            let request = NSFetchRequest<CDLibrary>(entityName: "Library")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }
    }

    // MARK: - Known Identifiers Cache

    /// Update the known identifiers cache used for duplicate detection in the extension.
    private func updateKnownIdentifiers(from entry: BibTeXEntry) {
        guard let defaults = defaults else { return }

        var known = defaults.dictionary(forKey: Keys.knownIdentifiers) as? [String: Bool] ?? [:]

        if let doi = entry.fields["doi"], !doi.isEmpty {
            known["doi:\(doi.lowercased())"] = true
        }

        if let arxivID = entry.fields["eprint"], !arxivID.isEmpty {
            let normalized = arxivID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
            known["arxiv:\(normalized)"] = true
        }

        if let bibcode = entry.fields["bibcode"], !bibcode.isEmpty {
            known["bibcode:\(bibcode)"] = true
        }

        defaults.set(known, forKey: Keys.knownIdentifiers)
    }

    /// Sync all known identifiers from the database to the App Group cache.
    /// Call this on app launch to ensure the extension has current data.
    public func syncKnownIdentifiers() async {
        guard let defaults = defaults else { return }

        let repository = PublicationRepository()
        let publications = await repository.fetchAll()

        var known: [String: Bool] = [:]

        for pub in publications {
            if let doi = pub.doi, !doi.isEmpty {
                known["doi:\(doi.lowercased())"] = true
            }

            if let arxivID = pub.arxivID, !arxivID.isEmpty {
                let normalized = arxivID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
                known["arxiv:\(normalized)"] = true
            }

            if let bibcode = pub.bibcode, !bibcode.isEmpty {
                known["bibcode:\(bibcode)"] = true
            }
        }

        defaults.set(known, forKey: Keys.knownIdentifiers)
        defaults.synchronize()

        logger.info("Synced \(known.count) identifiers to App Group")
    }

    // MARK: - Library List Sync

    /// Sync available libraries to the App Group for the extension's library picker.
    public func syncAvailableLibraries() async {
        guard let defaults = defaults else { return }

        let context = PersistenceController.shared.viewContext
        let libraries: [[String: String]] = await MainActor.run {
            let request = NSFetchRequest<CDLibrary>(entityName: "Library")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

            guard let results = try? context.fetch(request) else { return [] }

            return results.map { lib in
                [
                    "id": lib.id.uuidString,
                    "name": lib.name
                ]
            }
        }

        defaults.set(libraries, forKey: Keys.availableLibraries)
        defaults.synchronize()

        logger.info("Synced \(libraries.count) libraries to App Group")
    }

    // MARK: - Darwin Notification Observer

    /// Set up Darwin notification observers for notifications from the extension.
    /// Call this on app startup.
    public nonisolated func setupNotificationObserver() {
        // Import notification
        let importName = "com.imbib.safariImportReceived" as CFString

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task {
                    // Process any pending imports from the Safari extension
                    await SafariImportHandler.shared.processPendingImports()
                    // Sync data back to App Group for future extension use
                    // This is the first time we access the App Group, so TCC dialog
                    // may appear here (only when user actually uses the extension)
                    await SafariImportHandler.shared.syncKnownIdentifiers()
                    await SafariImportHandler.shared.syncAvailableLibraries()
                }
            },
            importName,
            nil,
            .deliverImmediately
        )

        // Smart search notification
        let smartSearchName = "com.imbib.safariSmartSearchReceived" as CFString

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task {
                    // Process any pending smart search requests from the Safari extension
                    await SafariImportHandler.shared.processPendingSmartSearches()
                }
            },
            smartSearchName,
            nil,
            .deliverImmediately
        )

        // Use a detached logger call since we're nonisolated
        Task { @MainActor in
            Logger(subsystem: "com.imbib", category: "safari-import")
                .info("Darwin notification observers registered (import + smart search)")
        }
    }
}

// MARK: - Errors

/// Errors that can occur during Safari import.
public enum SafariImportError: LocalizedError {
    case missingSourceType
    case unknownSourceType(String)
    case notFound(String)
    case createFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSourceType:
            return "Import item missing source type"
        case .unknownSourceType(let type):
            return "Unknown source type: \(type)"
        case .notFound(let identifier):
            return "Publication not found: \(identifier)"
        case .createFailed(let reason):
            return "Failed to create publication: \(reason)"
        }
    }
}
