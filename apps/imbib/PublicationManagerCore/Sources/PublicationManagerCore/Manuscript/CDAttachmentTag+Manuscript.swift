//
//  CDAttachmentTag+Manuscript.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData

// MARK: - CDAttachmentTag Manuscript Extension (ADR-021)

public extension CDAttachmentTag {

    // MARK: - Manuscript Tag Detection

    /// Whether this tag is a manuscript-related tag
    var isManuscriptTag: Bool {
        ManuscriptAttachmentTag.isManuscriptTag(name)
    }

    /// The manuscript tag type, if this is a manuscript tag
    var manuscriptTagType: ManuscriptAttachmentTag? {
        ManuscriptAttachmentTag(rawValue: name)
    }

    // MARK: - Factory Methods

    /// Create or fetch a manuscript attachment tag
    @MainActor
    static func manuscriptTag(
        _ tag: ManuscriptAttachmentTag,
        in context: NSManagedObjectContext
    ) -> CDAttachmentTag {
        // Try to find existing tag
        let request = NSFetchRequest<CDAttachmentTag>(entityName: "AttachmentTag")
        request.predicate = NSPredicate(format: "name == %@", tag.rawValue)
        request.fetchLimit = 1

        if let existing = try? context.fetch(request).first {
            return existing
        }

        // Create new tag
        let newTag = CDAttachmentTag(context: context)
        newTag.id = UUID()
        newTag.name = tag.rawValue
        newTag.color = tag.color.description
        newTag.order = Int16(tag.hashValue % 1000)

        return newTag
    }

    /// Create or fetch a submission version tag
    @MainActor
    static func submissionTag(
        version: Int,
        in context: NSManagedObjectContext
    ) -> CDAttachmentTag {
        let tagName = ManuscriptAttachmentTag.submission(version: version)

        let request = NSFetchRequest<CDAttachmentTag>(entityName: "AttachmentTag")
        request.predicate = NSPredicate(format: "name == %@", tagName)
        request.fetchLimit = 1

        if let existing = try? context.fetch(request).first {
            return existing
        }

        let newTag = CDAttachmentTag(context: context)
        newTag.id = UUID()
        newTag.name = tagName
        newTag.color = "blue"
        newTag.order = Int16(version)

        return newTag
    }

    /// Create or fetch a revision round tag
    @MainActor
    static func revisionTag(
        round: Int,
        in context: NSManagedObjectContext
    ) -> CDAttachmentTag {
        let tagName = ManuscriptAttachmentTag.revision(round: round)

        let request = NSFetchRequest<CDAttachmentTag>(entityName: "AttachmentTag")
        request.predicate = NSPredicate(format: "name == %@", tagName)
        request.fetchLimit = 1

        if let existing = try? context.fetch(request).first {
            return existing
        }

        let newTag = CDAttachmentTag(context: context)
        newTag.id = UUID()
        newTag.name = tagName
        newTag.color = "purple"
        newTag.order = Int16(100 + round)

        return newTag
    }

    // MARK: - Tag Application

    /// Apply a manuscript tag to a linked file
    @MainActor
    static func applyManuscriptTag(
        _ tag: ManuscriptAttachmentTag,
        to file: CDLinkedFile,
        in context: NSManagedObjectContext
    ) {
        let attachmentTag = manuscriptTag(tag, in: context)
        file.addTag(attachmentTag)
    }

    /// Apply a submission version tag to a linked file
    @MainActor
    static func applySubmissionTag(
        version: Int,
        to file: CDLinkedFile,
        in context: NSManagedObjectContext
    ) {
        let attachmentTag = submissionTag(version: version, in: context)
        file.addTag(attachmentTag)
    }

    /// Apply a revision round tag to a linked file
    @MainActor
    static func applyRevisionTag(
        round: Int,
        to file: CDLinkedFile,
        in context: NSManagedObjectContext
    ) {
        let attachmentTag = revisionTag(round: round, in: context)
        file.addTag(attachmentTag)
    }
}

// MARK: - CDLinkedFile Manuscript Extension

public extension CDLinkedFile {

    /// Whether this file has any manuscript tags
    var hasManuscriptTags: Bool {
        guard let tags = attachmentTags else { return false }
        return tags.contains { ManuscriptAttachmentTag.isManuscriptTag($0.name) }
    }

    /// Get all manuscript tags on this file
    var manuscriptTags: [CDAttachmentTag] {
        guard let tags = attachmentTags else { return [] }
        return tags.filter { ManuscriptAttachmentTag.isManuscriptTag($0.name) }
    }

    /// Add a tag to this file
    func addTag(_ tag: CDAttachmentTag) {
        var currentTags = attachmentTags ?? []
        currentTags.insert(tag)
        attachmentTags = currentTags
    }

    /// Remove a tag from this file
    func removeTag(_ tag: CDAttachmentTag) {
        var currentTags = attachmentTags ?? []
        currentTags.remove(tag)
        attachmentTags = currentTags
    }

    /// Get the version number from manuscript tags (if any)
    var manuscriptVersionNumber: Int? {
        guard let tags = attachmentTags else { return nil }
        for tag in tags {
            if let version = ManuscriptAttachmentTag.parseVersionNumber(from: tag.name) {
                return version
            }
        }
        return nil
    }
}
