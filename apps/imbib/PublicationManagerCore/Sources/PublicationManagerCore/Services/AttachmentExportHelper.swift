//
//  AttachmentExportHelper.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import CoreData
import OSLog

// MARK: - Attachment Export Helper

/// Shared helper for exporting file attachments.
///
/// Provides common functionality used by both `LibraryBackupService` and `MboxExporter`
/// for handling publication attachments during export operations.
public enum AttachmentExportHelper {

    private static let logger = Logger(subsystem: "PublicationManagerCore", category: "AttachmentExportHelper")

    // MARK: - File Data Reading

    /// Attachment file data with metadata.
    public struct AttachmentData: Sendable {
        public let filename: String
        public let relativePath: String
        public let data: Data
        public let mimeType: String
        public let isMainFile: Bool

        public init(filename: String, relativePath: String, data: Data, mimeType: String, isMainFile: Bool) {
            self.filename = filename
            self.relativePath = relativePath
            self.data = data
            self.mimeType = mimeType
            self.isMainFile = isMainFile
        }
    }

    /// Read attachment data for a publication.
    ///
    /// - Parameters:
    ///   - linkedFiles: The linked files to read (from publication.linkedFiles).
    ///   - papersContainerURL: The URL of the library's papers container.
    ///   - maxFileSize: Optional maximum file size in bytes. Files larger than this are skipped.
    /// - Returns: Array of attachment data for the publication's linked files.
    public static func readAttachmentData(
        linkedFiles: Set<CDLinkedFile>?,
        papersContainerURL: URL?,
        maxFileSize: Int? = nil
    ) -> [AttachmentData] {
        var attachments: [AttachmentData] = []

        guard let linkedFiles = linkedFiles else { return attachments }

        for (index, linkedFile) in linkedFiles.enumerated() {
            // Try to read file data
            let fileData: Data?

            // First check if fileData is stored in Core Data (for CloudKit sync)
            if let storedData = linkedFile.fileData, !storedData.isEmpty {
                fileData = storedData
            } else if let containerURL = papersContainerURL {
                // Try to read from disk
                let fileURL = containerURL.appendingPathComponent(linkedFile.relativePath)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    // Check file size limit
                    if let maxSize = maxFileSize {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                        let size = (attrs?[.size] as? Int) ?? 0
                        if size > maxSize {
                            logger.warning("Skipping large file: \(linkedFile.filename) (\(size) bytes)")
                            continue
                        }
                    }
                    fileData = try? Data(contentsOf: fileURL)
                } else {
                    fileData = nil
                }
            } else {
                fileData = nil
            }

            guard let data = fileData else {
                logger.warning("Could not read file data for: \(linkedFile.filename)")
                continue
            }

            // Determine content type
            let contentType = linkedFile.mimeType ?? mimeType(for: linkedFile.fileExtension)

            attachments.append(AttachmentData(
                filename: linkedFile.filename,
                relativePath: linkedFile.relativePath,
                data: data,
                mimeType: contentType,
                isMainFile: index == 0
            ))
        }

        return attachments
    }

    // MARK: - Directory Copy

    /// Information about a file to copy.
    public struct FileToCopy: Sendable {
        public let citeKey: String
        public let relativePath: String
        public let sourceURL: URL

        public init(citeKey: String, relativePath: String, sourceURL: URL) {
            self.citeKey = citeKey
            self.relativePath = relativePath
            self.sourceURL = sourceURL
        }
    }

    /// Get all attachment files for publications.
    ///
    /// This is a data-gathering function that returns file information for later copying.
    /// Called from within a MainActor context where AttachmentManager is available.
    ///
    /// - Parameters:
    ///   - publications: The publications to get attachments from.
    ///   - resolveURL: A closure that resolves file URLs (typically AttachmentManager.shared.resolveURL).
    /// - Returns: Array of file information for copying.
    public static func getAttachmentFiles<T: Sequence>(
        from publications: T,
        resolveURL: (CDLinkedFile) -> URL?
    ) -> [FileToCopy] where T.Element == CDPublication {
        var files: [FileToCopy] = []

        for pub in publications {
            guard let linkedFiles = pub.linkedFiles, !linkedFiles.isEmpty else {
                continue
            }

            for linkedFile in linkedFiles {
                if let sourceURL = resolveURL(linkedFile) {
                    files.append(FileToCopy(
                        citeKey: pub.citeKey,
                        relativePath: linkedFile.relativePath,
                        sourceURL: sourceURL
                    ))
                }
            }
        }

        return files
    }

    /// Copy attachments to a directory.
    ///
    /// - Parameters:
    ///   - files: Array of files to copy.
    ///   - destination: The destination directory URL.
    ///   - progressHandler: Optional progress callback.
    /// - Returns: The number of files successfully copied.
    public static func copyAttachments(
        _ files: [FileToCopy],
        to destination: URL,
        fileManager: FileManager = .default,
        progressHandler: ((_ current: Int, _ total: Int, _ currentItem: String?) -> Void)? = nil
    ) throws -> Int {
        var copiedCount = 0

        for (index, fileInfo) in files.enumerated() {
            progressHandler?(index, files.count, fileInfo.citeKey)

            if fileManager.fileExists(atPath: fileInfo.sourceURL.path) {
                let destURL = destination.appendingPathComponent(fileInfo.relativePath)

                // Create subdirectories if needed
                let destDir = destURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: destDir.path) {
                    try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
                }

                try fileManager.copyItem(at: fileInfo.sourceURL, to: destURL)
                copiedCount += 1
            } else {
                logger.warning("Attachment not found at: \(fileInfo.sourceURL.path)")
            }
        }

        logger.info("Copied \(copiedCount) attachment files")
        return copiedCount
    }

    // MARK: - MIME Types

    /// Get MIME type for a file extension.
    ///
    /// - Parameter ext: The file extension (without leading dot).
    /// - Returns: The MIME type string.
    public static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":
            return "application/pdf"
        case "txt":
            return "text/plain"
        case "html", "htm":
            return "text/html"
        case "doc":
            return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "tiff", "tif":
            return "image/tiff"
        case "webp":
            return "image/webp"
        case "bib":
            return "text/x-bibtex"
        case "ris":
            return "application/x-research-info-systems"
        case "xml":
            return "application/xml"
        case "json":
            return "application/json"
        case "zip":
            return "application/zip"
        case "gz", "gzip":
            return "application/gzip"
        case "tar":
            return "application/x-tar"
        case "epub":
            return "application/epub+zip"
        case "djvu":
            return "image/vnd.djvu"
        case "ps":
            return "application/postscript"
        case "rtf":
            return "application/rtf"
        case "tex":
            return "application/x-tex"
        case "csv":
            return "text/csv"
        case "md", "markdown":
            return "text/markdown"
        default:
            return "application/octet-stream"
        }
    }

    /// Get file extension from MIME type.
    ///
    /// - Parameter mimeType: The MIME type string.
    /// - Returns: The file extension (without leading dot), or nil if unknown.
    public static func fileExtension(for mimeType: String) -> String? {
        switch mimeType.lowercased() {
        case "application/pdf":
            return "pdf"
        case "text/plain":
            return "txt"
        case "text/html":
            return "html"
        case "application/msword":
            return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return "docx"
        case "image/png":
            return "png"
        case "image/jpeg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/tiff":
            return "tiff"
        case "image/webp":
            return "webp"
        case "text/x-bibtex":
            return "bib"
        case "application/x-research-info-systems":
            return "ris"
        case "application/xml":
            return "xml"
        case "application/json":
            return "json"
        case "application/zip":
            return "zip"
        case "application/gzip":
            return "gz"
        case "application/epub+zip":
            return "epub"
        default:
            return nil
        }
    }
}
