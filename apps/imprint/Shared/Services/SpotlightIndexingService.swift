import Foundation
import CoreSpotlight
import OSLog

/// Indexes imprint documents for system Spotlight search.
public actor SpotlightIndexingService {
    public static let shared = SpotlightIndexingService()
    public static let domainIdentifier = "com.imprint.document"

    private let index: CSSearchableIndex
    private var isAvailable: Bool = true

    private init() {
        self.index = CSSearchableIndex.default()
        Task { await checkAvailability() }
    }

    private func checkAvailability() {
        isAvailable = true
        Logger.spotlight.info("Spotlight indexing service initialized")
    }

    /// Index a document for Spotlight search.
    public func indexDocument(id: UUID, title: String, content: String, authors: [String]) async {
        guard isAvailable else { return }

        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = title
        attributeSet.displayName = title
        attributeSet.authorNames = authors
        if let firstAuthor = authors.first {
            attributeSet.creator = firstAuthor
        }
        // Index first ~500 chars of Typst source as content description
        let preview = String(content.prefix(500))
        attributeSet.contentDescription = preview
        attributeSet.url = URL(string: "imprint://open/document/\(id.uuidString)")

        let item = CSSearchableItem(
            uniqueIdentifier: id.uuidString,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributeSet
        )
        item.expirationDate = Date.distantFuture

        do {
            try await index.indexSearchableItems([item])
            Logger.spotlight.debug("Indexed document: \(title)")
        } catch {
            Logger.spotlight.error("Failed to index document \(title): \(error.localizedDescription)")
        }
    }

    /// Remove a document from the Spotlight index.
    public func removeDocument(id: UUID) async {
        guard isAvailable else { return }
        do {
            try await index.deleteSearchableItems(withIdentifiers: [id.uuidString])
            Logger.spotlight.debug("Removed document from Spotlight: \(id.uuidString)")
        } catch {
            Logger.spotlight.error("Failed to remove document from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Remove all imprint items from the Spotlight index.
    public func removeAllItems() async {
        guard isAvailable else { return }
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
            Logger.spotlight.info("Removed all imprint items from Spotlight index")
        } catch {
            Logger.spotlight.error("Failed to remove all items from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Rebuild the entire Spotlight index.
    public func rebuildIndex(documents: [(id: UUID, title: String, content: String, authors: [String])]) async {
        guard isAvailable else { return }
        Logger.spotlight.info("Rebuilding Spotlight index with \(documents.count) documents")
        await removeAllItems()
        for doc in documents {
            await indexDocument(id: doc.id, title: doc.title, content: doc.content, authors: doc.authors)
        }
        Logger.spotlight.info("Spotlight index rebuild complete")
    }
}

extension Logger {
    static let spotlight = Logger(subsystem: "com.imbib.imprint", category: "spotlight")
}
