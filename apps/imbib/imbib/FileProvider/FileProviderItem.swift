//
//  FileProviderItem.swift
//  imbib-FileProvider
//
//  Created by Claude on 2026-01-25.
//

import FileProvider
import PublicationManagerCore
import UniformTypeIdentifiers

/// NSFileProviderItem wrapper for a publication's PDF.
///
/// Represents a single PDF file in the File Provider hierarchy.
/// Files are named by bibcode (e.g., `2025ApJ...897..123B.pdf`) with fallback to citeKey.
final class FileProviderItem: NSObject, NSFileProviderItem {

    // MARK: - Properties

    private let publication: FileProviderPublication

    // MARK: - Initialization

    init(publication: FileProviderPublication) {
        self.publication = publication
        super.init()
    }

    // MARK: - NSFileProviderItem Required Properties

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(publication.itemIdentifier)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        // Flat hierarchy - all items are in root
        .rootContainer
    }

    var filename: String {
        publication.displayFilename
    }

    // MARK: - Content Properties

    var contentType: UTType {
        .pdf
    }

    var documentSize: NSNumber? {
        NSNumber(value: publication.fileSize)
    }

    // MARK: - Capabilities

    var capabilities: NSFileProviderItemCapabilities {
        // Read-only: can read but not modify or delete
        [.allowsReading]
    }

    // MARK: - Timestamps

    var contentModificationDate: Date? {
        publication.dateModified
    }

    var creationDate: Date? {
        publication.dateAdded
    }

    // MARK: - Download State

    var isDownloaded: Bool {
        publication.hasLocalFile
    }

    var isDownloading: Bool {
        false
    }

    var downloadingError: Error? {
        nil
    }

    // MARK: - Upload State (Read-only provider)

    var isUploaded: Bool {
        true // Always "uploaded" since we don't allow modifications
    }

    var isUploading: Bool {
        false
    }

    var uploadingError: Error? {
        nil
    }

    // MARK: - Version

    var itemVersion: NSFileProviderItemVersion {
        // Use modification date as version
        let contentVersion = Data(withUnsafeBytes(of: publication.dateModified.timeIntervalSince1970) { Data($0) })
        return NSFileProviderItemVersion(contentVersion: contentVersion, metadataVersion: contentVersion)
    }
}
