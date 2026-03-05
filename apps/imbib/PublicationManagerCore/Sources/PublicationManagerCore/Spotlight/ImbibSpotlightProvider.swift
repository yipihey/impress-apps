import CoreSpotlight
import Foundation
import ImpressSpotlight
import UniformTypeIdentifiers

/// Adapts imbib's publication data for Spotlight indexing.
///
/// Uses `RustStoreAdapter`'s `nonisolated` background methods to avoid
/// main-actor contention during batch indexing operations.
public struct ImbibSpotlightProvider: SpotlightItemProvider {
    public let domain = SpotlightDomain.paper

    public init() {}

    public func allItemIDs() async -> Set<UUID> {
        let libraries = RustStoreAdapter.shared.listLibrariesBackground()
        var allIDs = Set<UUID>()
        for lib in libraries {
            let ids = RustStoreAdapter.shared.queryPublicationIDsBackground(parentId: lib.id)
            allIDs.formUnion(ids)
        }
        return allIDs
    }

    public func spotlightItems(for ids: [UUID]) async -> [any SpotlightItem] {
        ids.compactMap { id -> (any SpotlightItem)? in
            guard let pub = RustStoreAdapter.shared.getPublicationBackground(id: id) else {
                return nil
            }
            return PublicationSpotlightItem(pub: pub)
        }
    }
}

// MARK: - Publication → SpotlightItem

/// Lightweight wrapper that converts a `PublicationRowData` into a `SpotlightItem`.
struct PublicationSpotlightItem: SpotlightItem {
    let spotlightID: UUID
    let spotlightDomain: String
    let spotlightAttributeSet: CSSearchableItemAttributeSet

    init(pub: PublicationRowData) {
        self.spotlightID = pub.id
        self.spotlightDomain = SpotlightDomain.paper

        let attrs = CSSearchableItemAttributeSet(contentType: .text)

        // Title
        attrs.title = pub.title
        attrs.displayName = pub.title

        // Authors
        let authorNames = pub.authorString.components(separatedBy: ", ")
        attrs.authorNames = authorNames
        if let firstAuthor = authorNames.first {
            attrs.creator = firstAuthor
        }

        // Abstract as both description and full-text content
        attrs.contentDescription = pub.abstract
        if let abstract = pub.abstract {
            attrs.textContent = abstract
        }

        // Keywords: DOI, arXiv ID, cite key, bibcode, venue
        var keywords: [String] = [pub.citeKey]
        if let doi = pub.doi, !doi.isEmpty { keywords.append(doi) }
        if let arxivID = pub.arxivID, !arxivID.isEmpty {
            keywords.append(arxivID)
            keywords.append("arXiv")
        }
        if let bibcode = pub.bibcode, !bibcode.isEmpty { keywords.append(bibcode) }
        if let venue = pub.venue, !venue.isEmpty { keywords.append(venue) }
        attrs.keywords = keywords

        // Year → content creation date
        if let year = pub.year, year > 0 {
            var components = DateComponents()
            components.year = year
            if let date = Calendar.current.date(from: components) {
                attrs.contentCreationDate = date
            }
        }

        // Deep link URL
        attrs.url = URL(string: "imbib://open/artifact/\(pub.id.uuidString)")

        self.spotlightAttributeSet = attrs
    }
}
