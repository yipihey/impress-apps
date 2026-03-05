import CoreSpotlight
import Foundation
import ImpressLogging
import OSLog

/// Shared actor for all Spotlight indexing operations across impress apps.
///
/// Replaces per-app `SpotlightIndexingService` actors with a single,
/// centralized indexer that handles batching, error logging, and
/// availability checks.
///
/// Identifiers are stored as `"{domain}::{uuid}"` compound strings so that
/// the deep-link handler can determine which app owns a Spotlight result
/// (macOS does not include the domain identifier in the user activity).
public actor SpotlightIndexer {

    // MARK: - Singleton

    public static let shared = SpotlightIndexer()

    // MARK: - State

    private let index: CSSearchableIndex

    // MARK: - Initialization

    private init() {
        self.index = CSSearchableIndex.default()
        Logger.spotlight.info("SpotlightIndexer initialized")
    }

    // MARK: - Compound Identifier

    /// Builds a compound identifier: `"{domain}::{uuid}"`.
    static func compoundIdentifier(domain: String, id: UUID) -> String {
        "\(domain)::\(id.uuidString)"
    }

    /// Parses a compound identifier into (domain, uuid). Returns nil if invalid.
    public static func parseIdentifier(_ identifier: String) -> (domain: String, uuid: UUID)? {
        let parts = identifier.split(separator: "::", maxSplits: 1)
        if parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) {
            return (String(parts[0]), uuid)
        }
        // Fallback: bare UUID (legacy or external)
        if let uuid = UUID(uuidString: identifier) {
            return ("", uuid)
        }
        return nil
    }

    // MARK: - Indexing

    /// Index a batch of items. Batches internally in groups of 100.
    public func index(_ items: [any SpotlightItem]) async {
        guard !items.isEmpty else { return }

        let batchSize = 100
        for start in stride(from: 0, to: items.count, by: batchSize) {
            let end = min(start + batchSize, items.count)
            let batch = items[start..<end]

            let searchableItems = batch.map { item -> CSSearchableItem in
                let compoundID = Self.compoundIdentifier(domain: item.spotlightDomain, id: item.spotlightID)
                let si = CSSearchableItem(
                    uniqueIdentifier: compoundID,
                    domainIdentifier: item.spotlightDomain,
                    attributeSet: item.spotlightAttributeSet
                )
                si.expirationDate = Date.distantFuture
                return si
            }

            do {
                try await index.indexSearchableItems(searchableItems)
            } catch {
                Logger.spotlight.error("Failed to index \(batch.count) items: \(error.localizedDescription)")
            }
        }

        Logger.spotlight.info("Indexed \(items.count) items for Spotlight")
    }

    /// Remove items by their UUIDs within a specific domain.
    public func remove(ids: [UUID], domain: String) async {
        guard !ids.isEmpty else { return }

        let identifiers = ids.map { Self.compoundIdentifier(domain: domain, id: $0) }
        do {
            try await index.deleteSearchableItems(withIdentifiers: identifiers)
            Logger.spotlight.info("Removed \(ids.count) items from Spotlight")
        } catch {
            Logger.spotlight.error("Failed to remove \(ids.count) items: \(error.localizedDescription)")
        }
    }

    /// Remove all items for a given domain.
    public func removeAll(domain: String) async {
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            Logger.spotlight.info("Removed all items for domain '\(domain)'")
        } catch {
            Logger.spotlight.error("Failed to remove domain '\(domain)': \(error.localizedDescription)")
        }
    }

    /// Rebuild the Spotlight index for a domain: remove all existing, then re-index.
    public func rebuild(items: [any SpotlightItem], domain: String) async {
        Logger.spotlight.info("Rebuilding Spotlight index for '\(domain)' with \(items.count) items")
        await removeAll(domain: domain)
        await index(items)
        Logger.spotlight.info("Spotlight rebuild complete for '\(domain)'")
    }
}

// MARK: - Logger Extension

extension Logger {
    static let spotlight = Logger(subsystem: "com.impress.suite", category: "spotlight")
}
