//
//  EnrichmentCoordinator.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import Foundation
import OSLog

// MARK: - Enrichment Coordinator

/// Coordinates enrichment services, connecting the EnrichmentService to Rust store persistence.
///
/// The EnrichmentCoordinator handles:
/// - Creating and configuring the EnrichmentService with plugins
/// - Wiring the persistence callback to save enrichment results
/// - Queueing publications for background enrichment
/// - Starting/stopping background sync
///
/// ## Usage
///
/// ```swift
/// // At app startup
/// let coordinator = EnrichmentCoordinator.shared
/// await coordinator.start()
///
/// // Queue a paper for enrichment
/// await coordinator.queueForEnrichment(publicationID: pubID)
/// ```
public actor EnrichmentCoordinator {

    // MARK: - Shared Instance

    /// Shared coordinator instance
    public static let shared = EnrichmentCoordinator()

    // MARK: - Properties

    private let service: EnrichmentService
    private let adsSource: ADSSource
    private var isStarted = false

    /// Public access to the enrichment service for citation explorer and other features
    public var enrichmentService: EnrichmentService {
        service
    }

    // MARK: - Initialization

    public init(
        credentialManager: CredentialManager = .shared
    ) {
        // Create enrichment plugins - ADS only
        let ads = ADSSource(credentialManager: credentialManager)
        self.adsSource = ads

        // Create service with ADS plugin for references/citations
        self.service = EnrichmentService(
            plugins: [ads],
            settingsProvider: DefaultEnrichmentSettingsProvider(settings: EnrichmentSettings(
                preferredSource: .ads,
                sourcePriority: [.ads],
                autoSyncEnabled: true,
                refreshIntervalDays: 7
            ))
        )
    }

    // MARK: - Store Access

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Lifecycle

    /// Start the enrichment coordinator.
    ///
    /// This wires up the persistence callback and starts background sync.
    public func start() async {
        guard !isStarted else {
            Logger.enrichment.debug("EnrichmentCoordinator already started")
            return
        }

        Logger.enrichment.infoCapture("Starting EnrichmentCoordinator", category: "enrichment")

        // Wire up the persistence callback
        await service.setOnEnrichmentComplete { publicationID, result in
            await Self.saveEnrichmentResult(publicationID: publicationID, result: result)
        }

        // Start background sync
        await service.startBackgroundSync()
        isStarted = true

        Logger.enrichment.infoCapture("EnrichmentCoordinator started", category: "enrichment")
    }

    /// Stop the enrichment coordinator.
    public func stop() async {
        guard isStarted else { return }

        Logger.enrichment.infoCapture("Stopping EnrichmentCoordinator", category: "enrichment")
        await service.stopBackgroundSync()
        isStarted = false
    }

    // MARK: - Queue Operations

    /// Queue a publication for background enrichment by ID.
    ///
    /// - Parameters:
    ///   - publicationID: The UUID of the publication to enrich
    ///   - priority: Priority level (default: libraryPaper)
    public func queueForEnrichment(
        publicationID: UUID,
        priority: EnrichmentPriority = .libraryPaper
    ) async {
        // Fetch publication detail from Rust store
        guard let pub = await withStore({ $0.getPublicationDetail(id: publicationID) }) else {
            Logger.enrichment.debug("Skipping enrichment - publication not found: \(publicationID)")
            return
        }

        let identifiers = pub.enrichmentIdentifiers
        guard !identifiers.isEmpty else {
            Logger.enrichment.debug("Skipping enrichment - no identifiers: \(pub.citeKey)")
            return
        }

        await service.queueForEnrichment(
            publicationID: publicationID,
            identifiers: identifiers,
            priority: priority
        )
    }

    /// Queue multiple publications for enrichment by IDs.
    public func queueForEnrichment(
        _ publicationIDs: [UUID],
        priority: EnrichmentPriority = .backgroundSync
    ) async {
        for id in publicationIDs {
            await queueForEnrichment(publicationID: id, priority: priority)
        }
    }

    /// Queue all unenriched publications in a library.
    public func queueUnenrichedPublications(inLibrary libraryID: UUID) async {
        let store = await withStore({ $0 })
        let publications = await MainActor.run {
            store.queryPublications(parentId: libraryID)
        }

        // Filter to those with identifiers (potential for enrichment)
        let unenriched = publications.filter { pub in
            pub.doi != nil || pub.arxivID != nil || pub.bibcode != nil
        }

        Logger.enrichment.infoCapture(
            "Queueing \(unenriched.count) publications for enrichment from library \(libraryID)",
            category: "enrichment"
        )

        for pub in unenriched {
            await queueForEnrichment(publicationID: pub.id, priority: .backgroundSync)
        }
    }

    // MARK: - Status

    /// Get current queue depth.
    public func queueDepth() async -> Int {
        await service.queueDepth()
    }

    /// Check if background sync is running.
    public var isRunning: Bool {
        get async { await service.isRunning }
    }

    // MARK: - Enrichment Persistence

    /// Save enrichment result to the Rust store via field updates.
    @MainActor
    private static func saveEnrichmentResult(publicationID: UUID, result: EnrichmentResult) {
        let store = RustStoreAdapter.shared
        let data = result.data

        // Save resolved identifiers
        for (idType, value) in result.resolvedIdentifiers {
            switch idType {
            case .doi:
                store.updateField(id: publicationID, field: "doi", value: value)
            case .arxiv:
                store.updateField(id: publicationID, field: "arxiv_id", value: value)
            case .bibcode:
                store.updateField(id: publicationID, field: "bibcode", value: value)
            case .pmid:
                store.updateField(id: publicationID, field: "pmid", value: value)
            default:
                break
            }
        }

        // Save enrichment data fields
        if let citationCount = data.citationCount {
            store.updateIntField(id: publicationID, field: "citation_count", value: Int64(citationCount))
        }
        if let referenceCount = data.referenceCount {
            store.updateIntField(id: publicationID, field: "reference_count", value: Int64(referenceCount))
        }
        if let abstract = data.abstract {
            store.updateField(id: publicationID, field: "abstract_text", value: abstract)
        }
        if let venue = data.venue {
            store.updateField(id: publicationID, field: "journal", value: venue)
        }

        Logger.enrichment.debug("Saved enrichment result for \(publicationID)")
    }

    // MARK: - Immediate Batch Enrichment

    /// Immediately enrich a batch of papers with ADS data.
    ///
    /// This is used for arXiv feed imports where we want quick bibcode resolution
    /// to enable Similar Papers and Co-read features. Uses a single ADS API call
    /// for up to 50 papers (much more efficient than individual calls).
    ///
    /// - Parameter publicationIDs: UUIDs of publications to enrich (must have arXiv IDs)
    /// - Returns: Number of papers successfully enriched
    @discardableResult
    public func enrichBatchByIDs(_ publicationIDs: [UUID]) async -> Int {
        guard !publicationIDs.isEmpty else { return 0 }

        // Fetch publication details and extract Sendable data
        let arxivPapers: [(id: UUID, identifiers: [IdentifierType: String])] = await withStore { store in
            publicationIDs.compactMap { pubID in
                guard let pub = store.getPublicationDetail(id: pubID) else { return nil }
                // Filter to papers with arXiv IDs that don't already have bibcodes
                guard pub.arxivID != nil && pub.bibcode == nil else { return nil }
                return (pub.id, pub.enrichmentIdentifiers)
            }
        }

        guard !arxivPapers.isEmpty else {
            Logger.enrichment.debug("No papers need immediate ADS enrichment")
            return 0
        }

        Logger.enrichment.infoCapture(
            "Immediate ADS enrichment: \(arxivPapers.count) papers with arXiv IDs",
            category: "enrichment"
        )

        // Build batch request
        let requests = arxivPapers.map { ($0.id, $0.identifiers) }

        // Use ADS batch enrichment (single API call)
        let results = await adsSource.enrichBatch(requests: requests)

        // Save successful results
        var successCount = 0
        for (pubID, result) in results {
            if case .success(let enrichment) = result {
                await Self.saveEnrichmentResult(publicationID: pubID, result: enrichment)
                successCount += 1
            }
        }

        Logger.enrichment.infoCapture(
            "Immediate ADS enrichment complete: \(successCount)/\(arxivPapers.count) papers resolved",
            category: "enrichment"
        )

        return successCount
    }
}

// MARK: - EnrichmentService Extension

extension EnrichmentService {

    /// Set the enrichment completion callback.
    ///
    /// This method allows setting the callback from outside the actor.
    public func setOnEnrichmentComplete(_ callback: @escaping (UUID, EnrichmentResult) async -> Void) {
        self.onEnrichmentComplete = callback
    }
}
