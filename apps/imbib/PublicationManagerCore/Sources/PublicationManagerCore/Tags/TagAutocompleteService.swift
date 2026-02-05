//
//  TagAutocompleteService.swift
//  PublicationManagerCore
//

import Foundation
import CoreData
import ImpressFTUI

/// In-memory tag autocomplete service for fast prefix matching.
///
/// Loads all tags from Core Data into memory and provides ranked completions.
/// Ranking: recency > shallow depth > frequency > alphabetical.
@MainActor
@Observable
public final class TagAutocompleteService {

    // MARK: - Properties

    private var cachedTags: [CachedTag] = []
    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    // MARK: - Cache Management

    /// Reload all tags from Core Data into the in-memory cache.
    public func reload() {
        let context = persistenceController.viewContext

        context.performAndWait {
            let request = NSFetchRequest<CDTag>(entityName: "Tag")
            request.sortDescriptors = [NSSortDescriptor(key: "canonicalPath", ascending: true)]

            guard let tags = try? context.fetch(request) else { return }

            self.cachedTags = tags.map { tag in
                CachedTag(
                    id: tag.id,
                    path: tag.canonicalPath ?? tag.name,
                    leaf: tag.leaf,
                    depth: tag.depth,
                    useCount: Int(tag.useCount),
                    lastUsedAt: tag.lastUsedAt,
                    colorLight: tag.colorLight,
                    colorDark: tag.colorDark
                )
            }
        }
    }

    /// Invalidate the cache (triggers reload on next completion request).
    public func invalidate() {
        cachedTags = []
    }

    // MARK: - Completion

    /// Find completions matching a prefix string.
    ///
    /// Ranked by: recency > shallow depth > frequency > alphabetical.
    public func complete(_ input: String, limit: Int = 8) -> [TagCompletion] {
        if cachedTags.isEmpty {
            reload()
        }

        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }

        let now = Date()

        var seenPaths = Set<String>()
        return cachedTags
            .filter { $0.path.lowercased().hasPrefix(trimmed) || $0.leaf.lowercased().hasPrefix(trimmed) }
            .sorted { a, b in
                // 1. Recency (used in last 7 days gets priority)
                let aRecent = a.isRecent(relativeTo: now)
                let bRecent = b.isRecent(relativeTo: now)
                if aRecent != bRecent { return aRecent }

                // 2. Shallower depth preferred
                if a.depth != b.depth { return a.depth < b.depth }

                // 3. Higher use count preferred
                if a.useCount != b.useCount { return a.useCount > b.useCount }

                // 4. Alphabetical
                return a.path < b.path
            }
            .filter { seenPaths.insert($0.path.lowercased()).inserted }
            .prefix(limit)
            .map { cached in
                TagCompletion(
                    id: cached.id,
                    path: cached.path,
                    leaf: cached.leaf,
                    depth: cached.depth,
                    useCount: cached.useCount,
                    lastUsedAt: cached.lastUsedAt,
                    colorLight: cached.colorLight,
                    colorDark: cached.colorDark
                )
            }
    }
}

// MARK: - Cached Tag

private struct CachedTag {
    let id: UUID
    let path: String
    let leaf: String
    let depth: Int
    let useCount: Int
    let lastUsedAt: Date?
    let colorLight: String?
    let colorDark: String?

    func isRecent(relativeTo now: Date) -> Bool {
        guard let lastUsed = lastUsedAt else { return false }
        return now.timeIntervalSince(lastUsed) < 7 * 24 * 3600
    }
}
