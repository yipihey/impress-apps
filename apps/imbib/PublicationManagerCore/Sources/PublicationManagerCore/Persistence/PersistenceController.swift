//
//  PersistenceController.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - Persistence Configuration

/// Configuration options for the persistence controller.
public struct PersistenceConfiguration {
    /// Whether to use an in-memory store (for previews/testing)
    public var inMemory: Bool = false

    /// Whether to enable CloudKit sync (requires iCloud entitlement)
    public var enableCloudKit: Bool = false

    /// CloudKit container identifier (e.g., "iCloud.com.imbib.app")
    public var cloudKitContainerIdentifier: String?

    /// Custom store URL (for UI testing isolation)
    /// When set, the Core Data store will be created at this location instead of the default.
    public var storeURL: URL?

    public init(
        inMemory: Bool = false,
        enableCloudKit: Bool = false,
        cloudKitContainerIdentifier: String? = nil,
        storeURL: URL? = nil
    ) {
        self.inMemory = inMemory
        self.enableCloudKit = enableCloudKit
        self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
        self.storeURL = storeURL
    }

    /// Default configuration for production use
    public static let `default` = PersistenceConfiguration()

    /// Configuration for previews and testing
    public static let preview = PersistenceConfiguration(inMemory: true)

    /// Configuration with CloudKit enabled
    public static func withCloudKit(containerID: String) -> PersistenceConfiguration {
        PersistenceConfiguration(
            inMemory: false,
            enableCloudKit: true,
            cloudKitContainerIdentifier: containerID
        )
    }

    /// Configuration for UI testing with isolated, sandboxed storage.
    ///
    /// - Parameter storeURL: Custom file URL for the SQLite store (e.g., temp directory)
    /// - Returns: Configuration with CloudKit disabled and custom store location
    ///
    /// Usage:
    /// ```swift
    /// let config = PersistenceConfiguration.uiTesting(
    ///     storeURL: UITestingEnvironment.testStoreURL
    /// )
    /// ```
    public static func uiTesting(storeURL: URL) -> PersistenceConfiguration {
        PersistenceConfiguration(
            inMemory: false,  // Persistent within test session
            enableCloudKit: false,  // No iCloud sync during tests
            cloudKitContainerIdentifier: nil,
            storeURL: storeURL
        )
    }
}

// MARK: - Persistence Controller

/// Manages the Core Data stack for the publication database.
///
/// Supports optional CloudKit sync for cross-device library synchronization.
/// Enable CloudKit by passing a configuration with `enableCloudKit: true`.
public final class PersistenceController: @unchecked Sendable {

    // MARK: - Shared Instance

    /// Shared instance, configured based on the runtime environment.
    ///
    /// - **Production**: CloudKit sync enabled (if iCloud available and user hasn't disabled it)
    /// - **UI Testing**: Isolated SQLite store in temp directory, CloudKit disabled
    /// - **No iCloud**: Local-only storage fallback
    ///
    /// CloudKit container must be created at: https://developer.apple.com/account/resources/identifiers/list/cloudContainers
    /// The schema is automatically created on first sync (development mode).
    ///
    /// Note: This uses synchronous initialization. For async initialization with safe CloudKit
    /// pre-flight checks, use `createShared()` instead.
    public static let shared: PersistenceController = {
        // Use print() for very early init logging (before Logger may be ready)
        let hasPendingReset = CloudKitSyncSettingsStore.shared.pendingReset
        print("[imbib] PersistenceController.shared init - pendingReset=\(hasPendingReset)")
        Logger.persistence.warning("PersistenceController.shared init - pendingReset flag: \(hasPendingReset)")

        // Check for pending reset FIRST - delete store files before loading anything
        if hasPendingReset {
            print("[imbib] PENDING RESET DETECTED - deleting store files!")
            Logger.persistence.warning("PENDING RESET DETECTED - deleting local store files")
            deleteLocalStoreFiles()
            CloudKitSyncSettingsStore.shared.pendingReset = false
            // Re-enable CloudKit sync after reset - it was disabled during resetToFirstRun()
            // to stop ongoing sync operations. Now that we have a fresh store, sync can resume.
            CloudKitSyncSettingsStore.shared.isDisabledByUser = false
            print("[imbib] Pending reset complete - flags cleared, CloudKit re-enabled")
            Logger.persistence.warning("Pending reset complete - flags cleared, CloudKit re-enabled")
        }

        // UI Testing mode - use isolated storage
        if UITestingEnvironment.isUITesting {
            Logger.persistence.info("UI Testing mode detected - using sandboxed persistence")
            UITestingEnvironment.performFullCleanup()
            UITestingEnvironment.ensureTestDirectoryExists()
            return PersistenceController(
                configuration: .uiTesting(storeURL: UITestingEnvironment.testStoreURL)
            )
        }

        // Check if user explicitly disabled sync
        if CloudKitSyncSettingsStore.shared.isDisabledByUser {
            Logger.persistence.info("CloudKit sync disabled by user preference")
            return PersistenceController(configuration: .default)
        }

        // Quick synchronous check for iCloud availability
        // This doesn't guarantee CloudKit will work, but filters out obvious non-availability
        guard FileManager.default.ubiquityIdentityToken != nil else {
            Logger.persistence.info("iCloud not available - using local storage")
            return PersistenceController(configuration: .default)
        }

        // iCloud is available - enable CloudKit sync
        Logger.persistence.info("iCloud available - enabling CloudKit sync")
        return PersistenceController(configuration: .withCloudKit(containerID: cloudKitContainerID))
    }()

    // MARK: - Async Factory Method

    /// CloudKit container identifier
    private static let cloudKitContainerID = "iCloud.com.imbib.app"

    /// Creates a shared PersistenceController with safe CloudKit pre-flight checks.
    ///
    /// This method performs safe asynchronous checks before attempting to enable CloudKit:
    /// 1. Checks if user has explicitly disabled sync
    /// 2. Checks if iCloud identity token exists
    /// 3. Checks CKContainer.accountStatus() - safe API that won't crash
    ///
    /// If all checks pass, CloudKit sync is enabled. Otherwise, falls back to local storage.
    ///
    /// - Returns: A configured PersistenceController
    public static func createShared() async -> PersistenceController {
        // Check for pending reset FIRST - delete store files before loading anything
        if CloudKitSyncSettingsStore.shared.pendingReset {
            Logger.persistence.warning("Pending reset detected - deleting local store files")
            deleteLocalStoreFiles()
            CloudKitSyncSettingsStore.shared.pendingReset = false
            Logger.persistence.info("Pending reset complete - store files deleted")
        }

        // UI Testing mode - use isolated storage
        if UITestingEnvironment.isUITesting {
            Logger.persistence.info("UI Testing mode detected - using sandboxed persistence")
            UITestingEnvironment.performFullCleanup()
            UITestingEnvironment.ensureTestDirectoryExists()
            return PersistenceController(
                configuration: .uiTesting(storeURL: UITestingEnvironment.testStoreURL)
            )
        }

        // Check if user explicitly disabled sync
        if CloudKitSyncSettingsStore.shared.isDisabledByUser {
            Logger.persistence.info("CloudKit sync disabled by user preference")
            return PersistenceController(configuration: .default)
        }

        // Safe pre-flight check - auto-enable if available
        if await isCloudKitSafelyAvailable() {
            Logger.persistence.info("CloudKit available - enabling sync")
            CloudKitSyncSettingsStore.shared.clearError()
            return PersistenceController(configuration: .withCloudKit(containerID: cloudKitContainerID))
        }

        Logger.persistence.info("CloudKit not available - using local storage")
        return PersistenceController(configuration: .default)
    }

    /// Deletes local Core Data store files.
    ///
    /// Called during pending reset to ensure clean slate before loading.
    /// This deletes the SQLite database and associated files (-shm, -wal).
    private static func deleteLocalStoreFiles() {
        let fileManager = FileManager.default

        // Get the default store directory (Application Support)
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            Logger.persistence.error("Could not find Application Support directory")
            return
        }

        Logger.persistence.warning("Deleting store files from: \(appSupportURL.path)")

        // Try multiple possible locations for the store files
        let possibleDirectories = [
            appSupportURL,
            appSupportURL.appendingPathComponent("PublicationManager"),
            appSupportURL.appendingPathComponent("imbib"),
        ]

        var deletedCount = 0

        for directory in possibleDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            do {
                let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for item in contents {
                    let name = item.lastPathComponent

                    // Delete SQLite store files
                    let shouldDelete = name.hasPrefix("PublicationManager") ||
                        name.hasPrefix(".PublicationManager") ||
                        name.hasPrefix("CoreDataCloudKit") ||
                        name.hasPrefix("ckAssetFiles") ||
                        name.contains("CloudKit") ||
                        name.hasSuffix(".sqlite") ||
                        name.hasSuffix(".sqlite-shm") ||
                        name.hasSuffix(".sqlite-wal")

                    if shouldDelete {
                        try fileManager.removeItem(at: item)
                        deletedCount += 1
                        Logger.persistence.info("Deleted: \(item.path)")
                    }
                }
            } catch {
                Logger.persistence.warning("Could not enumerate \(directory.path): \(error.localizedDescription)")
            }
        }

        // Also use NSPersistentContainer's default directory URL
        let defaultURL = NSPersistentContainer.defaultDirectoryURL()
        Logger.persistence.info("NSPersistentContainer default directory: \(defaultURL.path)")

        if defaultURL != appSupportURL {
            do {
                let contents = try fileManager.contentsOfDirectory(at: defaultURL, includingPropertiesForKeys: nil)
                for item in contents {
                    let name = item.lastPathComponent
                    if name.hasPrefix("PublicationManager") || name.contains("CloudKit") {
                        try fileManager.removeItem(at: item)
                        deletedCount += 1
                        Logger.persistence.info("Deleted from default dir: \(item.path)")
                    }
                }
            } catch {
                Logger.persistence.warning("Could not enumerate default directory: \(error.localizedDescription)")
            }
        }

        Logger.persistence.warning("Total files deleted: \(deletedCount)")
    }

    /// Performs a safe pre-flight check to determine if CloudKit is available.
    ///
    /// This check uses safe APIs that won't crash even if the CloudKit container
    /// doesn't exist or entitlements are misconfigured:
    /// 1. FileManager.ubiquityIdentityToken - checks if signed into iCloud
    /// 2. CKContainer.accountStatus() - checks account availability
    ///
    /// - Returns: true if CloudKit can be safely enabled
    private static func isCloudKitSafelyAvailable() async -> Bool {
        // First check: ubiquity identity token (quick, synchronous)
        guard FileManager.default.ubiquityIdentityToken != nil else {
            Logger.persistence.debug("CloudKit pre-flight: No ubiquity identity token")
            return false
        }

        // Second check: CKContainer account status (async, safe)
        #if canImport(CloudKit)
        do {
            let container = CKContainer(identifier: cloudKitContainerID)
            let status = try await container.accountStatus()

            switch status {
            case .available:
                Logger.persistence.debug("CloudKit pre-flight: Account available")
                return true
            case .noAccount:
                Logger.persistence.debug("CloudKit pre-flight: No iCloud account")
                CloudKitSyncSettingsStore.shared.lastError = "Not signed in to iCloud"
                return false
            case .restricted:
                Logger.persistence.debug("CloudKit pre-flight: Account restricted")
                CloudKitSyncSettingsStore.shared.lastError = "iCloud access restricted"
                return false
            case .couldNotDetermine:
                Logger.persistence.debug("CloudKit pre-flight: Could not determine status")
                CloudKitSyncSettingsStore.shared.lastError = "Could not determine iCloud status"
                return false
            case .temporarilyUnavailable:
                Logger.persistence.debug("CloudKit pre-flight: Temporarily unavailable")
                CloudKitSyncSettingsStore.shared.lastError = "iCloud temporarily unavailable"
                return false
            @unknown default:
                Logger.persistence.debug("CloudKit pre-flight: Unknown status")
                return false
            }
        } catch {
            Logger.persistence.warning("CloudKit pre-flight check failed: \(error.localizedDescription)")
            CloudKitSyncSettingsStore.shared.lastError = error.localizedDescription
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Preview Instance

    public static let preview: PersistenceController = {
        let controller = PersistenceController(configuration: .preview)
        // Add sample data for previews
        controller.addSampleData()
        return controller
    }()

    // MARK: - Store Load State

    /// Represents the current state of the persistent store loading process.
    public enum StoreLoadState: Sendable {
        case loading
        case loaded
        case failed(Error)
        case fallbackToLocal
    }

    // MARK: - Properties

    public let container: NSPersistentContainer
    public let configuration: PersistenceConfiguration

    /// Current state of the persistent store loading.
    /// Observe `.persistentStoreLoadFailed` or `.persistentStoreFellBackToLocal` notifications
    /// for reactive updates when state changes.
    public private(set) var storeLoadState: StoreLoadState = .loading

    public var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    /// Whether CloudKit sync is enabled
    public var isCloudKitEnabled: Bool {
        configuration.enableCloudKit
    }

    // MARK: - Initialization

    public convenience init(inMemory: Bool = false) {
        self.init(configuration: PersistenceConfiguration(inMemory: inMemory))
    }

    public init(configuration: PersistenceConfiguration) {
        Logger.persistence.entering()

        self.configuration = configuration

        // Create the managed object model programmatically
        let model = Self.createManagedObjectModel()

        // Use CloudKit container if enabled, otherwise standard container
        if configuration.enableCloudKit {
            container = NSPersistentCloudKitContainer(name: "PublicationManager", managedObjectModel: model)
            Logger.persistence.info("Using NSPersistentCloudKitContainer for CloudKit sync")
        } else {
            container = NSPersistentContainer(name: "PublicationManager", managedObjectModel: model)
            Logger.persistence.info("Using standard NSPersistentContainer (no CloudKit)")
        }

        // Configure store description
        if let description = container.persistentStoreDescriptions.first {
            if configuration.inMemory {
                description.url = URL(fileURLWithPath: "/dev/null")
            } else if let storeURL = configuration.storeURL {
                // Use custom store URL (for UI testing isolation)
                description.url = storeURL
                Logger.persistence.info("Using custom store URL: \(storeURL.path)")
            }

            if configuration.enableCloudKit {
                // Enable CloudKit sync
                if let containerID = configuration.cloudKitContainerIdentifier {
                    description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                        containerIdentifier: containerID
                    )
                    Logger.persistence.info("CloudKit container: \(containerID)")
                }

                // Enable history tracking for CloudKit
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            }
        }

        // Capture configuration for use in closure
        let enableCloudKit = configuration.enableCloudKit

        container.loadPersistentStores { [weak self] description, error in
            guard let self = self else { return }

            if let error = error as NSError? {
                Logger.persistence.error("Failed to load persistent stores: \(error), \(error.userInfo)")
                self.handleStoreLoadFailure(error)
                return
            }

            Logger.persistence.info("Loaded persistent store: \(description.url?.absoluteString ?? "unknown")")
            self.storeLoadState = .loaded

            // IMPORTANT: Only set up CloudKit observers AFTER store is loaded successfully.
            // Setting up observers before the store is ready causes race conditions with
            // CloudKit's background queue that can crash on startup.
            if enableCloudKit {
                self.setupCloudKitObservers()
                Logger.persistence.debug("CloudKit observers configured after store load")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        Logger.persistence.exiting()
    }

    // MARK: - Store Load Error Handling

    /// Handle store load failures with graceful fallback for CloudKit errors.
    private func handleStoreLoadFailure(_ error: Error) {
        let nsError = error as NSError

        // Check if this is a CloudKit-specific error that allows fallback to local-only mode.
        // CloudKit errors have domain containing "CKError" or are wrapped Core Data errors
        // with CloudKit underlying errors.
        let isCloudKitError = nsError.domain.contains("CKError") ||
            nsError.domain == "NSCloudKitMirroringError" ||
            (nsError.domain == "NSCocoaErrorDomain" && nsError.userInfo[NSUnderlyingErrorKey] != nil &&
             "\(nsError.userInfo[NSUnderlyingErrorKey]!)".contains("CKError"))

        if isCloudKitError && configuration.enableCloudKit {
            Logger.persistence.warning("CloudKit error during store load, attempting local fallback: \(error.localizedDescription)")
            attemptLocalFallback(originalError: error)
        } else {
            // Non-recoverable error - update state and notify
            storeLoadState = .failed(error)
            NotificationCenter.default.post(
                name: .persistentStoreLoadFailed,
                object: self,
                userInfo: ["error": error]
            )
        }
    }

    /// Attempt to recover from CloudKit failure by creating a local-only store.
    private func attemptLocalFallback(originalError: Error) {
        Logger.persistence.info("Attempting local-only store fallback")

        // Note: Creating a completely new store at runtime is complex because the container
        // is already configured. For now, we mark the state and notify the app.
        // The app can restart with CloudKit disabled if needed.

        storeLoadState = .fallbackToLocal
        NotificationCenter.default.post(
            name: .persistentStoreFellBackToLocal,
            object: self,
            userInfo: ["originalError": originalError]
        )

        Logger.persistence.warning("Store load failed with CloudKit error. App should handle fallback or prompt user.")
    }

    // MARK: - CloudKit Observers

    private func setupCloudKitObservers() {
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            self?.handleRemoteChanges()
        }
    }

    private func handleRemoteChanges() {
        // Refresh view context to pick up remote changes
        viewContext.perform {
            self.viewContext.refreshAllObjects()
        }

        // Post notification for UI updates
        NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
    }

    // MARK: - Core Data Model Creation

    /// Cached model to avoid multiple entity descriptions claiming the same NSManagedObject subclasses
    private static let cachedModel: NSManagedObjectModel = createManagedObjectModelInternal()

    private static func createManagedObjectModel() -> NSManagedObjectModel {
        return cachedModel
    }

    private static func createManagedObjectModelInternal() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // Create entities
        let publicationEntity = createPublicationEntity()
        let authorEntity = createAuthorEntity()
        let publicationAuthorEntity = createPublicationAuthorEntity()
        let linkedFileEntity = createLinkedFileEntity()
        let tagEntity = createTagEntity()
        let attachmentTagEntity = createAttachmentTagEntity()
        let collectionEntity = createCollectionEntity()
        let libraryEntity = createLibraryEntity()
        let smartSearchEntity = createSmartSearchEntity()
        let mutedItemEntity = createMutedItemEntity()
        let dismissedPaperEntity = createDismissedPaperEntity()
        let scixLibraryEntity = createSciXLibraryEntity()
        let scixPendingChangeEntity = createSciXPendingChangeEntity()
        let annotationEntity = createAnnotationEntity()
        let recommendationProfileEntity = createRecommendationProfileEntity()

        // Set up relationships
        setupRelationships(
            publication: publicationEntity,
            author: authorEntity,
            publicationAuthor: publicationAuthorEntity,
            linkedFile: linkedFileEntity,
            tag: tagEntity,
            collection: collectionEntity
        )

        // Set up library-smart search relationship
        setupLibrarySmartSearchRelationship(
            library: libraryEntity,
            smartSearch: smartSearchEntity
        )

        // ADR-016: Set up smart search-collection relationship
        setupSmartSearchCollectionRelationship(
            smartSearch: smartSearchEntity,
            collection: collectionEntity
        )

        // ADR-016: Set up library-lastSearchCollection relationship
        setupLibraryLastSearchRelationship(
            library: libraryEntity,
            collection: collectionEntity
        )

        // Set up library <-> publications relationship
        setupLibraryPublicationsRelationship(
            library: libraryEntity,
            publication: publicationEntity
        )

        // Set up library <-> collections relationship
        setupLibraryCollectionsRelationship(
            library: libraryEntity,
            collection: collectionEntity
        )

        // Set up collection parent/child hierarchy for exploration drill-down
        setupCollectionHierarchyRelationship(
            collection: collectionEntity
        )

        // Set up linkedFile <-> attachmentTag relationship (many-to-many)
        setupLinkedFileAttachmentTagRelationship(
            linkedFile: linkedFileEntity,
            attachmentTag: attachmentTagEntity
        )

        // Set up SciX library relationships
        setupSciXLibraryPublicationsRelationship(
            scixLibrary: scixLibraryEntity,
            publication: publicationEntity
        )

        setupSciXLibraryPendingChangesRelationship(
            scixLibrary: scixLibraryEntity,
            pendingChange: scixPendingChangeEntity
        )

        // Set up annotation relationships
        setupAnnotationRelationships(
            annotation: annotationEntity,
            linkedFile: linkedFileEntity
        )

        // Set up recommendation profile relationship
        setupRecommendationProfileRelationship(
            recommendationProfile: recommendationProfileEntity,
            library: libraryEntity
        )

        model.entities = [
            publicationEntity,
            authorEntity,
            publicationAuthorEntity,
            linkedFileEntity,
            tagEntity,
            attachmentTagEntity,
            collectionEntity,
            libraryEntity,
            smartSearchEntity,
            mutedItemEntity,
            dismissedPaperEntity,
            scixLibraryEntity,
            scixPendingChangeEntity,
            annotationEntity,
            recommendationProfileEntity,
        ]

        return model
    }

    // MARK: - Entity Creation

    private static func createPublicationEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Publication"
        entity.managedObjectClassName = "PublicationManagerCore.CDPublication"

        var properties: [NSPropertyDescription] = []

        // Primary key
        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        // Core fields
        let citeKey = NSAttributeDescription()
        citeKey.name = "citeKey"
        citeKey.attributeType = .stringAttributeType
        citeKey.isOptional = false
        citeKey.defaultValue = ""  // CloudKit requires default value
        properties.append(citeKey)

        let entryType = NSAttributeDescription()
        entryType.name = "entryType"
        entryType.attributeType = .stringAttributeType
        entryType.isOptional = false
        entryType.defaultValue = "article"
        properties.append(entryType)

        let title = NSAttributeDescription()
        title.name = "title"
        title.attributeType = .stringAttributeType
        title.isOptional = true
        properties.append(title)

        let year = NSAttributeDescription()
        year.name = "year"
        year.attributeType = .integer16AttributeType
        year.isOptional = true
        properties.append(year)

        let abstract = NSAttributeDescription()
        abstract.name = "abstract"
        abstract.attributeType = .stringAttributeType
        abstract.isOptional = true
        properties.append(abstract)

        let doi = NSAttributeDescription()
        doi.name = "doi"
        doi.attributeType = .stringAttributeType
        doi.isOptional = true
        properties.append(doi)

        let url = NSAttributeDescription()
        url.name = "url"
        url.attributeType = .stringAttributeType
        url.isOptional = true
        properties.append(url)

        // Raw BibTeX for round-trip
        let rawBibTeX = NSAttributeDescription()
        rawBibTeX.name = "rawBibTeX"
        rawBibTeX.attributeType = .stringAttributeType
        rawBibTeX.isOptional = true
        properties.append(rawBibTeX)

        // JSON storage for all fields
        let rawFields = NSAttributeDescription()
        rawFields.name = "rawFields"
        rawFields.attributeType = .stringAttributeType
        rawFields.isOptional = true
        properties.append(rawFields)

        // Field timestamps for conflict resolution
        let fieldTimestamps = NSAttributeDescription()
        fieldTimestamps.name = "fieldTimestamps"
        fieldTimestamps.attributeType = .stringAttributeType
        fieldTimestamps.isOptional = true
        properties.append(fieldTimestamps)

        // Metadata
        let dateAdded = NSAttributeDescription()
        dateAdded.name = "dateAdded"
        dateAdded.attributeType = .dateAttributeType
        dateAdded.isOptional = false
        dateAdded.defaultValue = Date()
        properties.append(dateAdded)

        let dateModified = NSAttributeDescription()
        dateModified.name = "dateModified"
        dateModified.attributeType = .dateAttributeType
        dateModified.isOptional = false
        dateModified.defaultValue = Date()
        properties.append(dateModified)

        // Enrichment fields (ADR-014)
        let citationCount = NSAttributeDescription()
        citationCount.name = "citationCount"
        citationCount.attributeType = .integer32AttributeType
        citationCount.isOptional = false
        citationCount.defaultValue = Int32(-1)  // -1 = never enriched
        properties.append(citationCount)

        let referenceCount = NSAttributeDescription()
        referenceCount.name = "referenceCount"
        referenceCount.attributeType = .integer32AttributeType
        referenceCount.isOptional = false
        referenceCount.defaultValue = Int32(-1)  // -1 = never enriched
        properties.append(referenceCount)

        let enrichmentSource = NSAttributeDescription()
        enrichmentSource.name = "enrichmentSource"
        enrichmentSource.attributeType = .stringAttributeType
        enrichmentSource.isOptional = true
        properties.append(enrichmentSource)

        let enrichmentDate = NSAttributeDescription()
        enrichmentDate.name = "enrichmentDate"
        enrichmentDate.attributeType = .dateAttributeType
        enrichmentDate.isOptional = true
        properties.append(enrichmentDate)

        // ADR-016: Online source metadata
        let originalSourceID = NSAttributeDescription()
        originalSourceID.name = "originalSourceID"
        originalSourceID.attributeType = .stringAttributeType
        originalSourceID.isOptional = true
        properties.append(originalSourceID)

        let pdfLinksJSON = NSAttributeDescription()
        pdfLinksJSON.name = "pdfLinksJSON"
        pdfLinksJSON.attributeType = .stringAttributeType
        pdfLinksJSON.isOptional = true
        properties.append(pdfLinksJSON)

        let webURL = NSAttributeDescription()
        webURL.name = "webURL"
        webURL.attributeType = .stringAttributeType
        webURL.isOptional = true
        properties.append(webURL)

        // ADR-016: PDF download state
        let hasPDFDownloaded = NSAttributeDescription()
        hasPDFDownloaded.name = "hasPDFDownloaded"
        hasPDFDownloaded.attributeType = .booleanAttributeType
        hasPDFDownloaded.isOptional = false
        hasPDFDownloaded.defaultValue = false
        properties.append(hasPDFDownloaded)

        let pdfDownloadDate = NSAttributeDescription()
        pdfDownloadDate.name = "pdfDownloadDate"
        pdfDownloadDate.attributeType = .dateAttributeType
        pdfDownloadDate.isOptional = true
        properties.append(pdfDownloadDate)

        // ADR-016: Extended identifiers for deduplication
        let semanticScholarID = NSAttributeDescription()
        semanticScholarID.name = "semanticScholarID"
        semanticScholarID.attributeType = .stringAttributeType
        semanticScholarID.isOptional = true
        properties.append(semanticScholarID)

        // Normalized arXiv ID for O(1) lookups (indexed)
        let arxivIDNormalized = NSAttributeDescription()
        arxivIDNormalized.name = "arxivIDNormalized"
        arxivIDNormalized.attributeType = .stringAttributeType
        arxivIDNormalized.isOptional = true
        properties.append(arxivIDNormalized)

        // Normalized bibcode for O(1) lookups (indexed)
        let bibcodeNormalized = NSAttributeDescription()
        bibcodeNormalized.name = "bibcodeNormalized"
        bibcodeNormalized.attributeType = .stringAttributeType
        bibcodeNormalized.isOptional = true
        properties.append(bibcodeNormalized)

        let openAlexID = NSAttributeDescription()
        openAlexID.name = "openAlexID"
        openAlexID.attributeType = .stringAttributeType
        openAlexID.isOptional = true
        properties.append(openAlexID)

        // Read status (Apple Mail styling)
        let isRead = NSAttributeDescription()
        isRead.name = "isRead"
        isRead.attributeType = .booleanAttributeType
        isRead.isOptional = false
        isRead.defaultValue = false
        properties.append(isRead)

        let dateRead = NSAttributeDescription()
        dateRead.name = "dateRead"
        dateRead.attributeType = .dateAttributeType
        dateRead.isOptional = true
        properties.append(dateRead)

        // Star/flag status (Inbox triage)
        let isStarred = NSAttributeDescription()
        isStarred.name = "isStarred"
        isStarred.attributeType = .booleanAttributeType
        isStarred.isOptional = false
        isStarred.defaultValue = false
        properties.append(isStarred)

        // Inbox tracking
        let dateAddedToInbox = NSAttributeDescription()
        dateAddedToInbox.name = "dateAddedToInbox"
        dateAddedToInbox.attributeType = .dateAttributeType
        dateAddedToInbox.isOptional = true
        properties.append(dateAddedToInbox)

        entity.properties = properties

        // Add indexes for O(1) deduplication lookups
        let doiIndex = NSFetchIndexDescription(name: "byDOI", elements: [
            NSFetchIndexElementDescription(property: doi, collationType: .binary)
        ])
        let arxivIndex = NSFetchIndexDescription(name: "byArxivID", elements: [
            NSFetchIndexElementDescription(property: arxivIDNormalized, collationType: .binary)
        ])
        let bibcodeIndex = NSFetchIndexDescription(name: "byBibcode", elements: [
            NSFetchIndexElementDescription(property: bibcodeNormalized, collationType: .binary)
        ])
        let semanticScholarIndex = NSFetchIndexDescription(name: "bySemanticScholarID", elements: [
            NSFetchIndexElementDescription(property: semanticScholarID, collationType: .binary)
        ])
        let openAlexIndex = NSFetchIndexDescription(name: "byOpenAlexID", elements: [
            NSFetchIndexElementDescription(property: openAlexID, collationType: .binary)
        ])
        entity.indexes = [doiIndex, arxivIndex, bibcodeIndex, semanticScholarIndex, openAlexIndex]

        return entity
    }

    private static func createAuthorEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Author"
        entity.managedObjectClassName = "PublicationManagerCore.CDAuthor"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let familyName = NSAttributeDescription()
        familyName.name = "familyName"
        familyName.attributeType = .stringAttributeType
        familyName.isOptional = false
        familyName.defaultValue = ""  // CloudKit requires default value
        properties.append(familyName)

        let givenName = NSAttributeDescription()
        givenName.name = "givenName"
        givenName.attributeType = .stringAttributeType
        givenName.isOptional = true
        properties.append(givenName)

        let nameSuffix = NSAttributeDescription()
        nameSuffix.name = "nameSuffix"
        nameSuffix.attributeType = .stringAttributeType
        nameSuffix.isOptional = true
        properties.append(nameSuffix)

        entity.properties = properties
        return entity
    }

    private static func createPublicationAuthorEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "PublicationAuthor"
        entity.managedObjectClassName = "PublicationManagerCore.CDPublicationAuthor"

        var properties: [NSPropertyDescription] = []

        let order = NSAttributeDescription()
        order.name = "order"
        order.attributeType = .integer16AttributeType
        order.isOptional = false
        order.defaultValue = 0
        properties.append(order)

        entity.properties = properties
        return entity
    }

    private static func createLinkedFileEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "LinkedFile"
        entity.managedObjectClassName = "PublicationManagerCore.CDLinkedFile"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let relativePath = NSAttributeDescription()
        relativePath.name = "relativePath"
        relativePath.attributeType = .stringAttributeType
        relativePath.isOptional = false
        relativePath.defaultValue = ""  // CloudKit requires default value
        properties.append(relativePath)

        let filename = NSAttributeDescription()
        filename.name = "filename"
        filename.attributeType = .stringAttributeType
        filename.isOptional = false
        filename.defaultValue = ""  // CloudKit requires default value
        properties.append(filename)

        let fileType = NSAttributeDescription()
        fileType.name = "fileType"
        fileType.attributeType = .stringAttributeType
        fileType.isOptional = true
        fileType.defaultValue = "pdf"
        properties.append(fileType)

        let sha256 = NSAttributeDescription()
        sha256.name = "sha256"
        sha256.attributeType = .stringAttributeType
        sha256.isOptional = true
        properties.append(sha256)

        let dateAdded = NSAttributeDescription()
        dateAdded.name = "dateAdded"
        dateAdded.attributeType = .dateAttributeType
        dateAdded.isOptional = false
        dateAdded.defaultValue = Date()
        properties.append(dateAdded)

        // General attachment support: user-editable display name
        let displayName = NSAttributeDescription()
        displayName.name = "displayName"
        displayName.attributeType = .stringAttributeType
        displayName.isOptional = true
        properties.append(displayName)

        // General attachment support: cached file size for UI display
        let fileSize = NSAttributeDescription()
        fileSize.name = "fileSize"
        fileSize.attributeType = .integer64AttributeType
        fileSize.isOptional = false
        fileSize.defaultValue = Int64(0)
        properties.append(fileSize)

        // General attachment support: MIME type for accurate type detection
        let mimeType = NSAttributeDescription()
        mimeType.name = "mimeType"
        mimeType.attributeType = .stringAttributeType
        mimeType.isOptional = true
        properties.append(mimeType)

        // CloudKit PDF sync: Binary file data for cross-device sync
        // Uses allowsExternalBinaryDataStorage so CloudKit handles it as CKAsset
        let fileData = NSAttributeDescription()
        fileData.name = "fileData"
        fileData.attributeType = .binaryDataAttributeType
        fileData.isOptional = true
        fileData.allowsExternalBinaryDataStorage = true
        properties.append(fileData)

        entity.properties = properties
        return entity
    }

    private static func createTagEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Tag"
        entity.managedObjectClassName = "PublicationManagerCore.CDTag"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""  // CloudKit requires default value
        properties.append(name)

        let color = NSAttributeDescription()
        color.name = "color"
        color.attributeType = .stringAttributeType
        color.isOptional = true
        properties.append(color)

        entity.properties = properties
        return entity
    }

    private static func createAttachmentTagEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "AttachmentTag"
        entity.managedObjectClassName = "PublicationManagerCore.CDAttachmentTag"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""  // CloudKit requires default value
        properties.append(name)

        let color = NSAttributeDescription()
        color.name = "color"
        color.attributeType = .stringAttributeType
        color.isOptional = true
        properties.append(color)

        let order = NSAttributeDescription()
        order.name = "order"
        order.attributeType = .integer16AttributeType
        order.isOptional = false
        order.defaultValue = Int16(0)
        properties.append(order)

        entity.properties = properties
        return entity
    }

    private static func createCollectionEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Collection"
        entity.managedObjectClassName = "PublicationManagerCore.CDCollection"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""  // CloudKit requires default value
        properties.append(name)

        let isSmartCollection = NSAttributeDescription()
        isSmartCollection.name = "isSmartCollection"
        isSmartCollection.attributeType = .booleanAttributeType
        isSmartCollection.isOptional = false
        isSmartCollection.defaultValue = false
        properties.append(isSmartCollection)

        let predicate = NSAttributeDescription()
        predicate.name = "predicate"
        predicate.attributeType = .stringAttributeType
        predicate.isOptional = true
        properties.append(predicate)

        // ADR-016: Unified Paper Model
        let isSmartSearchResults = NSAttributeDescription()
        isSmartSearchResults.name = "isSmartSearchResults"
        isSmartSearchResults.attributeType = .booleanAttributeType
        isSmartSearchResults.isOptional = false
        isSmartSearchResults.defaultValue = false
        properties.append(isSmartSearchResults)

        let isSystemCollection = NSAttributeDescription()
        isSystemCollection.name = "isSystemCollection"
        isSystemCollection.attributeType = .booleanAttributeType
        isSystemCollection.isOptional = false
        isSystemCollection.defaultValue = false
        properties.append(isSystemCollection)

        entity.properties = properties
        return entity
    }

    private static func createLibraryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Library"
        entity.managedObjectClassName = "PublicationManagerCore.CDLibrary"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""
        properties.append(name)

        let bibFilePath = NSAttributeDescription()
        bibFilePath.name = "bibFilePath"
        bibFilePath.attributeType = .stringAttributeType
        bibFilePath.isOptional = true
        properties.append(bibFilePath)

        let papersDirectoryPath = NSAttributeDescription()
        papersDirectoryPath.name = "papersDirectoryPath"
        papersDirectoryPath.attributeType = .stringAttributeType
        papersDirectoryPath.isOptional = true
        properties.append(papersDirectoryPath)

        let bookmarkData = NSAttributeDescription()
        bookmarkData.name = "bookmarkData"
        bookmarkData.attributeType = .binaryDataAttributeType
        bookmarkData.isOptional = true
        properties.append(bookmarkData)

        let dateCreated = NSAttributeDescription()
        dateCreated.name = "dateCreated"
        dateCreated.attributeType = .dateAttributeType
        dateCreated.isOptional = false
        dateCreated.defaultValue = Date()
        properties.append(dateCreated)

        let dateLastOpened = NSAttributeDescription()
        dateLastOpened.name = "dateLastOpened"
        dateLastOpened.attributeType = .dateAttributeType
        dateLastOpened.isOptional = true
        properties.append(dateLastOpened)

        let isDefault = NSAttributeDescription()
        isDefault.name = "isDefault"
        isDefault.attributeType = .booleanAttributeType
        isDefault.isOptional = false
        isDefault.defaultValue = false
        properties.append(isDefault)

        let sortOrder = NSAttributeDescription()
        sortOrder.name = "sortOrder"
        sortOrder.attributeType = .integer16AttributeType
        sortOrder.isOptional = false
        sortOrder.defaultValue = Int16(0)
        properties.append(sortOrder)

        let isInbox = NSAttributeDescription()
        isInbox.name = "isInbox"
        isInbox.attributeType = .booleanAttributeType
        isInbox.isOptional = false
        isInbox.defaultValue = false
        properties.append(isInbox)

        // System library flag (for Exploration library)
        let isSystemLibrary = NSAttributeDescription()
        isSystemLibrary.name = "isSystemLibrary"
        isSystemLibrary.attributeType = .booleanAttributeType
        isSystemLibrary.isOptional = false
        isSystemLibrary.defaultValue = false
        properties.append(isSystemLibrary)

        // Keep library flag (for Inbox triage)
        let isKeepLibrary = NSAttributeDescription()
        isKeepLibrary.name = "isKeepLibrary"
        isKeepLibrary.attributeType = .booleanAttributeType
        isKeepLibrary.isOptional = false
        isKeepLibrary.defaultValue = false
        properties.append(isKeepLibrary)

        // Dismissed library flag (for Inbox triage)
        let isDismissedLibrary = NSAttributeDescription()
        isDismissedLibrary.name = "isDismissedLibrary"
        isDismissedLibrary.attributeType = .booleanAttributeType
        isDismissedLibrary.isOptional = false
        isDismissedLibrary.defaultValue = false
        properties.append(isDismissedLibrary)

        // Local-only flag (for Exploration library - not synced via CloudKit)
        let isLocalOnly = NSAttributeDescription()
        isLocalOnly.name = "isLocalOnly"
        isLocalOnly.attributeType = .booleanAttributeType
        isLocalOnly.isOptional = false
        isLocalOnly.defaultValue = false
        properties.append(isLocalOnly)

        // Device identifier for local-only libraries (to identify which device created them)
        let deviceIdentifier = NSAttributeDescription()
        deviceIdentifier.name = "deviceIdentifier"
        deviceIdentifier.attributeType = .stringAttributeType
        deviceIdentifier.isOptional = true
        properties.append(deviceIdentifier)

        entity.properties = properties
        return entity
    }

    private static func createSmartSearchEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "SmartSearch"
        entity.managedObjectClassName = "PublicationManagerCore.CDSmartSearch"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""  // CloudKit requires default value
        properties.append(name)

        let query = NSAttributeDescription()
        query.name = "query"
        query.attributeType = .stringAttributeType
        query.isOptional = false
        query.defaultValue = ""  // CloudKit requires default value
        properties.append(query)

        let sourceIDs = NSAttributeDescription()
        sourceIDs.name = "sourceIDs"
        sourceIDs.attributeType = .stringAttributeType
        sourceIDs.isOptional = true
        properties.append(sourceIDs)

        let dateCreated = NSAttributeDescription()
        dateCreated.name = "dateCreated"
        dateCreated.attributeType = .dateAttributeType
        dateCreated.isOptional = false
        dateCreated.defaultValue = Date()
        properties.append(dateCreated)

        let dateLastExecuted = NSAttributeDescription()
        dateLastExecuted.name = "dateLastExecuted"
        dateLastExecuted.attributeType = .dateAttributeType
        dateLastExecuted.isOptional = true
        properties.append(dateLastExecuted)

        let order = NSAttributeDescription()
        order.name = "order"
        order.attributeType = .integer16AttributeType
        order.isOptional = false
        order.defaultValue = 0
        properties.append(order)

        // ADR-016: Unified Paper Model
        let maxResults = NSAttributeDescription()
        maxResults.name = "maxResults"
        maxResults.attributeType = .integer16AttributeType
        maxResults.isOptional = false
        maxResults.defaultValue = Int16(50)  // Default limit of 50 results
        properties.append(maxResults)

        // Inbox feature: Smart searches can feed papers to the Inbox
        let feedsToInbox = NSAttributeDescription()
        feedsToInbox.name = "feedsToInbox"
        feedsToInbox.attributeType = .booleanAttributeType
        feedsToInbox.isOptional = false
        feedsToInbox.defaultValue = false
        properties.append(feedsToInbox)

        let autoRefreshEnabled = NSAttributeDescription()
        autoRefreshEnabled.name = "autoRefreshEnabled"
        autoRefreshEnabled.attributeType = .booleanAttributeType
        autoRefreshEnabled.isOptional = false
        autoRefreshEnabled.defaultValue = false
        properties.append(autoRefreshEnabled)

        let refreshIntervalSeconds = NSAttributeDescription()
        refreshIntervalSeconds.name = "refreshIntervalSeconds"
        refreshIntervalSeconds.attributeType = .integer32AttributeType
        refreshIntervalSeconds.isOptional = false
        refreshIntervalSeconds.defaultValue = Int32(24 * 60 * 60)  // Default: Daily
        properties.append(refreshIntervalSeconds)

        let lastFetchCount = NSAttributeDescription()
        lastFetchCount.name = "lastFetchCount"
        lastFetchCount.attributeType = .integer16AttributeType
        lastFetchCount.isOptional = false
        lastFetchCount.defaultValue = Int16(0)
        properties.append(lastFetchCount)

        entity.properties = properties
        return entity
    }

    private static func createMutedItemEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "MutedItem"
        entity.managedObjectClassName = "PublicationManagerCore.CDMutedItem"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let type = NSAttributeDescription()
        type.name = "type"
        type.attributeType = .stringAttributeType
        type.isOptional = false
        type.defaultValue = ""  // CloudKit requires default value
        properties.append(type)

        let value = NSAttributeDescription()
        value.name = "value"
        value.attributeType = .stringAttributeType
        value.isOptional = false
        value.defaultValue = ""  // CloudKit requires default value
        properties.append(value)

        let dateAdded = NSAttributeDescription()
        dateAdded.name = "dateAdded"
        dateAdded.attributeType = .dateAttributeType
        dateAdded.isOptional = false
        dateAdded.defaultValue = Date()
        properties.append(dateAdded)

        entity.properties = properties
        return entity
    }

    private static func createDismissedPaperEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DismissedPaper"
        entity.managedObjectClassName = "PublicationManagerCore.CDDismissedPaper"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let doi = NSAttributeDescription()
        doi.name = "doi"
        doi.attributeType = .stringAttributeType
        doi.isOptional = true
        properties.append(doi)

        let arxivID = NSAttributeDescription()
        arxivID.name = "arxivID"
        arxivID.attributeType = .stringAttributeType
        arxivID.isOptional = true
        properties.append(arxivID)

        let bibcode = NSAttributeDescription()
        bibcode.name = "bibcode"
        bibcode.attributeType = .stringAttributeType
        bibcode.isOptional = true
        properties.append(bibcode)

        let dateDismissed = NSAttributeDescription()
        dateDismissed.name = "dateDismissed"
        dateDismissed.attributeType = .dateAttributeType
        dateDismissed.isOptional = false
        dateDismissed.defaultValue = Date()
        properties.append(dateDismissed)

        entity.properties = properties

        // Add indexes for O(1) lookups during deduplication
        let doiIndex = NSFetchIndexDescription(name: "dismissedByDOI", elements: [
            NSFetchIndexElementDescription(property: doi, collationType: .binary)
        ])
        let arxivIndex = NSFetchIndexDescription(name: "dismissedByArxivID", elements: [
            NSFetchIndexElementDescription(property: arxivID, collationType: .binary)
        ])
        let bibcodeIndex = NSFetchIndexDescription(name: "dismissedByBibcode", elements: [
            NSFetchIndexElementDescription(property: bibcode, collationType: .binary)
        ])
        entity.indexes = [doiIndex, arxivIndex, bibcodeIndex]

        return entity
    }

    private static func createSciXLibraryEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "SciXLibrary"
        entity.managedObjectClassName = "PublicationManagerCore.CDSciXLibrary"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let remoteID = NSAttributeDescription()
        remoteID.name = "remoteID"
        remoteID.attributeType = .stringAttributeType
        remoteID.isOptional = false
        remoteID.defaultValue = ""  // CloudKit requires default value
        properties.append(remoteID)

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""
        properties.append(name)

        let descriptionText = NSAttributeDescription()
        descriptionText.name = "descriptionText"
        descriptionText.attributeType = .stringAttributeType
        descriptionText.isOptional = true
        properties.append(descriptionText)

        let isPublic = NSAttributeDescription()
        isPublic.name = "isPublic"
        isPublic.attributeType = .booleanAttributeType
        isPublic.isOptional = false
        isPublic.defaultValue = false
        properties.append(isPublic)

        let dateCreated = NSAttributeDescription()
        dateCreated.name = "dateCreated"
        dateCreated.attributeType = .dateAttributeType
        dateCreated.isOptional = false
        dateCreated.defaultValue = Date()
        properties.append(dateCreated)

        let lastSyncDate = NSAttributeDescription()
        lastSyncDate.name = "lastSyncDate"
        lastSyncDate.attributeType = .dateAttributeType
        lastSyncDate.isOptional = true
        properties.append(lastSyncDate)

        let syncState = NSAttributeDescription()
        syncState.name = "syncState"
        syncState.attributeType = .stringAttributeType
        syncState.isOptional = false
        syncState.defaultValue = "synced"
        properties.append(syncState)

        let permissionLevel = NSAttributeDescription()
        permissionLevel.name = "permissionLevel"
        permissionLevel.attributeType = .stringAttributeType
        permissionLevel.isOptional = false
        permissionLevel.defaultValue = "read"
        properties.append(permissionLevel)

        let ownerEmail = NSAttributeDescription()
        ownerEmail.name = "ownerEmail"
        ownerEmail.attributeType = .stringAttributeType
        ownerEmail.isOptional = true
        properties.append(ownerEmail)

        let documentCount = NSAttributeDescription()
        documentCount.name = "documentCount"
        documentCount.attributeType = .integer32AttributeType
        documentCount.isOptional = false
        documentCount.defaultValue = Int32(0)
        properties.append(documentCount)

        let sortOrder = NSAttributeDescription()
        sortOrder.name = "sortOrder"
        sortOrder.attributeType = .integer16AttributeType
        sortOrder.isOptional = false
        sortOrder.defaultValue = Int16(0)
        properties.append(sortOrder)

        entity.properties = properties

        // Add index for O(1) remoteID lookups
        let remoteIDIndex = NSFetchIndexDescription(name: "byRemoteID", elements: [
            NSFetchIndexElementDescription(property: remoteID, collationType: .binary)
        ])
        entity.indexes = [remoteIDIndex]

        return entity
    }

    private static func createSciXPendingChangeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "SciXPendingChange"
        entity.managedObjectClassName = "PublicationManagerCore.CDSciXPendingChange"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        let action = NSAttributeDescription()
        action.name = "action"
        action.attributeType = .stringAttributeType
        action.isOptional = false
        action.defaultValue = "add"
        properties.append(action)

        let bibcodesJSON = NSAttributeDescription()
        bibcodesJSON.name = "bibcodesJSON"
        bibcodesJSON.attributeType = .stringAttributeType
        bibcodesJSON.isOptional = true
        properties.append(bibcodesJSON)

        let metadataJSON = NSAttributeDescription()
        metadataJSON.name = "metadataJSON"
        metadataJSON.attributeType = .stringAttributeType
        metadataJSON.isOptional = true
        properties.append(metadataJSON)

        let dateCreated = NSAttributeDescription()
        dateCreated.name = "dateCreated"
        dateCreated.attributeType = .dateAttributeType
        dateCreated.isOptional = false
        dateCreated.defaultValue = Date()
        properties.append(dateCreated)

        entity.properties = properties
        return entity
    }

    // MARK: - Annotation Entity (Phase 3: PDF Annotation Persistence)

    private static func createAnnotationEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Annotation"
        entity.managedObjectClassName = "PublicationManagerCore.CDAnnotation"

        var properties: [NSPropertyDescription] = []

        // Primary key
        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        // Annotation type (highlight, underline, strikethrough, note, freeText)
        let annotationType = NSAttributeDescription()
        annotationType.name = "annotationType"
        annotationType.attributeType = .stringAttributeType
        annotationType.isOptional = false
        annotationType.defaultValue = "highlight"
        properties.append(annotationType)

        // Page number (0-indexed)
        let pageNumber = NSAttributeDescription()
        pageNumber.name = "pageNumber"
        pageNumber.attributeType = .integer32AttributeType
        pageNumber.isOptional = false
        pageNumber.defaultValue = Int32(0)
        properties.append(pageNumber)

        // Bounds (stored as JSON: {"x": 0, "y": 0, "width": 100, "height": 20})
        let boundsJSON = NSAttributeDescription()
        boundsJSON.name = "boundsJSON"
        boundsJSON.attributeType = .stringAttributeType
        boundsJSON.isOptional = false
        boundsJSON.defaultValue = "{}"  // CloudKit requires default value
        properties.append(boundsJSON)

        // Color (hex string like "#FFFF00")
        let color = NSAttributeDescription()
        color.name = "color"
        color.attributeType = .stringAttributeType
        color.isOptional = true
        properties.append(color)

        // Text content (for notes and free text)
        let contents = NSAttributeDescription()
        contents.name = "contents"
        contents.attributeType = .stringAttributeType
        contents.isOptional = true
        properties.append(contents)

        // Selected text (the text that was highlighted/underlined)
        let selectedText = NSAttributeDescription()
        selectedText.name = "selectedText"
        selectedText.attributeType = .stringAttributeType
        selectedText.isOptional = true
        properties.append(selectedText)

        // Author (device name or user identifier)
        let author = NSAttributeDescription()
        author.name = "author"
        author.attributeType = .stringAttributeType
        author.isOptional = true
        properties.append(author)

        // Timestamps
        let dateCreated = NSAttributeDescription()
        dateCreated.name = "dateCreated"
        dateCreated.attributeType = .dateAttributeType
        dateCreated.isOptional = false
        dateCreated.defaultValue = Date()
        properties.append(dateCreated)

        let dateModified = NSAttributeDescription()
        dateModified.name = "dateModified"
        dateModified.attributeType = .dateAttributeType
        dateModified.isOptional = false
        dateModified.defaultValue = Date()
        properties.append(dateModified)

        // Sync state for CloudKit
        let syncState = NSAttributeDescription()
        syncState.name = "syncState"
        syncState.attributeType = .stringAttributeType
        syncState.isOptional = true
        properties.append(syncState)

        entity.properties = properties
        return entity
    }

    // MARK: - Recommendation Profile Entity (ADR-020)

    private static func createRecommendationProfileEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "RecommendationProfile"
        entity.managedObjectClassName = "PublicationManagerCore.CDRecommendationProfile"

        var properties: [NSPropertyDescription] = []

        // Primary key
        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()  // CloudKit requires default value
        properties.append(id)

        // Affinity data (stored as JSON)
        let topicAffinitiesData = NSAttributeDescription()
        topicAffinitiesData.name = "topicAffinitiesData"
        topicAffinitiesData.attributeType = .binaryDataAttributeType
        topicAffinitiesData.isOptional = true
        properties.append(topicAffinitiesData)

        let authorAffinitiesData = NSAttributeDescription()
        authorAffinitiesData.name = "authorAffinitiesData"
        authorAffinitiesData.attributeType = .binaryDataAttributeType
        authorAffinitiesData.isOptional = true
        properties.append(authorAffinitiesData)

        let venueAffinitiesData = NSAttributeDescription()
        venueAffinitiesData.name = "venueAffinitiesData"
        venueAffinitiesData.attributeType = .binaryDataAttributeType
        venueAffinitiesData.isOptional = true
        properties.append(venueAffinitiesData)

        // Training events (stored as JSON)
        let trainingEventsData = NSAttributeDescription()
        trainingEventsData.name = "trainingEventsData"
        trainingEventsData.attributeType = .binaryDataAttributeType
        trainingEventsData.isOptional = true
        properties.append(trainingEventsData)

        // Last updated timestamp
        let lastUpdated = NSAttributeDescription()
        lastUpdated.name = "lastUpdated"
        lastUpdated.attributeType = .dateAttributeType
        lastUpdated.isOptional = false
        lastUpdated.defaultValue = Date()
        properties.append(lastUpdated)

        entity.properties = properties
        return entity
    }

    // MARK: - Recommendation Profile Relationship

    private static func setupRecommendationProfileRelationship(
        recommendationProfile: NSEntityDescription,
        library: NSEntityDescription
    ) {
        // RecommendationProfile -> Library (many-to-one, optional)
        let profileToLibrary = NSRelationshipDescription()
        profileToLibrary.name = "library"
        profileToLibrary.destinationEntity = library
        profileToLibrary.maxCount = 1
        profileToLibrary.isOptional = true  // Global profile if no library
        profileToLibrary.deleteRule = .nullifyDeleteRule

        // Library -> RecommendationProfiles (one-to-many)
        let libraryToProfiles = NSRelationshipDescription()
        libraryToProfiles.name = "recommendationProfiles"
        libraryToProfiles.destinationEntity = recommendationProfile
        libraryToProfiles.isOptional = true
        libraryToProfiles.deleteRule = .cascadeDeleteRule  // Delete profiles when library deleted

        // Set inverse relationships
        profileToLibrary.inverseRelationship = libraryToProfiles
        libraryToProfiles.inverseRelationship = profileToLibrary

        // Add to entities
        recommendationProfile.properties.append(profileToLibrary)
        library.properties.append(libraryToProfiles)
    }

    // MARK: - Annotation Relationships

    private static func setupAnnotationRelationships(
        annotation: NSEntityDescription,
        linkedFile: NSEntityDescription
    ) {
        // LinkedFile -> Annotations (one-to-many)
        let fileToAnnotations = NSRelationshipDescription()
        fileToAnnotations.name = "annotations"
        fileToAnnotations.destinationEntity = annotation
        fileToAnnotations.isOptional = true
        fileToAnnotations.deleteRule = .cascadeDeleteRule  // Delete annotations when file is deleted

        // Annotation -> LinkedFile (many-to-one)
        let annotationToFile = NSRelationshipDescription()
        annotationToFile.name = "linkedFile"
        annotationToFile.destinationEntity = linkedFile
        annotationToFile.maxCount = 1
        annotationToFile.isOptional = true
        annotationToFile.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        fileToAnnotations.inverseRelationship = annotationToFile
        annotationToFile.inverseRelationship = fileToAnnotations

        // Add to entities
        linkedFile.properties.append(fileToAnnotations)
        annotation.properties.append(annotationToFile)
    }

    // MARK: - Relationship Setup

    private static func setupLibrarySmartSearchRelationship(
        library: NSEntityDescription,
        smartSearch: NSEntityDescription
    ) {
        // Library -> SmartSearches (one-to-many)
        let libraryToSmartSearches = NSRelationshipDescription()
        libraryToSmartSearches.name = "smartSearches"
        libraryToSmartSearches.destinationEntity = smartSearch
        libraryToSmartSearches.isOptional = true
        libraryToSmartSearches.deleteRule = .cascadeDeleteRule

        // SmartSearch -> Library (many-to-one)
        let smartSearchToLibrary = NSRelationshipDescription()
        smartSearchToLibrary.name = "library"
        smartSearchToLibrary.destinationEntity = library
        smartSearchToLibrary.maxCount = 1
        smartSearchToLibrary.isOptional = true
        smartSearchToLibrary.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        libraryToSmartSearches.inverseRelationship = smartSearchToLibrary
        smartSearchToLibrary.inverseRelationship = libraryToSmartSearches

        // Add to entities
        library.properties.append(libraryToSmartSearches)
        smartSearch.properties.append(smartSearchToLibrary)
    }

    // ADR-016: Smart Search <-> Result Collection relationship
    private static func setupSmartSearchCollectionRelationship(
        smartSearch: NSEntityDescription,
        collection: NSEntityDescription
    ) {
        // SmartSearch -> resultCollection (one-to-one)
        let smartSearchToCollection = NSRelationshipDescription()
        smartSearchToCollection.name = "resultCollection"
        smartSearchToCollection.destinationEntity = collection
        smartSearchToCollection.maxCount = 1
        smartSearchToCollection.isOptional = true
        smartSearchToCollection.deleteRule = .cascadeDeleteRule  // Delete collection when smart search is deleted

        // Collection -> smartSearch (one-to-one, inverse)
        let collectionToSmartSearch = NSRelationshipDescription()
        collectionToSmartSearch.name = "smartSearch"
        collectionToSmartSearch.destinationEntity = smartSearch
        collectionToSmartSearch.maxCount = 1
        collectionToSmartSearch.isOptional = true
        collectionToSmartSearch.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        smartSearchToCollection.inverseRelationship = collectionToSmartSearch
        collectionToSmartSearch.inverseRelationship = smartSearchToCollection

        // Add to entities
        smartSearch.properties.append(smartSearchToCollection)
        collection.properties.append(collectionToSmartSearch)
    }

    // ADR-016: Library <-> Last Search Collection relationship
    private static func setupLibraryLastSearchRelationship(
        library: NSEntityDescription,
        collection: NSEntityDescription
    ) {
        // Library -> lastSearchCollection (one-to-one)
        let libraryToLastSearch = NSRelationshipDescription()
        libraryToLastSearch.name = "lastSearchCollection"
        libraryToLastSearch.destinationEntity = collection
        libraryToLastSearch.maxCount = 1
        libraryToLastSearch.isOptional = true
        libraryToLastSearch.deleteRule = .cascadeDeleteRule  // Delete collection when library is deleted

        // Collection -> owningLibrary (one-to-one, inverse for system collections)
        let collectionToLibrary = NSRelationshipDescription()
        collectionToLibrary.name = "owningLibrary"
        collectionToLibrary.destinationEntity = library
        collectionToLibrary.maxCount = 1
        collectionToLibrary.isOptional = true
        collectionToLibrary.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        libraryToLastSearch.inverseRelationship = collectionToLibrary
        collectionToLibrary.inverseRelationship = libraryToLastSearch

        // Add to entities
        library.properties.append(libraryToLastSearch)
        collection.properties.append(collectionToLibrary)
    }

    // Library <-> Publications relationship (many-to-many)
    // Publications can belong to multiple libraries
    private static func setupLibraryPublicationsRelationship(
        library: NSEntityDescription,
        publication: NSEntityDescription
    ) {
        // Library -> publications (to-many)
        let libraryToPublications = NSRelationshipDescription()
        libraryToPublications.name = "publications"
        libraryToPublications.destinationEntity = publication
        libraryToPublications.isOptional = true
        libraryToPublications.deleteRule = .nullifyDeleteRule  // Don't delete publications when library is deleted

        // Publication -> libraries (to-many) - publications can be in multiple libraries
        let publicationToLibraries = NSRelationshipDescription()
        publicationToLibraries.name = "libraries"
        publicationToLibraries.destinationEntity = library
        publicationToLibraries.isOptional = true
        publicationToLibraries.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        libraryToPublications.inverseRelationship = publicationToLibraries
        publicationToLibraries.inverseRelationship = libraryToPublications

        // Add to entities
        library.properties.append(libraryToPublications)
        publication.properties.append(publicationToLibraries)
    }

    // Library <-> Collections relationship (one-to-many)
    private static func setupLibraryCollectionsRelationship(
        library: NSEntityDescription,
        collection: NSEntityDescription
    ) {
        // Library -> collections (one-to-many)
        let libraryToCollections = NSRelationshipDescription()
        libraryToCollections.name = "collections"
        libraryToCollections.destinationEntity = collection
        libraryToCollections.isOptional = true
        libraryToCollections.deleteRule = .cascadeDeleteRule  // Delete collections when library is deleted

        // Collection -> library (many-to-one)
        let collectionToLibrary = NSRelationshipDescription()
        collectionToLibrary.name = "library"
        collectionToLibrary.destinationEntity = library
        collectionToLibrary.maxCount = 1
        collectionToLibrary.isOptional = true
        collectionToLibrary.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        libraryToCollections.inverseRelationship = collectionToLibrary
        collectionToLibrary.inverseRelationship = libraryToCollections

        // Add to entities
        library.properties.append(libraryToCollections)
        collection.properties.append(collectionToLibrary)
    }

    private static func setupRelationships(
        publication: NSEntityDescription,
        author: NSEntityDescription,
        publicationAuthor: NSEntityDescription,
        linkedFile: NSEntityDescription,
        tag: NSEntityDescription,
        collection: NSEntityDescription
    ) {
        // Publication <-> PublicationAuthor
        let pubToAuthors = NSRelationshipDescription()
        pubToAuthors.name = "publicationAuthors"
        pubToAuthors.destinationEntity = publicationAuthor
        pubToAuthors.isOptional = true
        pubToAuthors.deleteRule = .cascadeDeleteRule

        let authorToPub = NSRelationshipDescription()
        authorToPub.name = "publication"
        authorToPub.destinationEntity = publication
        authorToPub.maxCount = 1
        authorToPub.isOptional = true  // CloudKit requires optional relationships
        authorToPub.deleteRule = .nullifyDeleteRule

        pubToAuthors.inverseRelationship = authorToPub
        authorToPub.inverseRelationship = pubToAuthors

        // PublicationAuthor <-> Author
        let paToAuthor = NSRelationshipDescription()
        paToAuthor.name = "author"
        paToAuthor.destinationEntity = author
        paToAuthor.maxCount = 1
        paToAuthor.isOptional = true  // CloudKit requires optional relationships
        paToAuthor.deleteRule = .nullifyDeleteRule

        let authorToPAs = NSRelationshipDescription()
        authorToPAs.name = "publicationAuthors"
        authorToPAs.destinationEntity = publicationAuthor
        authorToPAs.isOptional = true
        authorToPAs.deleteRule = .cascadeDeleteRule

        paToAuthor.inverseRelationship = authorToPAs
        authorToPAs.inverseRelationship = paToAuthor

        // Publication <-> LinkedFile
        let pubToFiles = NSRelationshipDescription()
        pubToFiles.name = "linkedFiles"
        pubToFiles.destinationEntity = linkedFile
        pubToFiles.isOptional = true
        pubToFiles.deleteRule = .cascadeDeleteRule

        let fileToPub = NSRelationshipDescription()
        fileToPub.name = "publication"
        fileToPub.destinationEntity = publication
        fileToPub.maxCount = 1
        fileToPub.isOptional = true  // CloudKit requires optional relationships
        fileToPub.deleteRule = .nullifyDeleteRule

        pubToFiles.inverseRelationship = fileToPub
        fileToPub.inverseRelationship = pubToFiles

        // Publication <-> Tag (many-to-many)
        let pubToTags = NSRelationshipDescription()
        pubToTags.name = "tags"
        pubToTags.destinationEntity = tag
        pubToTags.isOptional = true
        pubToTags.deleteRule = .nullifyDeleteRule

        let tagToPubs = NSRelationshipDescription()
        tagToPubs.name = "publications"
        tagToPubs.destinationEntity = publication
        tagToPubs.isOptional = true
        tagToPubs.deleteRule = .nullifyDeleteRule

        pubToTags.inverseRelationship = tagToPubs
        tagToPubs.inverseRelationship = pubToTags

        // Publication <-> Collection (many-to-many)
        let pubToCollections = NSRelationshipDescription()
        pubToCollections.name = "collections"
        pubToCollections.destinationEntity = collection
        pubToCollections.isOptional = true
        pubToCollections.deleteRule = .nullifyDeleteRule

        let collectionToPubs = NSRelationshipDescription()
        collectionToPubs.name = "publications"
        collectionToPubs.destinationEntity = publication
        collectionToPubs.isOptional = true
        collectionToPubs.deleteRule = .nullifyDeleteRule

        pubToCollections.inverseRelationship = collectionToPubs
        collectionToPubs.inverseRelationship = pubToCollections

        // Add relationships to entities
        publication.properties.append(contentsOf: [pubToAuthors, pubToFiles, pubToTags, pubToCollections])
        author.properties.append(authorToPAs)
        publicationAuthor.properties.append(contentsOf: [authorToPub, paToAuthor])
        linkedFile.properties.append(fileToPub)
        tag.properties.append(tagToPubs)
        collection.properties.append(collectionToPubs)
    }

    // LinkedFile <-> AttachmentTag relationship (many-to-many for file grouping)
    private static func setupLinkedFileAttachmentTagRelationship(
        linkedFile: NSEntityDescription,
        attachmentTag: NSEntityDescription
    ) {
        // LinkedFile -> attachmentTags (to-many)
        let fileToTags = NSRelationshipDescription()
        fileToTags.name = "attachmentTags"
        fileToTags.destinationEntity = attachmentTag
        fileToTags.isOptional = true
        fileToTags.deleteRule = .nullifyDeleteRule

        // AttachmentTag -> linkedFiles (to-many)
        let tagToFiles = NSRelationshipDescription()
        tagToFiles.name = "linkedFiles"
        tagToFiles.destinationEntity = linkedFile
        tagToFiles.isOptional = true
        tagToFiles.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        fileToTags.inverseRelationship = tagToFiles
        tagToFiles.inverseRelationship = fileToTags

        // Add to entities
        linkedFile.properties.append(fileToTags)
        attachmentTag.properties.append(tagToFiles)
    }

    // SciXLibrary <-> Publications relationship (many-to-many)
    // Publications can be cached in multiple SciX libraries
    private static func setupSciXLibraryPublicationsRelationship(
        scixLibrary: NSEntityDescription,
        publication: NSEntityDescription
    ) {
        // SciXLibrary -> publications (to-many)
        let libraryToPublications = NSRelationshipDescription()
        libraryToPublications.name = "publications"
        libraryToPublications.destinationEntity = publication
        libraryToPublications.isOptional = true
        libraryToPublications.deleteRule = .nullifyDeleteRule  // Don't delete publications when library is deleted

        // Publication -> scixLibraries (to-many)
        let publicationToLibraries = NSRelationshipDescription()
        publicationToLibraries.name = "scixLibraries"
        publicationToLibraries.destinationEntity = scixLibrary
        publicationToLibraries.isOptional = true
        publicationToLibraries.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        libraryToPublications.inverseRelationship = publicationToLibraries
        publicationToLibraries.inverseRelationship = libraryToPublications

        // Add to entities
        scixLibrary.properties.append(libraryToPublications)
        publication.properties.append(publicationToLibraries)
    }

    // SciXLibrary <-> PendingChanges relationship (one-to-many)
    private static func setupSciXLibraryPendingChangesRelationship(
        scixLibrary: NSEntityDescription,
        pendingChange: NSEntityDescription
    ) {
        // SciXLibrary -> pendingChanges (one-to-many)
        let libraryToChanges = NSRelationshipDescription()
        libraryToChanges.name = "pendingChanges"
        libraryToChanges.destinationEntity = pendingChange
        libraryToChanges.isOptional = true
        libraryToChanges.deleteRule = .cascadeDeleteRule  // Delete changes when library is deleted

        // PendingChange -> library (many-to-one)
        let changeToLibrary = NSRelationshipDescription()
        changeToLibrary.name = "library"
        changeToLibrary.destinationEntity = scixLibrary
        changeToLibrary.maxCount = 1
        changeToLibrary.isOptional = true
        changeToLibrary.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        libraryToChanges.inverseRelationship = changeToLibrary
        changeToLibrary.inverseRelationship = libraryToChanges

        // Add to entities
        scixLibrary.properties.append(libraryToChanges)
        pendingChange.properties.append(changeToLibrary)
    }

    // Collection hierarchy relationship for exploration drill-down
    private static func setupCollectionHierarchyRelationship(
        collection: NSEntityDescription
    ) {
        // Collection -> parentCollection (many-to-one, optional)
        let collectionToParent = NSRelationshipDescription()
        collectionToParent.name = "parentCollection"
        collectionToParent.destinationEntity = collection
        collectionToParent.maxCount = 1
        collectionToParent.isOptional = true
        collectionToParent.deleteRule = .nullifyDeleteRule  // Don't cascade to children when parent deleted

        // Collection -> childCollections (one-to-many)
        let collectionToChildren = NSRelationshipDescription()
        collectionToChildren.name = "childCollections"
        collectionToChildren.destinationEntity = collection
        collectionToChildren.isOptional = true
        collectionToChildren.deleteRule = .cascadeDeleteRule  // Delete children when parent deleted

        // Set inverse relationships
        collectionToParent.inverseRelationship = collectionToChildren
        collectionToChildren.inverseRelationship = collectionToParent

        // Add to entity
        collection.properties.append(contentsOf: [collectionToParent, collectionToChildren])
    }

    // MARK: - Save

    public func save() {
        guard viewContext.hasChanges else { return }

        do {
            try viewContext.save()
            Logger.persistence.debug("Context saved")
        } catch {
            Logger.persistence.error("Failed to save context: \(error.localizedDescription)")
        }
    }

    // MARK: - Background Context

    public func newBackgroundContext() -> NSManagedObjectContext {
        container.newBackgroundContext()
    }

    public func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask(block)
    }

    // MARK: - Migrations

    /// Backfill bibcodeNormalized for existing publications.
    ///
    /// Call this once after upgrading to populate the indexed bibcodeNormalized
    /// column from rawFields["bibcode"]. This enables O(1) bibcode lookups.
    public func migrateBibcodeNormalized() {
        Logger.persistence.info("Starting bibcodeNormalized migration")

        let context = viewContext

        // Use performAndWait to ensure proper Core Data concurrency coordination
        // This prevents race conditions with CloudKit sync that can crash on startup
        context.performAndWait {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            // Only migrate publications that have bibcode in rawFields but no bibcodeNormalized
            request.predicate = NSPredicate(format: "bibcodeNormalized == nil AND rawFields CONTAINS 'bibcode'")

            do {
                let publications = try context.fetch(request)
                var migrated = 0

                for publication in publications {
                    // updateBibcodeNormalized will extract bibcode from fields and normalize it
                    publication.updateBibcodeNormalized()
                    if publication.bibcodeNormalized != nil {
                        migrated += 1
                    }
                }

                if migrated > 0 {
                    try context.save()
                    Logger.persistence.info("Migrated bibcodeNormalized for \(migrated) publications")
                } else {
                    Logger.persistence.debug("No publications needed bibcodeNormalized migration")
                }
            } catch {
                Logger.persistence.error("bibcodeNormalized migration failed: \(error)")
            }
        }
    }

    /// Backfill arxivIDNormalized for existing publications.
    ///
    /// Similar to migrateBibcodeNormalized but for arXiv IDs.
    public func migrateArxivIDNormalized() {
        Logger.persistence.info("Starting arxivIDNormalized migration")

        let context = viewContext

        // Use performAndWait to ensure proper Core Data concurrency coordination
        // This prevents race conditions with CloudKit sync that can crash on startup
        context.performAndWait {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            // Only migrate publications that might have arXiv ID but no arxivIDNormalized
            request.predicate = NSPredicate(format: "arxivIDNormalized == nil AND (rawFields CONTAINS 'eprint' OR rawFields CONTAINS 'arxiv')")

            do {
                let publications = try context.fetch(request)
                var migrated = 0

                for publication in publications {
                    publication.updateArxivIDNormalized()
                    if publication.arxivIDNormalized != nil {
                        migrated += 1
                    }
                }

                if migrated > 0 {
                    try context.save()
                    Logger.persistence.info("Migrated arxivIDNormalized for \(migrated) publications")
                } else {
                    Logger.persistence.debug("No publications needed arxivIDNormalized migration")
                }
            } catch {
                Logger.persistence.error("arxivIDNormalized migration failed: \(error)")
            }
        }
    }

    /// Run all pending data migrations.
    ///
    /// Call this on app startup to ensure all indexed identifier columns are populated.
    public func runMigrations() {
        migrateArxivIDNormalized()
        migrateBibcodeNormalized()
        migrateYearFromRawFields()
        migrateCollectionPublicationsToLibrary()
    }

    /// Backfill year attribute from rawFields for publications where year is 0.
    ///
    /// Some older imports may not have populated the year attribute even though
    /// the year is present in rawFields. This enables smart collections to filter by year.
    public func migrateYearFromRawFields() {
        Logger.persistence.info("Starting year migration from rawFields")

        let context = viewContext

        // Use performAndWait to ensure proper Core Data concurrency coordination
        // This prevents race conditions with CloudKit sync that can crash on startup
        context.performAndWait {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            // Only migrate publications that have year=0 but might have year in rawFields
            request.predicate = NSPredicate(format: "year == 0 AND rawFields != nil")

            do {
                let publications = try context.fetch(request)
                var migrated = 0

                for publication in publications {
                    // Try to extract year from rawFields
                    if let yearString = publication.fields["year"],
                       let yearInt = Int16(yearString.trimmingCharacters(in: .whitespaces)) {
                        publication.year = yearInt
                        migrated += 1
                    }
                }

                if migrated > 0 {
                    try context.save()
                    Logger.persistence.info("Migrated year for \(migrated) publications")
                } else {
                    Logger.persistence.debug("No publications needed year migration")
                }
            } catch {
                Logger.persistence.error("Year migration failed: \(error)")
            }
        }
    }

    /// Ensure publications in collections are also in their owning library's publications relationship.
    ///
    /// Per ADR-016, search results are auto-imported to "Last Search" collections but weren't
    /// being added to the library relationship. Smart collections use `ANY libraries == %@`
    /// to filter, so papers in collections but not in the library relationship won't appear.
    ///
    /// This migration also fixes `collection.library` for smart search result collections
    /// that were created before this field was being set.
    public func migrateCollectionPublicationsToLibrary() {
        Logger.persistence.info("Starting collection-to-library migration")

        let context = viewContext

        // Use performAndWait to ensure proper Core Data concurrency coordination
        // This prevents race conditions with CloudKit sync that can crash on startup
        context.performAndWait {
            // Fetch ALL collections with prefetched relationships to avoid faulting during iteration
            let request = NSFetchRequest<CDCollection>(entityName: "Collection")
            request.relationshipKeyPathsForPrefetching = ["publications", "library", "smartSearch", "smartSearch.library"]

            do {
                let collections = try context.fetch(request)
                var migratedPubs = 0
                var fixedCollections = 0

                for collection in collections {
                    // Determine the owning library:
                    // 1. Direct collection.library (if set)
                    // 2. Via smart search: collection.smartSearch?.library
                    let library = collection.library ?? collection.smartSearch?.library

                    guard let library = library else { continue }

                    // Fix collection.library if it wasn't set (for smart search result collections)
                    if collection.library == nil {
                        collection.library = library
                        fixedCollections += 1
                        Logger.persistence.debug("Fixed collection.library for '\(collection.name ?? "unnamed")'")
                    }

                    // Migrate publications to library
                    // Use Array() to snapshot the set and avoid faulting issues
                    let publications = Array(collection.publications ?? [])

                    for publication in publications {
                        if !publication.belongsToLibrary(library) {
                            publication.addToLibrary(library)
                            migratedPubs += 1
                        }
                    }
                }

                if migratedPubs > 0 || fixedCollections > 0 {
                    try context.save()
                    Logger.persistence.info("Migration complete: \(migratedPubs) publications added to libraries, \(fixedCollections) collection.library relationships fixed")
                } else {
                    Logger.persistence.debug("No publications needed collection-to-library migration")
                }
            } catch {
                Logger.persistence.error("Collection-to-library migration failed: \(error)")
            }
        }
    }

    // MARK: - Database Health Check

    /// Report containing database health status and any detected issues.
    public struct DatabaseHealthReport: Sendable {
        /// Whether the database is in a healthy state (no critical issues).
        public let isHealthy: Bool

        /// Total number of publications in the database.
        public let publicationCount: Int

        /// Total number of libraries in the database.
        public let libraryCount: Int

        /// Number of publications not belonging to any library.
        public let orphanedPublicationsCount: Int

        /// List of detected issues (empty if healthy).
        public let issues: [String]

        /// When this health check was performed.
        public let timestamp: Date

        public init(
            isHealthy: Bool,
            publicationCount: Int,
            libraryCount: Int,
            orphanedPublicationsCount: Int,
            issues: [String],
            timestamp: Date = Date()
        ) {
            self.isHealthy = isHealthy
            self.publicationCount = publicationCount
            self.libraryCount = libraryCount
            self.orphanedPublicationsCount = orphanedPublicationsCount
            self.issues = issues
            self.timestamp = timestamp
        }
    }

    /// Check the health of the database and return a detailed report.
    ///
    /// This method checks for common data integrity issues:
    /// - Missing cite keys
    /// - Duplicate cite keys within libraries
    /// - Orphaned publications (not in any library)
    ///
    /// - Returns: A `DatabaseHealthReport` containing the results.
    public func checkDatabaseHealth() -> DatabaseHealthReport {
        var issues: [String] = []

        let context = viewContext
        var publicationCount = 0
        var libraryCount = 0
        var orphanedCount = 0

        context.performAndWait {
            // Count publications
            let pubCountRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            publicationCount = (try? context.count(for: pubCountRequest)) ?? 0

            // Count libraries
            let libCountRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
            libraryCount = (try? context.count(for: libCountRequest)) ?? 0

            // Check for publications with missing cite keys
            let missingCiteKeyRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            missingCiteKeyRequest.predicate = NSPredicate(format: "citeKey == nil OR citeKey == ''")
            let missingCiteKeyCount = (try? context.count(for: missingCiteKeyRequest)) ?? 0
            if missingCiteKeyCount > 0 {
                issues.append("Found \(missingCiteKeyCount) publication(s) with missing cite keys")
            }

            // Check for orphaned publications (not in any library)
            // These are publications that exist but aren't in any library's publications relationship
            let orphanedRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            orphanedRequest.predicate = NSPredicate(format: "libraries.@count == 0")
            orphanedCount = (try? context.count(for: orphanedRequest)) ?? 0
            if orphanedCount > 0 {
                // This is informational, not necessarily an error
                Logger.persistence.debug("Found \(orphanedCount) publication(s) not in any library")
            }

            // Check for duplicate cite keys within each library
            let libraryRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
            if let libraries = try? context.fetch(libraryRequest) {
                for library in libraries {
                    if let publications = library.publications {
                        let citeKeys = publications.compactMap { $0.citeKey }
                        let uniqueCiteKeys = Set(citeKeys)
                        let duplicateCount = citeKeys.count - uniqueCiteKeys.count
                        if duplicateCount > 0 {
                            issues.append("Library '\(library.name ?? "unnamed")' has \(duplicateCount) duplicate cite key(s)")
                        }
                    }
                }
            }
        }

        let isHealthy = issues.isEmpty
        let report = DatabaseHealthReport(
            isHealthy: isHealthy,
            publicationCount: publicationCount,
            libraryCount: libraryCount,
            orphanedPublicationsCount: orphanedCount,
            issues: issues
        )

        // Post notification with the report
        NotificationCenter.default.post(
            name: .databaseHealthCheckCompleted,
            object: self,
            userInfo: ["report": report]
        )

        if isHealthy {
            Logger.persistence.info("Database health check passed: \(publicationCount) publications, \(libraryCount) libraries")
        } else {
            Logger.persistence.warning("Database health check found issues: \(issues.joined(separator: "; "))")
        }

        return report
    }

    // MARK: - Sample Data

    private func addSampleData() {
        let context = viewContext

        // Create sample publications
        let pub1 = CDPublication(context: context)
        pub1.id = UUID()
        pub1.citeKey = "Einstein1905"
        pub1.entryType = "article"
        pub1.title = "On the Electrodynamics of Moving Bodies"
        pub1.year = 1905
        pub1.dateAdded = Date()
        pub1.dateModified = Date()

        let pub2 = CDPublication(context: context)
        pub2.id = UUID()
        pub2.citeKey = "Hawking1974"
        pub2.entryType = "article"
        pub2.title = "Black hole explosions?"
        pub2.year = 1974
        pub2.dateAdded = Date()
        pub2.dateModified = Date()

        try? context.save()
    }
}

// MARK: - CloudKit Notifications

extension Notification.Name {
    /// Posted when CloudKit remote changes are received
    public static let cloudKitDataDidChange = Notification.Name("cloudKitDataDidChange")
}
