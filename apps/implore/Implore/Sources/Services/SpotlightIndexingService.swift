import Foundation
import CoreSpotlight
import OSLog

/// Indexes implore figures for system Spotlight search.
public actor SpotlightIndexingService {
    public static let shared = SpotlightIndexingService()
    public static let domainIdentifier = "com.implore.figure"

    private let index: CSSearchableIndex
    private var isAvailable: Bool = true

    private init() {
        self.index = CSSearchableIndex.default()
        Task { await checkAvailability() }
    }

    private func checkAvailability() {
        isAvailable = true
        Logger.spotlight.info("implore Spotlight indexing service initialized")
    }

    /// Index a figure for Spotlight search.
    public func indexFigure(id: UUID, title: String, datasetName: String?, tags: [String]) async {
        guard isAvailable else { return }

        let attributeSet = CSSearchableItemAttributeSet(contentType: .image)
        attributeSet.title = title
        attributeSet.displayName = title
        if let dataset = datasetName {
            attributeSet.contentDescription = "Dataset: \(dataset)"
        }
        attributeSet.keywords = tags
        attributeSet.url = URL(string: "implore://open/figure/\(id.uuidString)")

        let item = CSSearchableItem(
            uniqueIdentifier: id.uuidString,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attributeSet
        )
        item.expirationDate = Date.distantFuture

        do {
            try await index.indexSearchableItems([item])
            Logger.spotlight.debug("Indexed figure: \(title)")
        } catch {
            Logger.spotlight.error("Failed to index figure \(title): \(error.localizedDescription)")
        }
    }

    /// Remove a figure from the Spotlight index.
    public func removeFigure(id: UUID) async {
        guard isAvailable else { return }
        do {
            try await index.deleteSearchableItems(withIdentifiers: [id.uuidString])
            Logger.spotlight.debug("Removed figure from Spotlight: \(id.uuidString)")
        } catch {
            Logger.spotlight.error("Failed to remove figure from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Remove all implore items from the Spotlight index.
    public func removeAllItems() async {
        guard isAvailable else { return }
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier])
            Logger.spotlight.info("Removed all implore items from Spotlight index")
        } catch {
            Logger.spotlight.error("Failed to remove all items from Spotlight: \(error.localizedDescription)")
        }
    }

    /// Rebuild the entire Spotlight index.
    public func rebuildIndex(figures: [(id: UUID, title: String, datasetName: String?, tags: [String])]) async {
        guard isAvailable else { return }
        Logger.spotlight.info("Rebuilding Spotlight index with \(figures.count) figures")
        await removeAllItems()
        for fig in figures {
            await indexFigure(id: fig.id, title: fig.title, datasetName: fig.datasetName, tags: fig.tags)
        }
        Logger.spotlight.info("Spotlight index rebuild complete")
    }
}

extension Logger {
    static let spotlight = Logger(subsystem: "com.impress.implore", category: "spotlight")
}
