//
//  CDPublication+ImprintIntegration.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-27.
//

import Foundation
import CoreData

// MARK: - CDPublication imprint Integration

public extension CDPublication {

    // MARK: - imprint Document Link Detection

    /// Whether this manuscript has a linked imprint document
    var hasLinkedImprintDocument: Bool {
        imprintDocumentUUID != nil
    }

    /// The UUID of the linked imprint document
    var imprintDocumentUUID: UUID? {
        get {
            guard let uuidString = fields[ManuscriptMetadataKey.imprintDocumentUUID.rawValue] else {
                return nil
            }
            return UUID(uuidString: uuidString)
        }
        set {
            var f = fields
            f[ManuscriptMetadataKey.imprintDocumentUUID.rawValue] = newValue?.uuidString
            fields = f
        }
    }

    /// Last known file path to the linked imprint document
    var imprintDocumentPath: String? {
        get { fields[ManuscriptMetadataKey.imprintDocumentPath.rawValue] }
        set {
            var f = fields
            f[ManuscriptMetadataKey.imprintDocumentPath.rawValue] = newValue
            fields = f
        }
    }

    /// Security-scoped bookmark data for sandboxed access (macOS)
    var imprintBookmarkData: Data? {
        get {
            guard let base64 = fields[ManuscriptMetadataKey.imprintBookmarkData.rawValue] else {
                return nil
            }
            return Data(base64Encoded: base64)
        }
        set {
            var f = fields
            f[ManuscriptMetadataKey.imprintBookmarkData.rawValue] = newValue?.base64EncodedString()
            fields = f
        }
    }

    /// UUID of the CDLinkedFile containing the compiled PDF
    var compiledPDFLinkedFileID: UUID? {
        get {
            guard let uuidString = fields[ManuscriptMetadataKey.compiledPDFLinkedFileID.rawValue] else {
                return nil
            }
            return UUID(uuidString: uuidString)
        }
        set {
            var f = fields
            f[ManuscriptMetadataKey.compiledPDFLinkedFileID.rawValue] = newValue?.uuidString
            fields = f
        }
    }

    // MARK: - Resolve imprint Document URL

    /// Attempts to resolve the URL to the linked imprint document.
    ///
    /// On macOS, first tries the security-scoped bookmark, then falls back to
    /// the stored path. On iOS, uses the stored path directly.
    ///
    /// - Returns: URL to the imprint document if resolvable, nil otherwise
    func resolveImprintDocumentURL() -> URL? {
        #if os(macOS)
        // Try bookmark first for sandbox compatibility
        if let bookmarkData = imprintBookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                // Refresh bookmark if stale
                if isStale, let freshBookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    imprintBookmarkData = freshBookmark
                }
                return url
            }
        }
        #endif

        // Fall back to stored path
        if let path = imprintDocumentPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                return url
            }
        }

        return nil
    }

    // MARK: - Link imprint Document

    /// Links an imprint document to this manuscript.
    ///
    /// Stores the document UUID, file path, and creates a security-scoped
    /// bookmark on macOS for sandbox compatibility.
    ///
    /// - Parameters:
    ///   - documentUUID: The stable UUID from the imprint document's metadata.json
    ///   - fileURL: The file URL to the .imprint document
    ///   - context: The managed object context to save changes
    func linkImprintDocument(
        documentUUID: UUID,
        fileURL: URL,
        context: NSManagedObjectContext
    ) throws {
        // Store the document UUID
        imprintDocumentUUID = documentUUID

        // Store the file path
        imprintDocumentPath = fileURL.path

        #if os(macOS)
        // Create security-scoped bookmark for sandbox
        let bookmarkData = try fileURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        imprintBookmarkData = bookmarkData
        #endif

        dateModified = Date()

        try context.save()
    }

    /// Unlinks the imprint document from this manuscript.
    ///
    /// - Parameter context: The managed object context to save changes
    func unlinkImprintDocument(context: NSManagedObjectContext) throws {
        imprintDocumentUUID = nil
        imprintDocumentPath = nil
        imprintBookmarkData = nil
        compiledPDFLinkedFileID = nil
        dateModified = Date()

        try context.save()
    }

    // MARK: - Compiled PDF Management

    /// Get the compiled PDF linked file, if any
    var compiledPDFFile: CDLinkedFile? {
        guard let fileID = compiledPDFLinkedFileID,
              let files = linkedFiles else {
            return nil
        }
        return files.first { $0.id == fileID }
    }

    /// Links a compiled PDF file to this manuscript.
    ///
    /// - Parameters:
    ///   - linkedFile: The CDLinkedFile containing the compiled PDF
    ///   - context: The managed object context to save changes
    func linkCompiledPDF(
        _ linkedFile: CDLinkedFile,
        context: NSManagedObjectContext
    ) throws {
        compiledPDFLinkedFileID = linkedFile.id

        // Ensure the file has the compiled-pdf tag
        if let tags = linkedFile.attachmentTags,
           !tags.contains(where: { $0.name == ManuscriptAttachmentTag.compiledPDF.rawValue }) {
            // Add the tag if not present
            let tag = CDAttachmentTag(context: context)
            tag.name = ManuscriptAttachmentTag.compiledPDF.rawValue
            linkedFile.addToAttachmentTags(tag)
        }

        dateModified = Date()
        try context.save()
    }
}

// MARK: - imprint URL Scheme Support

public extension CDPublication {

    /// Generates a URL to open this manuscript in imprint (iOS/macOS)
    ///
    /// Format: `imprint://open?imbibManuscript={citeKey}&documentUUID={uuid}`
    var imprintOpenURL: URL? {
        guard let docUUID = imprintDocumentUUID else { return nil }

        var components = URLComponents()
        components.scheme = "imprint"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "imbibManuscript", value: citeKey),
            URLQueryItem(name: "documentUUID", value: docUUID.uuidString)
        ]

        return components.url
    }

    /// Generates an imbib URL scheme command to open this manuscript in imprint
    ///
    /// Format: `imbib://manuscript/{citeKey}/open-in-imprint`
    var imbibOpenInImprintURL: URL? {
        var components = URLComponents()
        components.scheme = "imbib"
        components.host = "manuscript"
        components.path = "/\(citeKey)/open-in-imprint"

        return components.url
    }
}
