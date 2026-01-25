//
//  DetailViewCache.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-08.
//

import Foundation
import OSLog

/// LRU cache for DetailView data to avoid expensive recomputation.
///
/// Caches:
/// - LocalPaper snapshots (avoids Core Data traversal)
/// - Parsed abstracts (avoids AbstractRenderer recomputation)
/// - PDF sources (avoids URL construction)
/// - File sizes (avoids disk I/O)
///
/// Usage:
/// ```swift
/// // Check cache on DetailView init
/// if let cached = await DetailViewCache.shared.get(for: publication.id) {
///     // Use cached data
/// }
///
/// // Cache after first computation
/// await DetailViewCache.shared.set(data, for: publication.id)
///
/// // Invalidate on edit
/// await DetailViewCache.shared.invalidate(publication.id)
/// ```
public actor DetailViewCache {

    // MARK: - Shared Instance

    public static let shared = DetailViewCache()

    // MARK: - Types

    /// Cached data for a publication's detail view.
    public struct CachedDetailData: Sendable {
        /// The LocalPaper snapshot
        public let localPaper: LocalPaper

        /// Pre-parsed abstract (AttributedString from AbstractRenderer)
        /// Stored as Data since AttributedString isn't Sendable
        public let parsedAbstractData: Data?

        /// PDF source URLs
        public let pdfSources: [PDFSourceInfo]

        /// File sizes by linked file ID
        public let fileSizes: [UUID: Int64]

        /// When this cache entry was created
        public let createdAt: Date

        public init(
            localPaper: LocalPaper,
            parsedAbstractData: Data? = nil,
            pdfSources: [PDFSourceInfo] = [],
            fileSizes: [UUID: Int64] = [:],
            createdAt: Date = Date()
        ) {
            self.localPaper = localPaper
            self.parsedAbstractData = parsedAbstractData
            self.pdfSources = pdfSources
            self.fileSizes = fileSizes
            self.createdAt = createdAt
        }
    }

    /// Information about a PDF source
    public struct PDFSourceInfo: Sendable {
        public let name: String
        public let url: URL
        public let isPrimary: Bool

        public init(name: String, url: URL, isPrimary: Bool = false) {
            self.name = name
            self.url = url
            self.isPrimary = isPrimary
        }
    }

    // MARK: - Properties

    /// Cache storage
    private var cache: [UUID: CachedDetailData] = [:]

    /// Access order for LRU eviction (most recent at front)
    private var accessOrder: [UUID] = []

    /// Maximum cache size
    private let maxSize: Int

    /// Cache hit/miss statistics
    private var hits = 0
    private var misses = 0

    // MARK: - Initialization

    public init(maxSize: Int = 10) {
        self.maxSize = maxSize
    }

    // MARK: - Public API

    /// Get cached data for a publication.
    ///
    /// - Parameter id: Publication UUID
    /// - Returns: Cached data if available, nil otherwise
    public func get(for id: UUID) -> CachedDetailData? {
        guard let data = cache[id] else {
            misses += 1
            Logger.performance.debug("DetailViewCache MISS for \(id)")
            return nil
        }

        // Move to front of access order (LRU update)
        accessOrder.removeAll { $0 == id }
        accessOrder.insert(id, at: 0)

        hits += 1
        Logger.performance.debug("DetailViewCache HIT for \(id)")
        return data
    }

    /// Cache data for a publication.
    ///
    /// - Parameters:
    ///   - data: The data to cache
    ///   - id: Publication UUID
    public func set(_ data: CachedDetailData, for id: UUID) {
        cache[id] = data
        accessOrder.removeAll { $0 == id }
        accessOrder.insert(id, at: 0)

        // Evict oldest entries if over limit
        while accessOrder.count > maxSize {
            let oldest = accessOrder.removeLast()
            cache.removeValue(forKey: oldest)
            Logger.performance.debug("DetailViewCache evicted \(oldest)")
        }

        Logger.performance.debug("DetailViewCache SET for \(id), size=\(self.cache.count)")
    }

    /// Invalidate cache entry for a publication.
    ///
    /// Call this when a publication is edited.
    ///
    /// - Parameter id: Publication UUID
    public func invalidate(_ id: UUID) {
        cache.removeValue(forKey: id)
        accessOrder.removeAll { $0 == id }
        Logger.performance.debug("DetailViewCache INVALIDATE \(id)")
    }

    /// Invalidate all cache entries.
    public func invalidateAll() {
        cache.removeAll()
        accessOrder.removeAll()
        Logger.performance.info("DetailViewCache INVALIDATE ALL")
    }

    /// Check if a publication is cached.
    public func isCached(_ id: UUID) -> Bool {
        cache[id] != nil
    }

    /// Get cache statistics.
    public var statistics: (hits: Int, misses: Int, size: Int) {
        (hits, misses, cache.count)
    }

    /// Reset statistics.
    public func resetStatistics() {
        hits = 0
        misses = 0
    }
}

// MARK: - Notification-Based Invalidation

public extension DetailViewCache {

    /// Set up notification observers for automatic cache invalidation.
    ///
    /// Call this once on app startup.
    @MainActor
    func setupInvalidationObservers() {
        // Invalidate when a publication is edited
        NotificationCenter.default.addObserver(
            forName: .publicationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            Task {
                await self?.invalidate(id)
            }
        }

        // Invalidate all when Core Data context changes significantly
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Only invalidate all for major changes like sync
            // Individual edits use publicationDidChange
            Task {
                // For now, don't invalidate on every save
                // await self?.invalidateAll()
            }
        }

        Logger.performance.info("DetailViewCache invalidation observers set up")
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when a publication is edited and its cache should be invalidated.
    static let publicationDidChange = Notification.Name("publicationDidChange")
}
