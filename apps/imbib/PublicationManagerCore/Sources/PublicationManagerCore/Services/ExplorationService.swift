//
//  ExplorationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-13.
//

import Foundation
import OSLog

// MARK: - Exploration Service

/// Service for exploring paper references and citations.
///
/// Creates collections in the Exploration library when exploring a paper's
/// references or citations. Papers are imported as publications via BibTeX,
/// enabling full list view, info tab, and PDF download functionality.
///
/// ## Usage
///
/// ```swift
/// let collectionID = try await ExplorationService.shared.exploreReferences(
///     of: publicationID
/// )
/// ```
@MainActor
public final class ExplorationService {

    // MARK: - Shared Instance

    public static let shared = ExplorationService()

    // MARK: - Dependencies

    private var libraryManager: LibraryManager
    private var enrichmentService: EnrichmentService?
    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - State

    /// Whether an exploration is in progress
    public private(set) var isExploring = false

    /// Current error if exploration failed
    public private(set) var error: Error?

    /// Current exploration context -- the collection the user is currently viewing.
    /// When set, new explorations will be created as children of this collection.
    public var currentExplorationCollectionID: UUID?

    // MARK: - Initialization

    public init(
        libraryManager: LibraryManager? = nil
    ) {
        self.libraryManager = libraryManager ?? LibraryManager()
    }

    /// Set the enrichment service (called from coordinator after environment setup)
    public func setEnrichmentService(_ service: EnrichmentService) {
        self.enrichmentService = service
    }

    /// Set the library manager (must be called with the environment's LibraryManager)
    public func setLibraryManager(_ manager: LibraryManager) {
        self.libraryManager = manager
    }

    // MARK: - Exploration

    /// Explore references of a publication.
    ///
    /// Fetches the papers that this publication cites and creates a collection
    /// in the Exploration library containing them.
    ///
    /// - Parameters:
    ///   - publicationID: The UUID of the publication to explore references for
    ///   - parentCollectionID: Optional parent collection for drill-down hierarchy.
    ///                         If nil, uses `currentExplorationCollectionID` if set.
    /// - Returns: The UUID of the created collection containing referenced papers
    /// - Throws: ExplorationError if exploration fails
    @discardableResult
    public func exploreReferences(
        of publicationID: UUID,
        parentCollectionID: UUID? = nil
    ) async throws -> UUID {
        let effectiveParentID = parentCollectionID ?? currentExplorationCollectionID
        guard let pub = store.getPublicationDetail(id: publicationID) else {
            throw ExplorationError.noIdentifiers
        }

        Logger.viewModels.info("ExplorationService: exploring references of \(pub.citeKey)")

        isExploring = true
        error = nil
        defer { isExploring = false }

        guard let service = enrichmentService else {
            let err = ExplorationError.notConfigured
            error = err
            throw err
        }

        let identifiers = pub.allIdentifiers
        guard !identifiers.isEmpty else {
            let err = ExplorationError.noIdentifiers
            error = err
            throw err
        }

        let result = try await service.enrichNow(identifiers: identifiers)

        guard let references = result.data.references, !references.isEmpty else {
            let err = ExplorationError.noReferences
            error = err
            throw err
        }

        let collectionName = formatCollectionName("Refs", pub: pub)

        let collectionID = try createExplorationCollection(
            name: collectionName,
            papers: references,
            parentCollectionID: effectiveParentID
        )

        Logger.viewModels.info("ExplorationService: created collection '\(collectionName)' with \(references.count) papers")

        postNavigationNotification(collectionID: collectionID)

        return collectionID
    }

    /// Explore citations of a publication.
    @discardableResult
    public func exploreCitations(
        of publicationID: UUID,
        parentCollectionID: UUID? = nil
    ) async throws -> UUID {
        let effectiveParentID = parentCollectionID ?? currentExplorationCollectionID
        guard let pub = store.getPublicationDetail(id: publicationID) else {
            throw ExplorationError.noIdentifiers
        }

        Logger.viewModels.info("ExplorationService: exploring citations of \(pub.citeKey)")

        isExploring = true
        error = nil
        defer { isExploring = false }

        guard let service = enrichmentService else {
            let err = ExplorationError.notConfigured
            error = err
            throw err
        }

        let identifiers = pub.allIdentifiers
        guard !identifiers.isEmpty else {
            let err = ExplorationError.noIdentifiers
            error = err
            throw err
        }

        let result = try await service.enrichNow(identifiers: identifiers)

        guard let citations = result.data.citations, !citations.isEmpty else {
            let err = ExplorationError.noCitations
            error = err
            throw err
        }

        let collectionName = formatCollectionName("Cites", pub: pub)

        let collectionID = try createExplorationCollection(
            name: collectionName,
            papers: citations,
            parentCollectionID: effectiveParentID
        )

        Logger.viewModels.info("ExplorationService: created collection '\(collectionName)' with \(citations.count) papers")

        postNavigationNotification(collectionID: collectionID)

        return collectionID
    }

    /// Explore papers similar to a publication (by content).
    @discardableResult
    public func exploreSimilar(
        of publicationID: UUID,
        parentCollectionID: UUID? = nil
    ) async throws -> UUID {
        let effectiveParentID = parentCollectionID ?? currentExplorationCollectionID
        guard let pub = store.getPublicationDetail(id: publicationID) else {
            throw ExplorationError.noIdentifiers
        }

        Logger.viewModels.info("ExplorationService: exploring similar papers for \(pub.citeKey)")

        isExploring = true
        error = nil
        defer { isExploring = false }

        guard let service = enrichmentService else {
            let err = ExplorationError.notConfigured
            error = err
            throw err
        }

        let identifiers = pub.allIdentifiers
        guard !identifiers.isEmpty else {
            let err = ExplorationError.noIdentifiers
            error = err
            throw err
        }

        let result = try await service.enrichNow(identifiers: identifiers)

        guard let bibcode = result.resolvedIdentifiers[.bibcode]
                ?? pub.bibcode
                ?? pub.fields["bibcode"],
              !bibcode.isEmpty else {
            let err = ExplorationError.noIdentifiers
            error = err
            throw err
        }

        let adsSource = ADSSource()
        let similar = try await adsSource.fetchSimilar(bibcode: bibcode)
        guard !similar.isEmpty else {
            let err = ExplorationError.noSimilar
            error = err
            throw err
        }

        let collectionName = formatCollectionName("Similar", pub: pub)
        let collectionID = try createExplorationCollection(
            name: collectionName,
            papers: similar,
            parentCollectionID: effectiveParentID
        )

        Logger.viewModels.info("ExplorationService: created collection '\(collectionName)' with \(similar.count) papers")

        postNavigationNotification(collectionID: collectionID)

        return collectionID
    }

    /// Explore papers related via Web of Science co-citation analysis.
    @discardableResult
    public func exploreWoSRelated(
        of publicationID: UUID,
        parentCollectionID: UUID? = nil
    ) async throws -> UUID {
        let effectiveParentID = parentCollectionID ?? currentExplorationCollectionID
        guard let pub = store.getPublicationDetail(id: publicationID) else {
            throw ExplorationError.noIdentifiers
        }

        Logger.viewModels.info("ExplorationService: exploring WoS related records for \(pub.citeKey)")

        isExploring = true
        error = nil
        defer { isExploring = false }

        guard let doi = pub.doi, !doi.isEmpty else {
            let err = ExplorationError.noIdentifiers
            error = err
            throw err
        }

        let wosSource = WoSSource()
        let related = try await wosSource.fetchRelatedRecords(doi: doi)

        guard !related.isEmpty else {
            let err = ExplorationError.noWoSRelated
            error = err
            throw err
        }

        let collectionName = formatCollectionName("WoS Related", pub: pub)
        let collectionID = try createExplorationCollection(
            name: collectionName,
            papers: related,
            parentCollectionID: effectiveParentID,
            enrichmentSource: "wos"
        )

        Logger.viewModels.info("ExplorationService: created collection '\(collectionName)' with \(related.count) papers")

        postNavigationNotification(collectionID: collectionID)

        return collectionID
    }

    /// Explore papers frequently co-read with this publication.
    @discardableResult
    public func exploreCoReads(
        of publicationID: UUID,
        parentCollectionID: UUID? = nil
    ) async throws -> UUID {
        let effectiveParentID = parentCollectionID ?? currentExplorationCollectionID
        guard let pub = store.getPublicationDetail(id: publicationID) else {
            throw ExplorationError.noIdentifiers
        }

        Logger.viewModels.info("ExplorationService: exploring co-reads for \(pub.citeKey)")

        isExploring = true
        error = nil
        defer { isExploring = false }

        guard let service = enrichmentService else {
            let err = ExplorationError.notConfigured
            error = err
            throw err
        }

        let identifiers = pub.allIdentifiers
        guard !identifiers.isEmpty else {
            let err = ExplorationError.noIdentifiers
            error = err
            throw err
        }

        let result = try await service.enrichNow(identifiers: identifiers)

        guard let bibcode = result.resolvedIdentifiers[.bibcode]
                ?? pub.bibcode
                ?? pub.fields["bibcode"],
              !bibcode.isEmpty else {
            let err = ExplorationError.noIdentifiers
            error = err
            throw err
        }

        let adsSource = ADSSource()
        let coReads = try await adsSource.fetchCoReads(bibcode: bibcode)
        guard !coReads.isEmpty else {
            let err = ExplorationError.noCoReads
            error = err
            throw err
        }

        let collectionName = formatCollectionName("Co-Reads", pub: pub)
        let collectionID = try createExplorationCollection(
            name: collectionName,
            papers: coReads,
            parentCollectionID: effectiveParentID
        )

        Logger.viewModels.info("ExplorationService: created collection '\(collectionName)' with \(coReads.count) papers")

        postNavigationNotification(collectionID: collectionID)

        return collectionID
    }

    // MARK: - Private Helpers

    /// Format a collection name from a publication
    private func formatCollectionName(_ prefix: String, pub: PublicationModel) -> String {
        let firstAuthor = pub.authors.first?.familyName
            ?? pub.authorString.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
            ?? "Unknown"

        if let year = pub.year, year > 0 {
            return "\(prefix): \(firstAuthor) (\(year))"
        } else {
            return "\(prefix): \(firstAuthor)"
        }
    }

    /// Create an exploration collection and import papers into it via BibTeX.
    private func createExplorationCollection(
        name: String,
        papers: [PaperStub],
        parentCollectionID: UUID?,
        enrichmentSource: String = "ads"
    ) throws -> UUID {
        // Get or create exploration library
        let explorationModel = libraryManager.getOrCreateExplorationLibrary()

        // Create collection
        guard let collection = store.createCollection(
            name: name,
            libraryId: explorationModel.id
        ) else {
            throw ExplorationError.notConfigured
        }

        // Import papers as BibTeX entries
        var importedIDs: [UUID] = []
        for stub in papers {
            let bibtex = buildBibTeX(from: stub, enrichmentSource: enrichmentSource)
            let ids = store.importBibTeX(bibtex, libraryId: explorationModel.id)
            importedIDs.append(contentsOf: ids)
        }

        // Add all imported publications to the collection
        if !importedIDs.isEmpty {
            store.addToCollection(publicationIds: importedIDs, collectionId: collection.id)
        }

        return collection.id
    }

    /// Build a BibTeX entry string from a PaperStub.
    private func buildBibTeX(from stub: PaperStub, enrichmentSource: String) -> String {
        let citeKey = generateCiteKey(from: stub)
        var fields: [String] = []

        fields.append("  title = {\(stub.title)}")

        if !stub.authors.isEmpty {
            fields.append("  author = {\(stub.authors.joined(separator: " and "))}")
        }
        if let year = stub.year {
            fields.append("  year = {\(year)}")
        }
        if let venue = stub.venue {
            fields.append("  journal = {\(venue)}")
        }
        if let doi = stub.doi {
            fields.append("  doi = {\(doi)}")
        }
        if let arxiv = stub.arxivID {
            fields.append("  eprint = {\(arxiv)}")
        }
        if let abstract = stub.abstract {
            let escaped = abstract.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
            fields.append("  abstract = {\(escaped)}")
        }

        // Store source-specific identifier
        if enrichmentSource == "ads" {
            fields.append("  bibcode = {\(stub.id)}")
        } else if enrichmentSource == "wos" {
            fields.append("  wos-ut = {\(stub.id)}")
        }

        return "@article{\(citeKey),\n\(fields.joined(separator: ",\n"))\n}"
    }

    /// Generate a cite key from a PaperStub
    private func generateCiteKey(from stub: PaperStub) -> String {
        let firstAuthor = stub.authors.first?
            .components(separatedBy: ",").first?
            .components(separatedBy: " ").last?
            .trimmingCharacters(in: .whitespaces)
            ?? "Unknown"

        let year = stub.year.map { String($0) } ?? ""

        let titleWord = stub.title
            .components(separatedBy: .whitespaces)
            .first { $0.count > 3 }?
            .capitalized
            ?? ""

        return "\(firstAuthor)\(year)\(titleWord)"
    }

    /// Post navigation notification for sidebar.
    private func postNavigationNotification(collectionID: UUID) {
        // Get first publication in the collection for auto-selection
        let members = store.listCollectionMembers(collectionId: collectionID, limit: 1)
        let firstPubID = members.first?.id

        NotificationCenter.default.post(
            name: .navigateToCollection,
            object: nil,
            userInfo: [
                "collectionID": collectionID,
                "firstPublicationID": firstPubID as Any
            ]
        )

        NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
    }
}

// MARK: - Exploration Error

public enum ExplorationError: LocalizedError {
    case notConfigured
    case noIdentifiers
    case noReferences
    case noCitations
    case noSimilar
    case noCoReads
    case noWoSRelated
    case enrichmentFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Exploration service is not configured"
        case .noIdentifiers:
            return "Publication has no identifiers (DOI, arXiv, bibcode)"
        case .noReferences:
            return "No references found for this publication"
        case .noCitations:
            return "No citations found for this publication"
        case .noSimilar:
            return "No similar papers found for this publication"
        case .noCoReads:
            return "No co-read papers found for this publication"
        case .noWoSRelated:
            return "No related papers found in Web of Science"
        case .enrichmentFailed(let error):
            return "Failed to fetch data: \(error.localizedDescription)"
        }
    }
}
