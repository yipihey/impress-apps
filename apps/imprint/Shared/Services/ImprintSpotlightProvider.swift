import CoreSpotlight
import CoreData
import Foundation
import ImpressSpotlight
import UniformTypeIdentifiers

/// Adapts imprint's document references for Spotlight indexing.
///
/// Uses Core Data `CDDocumentReference` entities to provide document
/// metadata to the shared `SpotlightSyncCoordinator`.
public struct ImprintSpotlightProvider: SpotlightItemProvider {
    public let domain = SpotlightDomain.document
    public let legacyDomains = ["com.imprint.document"]

    public init() {}

    /// Index every manuscript in the unified store.
    ///
    /// Phase F2 collapse: previously dual-read both `CDDocumentReference`
    /// and `ManuscriptStoreAdapter`. After Phase 3's migration runs,
    /// every legacy CD ref has a corresponding manuscript item with the
    /// same UUID, so the unified-store side carries the truth.
    @MainActor
    public func allItemIDs() async -> Set<UUID> {
        Set(ManuscriptStoreAdapter.shared.listManuscripts(limit: 10_000).map(\.id))
    }

    @MainActor
    public func spotlightItems(for ids: [UUID]) async -> [any SpotlightItem] {
        let manuscriptsByUUID: [UUID: ManuscriptModel] = Dictionary(
            ManuscriptStoreAdapter.shared.listManuscripts(limit: 10_000).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { id -> (any SpotlightItem)? in
            guard let m = manuscriptsByUUID[id] else { return nil }
            return DocumentSpotlightItem(
                id: id,
                title: m.title,
                authors: m.authors.isEmpty ? nil : m.authors.joined(separator: ", ")
            )
        }
    }
}

// MARK: - Document → SpotlightItem

struct DocumentSpotlightItem: SpotlightItem {
    let spotlightID: UUID
    let spotlightDomain: String
    let spotlightAttributeSet: CSSearchableItemAttributeSet

    init(id: UUID, title: String, authors: String?) {
        self.spotlightID = id
        self.spotlightDomain = SpotlightDomain.document

        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = title
        attrs.displayName = title

        if let authors, !authors.isEmpty {
            let authorList = authors.components(separatedBy: ", ")
            attrs.authorNames = authorList
            if let first = authorList.first {
                attrs.creator = first
            }
        }

        attrs.kind = "Manuscript"
        attrs.url = URL(string: "imprint://open/document/\(id.uuidString)")

        self.spotlightAttributeSet = attrs
    }
}
