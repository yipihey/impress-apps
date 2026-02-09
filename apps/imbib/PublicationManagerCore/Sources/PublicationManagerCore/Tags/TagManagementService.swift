//
//  TagManagementService.swift
//  PublicationManagerCore
//
//  Service for managing tag hierarchy operations: rename, move, merge, delete.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "tagManagement")

/// Service for managing tag hierarchy operations: rename, move, merge, delete.
@MainActor
public final class TagManagementService {

    // MARK: - Singleton

    public static let shared = TagManagementService()

    private let store: RustStoreAdapter

    private init() {
        self.store = .shared
    }

    // MARK: - Rename

    /// Rename a tag (leaf only). Computes the new full path and delegates
    /// the rename to the store which updates all assignments.
    public func renameTag(oldPath: String, newLeafName: String) throws {
        // Compute new path
        let segments = oldPath.components(separatedBy: "/")
        var newSegments = segments
        newSegments[newSegments.count - 1] = newLeafName
        let newPath = newSegments.joined(separator: "/")

        // Check for conflict by seeing if any existing tags match the new path
        let existingTags = store.listTags()
        if existingTags.contains(where: { $0.path == newPath }) {
            throw TagManagementError.pathConflict(newPath)
        }

        store.renameTag(oldPath: oldPath, newPath: newPath)
        logger.info("Renamed tag '\(oldPath)' to '\(newPath)'")
    }

    // MARK: - Move

    /// Move a tag to a new parent. Computes the new path and renames accordingly.
    public func moveTag(tagPath: String, newParentPath: String?) throws {
        let segments = tagPath.components(separatedBy: "/")
        guard let leafName = segments.last else {
            throw TagManagementError.tagNotFound(tagPath)
        }

        // Verify the tag exists
        let existingTags = store.listTags()
        guard existingTags.contains(where: { $0.path == tagPath }) else {
            throw TagManagementError.tagNotFound(tagPath)
        }

        // Verify new parent exists (if specified)
        if let newParentPath {
            guard existingTags.contains(where: { $0.path == newParentPath }) else {
                throw TagManagementError.tagNotFound(newParentPath)
            }
        }

        // Compute new path
        let newPath: String
        if let newParentPath {
            newPath = "\(newParentPath)/\(leafName)"
        } else {
            newPath = leafName
        }

        // Check for conflict
        if existingTags.contains(where: { $0.path == newPath }) {
            throw TagManagementError.pathConflict(newPath)
        }

        store.renameTag(oldPath: tagPath, newPath: newPath)
        logger.info("Moved tag '\(tagPath)' to '\(newPath)'")
    }

    // MARK: - Merge

    /// Merge source tag into target tag. All publications tagged with source
    /// get tagged with target instead, then source is deleted.
    ///
    /// The store handles the re-tagging: we query pubs with source, add target,
    /// remove source, then delete the source tag definition.
    public func mergeTags(sourcePath: String, targetPath: String) throws {
        let existingTags = store.listTagsWithCounts()

        guard existingTags.contains(where: { $0.path == sourcePath }) else {
            throw TagManagementError.tagNotFound(sourcePath)
        }
        guard existingTags.contains(where: { $0.path == targetPath }) else {
            throw TagManagementError.tagNotFound(targetPath)
        }

        // Get publications with source tag and re-tag them to target
        let sourcePubs = store.queryByTag(tagPath: sourcePath)
        if !sourcePubs.isEmpty {
            let ids = sourcePubs.map(\.id)
            store.addTag(ids: ids, tagPath: targetPath)
            store.removeTag(ids: ids, tagPath: sourcePath)
        }

        // Delete the source tag definition
        store.deleteTag(path: sourcePath)
        logger.info("Merged tag '\(sourcePath)' into '\(targetPath)' (\(sourcePubs.count) publications retagged)")
    }

    // MARK: - Delete

    /// Delete a tag. Fails if the tag has children or tagged publications.
    /// Use `force: true` to remove from all publications and delete children first.
    public func deleteTag(path: String, force: Bool = false) throws {
        let allTags = store.listTagsWithCounts()
        guard allTags.contains(where: { $0.path == path }) else {
            throw TagManagementError.tagNotFound(path)
        }

        // Check for children (tags that start with path + "/")
        let children = allTags.filter { $0.path.hasPrefix(path + "/") }

        if !children.isEmpty && !force {
            throw TagManagementError.hasChildren(path, count: children.count)
        }

        // Check for tagged publications
        let taggedPubs = store.queryByTag(tagPath: path)

        if !taggedPubs.isEmpty && !force {
            throw TagManagementError.hasPublications(path, count: taggedPubs.count)
        }

        if force {
            // Remove from all publications
            if !taggedPubs.isEmpty {
                store.removeTag(ids: taggedPubs.map(\.id), tagPath: path)
            }

            // Delete children first (deepest first to avoid orphans)
            let sortedChildren = children.sorted { $0.path > $1.path }
            for child in sortedChildren {
                let childPubs = store.queryByTag(tagPath: child.path)
                if !childPubs.isEmpty {
                    store.removeTag(ids: childPubs.map(\.id), tagPath: child.path)
                }
                store.deleteTag(path: child.path)
                logger.debug("Force-deleted child tag '\(child.path)'")
            }
        }

        store.deleteTag(path: path)
        logger.info("Deleted tag '\(path)'\(force ? " (forced)" : "")")
    }

    // MARK: - Query

    /// Get a formatted tree view of all tags with publication counts.
    public func tagTree() -> String {
        let allTags = store.listTagsWithCounts()

        let sorted = allTags.sorted { $0.path < $1.path }
        var lines: [String] = []
        for tag in sorted {
            let depth = tag.path.components(separatedBy: "/").count - 1
            let indent = String(repeating: "  ", count: depth)
            let countStr = tag.publicationCount > 0 ? " (\(tag.publicationCount))" : ""
            lines.append("\(indent)\(tag.leafName)\(countStr)")
        }

        return lines.isEmpty ? "(no tags)" : lines.joined(separator: "\n")
    }
}

// MARK: - Errors

public enum TagManagementError: LocalizedError {
    case tagNotFound(String)
    case pathConflict(String)
    case hasChildren(String, count: Int)
    case hasPublications(String, count: Int)

    public var errorDescription: String? {
        switch self {
        case .tagNotFound(let path):
            return "Tag not found: \(path)"
        case .pathConflict(let path):
            return "A tag already exists at path: \(path)"
        case .hasChildren(let path, let count):
            return "Tag '\(path)' has \(count) child tag(s). Use force delete to remove."
        case .hasPublications(let path, let count):
            return "Tag '\(path)' is applied to \(count) publication(s). Use force delete to remove."
        }
    }
}
