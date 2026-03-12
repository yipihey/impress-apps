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
    private let scheduler: BackgroundScheduler
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

        let settings = DefaultEnrichmentSettingsProvider(settings: EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: true,
            refreshIntervalDays: 7
        ))

        // Create service with ADS plugin for references/citations
        let svc = EnrichmentService(
            plugins: [ads],
            settingsProvider: settings
        )
        self.service = svc

        // Create background scheduler for periodic discovery of unenriched/stale papers
        self.scheduler = BackgroundScheduler(
            enrichmentService: svc,
            publicationProvider: RustStorePublicationProvider(),
            settingsProvider: settings
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

        // Wire up the persistence callbacks.
        // The batch callback wraps all saves in one outer beginBatchMutation/endBatchMutation,
        // so only ONE .fieldDidChange + .storeDidMutate notification fires per batch of 50.
        await service.setOnBatchEnrichmentComplete { [weak self] results in
            await MainActor.run {
                let store = RustStoreAdapter.shared
                store.beginBatchMutation()
                for (publicationID, result) in results {
                    Self.saveEnrichmentResult(publicationID: publicationID, result: result)
                }
                store.endBatchMutation()
            }
            // Fire auto-tagging in the background after persistence (Apple Intelligence, macOS 26+)
            if #available(macOS 26, iOS 26, *) {
                await self?.classifyAndTagAfterEnrichment(results: results)
            }
        }
        // Keep per-item callback as fallback
        await service.setOnEnrichmentComplete { publicationID, result in
            await Self.saveEnrichmentResult(publicationID: publicationID, result: result)
        }

        // Start background sync (processes queued items)
        await service.startBackgroundSync()

        // Start scheduler (periodically discovers unenriched/stale papers and queues them)
        await scheduler.start()

        isStarted = true

        Logger.enrichment.infoCapture("EnrichmentCoordinator started", category: "enrichment")
    }

    /// Stop the enrichment coordinator.
    public func stop() async {
        guard isStarted else { return }

        Logger.enrichment.infoCapture("Stopping EnrichmentCoordinator", category: "enrichment")
        await scheduler.stop()
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

        // Batch all field updates — one notification at the end instead of per-field
        store.beginBatchMutation()

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

        // Record enrichment timestamp so the scheduler can track staleness
        store.updateField(id: publicationID, field: "enrichment_date", value: ISO8601DateFormatter().string(from: Date()))

        store.endBatchMutation()

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

        // Save all successful results in one batch (one notification instead of N)
        var successCount = 0
        await MainActor.run {
            let store = RustStoreAdapter.shared
            store.beginBatchMutation()
            for (pubID, result) in results {
                if case .success(let enrichment) = result {
                    Self.saveEnrichmentResult(publicationID: pubID, result: enrichment)
                    successCount += 1
                }
            }
            store.endBatchMutation()
        }

        Logger.enrichment.infoCapture(
            "Immediate ADS enrichment complete: \(successCount)/\(arxivPapers.count) papers resolved",
            category: "enrichment"
        )

        return successCount
    }
}

// MARK: - Auto-Tag Classification

extension EnrichmentCoordinator {

    /// After enrichment, classify newly-enriched papers and apply suggested tags.
    ///
    /// Only fires when Apple Intelligence is available (macOS 26+). Skips papers
    /// that already have tags, and only applies classification with confidence above
    /// the user's configured threshold.
    ///
    /// Tags are organized into a three-tier hierarchy under `ai/`:
    /// - `ai/field/{value}` — research sub-field (e.g., cosmology, stellar)
    /// - `ai/type/{value}` — paper type (e.g., review, empirical) — off by default
    /// - `ai/topic/{value}` — specific topic keywords (e.g., dark-energy)
    ///
    /// All LLM classification runs off MainActor, then all tag mutations are applied
    /// in a single batched MainActor hop to avoid per-paper UI rebuilds.
    @available(macOS 26, iOS 26, *)
    func classifyAndTagAfterEnrichment(
        results: [(UUID, EnrichmentResult)]
    ) async {
        // Load user settings
        let autoTagSettings = await AutoTagSettingsStore.shared.settings
        guard autoTagSettings.enabled else {
            Logger.enrichment.debug("Auto-tagging disabled in settings, skipping")
            return
        }

        let service = FoundationModelsService.shared
        guard await service.isAvailable else { return }

        // Only process papers that gained an abstract
        let candidates = results.filter { _, result in result.data.abstract != nil }
        guard !candidates.isEmpty else { return }

        Logger.enrichment.infoCapture(
            "Auto-tagging: classifying \(candidates.count) newly-enriched papers",
            category: "enrichment"
        )

        // Phase 1: Gather candidate info from MainActor in one batch
        struct TagCandidate: Sendable {
            let pubID: UUID
            let title: String
            let abstract: String?
        }

        let tagCandidates: [TagCandidate] = await MainActor.run {
            let store = RustStoreAdapter.shared
            return candidates.compactMap { pubID, result in
                guard let row = store.getPublication(id: pubID),
                      !row.title.isEmpty,
                      row.tagDisplays.isEmpty else { return nil }
                return TagCandidate(pubID: pubID, title: row.title, abstract: result.data.abstract)
            }
        }

        guard !tagCandidates.isEmpty else { return }

        // Phase 2: Classify all papers off MainActor (LLM calls)
        struct TagPlanEntry: Sendable {
            let pubID: UUID
            let title: String
            let tags: [String]  // full paths like "ai/field/cosmology"
        }

        var tagPlan: [TagPlanEntry] = []
        let threshold = autoTagSettings.confidenceThreshold

        for candidate in tagCandidates {
            guard !Task.isCancelled else { break }

            guard let classification = await service.classifyPaper(
                title: candidate.title,
                abstract: candidate.abstract
            ) else { continue }

            guard classification.confidence >= threshold else {
                Logger.enrichment.debug(
                    "Auto-tag skipped '\(candidate.title.prefix(40))': confidence \(classification.confidence, format: .fixed(precision: 2)) < threshold \(threshold, format: .fixed(precision: 2))"
                )
                continue
            }

            // Build three-tier tag paths based on settings
            var tags: [String] = []

            if autoTagSettings.includeFieldTag {
                let field = TagPathNormalizer.normalize(classification.field)
                if !field.isEmpty {
                    tags.append("ai/field/\(field)")
                }
            }

            if autoTagSettings.includeTypeTag {
                let paperType = TagPathNormalizer.normalize(classification.paperType)
                if !paperType.isEmpty {
                    tags.append("ai/type/\(paperType)")
                }
            }

            if autoTagSettings.includeTopicTags {
                for keyword in classification.tags {
                    let normalized = TagPathNormalizer.normalize(keyword)
                    if !normalized.isEmpty {
                        tags.append("ai/topic/\(normalized)")
                    }
                }
            }

            if !tags.isEmpty {
                tagPlan.append(TagPlanEntry(pubID: candidate.pubID, title: candidate.title, tags: tags))
            }
        }

        guard !tagPlan.isEmpty else { return }

        // Phase 3: Apply ALL tags in a single batched MainActor hop
        await MainActor.run {
            let store = RustStoreAdapter.shared
            store.beginBatchMutation()
            for entry in tagPlan {
                for tagPath in entry.tags {
                    store.createTag(path: tagPath)
                    store.addTag(ids: [entry.pubID], tagPath: tagPath)
                }
            }
            store.endBatchMutation()
        }

        for entry in tagPlan {
            Logger.enrichment.infoCapture(
                "Auto-tagged '\(entry.title.prefix(40))': \(entry.tags.joined(separator: ", "))",
                category: "enrichment"
            )
        }
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

    /// Set the batch enrichment completion callback.
    ///
    /// When set, this replaces per-item `onEnrichmentComplete` during batch processing,
    /// enabling the caller to wrap all saves in one outer batch mutation.
    public func setOnBatchEnrichmentComplete(_ callback: @escaping ([(UUID, EnrichmentResult)]) async -> Void) {
        self.onBatchEnrichmentComplete = callback
    }
}

// MARK: - Rust Store Publication Provider

/// StalePublicationProvider backed by RustStoreAdapter.
/// Queries all libraries for publications with missing or stale enrichment data.
///
/// Uses `PublicationRowData.enrichmentDate` (from BibliographyRow) to filter in-memory,
/// avoiding N+1 `getPublicationDetail()` FFI calls that previously blocked startup for 32+ seconds.
struct RustStorePublicationProvider: StalePublicationProvider {

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse an enrichment_date string to Date, trying fractional seconds first, then plain ISO8601.
    private static func parseEnrichmentDate(_ dateStr: String) -> Date? {
        isoFormatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
    }

    /// Collect all unique publications with identifiers from all libraries.
    private static func allPublicationsWithIdentifiers() async -> [PublicationRowData] {
        await MainActor.run {
            let store = RustStoreAdapter.shared
            let libraries = store.listLibraries()
            var result: [PublicationRowData] = []
            var seen = Set<UUID>()

            for library in libraries {
                let pubs = store.queryPublications(parentId: library.id)
                for pub in pubs {
                    guard !seen.contains(pub.id) else { continue }
                    seen.insert(pub.id)
                    guard pub.doi != nil || pub.arxivID != nil || pub.bibcode != nil else { continue }
                    result.append(pub)
                }
            }
            return result
        }
    }

    /// Build identifier map for a publication from its row data (no detail query needed).
    private static func identifiers(from pub: PublicationRowData) -> [IdentifierType: String] {
        var ids: [IdentifierType: String] = [:]
        if let doi = pub.doi { ids[.doi] = doi }
        if let arxiv = pub.arxivID { ids[.arxiv] = arxiv }
        if let bibcode = pub.bibcode { ids[.bibcode] = bibcode }
        return ids
    }

    func findStalePublications(
        olderThan date: Date,
        limit: Int
    ) async -> [(id: UUID, identifiers: [IdentifierType: String])] {
        let allPubs = await Self.allPublicationsWithIdentifiers()
        var results: [(id: UUID, identifiers: [IdentifierType: String])] = []

        for pub in allPubs {
            guard results.count < limit else { break }

            let enrichmentDate = pub.enrichmentDate.flatMap { Self.parseEnrichmentDate($0) }
            if enrichmentDate == nil || enrichmentDate! < date {
                results.append((id: pub.id, identifiers: Self.identifiers(from: pub)))
            }
        }

        return results
    }

    func countNeverEnriched() async -> Int {
        let allPubs = await Self.allPublicationsWithIdentifiers()
        return allPubs.filter { $0.enrichmentDate == nil }.count
    }

    func countStale(olderThan date: Date) async -> Int {
        let allPubs = await Self.allPublicationsWithIdentifiers()
        return allPubs.filter { pub in
            guard let dateStr = pub.enrichmentDate,
                  let enrichmentDate = Self.parseEnrichmentDate(dateStr) else { return false }
            return enrichmentDate < date
        }.count
    }
}
