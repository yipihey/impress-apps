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
        let context = ImprintPersistenceController.shared.viewContext
        let request = NSFetchRequest<CDDocumentReference>(entityName: "DocumentReference")

        do {
            let refs = try context.fetch(request)
            return Set(refs.compactMap { $0.documentUUID })
        } catch {
            return []
        }
    }

    @MainActor
    public func spotlightItems(for ids: [UUID]) async -> [any SpotlightItem] {
        let context = ImprintPersistenceController.shared.viewContext
        let request = NSFetchRequest<CDDocumentReference>(entityName: "DocumentReference")

        do {
            let refs = try context.fetch(request)
            let refsByUUID = Dictionary(
                refs.compactMap { ref -> (UUID, CDDocumentReference)? in
                    guard let uuid = ref.documentUUID else { return nil }
                    return (uuid, ref)
                },
                uniquingKeysWith: { first, _ in first }
            )

            return ids.compactMap { id -> (any SpotlightItem)? in
                guard let ref = refsByUUID[id] else { return nil }
                return DocumentSpotlightItem(
                    id: id,
                    title: ref.cachedTitle ?? "Untitled",
                    authors: ref.cachedAuthors
                )
            }
        } catch {
            return []
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
