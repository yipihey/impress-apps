//
//  SpotlightIndexingService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import CoreData
import CoreSpotlight
import OSLog

// MARK: - Spotlight Indexing Service

/// Indexes publications for system Spotlight search.
///
/// This service enables users to search for their papers directly from the
/// macOS/iOS Spotlight search, providing quick access to the library from
/// anywhere in the system.
///
/// Features:
/// - Index publications with title, authors, abstract, and keywords
/// - Update index when publications change
/// - Remove items when publications are deleted
/// - Batch operations for efficiency
///
/// Integration:
/// - Call `indexPublication()` from `PublicationRepository.create()` and `update()`
/// - Call `removePublication()` from `PublicationRepository.delete()`
/// - Handle user taps via `CSSearchableItemActionType` in the app
public actor SpotlightIndexingService {

    // MARK: - Singleton

    public static let shared = SpotlightIndexingService()

    // MARK: - Constants

    /// Domain identifier for imbib publications in Spotlight
    public static let domainIdentifier = "com.imbib.publication"

    /// Activity type for continuing Spotlight searches in the app
    public static let searchActivityType = "com.imbib.spotlight-search"

    // MARK: - State

    private let index: CSSearchableIndex
    private var isAvailable: Bool = true

    // MARK: - Initialization

    private init() {
        self.index = CSSearchableIndex.default()

        // Check if Core Spotlight is available
        Task {
            await checkAvailability()
        }
    }

    /// Check if Spotlight indexing is available on this device
    private func checkAvailability() {
        // Core Spotlight is available on iOS 9+ and macOS 10.13+
        // The framework will gracefully fail if unavailable
        isAvailable = true
        Logger.spotlight.info("Spotlight indexing service initialized")
    }

    // MARK: - Indexing Operations

    /// Index a publication for Spotlight search.
    ///
    /// Creates a searchable item with the publication's metadata including
    /// title, authors, abstract, and identifiers as keywords.
    ///
    /// - Parameter publication: The publication to index
    public func indexPublication(_ publication: CDPublication) async {
        guard isAvailable else { return }

        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)

        // Title
        attributeSet.title = publication.title
        attributeSet.displayName = publication.title

        // Authors
        let authors = publication.sortedAuthors.map { $0.displayName }
        attributeSet.authorNames = authors
        if let firstAuthor = authors.first {
            attributeSet.creator = firstAuthor
        }

        // Abstract/Description
        attributeSet.contentDescription = publication.abstract

        // Keywords: DOI, arXiv ID, cite key, bibcode
        var keywords: [String] = [publication.citeKey]
        if let doi = publication.doi, !doi.isEmpty {
            keywords.append(doi)
        }
        if let arxivID = publication.arxivID, !arxivID.isEmpty {
            keywords.append(arxivID)
            keywords.append("arXiv")
        }
        if let bibcode = publication.bibcode, !bibcode.isEmpty {
            keywords.append(bibcode)
        }
        if let journal = publication.fields["journal"], !journal.isEmpty {
            keywords.append(journal)
        }
        attributeSet.keywords = keywords

        // Year
        if publication.year > 0 {
            // Create a date from just the year
            var components = DateComponents()
            components.year = Int(publication.year)
            if let date = Calendar.current.date(from: components) {
                attributeSet.contentCreationDate = date
            }
        }

        // Entry type for categorization
        attributeSet.kind = publication.entryType.capitalized

        // URL for deep linking
        let deepLink = URL(string: "imbib://paper/\(publication.id.uuidString)")
        attributeSet.url = deepLink

        // Thumbnail hint: has PDF indicator
        if publication.hasPDFAvailable {
            attributeSet.thumbnailData = nil  // Could add PDF icon data here
        }

        // Create searchable item
        let item = CSSearchableItem(
            uniqueIdentifier: publication.id.uuidString,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributeSet
        )

        // Set expiration (papers don't expire, but we can update this if needed)
        item.expirationDate = Date.distantFuture

        do {
            try await index.indexSearchableItems([item])
            Logger.spotlight.debug("Indexed publication: \(publication.citeKey)")
        } catch {
            Logger.spotlight.error("Failed to index publication \(publication.citeKey): \(error.localizedDescription)")
        }
    }

    /// Remove a publication from the Spotlight index.
    ///
    /// - Parameter id: The UUID of the publication to remove
    public func removePublication(id: UUID) async {
        guard isAvailable else { return }

        do {
            try await index.deleteSearchableItems(withIdentifiers: [id.uuidString])
            Logger.spotlight.debug("Removed publication from Spotlight: \(id.uuidString)")
        } catch {
            Logger.spotlight.error("Failed to remove publication from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Index multiple publications in a batch.
    ///
    /// More efficient than calling `indexPublication()` multiple times.
    ///
    /// - Parameter publications: The publications to index
    public func indexPublications(_ publications: [CDPublication]) async {
        guard isAvailable, !publications.isEmpty else { return }

        var items: [CSSearchableItem] = []

        for publication in publications {
            let attributeSet = CSSearchableItemAttributeSet(contentType: .text)

            attributeSet.title = publication.title
            attributeSet.displayName = publication.title

            let authors = publication.sortedAuthors.map { $0.displayName }
            attributeSet.authorNames = authors
            if let firstAuthor = authors.first {
                attributeSet.creator = firstAuthor
            }

            attributeSet.contentDescription = publication.abstract

            var keywords: [String] = [publication.citeKey]
            if let doi = publication.doi, !doi.isEmpty {
                keywords.append(doi)
            }
            if let arxivID = publication.arxivID, !arxivID.isEmpty {
                keywords.append(arxivID)
                keywords.append("arXiv")
            }
            if let bibcode = publication.bibcode, !bibcode.isEmpty {
                keywords.append(bibcode)
            }
            attributeSet.keywords = keywords

            if publication.year > 0 {
                var components = DateComponents()
                components.year = Int(publication.year)
                if let date = Calendar.current.date(from: components) {
                    attributeSet.contentCreationDate = date
                }
            }

            attributeSet.kind = publication.entryType.capitalized
            attributeSet.url = URL(string: "imbib://paper/\(publication.id.uuidString)")

            let item = CSSearchableItem(
                uniqueIdentifier: publication.id.uuidString,
                domainIdentifier: Self.domainIdentifier,
                attributeSet: attributeSet
            )
            item.expirationDate = Date.distantFuture

            items.append(item)
        }

        do {
            try await index.indexSearchableItems(items)
            Logger.spotlight.info("Batch indexed \(items.count) publications for Spotlight")
        } catch {
            Logger.spotlight.error("Failed to batch index publications: \(error.localizedDescription)")
        }
    }

    /// Remove multiple publications from the Spotlight index.
    ///
    /// - Parameter ids: The UUIDs of the publications to remove
    public func removePublications(ids: [UUID]) async {
        guard isAvailable, !ids.isEmpty else { return }

        let identifiers = ids.map { $0.uuidString }

        do {
            try await index.deleteSearchableItems(withIdentifiers: identifiers)
            Logger.spotlight.info("Removed \(ids.count) publications from Spotlight")
        } catch {
            Logger.spotlight.error("Failed to remove publications from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Remove all imbib items from the Spotlight index.
    ///
    /// Use this sparingly, e.g., when the user resets their library.
    public func removeAllItems() async {
        guard isAvailable else { return }

        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
            Logger.spotlight.info("Removed all imbib items from Spotlight index")
        } catch {
            Logger.spotlight.error("Failed to remove all items from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Rebuild the entire Spotlight index from all publications.
    ///
    /// This clears all existing items and re-indexes everything.
    /// Use this if the index becomes corrupted or out of sync.
    ///
    /// - Parameter publications: All publications to index
    public func rebuildIndex(publications: [CDPublication]) async {
        guard isAvailable else { return }

        Logger.spotlight.info("Rebuilding Spotlight index with \(publications.count) publications")

        // Remove all existing items first
        await removeAllItems()

        // Re-index all publications in batches
        let batchSize = 100
        for i in stride(from: 0, to: publications.count, by: batchSize) {
            let end = min(i + batchSize, publications.count)
            let batch = Array(publications[i..<end])
            await indexPublications(batch)
        }

        Logger.spotlight.info("Spotlight index rebuild complete")
    }
}

// MARK: - Logger Extension

extension Logger {
    static let spotlight = Logger(subsystem: "com.imbib.app", category: "spotlight")
}
