//
//  EnrichmentCoordinator.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import Foundation
import CoreData
import OSLog

// MARK: - Enrichment Coordinator

/// Coordinates enrichment services, connecting the EnrichmentService to Core Data persistence.
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
/// await coordinator.queueForEnrichment(publication)
/// ```
public actor EnrichmentCoordinator {

    // MARK: - Shared Instance

    /// Shared coordinator instance
    public static let shared = EnrichmentCoordinator()

    // MARK: - Properties

    private let service: EnrichmentService
    private let repository: PublicationRepository
    private let adsSource: ADSSource
    private var isStarted = false

    /// Public access to the enrichment service for citation explorer and other features
    public var enrichmentService: EnrichmentService {
        service
    }

    // MARK: - Initialization

    public init(
        repository: PublicationRepository = PublicationRepository(),
        credentialManager: CredentialManager = .shared
    ) {
        self.repository = repository

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
        await service.setOnEnrichmentComplete { [repository] publicationID, result in
            await repository.saveEnrichmentResult(publicationID: publicationID, result: result)
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

    /// Queue a publication for background enrichment.
    ///
    /// - Parameters:
    ///   - publication: The publication to enrich
    ///   - priority: Priority level (default: libraryPaper)
    public func queueForEnrichment(
        _ publication: CDPublication,
        priority: EnrichmentPriority = .libraryPaper
    ) async {
        // Extract Core Data properties on main actor for thread safety
        // Check for deleted/faulted objects to avoid crash
        let result: (identifiers: [IdentifierType: String], publicationID: UUID, citeKey: String, isStale: Bool)? = await MainActor.run {
            guard !publication.isDeleted, !publication.isFault else {
                return nil
            }
            return (
                publication.enrichmentIdentifiers,
                publication.id,
                publication.citeKey,
                publication.isEnrichmentStale(thresholdDays: 1)
            )
        }

        guard let (identifiers, publicationID, citeKey, isStale) = result else {
            Logger.enrichment.debug("Skipping enrichment - publication deleted or faulted")
            return
        }

        guard !identifiers.isEmpty else {
            Logger.enrichment.debug("Skipping enrichment - no identifiers: \(citeKey)")
            return
        }

        // Skip if recently enriched
        if !isStale {
            Logger.enrichment.debug("Skipping enrichment - recently enriched: \(citeKey)")
            return
        }

        await service.queueForEnrichment(
            publicationID: publicationID,
            identifiers: identifiers,
            priority: priority
        )
    }

    /// Queue multiple publications for enrichment.
    public func queueForEnrichment(
        _ publications: [CDPublication],
        priority: EnrichmentPriority = .backgroundSync
    ) async {
        for publication in publications {
            await queueForEnrichment(publication, priority: priority)
        }
    }

    /// Queue all unenriched publications in a library.
    public func queueUnenrichedPublications(in library: CDLibrary) async {
        // Extract unenriched publications on main actor for thread safety
        let (unenriched, libraryName) = await MainActor.run {
            let pubs = library.publications ?? []
            let filtered = pubs.filter { !$0.hasBeenEnriched || $0.isEnrichmentStale(thresholdDays: 7) }
            return (Array(filtered), library.displayName)
        }

        Logger.enrichment.infoCapture(
            "Queueing \(unenriched.count) unenriched publications from \(libraryName)",
            category: "enrichment"
        )

        for publication in unenriched {
            await queueForEnrichment(publication, priority: .backgroundSync)
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

    // MARK: - Immediate Batch Enrichment

    /// Immediately enrich a batch of papers with ADS data.
    ///
    /// This is used for arXiv feed imports where we want quick bibcode resolution
    /// to enable Similar Papers and Co-read features. Uses a single ADS API call
    /// for up to 50 papers (much more efficient than individual calls).
    ///
    /// - Parameter papers: Publications to enrich (must have arXiv IDs)
    /// - Returns: Number of papers successfully enriched
    @discardableResult
    public func enrichBatchImmediately(_ papers: [CDPublication]) async -> Int {
        // Extract Sendable data on main actor for thread safety
        let requests: [(publicationID: UUID, identifiers: [IdentifierType: String])] = await MainActor.run {
            papers.compactMap { paper in
                // Filter to papers with arXiv IDs that haven't been enriched yet
                guard paper.fields["eprint"] != nil && paper.bibcodeNormalized == nil else {
                    return nil
                }
                return (paper.id, paper.enrichmentIdentifiers)
            }
        }

        guard !requests.isEmpty else {
            Logger.enrichment.debug("No papers need immediate ADS enrichment")
            return 0
        }

        Logger.enrichment.infoCapture(
            "Immediate ADS enrichment: \(requests.count) papers with arXiv IDs",
            category: "enrichment"
        )

        // Use ADS batch enrichment (single API call)
        let results = await adsSource.enrichBatch(requests: requests)

        // Save successful results
        var successCount = 0
        for (pubID, result) in results {
            if case .success(let enrichment) = result {
                await repository.saveEnrichmentResult(publicationID: pubID, result: enrichment)
                successCount += 1
            }
        }

        Logger.enrichment.infoCapture(
            "Immediate ADS enrichment complete: \(successCount)/\(requests.count) papers resolved",
            category: "enrichment"
        )

        return successCount
    }

    /// Immediately enrich a batch of papers by their IDs.
    ///
    /// This variant takes UUIDs instead of CDPublication objects, making it safe to call
    /// from non-main-actor contexts (e.g., actors). The publications are fetched on the
    /// main actor internally.
    ///
    /// - Parameter publicationIDs: UUIDs of publications to enrich
    /// - Returns: Number of papers successfully enriched
    @discardableResult
    public func enrichBatchByIDs(_ publicationIDs: [UUID]) async -> Int {
        guard !publicationIDs.isEmpty else { return 0 }

        // Fetch publications and extract Sendable data on main actor in one call
        let arxivPapers: [(id: UUID, identifiers: [IdentifierType: String])] = await MainActor.run {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id IN %@", publicationIDs)
            guard let papers = try? PersistenceController.shared.viewContext.fetch(request) else {
                return []
            }

            // Filter and extract Sendable data in the same block
            return papers.compactMap { paper in
                guard paper.fields["eprint"] != nil && paper.bibcodeNormalized == nil else {
                    return nil
                }
                return (paper.id, paper.enrichmentIdentifiers)
            }
        }

        guard !arxivPapers.isEmpty else {
            Logger.enrichment.debug("No papers need immediate ADS enrichment")
            return 0
        }

        Logger.enrichment.infoCapture(
            "Immediate ADS enrichment by IDs: \(arxivPapers.count) papers",
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
                await repository.saveEnrichmentResult(publicationID: pubID, result: enrichment)
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
