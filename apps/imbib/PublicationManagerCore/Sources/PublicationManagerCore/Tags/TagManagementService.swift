//
//  TagManagementService.swift
//  PublicationManagerCore
//

import Foundation
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "tagManagement")

/// Service for managing tag hierarchy operations: rename, move, merge, delete.
@MainActor
public final class TagManagementService {

    // MARK: - Singleton

    public static let shared = TagManagementService()

    private let persistenceController = PersistenceController.shared

    // MARK: - Rename

    /// Rename a tag (leaf only). Updates the tag's name and canonicalPath,
    /// plus all descendant canonicalPaths.
    public func renameTag(oldPath: String, newLeafName: String) async throws {
        let context = persistenceController.viewContext

        try await context.perform {
            // Find the tag to rename
            let request = NSFetchRequest<CDTag>(entityName: "Tag")
            request.predicate = NSPredicate(format: "canonicalPath == %@", oldPath)
            request.fetchLimit = 1

            guard let tag = try context.fetch(request).first else {
                throw TagManagementError.tagNotFound(oldPath)
            }

            // Compute new path
            let segments = oldPath.components(separatedBy: "/")
            var newSegments = segments
            newSegments[newSegments.count - 1] = newLeafName
            let newPath = newSegments.joined(separator: "/")

            // Check for conflict
            let conflictRequest = NSFetchRequest<CDTag>(entityName: "Tag")
            conflictRequest.predicate = NSPredicate(format: "canonicalPath == %@", newPath)
            conflictRequest.fetchLimit = 1
            if let _ = try? context.fetch(conflictRequest).first {
                throw TagManagementError.pathConflict(newPath)
            }

            // Update the tag itself
            tag.name = newLeafName
            tag.canonicalPath = newPath

            // Update all descendants
            let descendantRequest = NSFetchRequest<CDTag>(entityName: "Tag")
            descendantRequest.predicate = NSPredicate(format: "canonicalPath BEGINSWITH %@", oldPath + "/")
            let descendants = (try? context.fetch(descendantRequest)) ?? []

            for descendant in descendants {
                if let descPath = descendant.canonicalPath {
                    descendant.canonicalPath = newPath + descPath.dropFirst(oldPath.count)
                }
            }

            self.persistenceController.save()
            logger.info("Renamed tag '\(oldPath)' to '\(newPath)' (updated \(descendants.count) descendants)")
        }
    }

    // MARK: - Move

    /// Move a tag to a new parent. Updates canonicalPath for the tag and all descendants.
    public func moveTag(tagPath: String, newParentPath: String?) async throws {
        let context = persistenceController.viewContext

        try await context.perform {
            // Find the tag to move
            let request = NSFetchRequest<CDTag>(entityName: "Tag")
            request.predicate = NSPredicate(format: "canonicalPath == %@", tagPath)
            request.fetchLimit = 1

            guard let tag = try context.fetch(request).first else {
                throw TagManagementError.tagNotFound(tagPath)
            }

            let leafName = tag.name

            // Find new parent (if any)
            var newParentTag: CDTag?
            if let newParentPath {
                let parentRequest = NSFetchRequest<CDTag>(entityName: "Tag")
                parentRequest.predicate = NSPredicate(format: "canonicalPath == %@", newParentPath)
                parentRequest.fetchLimit = 1
                newParentTag = try? context.fetch(parentRequest).first
                if newParentTag == nil {
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
            let conflictRequest = NSFetchRequest<CDTag>(entityName: "Tag")
            conflictRequest.predicate = NSPredicate(format: "canonicalPath == %@", newPath)
            conflictRequest.fetchLimit = 1
            if let _ = try? context.fetch(conflictRequest).first {
                throw TagManagementError.pathConflict(newPath)
            }

            let oldPath = tagPath

            // Update parent relationship
            tag.parentTag = newParentTag
            tag.parentID = newParentTag?.id
            tag.canonicalPath = newPath

            // Update all descendants
            let descendantRequest = NSFetchRequest<CDTag>(entityName: "Tag")
            descendantRequest.predicate = NSPredicate(format: "canonicalPath BEGINSWITH %@", oldPath + "/")
            let descendants = (try? context.fetch(descendantRequest)) ?? []

            for descendant in descendants {
                if let descPath = descendant.canonicalPath {
                    descendant.canonicalPath = newPath + descPath.dropFirst(oldPath.count)
                }
            }

            self.persistenceController.save()
            logger.info("Moved tag '\(oldPath)' to '\(newPath)' (updated \(descendants.count) descendants)")
        }
    }

    // MARK: - Merge

    /// Merge source tag into target tag. All publications tagged with source
    /// get tagged with target instead, then source is deleted.
    public func mergeTags(sourcePath: String, targetPath: String) async throws {
        let context = persistenceController.viewContext

        try await context.perform {
            // Find source tag
            let sourceRequest = NSFetchRequest<CDTag>(entityName: "Tag")
            sourceRequest.predicate = NSPredicate(format: "canonicalPath == %@", sourcePath)
            sourceRequest.fetchLimit = 1
            guard let sourceTag = try context.fetch(sourceRequest).first else {
                throw TagManagementError.tagNotFound(sourcePath)
            }

            // Find target tag
            let targetRequest = NSFetchRequest<CDTag>(entityName: "Tag")
            targetRequest.predicate = NSPredicate(format: "canonicalPath == %@", targetPath)
            targetRequest.fetchLimit = 1
            guard let targetTag = try context.fetch(targetRequest).first else {
                throw TagManagementError.tagNotFound(targetPath)
            }

            // Retag all publications from source to target
            let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            pubRequest.predicate = NSPredicate(format: "ANY tags == %@", sourceTag)
            let publications = (try? context.fetch(pubRequest)) ?? []

            var retagged = 0
            for publication in publications {
                let tagSet = publication.mutableSetValue(forKey: "tags")
                tagSet.remove(sourceTag)
                if !tagSet.contains(targetTag) {
                    tagSet.add(targetTag)
                    retagged += 1
                }
            }

            // Update target usage
            targetTag.useCount += Int32(retagged)
            targetTag.lastUsedAt = Date()

            // Delete source tag
            context.delete(sourceTag)

            self.persistenceController.save()
            logger.info("Merged tag '\(sourcePath)' into '\(targetPath)' (\(retagged) publications retagged)")
        }
    }

    // MARK: - Delete

    /// Delete a tag. Fails if the tag has children or tagged publications.
    /// Use `force: true` to remove from all publications and delete children first.
    public func deleteTag(path: String, force: Bool = false) async throws {
        let context = persistenceController.viewContext

        try await context.perform {
            let request = NSFetchRequest<CDTag>(entityName: "Tag")
            request.predicate = NSPredicate(format: "canonicalPath == %@", path)
            request.fetchLimit = 1

            guard let tag = try context.fetch(request).first else {
                throw TagManagementError.tagNotFound(path)
            }

            // Check for children
            let childRequest = NSFetchRequest<CDTag>(entityName: "Tag")
            childRequest.predicate = NSPredicate(format: "parentTag == %@", tag)
            let children = (try? context.fetch(childRequest)) ?? []

            if !children.isEmpty && !force {
                throw TagManagementError.hasChildren(path, count: children.count)
            }

            // Check for tagged publications
            let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            pubRequest.predicate = NSPredicate(format: "ANY tags == %@", tag)
            let publications = (try? context.fetch(pubRequest)) ?? []

            if !publications.isEmpty && !force {
                throw TagManagementError.hasPublications(path, count: publications.count)
            }

            if force {
                // Remove from all publications
                for publication in publications {
                    publication.mutableSetValue(forKey: "tags").remove(tag)
                }

                // Recursively delete children
                for child in children {
                    if let childPath = child.canonicalPath {
                        // Inline recursive delete for children
                        let grandchildRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
                        grandchildRequest.predicate = NSPredicate(format: "ANY tags == %@", child)
                        let childPubs = (try? context.fetch(grandchildRequest)) ?? []
                        for pub in childPubs {
                            pub.mutableSetValue(forKey: "tags").remove(child)
                        }
                        context.delete(child)
                        logger.debug("Force-deleted child tag '\(childPath)'")
                    }
                }
            }

            context.delete(tag)
            self.persistenceController.save()
            logger.info("Deleted tag '\(path)'\(force ? " (forced)" : "")")
        }
    }

    // MARK: - Query

    /// Get a formatted tree view of all tags with publication counts.
    public func tagTree() async -> String {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDTag>(entityName: "Tag")
            request.sortDescriptors = [NSSortDescriptor(key: "canonicalPath", ascending: true)]
            let allTags = (try? context.fetch(request)) ?? []

            var lines: [String] = []
            for tag in allTags {
                let depth = (tag.canonicalPath ?? "").components(separatedBy: "/").count - 1
                let indent = String(repeating: "  ", count: depth)
                let pubCount = tag.publications?.count ?? 0
                let countStr = pubCount > 0 ? " (\(pubCount))" : ""
                lines.append("\(indent)\(tag.name)\(countStr)")
            }

            return lines.isEmpty ? "(no tags)" : lines.joined(separator: "\n")
        }
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
