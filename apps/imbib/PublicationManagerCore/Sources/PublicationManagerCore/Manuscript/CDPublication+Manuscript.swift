//
//  CDPublication+Manuscript.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData

// MARK: - CDPublication Manuscript Extension (ADR-021)

public extension CDPublication {

    // MARK: - Manuscript Detection

    /// Whether this publication is a manuscript (has manuscript status set)
    var isManuscript: Bool {
        manuscriptStatus != nil
    }

    /// Whether this is an active manuscript (still in progress)
    var isActiveManuscript: Bool {
        manuscriptStatus?.isActive ?? false
    }

    /// Whether this is a completed manuscript
    var isCompletedManuscript: Bool {
        manuscriptStatus?.isCompleted ?? false
    }

    // MARK: - Manuscript Status

    /// The manuscript status, if this is a manuscript
    var manuscriptStatus: ManuscriptStatus? {
        get {
            guard let value = fields[ManuscriptMetadataKey.status.rawValue] else {
                return nil
            }
            return ManuscriptStatus(rawValue: value)
        }
        set {
            var f = fields
            f[ManuscriptMetadataKey.status.rawValue] = newValue?.rawValue
            fields = f
        }
    }

    // MARK: - Submission Details

    /// The venue this manuscript is submitted to (e.g., "ApJ", "MNRAS")
    var submissionVenue: String? {
        get { fields[ManuscriptMetadataKey.venue.rawValue] }
        set {
            var f = fields
            f[ManuscriptMetadataKey.venue.rawValue] = newValue
            fields = f
        }
    }

    /// The target journal (may differ from submission venue during drafting)
    var targetJournal: String? {
        get { fields[ManuscriptMetadataKey.targetJournal.rawValue] }
        set {
            var f = fields
            f[ManuscriptMetadataKey.targetJournal.rawValue] = newValue
            fields = f
        }
    }

    /// Current revision number (0 = initial submission)
    var revisionNumber: Int {
        get {
            guard let value = fields[ManuscriptMetadataKey.revisionNumber.rawValue] else {
                return 0
            }
            return Int(value) ?? 0
        }
        set {
            var f = fields
            f[ManuscriptMetadataKey.revisionNumber.rawValue] = String(newValue)
            fields = f
        }
    }

    /// Date the manuscript was first submitted
    var submissionDate: Date? {
        get {
            guard let value = fields[ManuscriptMetadataKey.submissionDate.rawValue] else {
                return nil
            }
            return ISO8601DateFormatter().date(from: value)
        }
        set {
            var f = fields
            if let date = newValue {
                f[ManuscriptMetadataKey.submissionDate.rawValue] = ISO8601DateFormatter().string(from: date)
            } else {
                f[ManuscriptMetadataKey.submissionDate.rawValue] = nil
            }
            fields = f
        }
    }

    /// Date the manuscript was accepted
    var acceptanceDate: Date? {
        get {
            guard let value = fields[ManuscriptMetadataKey.acceptanceDate.rawValue] else {
                return nil
            }
            return ISO8601DateFormatter().date(from: value)
        }
        set {
            var f = fields
            if let date = newValue {
                f[ManuscriptMetadataKey.acceptanceDate.rawValue] = ISO8601DateFormatter().string(from: date)
            } else {
                f[ManuscriptMetadataKey.acceptanceDate.rawValue] = nil
            }
            fields = f
        }
    }

    // MARK: - Notes

    /// Free-form notes about the manuscript
    var manuscriptNotes: String? {
        get { fields[ManuscriptMetadataKey.notes.rawValue] }
        set {
            var f = fields
            f[ManuscriptMetadataKey.notes.rawValue] = newValue
            fields = f
        }
    }

    /// Coauthor email addresses (comma-separated)
    var coauthorEmails: String? {
        get { fields[ManuscriptMetadataKey.coauthorEmails.rawValue] }
        set {
            var f = fields
            f[ManuscriptMetadataKey.coauthorEmails.rawValue] = newValue
            fields = f
        }
    }

    // MARK: - Bibliography Management

    /// How the manuscript's bibliography is managed
    var bibliographyMode: BibliographyMode {
        get {
            guard let value = fields[ManuscriptMetadataKey.bibliographyMode.rawValue] else {
                return .manual
            }
            return BibliographyMode(rawValue: value) ?? .manual
        }
        set {
            var f = fields
            f[ManuscriptMetadataKey.bibliographyMode.rawValue] = newValue.rawValue
            fields = f
        }
    }

    /// Path to external .bib file (for watched mode)
    var externalBibPath: String? {
        get { fields[ManuscriptMetadataKey.externalBibPath.rawValue] }
        set {
            var f = fields
            f[ManuscriptMetadataKey.externalBibPath.rawValue] = newValue
            fields = f
        }
    }

    // MARK: - Citation Tracking

    /// IDs of publications cited by this manuscript
    var citedPublicationIDs: [UUID] {
        get {
            guard let json = fields[ManuscriptMetadataKey.citedPublicationIDs.rawValue],
                  let data = json.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return ids.compactMap { UUID(uuidString: $0) }
        }
        set {
            var f = fields
            let idStrings = newValue.map { $0.uuidString }
            if let data = try? JSONEncoder().encode(idStrings),
               let json = String(data: data, encoding: .utf8) {
                f[ManuscriptMetadataKey.citedPublicationIDs.rawValue] = json
            }
            fields = f
        }
    }

    /// Number of publications cited by this manuscript
    var citedPublicationCount: Int {
        citedPublicationIDs.count
    }

    /// Add a publication to the cited list
    func addCitation(_ publication: CDPublication) {
        var ids = citedPublicationIDs
        if !ids.contains(publication.id) {
            ids.append(publication.id)
            citedPublicationIDs = ids
        }
    }

    /// Remove a publication from the cited list
    func removeCitation(_ publication: CDPublication) {
        var ids = citedPublicationIDs
        ids.removeAll { $0 == publication.id }
        citedPublicationIDs = ids
    }

    /// Check if a publication is cited by this manuscript
    func cites(_ publication: CDPublication) -> Bool {
        citedPublicationIDs.contains(publication.id)
    }

    // MARK: - Manuscript Lifecycle

    /// Convert this publication to a manuscript
    ///
    /// Sets initial status to drafting and populates basic metadata.
    func convertToManuscript(targetJournal: String? = nil) {
        manuscriptStatus = .drafting
        self.targetJournal = targetJournal
        dateModified = Date()
    }

    /// Remove manuscript status (revert to regular publication)
    func removeManuscriptStatus() {
        var f = fields
        for key in ManuscriptMetadataKey.allCases {
            f[key.rawValue] = nil
        }
        fields = f
        dateModified = Date()
    }

    /// Update manuscript status with automatic date tracking
    func updateManuscriptStatus(to newStatus: ManuscriptStatus) {
        let oldStatus = manuscriptStatus
        manuscriptStatus = newStatus

        // Auto-set dates based on status transitions
        if oldStatus != .submitted && newStatus == .submitted {
            submissionDate = Date()
        }
        if oldStatus != .accepted && newStatus == .accepted {
            acceptanceDate = Date()
        }

        // Increment revision number on revision status
        if newStatus == .revision && oldStatus != .revision {
            revisionNumber += 1
        }

        dateModified = Date()
    }

    // MARK: - Version Files

    /// Get all linked files that are manuscript versions
    var manuscriptVersionFiles: [CDLinkedFile] {
        guard let files = linkedFiles else { return [] }
        return files.filter { file in
            guard let tags = file.attachmentTags else { return false }
            return tags.contains { ManuscriptAttachmentTag.isManuscriptTag($0.name) }
        }.sorted { $0.dateAdded < $1.dateAdded }
    }

    /// Get the latest manuscript version file
    var latestManuscriptVersion: CDLinkedFile? {
        manuscriptVersionFiles.last
    }

    /// Get referee reports attached to this manuscript
    var refereeReports: [CDLinkedFile] {
        guard let files = linkedFiles else { return [] }
        return files.filter { file in
            guard let tags = file.attachmentTags else { return false }
            return tags.contains { $0.name == ManuscriptAttachmentTag.refereeReport.rawValue }
        }.sorted { $0.dateAdded < $1.dateAdded }
    }

    /// Get response letters attached to this manuscript
    var responseLetters: [CDLinkedFile] {
        guard let files = linkedFiles else { return [] }
        return files.filter { file in
            guard let tags = file.attachmentTags else { return false }
            return tags.contains { $0.name == ManuscriptAttachmentTag.responseLetter.rawValue }
        }.sorted { $0.dateAdded < $1.dateAdded }
    }
}

// MARK: - ManuscriptMetadataKey CaseIterable

extension ManuscriptMetadataKey: CaseIterable {
    public static let allCases: [ManuscriptMetadataKey] = [
        .status, .venue, .revisionNumber, .notes, .citedPublicationIDs,
        .bibliographyMode, .externalBibPath, .submissionDate,
        .acceptanceDate, .targetJournal, .coauthorEmails,
        // imprint integration
        .imprintDocumentUUID, .imprintDocumentPath, .imprintBookmarkData,
        .compiledPDFLinkedFileID
    ]
}
