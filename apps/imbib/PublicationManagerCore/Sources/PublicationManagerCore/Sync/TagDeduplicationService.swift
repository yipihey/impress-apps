//
//  TagDeduplicationService.swift
//  PublicationManagerCore
//
//  Merges duplicate CDTag entities that can occur when multiple devices
//  create the same tag before CloudKit sync completes, or when the
//  shared library copy service creates tags without deduplication.
//

import Foundation
import CoreData
import OSLog

// MARK: - Tag Merge Result

/// Result of a tag deduplication operation.
public struct TagMergeResult: Sendable {
    /// The canonical path that had duplicates
    public let canonicalPath: String

    /// Number of duplicate tags merged
    public let duplicatesMerged: Int

    /// Number of publications re-tagged
    public let publicationsRetagged: Int
}

// MARK: - Tag Deduplication Service

/// Service for detecting and merging duplicate CDTag entities.
///
/// Duplicate tags can occur when:
/// 1. Multiple devices create the same tag before CloudKit sync completes
/// 2. SharedLibraryCopyService creates new tag entities without checking for existing ones
/// 3. CloudKit merge unions tag sets that contain duplicates with different UUIDs
///
/// This service detects CDTag entities with the same `canonicalPath` and merges them:
/// - Keeps the tag with the highest `useCount` (most established)
/// - Re-tags all publications from duplicates to the keeper
/// - Sums use counts and preserves the most recent `lastUsedAt`
/// - Deletes the duplicate tags
///
/// ## Usage
///
/// ```swift
/// let service = TagDeduplicationService(persistenceController: .shared)
/// let results = await service.deduplicateTags()
/// ```
public actor TagDeduplicationService {

    private let persistenceController: PersistenceController

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Deduplication

    /// Detect and merge duplicate tags by canonical path.
    ///
    /// - Returns: Array of merge results describing what was merged
    @MainActor
    public func deduplicateTags() async -> [TagMergeResult] {
        let context = persistenceController.viewContext

        // Fetch all tags
        let request = NSFetchRequest<CDTag>(entityName: "Tag")
        request.sortDescriptors = [NSSortDescriptor(key: "canonicalPath", ascending: true)]

        guard let allTags = try? context.fetch(request) else {
            return []
        }

        // Group by normalized canonical path
        var groups: [String: [CDTag]] = [:]
        for tag in allTags {
            let path = (tag.canonicalPath ?? tag.name).lowercased()
            groups[path, default: []].append(tag)
        }

        var results: [TagMergeResult] = []

        for (path, tags) in groups where tags.count > 1 {
            let result = mergeDuplicateTags(tags, path: path, context: context)
            results.append(result)
        }

        if !results.isEmpty {
            persistenceController.save()
            let totalMerged = results.reduce(0) { $0 + $1.duplicatesMerged }
            Logger.tagDedup.info("Tag deduplication: merged \(totalMerged) duplicates across \(results.count) paths")
        }

        return results
    }

    // MARK: - Private

    /// Merge a group of duplicate tags into the canonical one.
    @MainActor
    private func mergeDuplicateTags(_ tags: [CDTag], path: String, context: NSManagedObjectContext) -> TagMergeResult {
        // Keep the tag with the highest use count; break ties by earliest creation (lowest UUID string)
        let sorted = tags.sorted { a, b in
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            return a.id.uuidString < b.id.uuidString
        }

        let keeper = sorted[0]
        let duplicates = Array(sorted.dropFirst())

        Logger.tagDedup.debug("Merging \(duplicates.count) duplicate(s) for '\(path)' into tag \(keeper.id)")

        var publicationsRetagged = 0

        for duplicate in duplicates {
            // Move all publications from duplicate to keeper
            if let publications = duplicate.publications {
                for pub in publications {
                    let pubTags = pub.mutableSetValue(forKey: "tags")
                    pubTags.remove(duplicate)
                    if !pubTags.contains(keeper) {
                        pubTags.add(keeper)
                        publicationsRetagged += 1
                    }
                }
            }

            // Accumulate usage stats
            keeper.useCount += duplicate.useCount
            if let dupDate = duplicate.lastUsedAt {
                if let keepDate = keeper.lastUsedAt {
                    keeper.lastUsedAt = max(keepDate, dupDate)
                } else {
                    keeper.lastUsedAt = dupDate
                }
            }

            // Preserve hierarchy: if keeper lacks canonicalPath but duplicate has it, adopt it
            if keeper.canonicalPath == nil, let dupPath = duplicate.canonicalPath {
                keeper.canonicalPath = dupPath
            }

            // Preserve colors: if keeper lacks colors but duplicate has them, adopt them
            if keeper.colorLight == nil { keeper.colorLight = duplicate.colorLight }
            if keeper.colorDark == nil { keeper.colorDark = duplicate.colorDark }

            // Re-parent children of the duplicate to the keeper
            if let children = duplicate.childTags {
                for child in children {
                    child.parentTag = keeper
                }
            }

            context.delete(duplicate)
        }

        return TagMergeResult(
            canonicalPath: keeper.canonicalPath ?? keeper.name,
            duplicatesMerged: duplicates.count,
            publicationsRetagged: publicationsRetagged
        )
    }
}

// MARK: - Logger

private extension Logger {
    static let tagDedup = Logger(subsystem: "com.imbib.app", category: "tag-deduplication")
}
