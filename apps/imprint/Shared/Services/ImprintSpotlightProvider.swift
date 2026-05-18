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

    @MainActor
    public func allItemIDs() async -> Set<UUID> {
        var ids: Set<UUID> = []

        // Legacy CD-backed documents (still authoritative until Phase
        // 4b retires FileDocument).
        let context = ImprintPersistenceController.shared.viewContext
        let request = NSFetchRequest<CDDocumentReference>(entityName: "DocumentReference")
        if let refs = try? context.fetch(request) {
            ids.formUnion(refs.compactMap { $0.documentUUID })
        }

        // Phase 4a dual-read: unified-store manuscripts. Spotlight now
        // sees both sets and dedupes by UUID (which is preserved across
        // the migration, so duplicates collapse correctly).
        for m in ManuscriptStoreAdapter.shared.listManuscripts(limit: 10_000) {
            ids.insert(m.id)
        }
        return ids
    }

    @MainActor
    public func spotlightItems(for ids: [UUID]) async -> [any SpotlightItem] {
        // Build the CD-side lookup once.
        let context = ImprintPersistenceController.shared.viewContext
        let request = NSFetchRequest<CDDocumentReference>(entityName: "DocumentReference")
        let cdRefs = (try? context.fetch(request)) ?? []
        let refsByUUID = Dictionary(
            cdRefs.compactMap { ref -> (UUID, CDDocumentReference)? in
                guard let uuid = ref.documentUUID else { return nil }
                return (uuid, ref)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Build the manuscript-store lookup once. The list is bounded
        // by the user's manuscript count, not the Spotlight `ids` set,
        // but indexing is faster than re-querying per id.
        let manuscriptsByUUID: [UUID: ManuscriptModel] = Dictionary(
            ManuscriptStoreAdapter.shared.listManuscripts(limit: 10_000).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return ids.compactMap { id -> (any SpotlightItem)? in
            // Prefer the unified-store snapshot when both exist — it
            // has fresher metadata (title and authors are updated by
            // the editor's debounced write) than the cached CD copy.
            if let m = manuscriptsByUUID[id] {
                return DocumentSpotlightItem(
                    id: id,
                    title: m.title,
                    authors: m.authors.isEmpty ? nil : m.authors.joined(separator: ", ")
                )
            }
            if let ref = refsByUUID[id] {
                return DocumentSpotlightItem(
                    id: id,
                    title: ref.cachedTitle ?? "Untitled",
                    authors: ref.cachedAuthors
                )
            }
            return nil
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
