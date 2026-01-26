//
//  FileProviderPublication.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-25.
//

import Foundation

/// Lightweight DTO representing a publication with an attached PDF for File Provider.
///
/// This struct contains only the data needed by the File Provider Extension to expose
/// PDFs in Finder/Files app. It is designed to be thread-safe and independent of Core Data.
public struct FileProviderPublication: Sendable, Identifiable, Hashable {

    /// Unique identifier for this publication-file pair
    public let id: UUID

    /// Publication ID (CDPublication.id)
    public let publicationID: UUID

    /// Linked file ID (CDLinkedFile.id)
    public let linkedFileID: UUID

    /// ADS bibcode (e.g., "2025ApJ...897..123B")
    public let bibcode: String?

    /// Citation key (e.g., "Einstein1905")
    public let citeKey: String

    /// File size in bytes
    public let fileSize: Int64

    /// Whether the file exists on local disk
    public let hasLocalFile: Bool

    /// Whether the file has data available in CloudKit (fileData != nil)
    public let hasCloudKitData: Bool

    /// Relative path to the file (e.g., "Papers/Einstein_1905.pdf")
    public let relativePath: String

    /// Date the file was added
    public let dateAdded: Date

    /// Date the publication was modified
    public let dateModified: Date

    // MARK: - Computed Properties

    /// Display filename for Finder/Files app.
    /// Uses bibcode.pdf if available, otherwise citeKey.pdf
    public var displayFilename: String {
        if let bibcode = bibcode, !bibcode.isEmpty {
            return sanitizeFilename(bibcode) + ".pdf"
        }
        return sanitizeFilename(citeKey) + ".pdf"
    }

    /// Item identifier string for File Provider (uses linked file UUID)
    public var itemIdentifier: String {
        linkedFileID.uuidString
    }

    // MARK: - Private Helpers

    /// Sanitize a string for use as a filename
    private func sanitizeFilename(_ name: String) -> String {
        // Remove characters that are problematic in filenames
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = name.components(separatedBy: invalidChars).joined()

        // Limit length
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }

        return sanitized.isEmpty ? "Unknown" : sanitized
    }
}

// MARK: - Core Data Conversion

public extension FileProviderPublication {

    /// Create from Core Data entities
    init?(publication: CDPublication, linkedFile: CDLinkedFile, localFileExists: Bool) {
        guard linkedFile.isPDF else { return nil }

        self.id = linkedFile.id
        self.publicationID = publication.id
        self.linkedFileID = linkedFile.id
        self.bibcode = publication.bibcode
        self.citeKey = publication.citeKey
        self.fileSize = linkedFile.fileSize
        self.hasLocalFile = localFileExists
        self.hasCloudKitData = linkedFile.fileData != nil
        self.relativePath = linkedFile.relativePath
        self.dateAdded = linkedFile.dateAdded
        self.dateModified = publication.dateModified
    }
}
