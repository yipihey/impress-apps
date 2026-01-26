//
//  PDFManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData
import CryptoKit
import OSLog
import UniformTypeIdentifiers

// MARK: - Backward Compatibility

/// Type alias for backward compatibility with existing code.
public typealias PDFManager = AttachmentManager

// MARK: - Attachment Manager

/// Manages attached files (PDFs, images, code, data files, etc.) for publications.
///
/// Handles:
/// - Importing any file type with human-readable filenames (ADR-004)
/// - Auto-generation of filenames for PDFs based on publication metadata
/// - Preserving original filenames for non-PDF attachments
/// - Collision handling with numeric suffixes
/// - SHA256 integrity verification
/// - MIME type detection for accurate file type icons
/// - File size tracking for UI display
@MainActor
public final class AttachmentManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = AttachmentManager()

    // MARK: - Properties

    private let persistenceController: PersistenceController
    private let fileManager = FileManager.default

    /// Default papers directory name
    private let papersFolderName = "Papers"

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Link Existing PDF (BibDesk Import)

    /// Link an existing PDF file without copying.
    ///
    /// Used when importing BibDesk .bib files that already have PDFs in place.
    /// The file is NOT copied - we just create a CDLinkedFile record pointing to it.
    ///
    /// - Parameters:
    ///   - relativePath: The relative path from .bib file location (e.g., "Papers/Einstein_1905.pdf")
    ///   - publication: The publication to link the PDF to
    ///   - library: The library containing the publication
    /// - Returns: The created CDLinkedFile entity, or nil if the file doesn't exist
    @discardableResult
    public func linkExistingPDF(
        relativePath: String,
        for publication: CDPublication,
        in library: CDLibrary? = nil
    ) -> CDLinkedFile? {
        Logger.files.infoCapture("Linking existing PDF: \(relativePath)", category: "files")

        // Verify file exists using container-based path
        var absoluteURL: URL?
        if let library = library {
            absoluteURL = library.containerURL.appendingPathComponent(relativePath)
        } else if let appSupport = applicationSupportURL {
            absoluteURL = appSupport.appendingPathComponent("DefaultLibrary/\(relativePath)")
        }

        if let url = absoluteURL, !fileManager.fileExists(atPath: url.path) {
            Logger.files.warningCapture("Linked PDF not found at: \(url.path)", category: "files")
            // Still create the link - file might be on another device (CloudKit sync)
        }

        let filename = (relativePath as NSString).lastPathComponent

        // Check if already linked
        if let existingLinks = publication.linkedFiles,
           existingLinks.contains(where: { $0.relativePath == relativePath }) {
            Logger.files.debugCapture("PDF already linked: \(relativePath)", category: "files")
            return existingLinks.first { $0.relativePath == relativePath }
        }

        // Create linked file record
        let context = persistenceController.viewContext
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = relativePath
        linkedFile.filename = filename
        linkedFile.fileType = (filename as NSString).pathExtension.lowercased()
        linkedFile.dateAdded = Date()
        linkedFile.publication = publication

        // Compute SHA256 if file exists
        if let url = absoluteURL {
            linkedFile.sha256 = computeSHA256(for: url)
        }

        // Mark PDF downloaded
        markPDFDownloaded(publication)

        persistenceController.save()

        Logger.files.infoCapture("Linked existing PDF: \(filename)", category: "files")
        return linkedFile
    }

    /// Process Bdsk-File-* fields from a BibTeX entry and create linked file records.
    ///
    /// This is called during BibTeX import to preserve existing PDF links from BibDesk.
    public func processBdskFiles(
        from entry: BibTeXEntry,
        for publication: CDPublication,
        in library: CDLibrary? = nil
    ) {
        // Find all Bdsk-File-* fields
        let bdskFields = entry.fields.filter { $0.key.hasPrefix("Bdsk-File-") }

        for (_, value) in bdskFields.sorted(by: { $0.key < $1.key }) {
            if let relativePath = BdskFileCodec.decode(value) {
                linkExistingPDF(relativePath: relativePath, for: publication, in: library)
            }
        }
    }

    // MARK: - Import Attachment (General)

    /// Import any file as an attachment for a publication.
    ///
    /// The file is copied to the library's Papers folder. For PDFs, a human-readable
    /// name is generated based on publication metadata. For other file types, the
    /// original filename is preserved by default.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the source file
    ///   - publication: The publication to link the file to
    ///   - library: The library containing the publication (determines Papers folder location)
    ///   - preserveFilename: If true, keeps the original filename. Default: true for non-PDFs, false for PDFs
    ///   - displayName: Optional user-friendly display name (if nil, uses filename)
    ///   - precomputedHash: Optional pre-computed SHA256 hash (from `checkForDuplicate`). Avoids redundant hash computation.
    /// - Returns: The created CDLinkedFile entity
    @discardableResult
    public func importAttachment(
        from sourceURL: URL,
        for publication: CDPublication,
        in library: CDLibrary? = nil,
        preserveFilename: Bool? = nil,
        displayName: String? = nil,
        precomputedHash: String? = nil
    ) throws -> CDLinkedFile {
        let fileExtension = sourceURL.pathExtension.lowercased()
        let isPDF = fileExtension == "pdf"

        // Default: preserve filename for non-PDFs, auto-generate for PDFs
        let shouldPreserveFilename = preserveFilename ?? !isPDF

        Logger.files.infoCapture("Importing attachment: \(sourceURL.lastPathComponent) (preserve: \(shouldPreserveFilename))", category: "files")

        // Determine papers directory
        let papersDirectory = try resolvePapersDirectory(for: library)

        // Generate filename
        let filename: String
        if shouldPreserveFilename {
            filename = sourceURL.lastPathComponent
        } else if isPDF {
            filename = generateFilename(for: publication)
        } else {
            filename = generateFilename(for: publication, extension: fileExtension)
        }
        let resolvedFilename = resolveCollision(filename, in: papersDirectory)

        // Destination path
        let destinationURL = papersDirectory.appendingPathComponent(resolvedFilename)

        // Get file size before copying
        var fileSize: Int64 = 0
        if let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
           let size = attributes[.size] as? Int64 {
            fileSize = size
        }

        // Copy the file
        do {
            // Start accessing security-scoped resource if needed
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            Logger.files.infoCapture("Copied file to: \(resolvedFilename)", category: "files")
        } catch {
            Logger.files.errorCapture("Failed to copy file: \(error.localizedDescription)", category: "files")
            throw AttachmentError.copyFailed(sourceURL, error)
        }

        // Use precomputed hash or compute from destination file
        let sha256 = precomputedHash ?? computeSHA256(for: destinationURL)

        // Detect MIME type
        let mimeType = detectMIMEType(for: sourceURL)

        // Create linked file record
        let context = persistenceController.viewContext
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = "\(papersFolderName)/\(resolvedFilename)"
        linkedFile.filename = resolvedFilename
        linkedFile.fileType = fileExtension
        linkedFile.sha256 = sha256
        linkedFile.dateAdded = Date()
        linkedFile.publication = publication
        linkedFile.displayName = displayName
        linkedFile.fileSize = fileSize
        linkedFile.mimeType = mimeType

        // Store file data for CloudKit sync (PDFs only, for cross-device access)
        // Read the copied file to get the data for CloudKit CKAsset storage
        if isPDF {
            do {
                let pdfData = try Data(contentsOf: destinationURL)
                linkedFile.fileData = pdfData
                Logger.files.debugCapture("Stored \(pdfData.count) bytes in fileData for CloudKit sync", category: "files")
            } catch {
                Logger.files.warningCapture("Could not read PDF data for CloudKit sync: \(error.localizedDescription)", category: "files")
            }
        }

        // Mark PDF downloaded if it's a PDF
        if isPDF {
            markPDFDownloaded(publication)
        }

        persistenceController.save()

        // Signal File Provider about the new file
        FileProviderDomainManager.shared.signalChange()

        Logger.files.infoCapture("Created linked file: \(linkedFile.id) (\(linkedFile.formattedFileSize))", category: "files")
        return linkedFile
    }

    /// Import multiple files as attachments in batch.
    ///
    /// - Parameters:
    ///   - urls: Array of source file URLs
    ///   - publication: The publication to link the files to
    ///   - library: The library containing the publication
    ///   - progress: Optional progress callback (current, total)
    /// - Returns: Array of created CDLinkedFile entities
    public func importAttachments(
        from urls: [URL],
        for publication: CDPublication,
        in library: CDLibrary? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [CDLinkedFile] {
        Logger.files.infoCapture("Batch importing \(urls.count) attachments", category: "files")

        var linkedFiles: [CDLinkedFile] = []
        var errors: [Error] = []

        for (index, url) in urls.enumerated() {
            progress?(index + 1, urls.count)

            do {
                let linkedFile = try importAttachment(from: url, for: publication, in: library)
                linkedFiles.append(linkedFile)
            } catch {
                Logger.files.errorCapture("Failed to import \(url.lastPathComponent): \(error.localizedDescription)", category: "files")
                errors.append(error)
            }
        }

        if !errors.isEmpty {
            Logger.files.warningCapture("Batch import completed with \(errors.count) errors", category: "files")
        }

        return linkedFiles
    }

    // MARK: - Import PDF (Copy) - Backward Compatible

    /// Import a PDF file for a publication.
    ///
    /// The PDF is copied to the library's Papers folder with a human-readable name
    /// based on the publication's metadata.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the source PDF file
    ///   - publication: The publication to link the PDF to
    ///   - library: The library containing the publication (determines Papers folder location)
    ///   - preserveFilename: If true, keeps the original filename instead of auto-generating
    /// - Returns: The created CDLinkedFile entity
    @discardableResult
    public func importPDF(
        from sourceURL: URL,
        for publication: CDPublication,
        in library: CDLibrary? = nil,
        preserveFilename: Bool = false
    ) throws -> CDLinkedFile {
        // Check if source file has a non-PDF extension (e.g., .tmp from URLSession downloads)
        // In that case, read the data and use the data-based import which correctly forces .pdf extension
        let sourceExtension = sourceURL.pathExtension.lowercased()
        if sourceExtension != "pdf" && !sourceExtension.isEmpty {
            Logger.files.infoCapture("Source file has non-PDF extension '\(sourceExtension)', reading data to force .pdf extension", category: "files")

            // Start accessing security-scoped resource if needed
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            }

            let data = try Data(contentsOf: sourceURL)
            return try importPDF(data: data, for: publication, in: library)
        }

        // Normal PDF file - delegate to importAttachment
        return try importAttachment(
            from: sourceURL,
            for: publication,
            in: library,
            preserveFilename: preserveFilename
        )
    }

    /// Import PDF data directly (e.g., from downloaded content).
    @discardableResult
    public func importPDF(
        data: Data,
        for publication: CDPublication,
        in library: CDLibrary? = nil
    ) throws -> CDLinkedFile {
        return try importAttachment(data: data, for: publication, in: library, fileExtension: "pdf")
    }

    /// Import attachment data directly (e.g., from downloaded content or clipboard).
    ///
    /// - Parameters:
    ///   - data: The file data
    ///   - publication: The publication to link the file to
    ///   - library: The library containing the publication
    ///   - fileExtension: File extension (e.g., "pdf", "png", "tar.gz")
    ///   - displayName: Optional user-friendly display name
    /// - Returns: The created CDLinkedFile entity
    @discardableResult
    public func importAttachment(
        data: Data,
        for publication: CDPublication,
        in library: CDLibrary? = nil,
        fileExtension: String = "pdf",
        displayName: String? = nil
    ) throws -> CDLinkedFile {
        let isPDF = fileExtension.lowercased() == "pdf"
        Logger.files.infoCapture("Importing attachment data (\(data.count) bytes, .\(fileExtension))", category: "files")

        // Determine papers directory
        let papersDirectory = try resolvePapersDirectory(for: library)

        // Generate human-readable filename
        let filename = generateFilename(for: publication, extension: fileExtension)
        let resolvedFilename = resolveCollision(filename, in: papersDirectory)

        // Destination path
        let destinationURL = papersDirectory.appendingPathComponent(resolvedFilename)

        // Write the data
        do {
            try data.write(to: destinationURL)
            Logger.files.infoCapture("Wrote file to: \(resolvedFilename)", category: "files")
        } catch {
            Logger.files.errorCapture("Failed to write file: \(error.localizedDescription)", category: "files")
            throw AttachmentError.writeFailed(destinationURL, error)
        }

        // Compute SHA256
        let sha256 = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()

        // Detect MIME type from data
        let mimeType = detectMIMEType(fromData: data, fileExtension: fileExtension)

        // Create linked file record
        let context = persistenceController.viewContext
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = "\(papersFolderName)/\(resolvedFilename)"
        linkedFile.filename = resolvedFilename
        linkedFile.fileType = fileExtension.lowercased()
        linkedFile.sha256 = sha256
        linkedFile.dateAdded = Date()
        linkedFile.publication = publication
        linkedFile.displayName = displayName
        linkedFile.fileSize = Int64(data.count)
        linkedFile.mimeType = mimeType

        // Store file data for CloudKit sync (PDFs only, for cross-device access)
        // CloudKit handles this as CKAsset via allowsExternalBinaryDataStorage
        if isPDF {
            linkedFile.fileData = data
            Logger.files.debugCapture("Stored \(data.count) bytes in fileData for CloudKit sync", category: "files")
        }

        // Mark PDF downloaded if it's a PDF
        if isPDF {
            markPDFDownloaded(publication)
        }

        persistenceController.save()

        // Signal File Provider about the new file
        FileProviderDomainManager.shared.signalChange()

        Logger.files.infoCapture("Created linked file: \(linkedFile.id) (\(linkedFile.formattedFileSize))", category: "files")
        return linkedFile
    }

    // MARK: - Download PDF

    /// Download a PDF from a URL and import it.
    @discardableResult
    public func downloadAndImport(
        from url: URL,
        for publication: CDPublication,
        in library: CDLibrary? = nil
    ) async throws -> CDLinkedFile {
        Logger.files.infoCapture("Downloading PDF from: \(url.absoluteString)", category: "files")

        // Download the PDF
        let (data, response) = try await URLSession.shared.data(from: url)

        // Verify it's a PDF
        if let httpResponse = response as? HTTPURLResponse {
            guard httpResponse.statusCode == 200 else {
                Logger.files.errorCapture("HTTP error: \(httpResponse.statusCode)", category: "files")
                throw PDFError.downloadFailed(url, nil)
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !contentType.contains("pdf") && !contentType.contains("octet-stream") {
                Logger.files.warningCapture("Unexpected content type: \(contentType)", category: "files")
            }
        }

        guard !data.isEmpty else {
            throw PDFError.emptyDownload(url)
        }

        Logger.files.infoCapture("Downloaded \(data.count) bytes", category: "files")

        let linkedFile = try importPDF(data: data, for: publication, in: library)
        markPDFDownloaded(publication)

        // ADR-020: Record PDF download signal for recommendation engine
        Task { await SignalCollector.shared.recordPDFDownload(publication) }

        return linkedFile
    }

    // MARK: - PDF Download State

    /// Mark a publication as having a PDF downloaded.
    ///
    /// This updates the `hasPDFDownloaded` and `pdfDownloadDate` fields which
    /// were previously unused but are now set consistently across all import paths.
    private func markPDFDownloaded(_ publication: CDPublication) {
        publication.hasPDFDownloaded = true
        publication.pdfDownloadDate = Date()
        Logger.files.debugCapture("Marked PDF downloaded for: \(publication.citeKey)", category: "files")
    }

    // MARK: - Filename Generation

    /// Generate a human-readable filename for a publication.
    ///
    /// Format: `{FirstAuthorLastName}_{Year}_{TruncatedTitle}.{ext}`
    /// Example: `Einstein_1905_OnTheElectrodynamics.pdf`
    ///
    /// - Parameters:
    ///   - publication: The publication for metadata
    ///   - extension: File extension (default: "pdf")
    public func generateFilename(for publication: CDPublication, extension ext: String = "pdf") -> String {
        // Get first author's last name
        let author: String
        if let firstAuthor = publication.sortedAuthors.first {
            author = firstAuthor.familyName
        } else if let authorField = publication.fields["author"] {
            // Parse first author from field
            let firstAuthorStr = authorField.components(separatedBy: " and ").first ?? authorField
            let parsed = CDAuthor.parse(firstAuthorStr)
            author = parsed.familyName
        } else {
            author = "Unknown"
        }

        // Get year
        let year = publication.year > 0 ? String(publication.year) : "NoYear"

        // Get truncated title
        let title = truncateTitle(publication.title ?? "Untitled", maxLength: 40)

        // Combine and sanitize
        let base = "\(author)_\(year)_\(title)"
        let sanitized = sanitizeFilename(base)

        return sanitized + ".\(ext)"
    }

    /// Generate filename from a BibTeX entry (for imports before CDPublication exists).
    ///
    /// - Parameters:
    ///   - entry: The BibTeX entry for metadata
    ///   - extension: File extension (default: "pdf")
    public func generateFilename(from entry: BibTeXEntry, extension ext: String = "pdf") -> String {
        // Get first author
        let author: String
        if let authorField = entry.fields["author"] {
            let firstAuthorStr = authorField.components(separatedBy: " and ").first ?? authorField
            let parsed = CDAuthor.parse(firstAuthorStr)
            author = parsed.familyName
        } else {
            author = "Unknown"
        }

        // Get year
        let year = entry.fields["year"] ?? "NoYear"

        // Get truncated title
        let title = truncateTitle(entry.title ?? "Untitled", maxLength: 40)

        // Combine and sanitize
        let base = "\(author)_\(year)_\(title)"
        let sanitized = sanitizeFilename(base)

        return sanitized + ".\(ext)"
    }

    // MARK: - File Operations

    /// Get the absolute URL for a linked file.
    ///
    /// With iCloud-only storage, files are resolved relative to the library's
    /// container URL (`~/Library/Application Support/imbib/Libraries/{UUID}/`).
    /// Falls back to legacy path (`imbib/Papers/`) for pre-v1.3.0 downloads.
    public func resolveURL(for linkedFile: CDLinkedFile, in library: CDLibrary?) -> URL? {
        let normalizedPath = linkedFile.relativePath.precomposedStringWithCanonicalMapping
        guard let appSupport = applicationSupportURL else { return nil }

        if let library = library {
            // Primary: container-based path (iCloud-only storage)
            let containerURL = library.containerURL.appendingPathComponent(normalizedPath)
            // Fallback: legacy path (pre-v1.3.0 downloads went to imbib/Papers/)
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)

            if fileManager.fileExists(atPath: containerURL.path) {
                return containerURL
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                return legacyURL
            }
            return containerURL
        }

        // No library - check default library path and legacy path
        let defaultURL = appSupport.appendingPathComponent("DefaultLibrary/\(normalizedPath)")
        let legacyURL = appSupport.appendingPathComponent(normalizedPath)

        if fileManager.fileExists(atPath: defaultURL.path) {
            return defaultURL
        } else if fileManager.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return defaultURL
    }

    /// Delete a linked file from disk and Core Data.
    public func delete(_ linkedFile: CDLinkedFile, in library: CDLibrary? = nil) throws {
        Logger.files.infoCapture("Deleting linked file: \(linkedFile.filename)", category: "files")

        // Delete file from disk
        if let url = resolveURL(for: linkedFile, in: library) {
            try? fileManager.removeItem(at: url)
        }

        // Delete from Core Data
        let context = persistenceController.viewContext
        context.delete(linkedFile)
        persistenceController.save()

        // Signal File Provider about the deletion
        FileProviderDomainManager.shared.signalChange()
    }

    /// Verify file integrity using SHA256.
    public func verifyIntegrity(of linkedFile: CDLinkedFile, in library: CDLibrary? = nil) -> Bool {
        guard let expectedHash = linkedFile.sha256,
              let url = resolveURL(for: linkedFile, in: library),
              let actualHash = computeSHA256(for: url) else {
            return false
        }
        return expectedHash == actualHash
    }

    // MARK: - Duplicate Detection

    /// Check if a file with matching content already exists for this publication.
    ///
    /// Uses a two-phase approach for efficiency:
    /// 1. File size pre-check: Skip hash computation if no existing files match size
    /// 2. SHA256 comparison: Only compute hash when size matches
    ///
    /// The computed hash is returned in both cases so it can be reused during import,
    /// avoiding redundant hash computation.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the file to check
    ///   - publication: The publication to check against
    /// - Returns: Result indicating duplicate status and computed hash, or nil on error
    public func checkForDuplicate(
        sourceURL: URL,
        in publication: CDPublication
    ) -> DuplicateCheckResult? {
        // Get source file size
        guard let sourceSize = try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64 else {
            Logger.files.warningCapture("Could not get file size for: \(sourceURL.lastPathComponent)", category: "files")
            return nil
        }

        // Find existing files with matching size (fast pre-check)
        let existingFiles = publication.linkedFiles ?? []
        let sameSizeFiles = existingFiles.filter { $0.fileSize == sourceSize && $0.sha256 != nil }

        // No files with same size = no duplicate possible, but still compute hash for import
        guard !sameSizeFiles.isEmpty else {
            guard let hash = computeSHA256(for: sourceURL) else {
                Logger.files.warningCapture("Could not compute hash for: \(sourceURL.lastPathComponent)", category: "files")
                return nil
            }
            return .noDuplicate(hash: hash)
        }

        // Same size exists - compute hash to confirm duplicate
        guard let hash = computeSHA256(for: sourceURL) else {
            Logger.files.warningCapture("Could not compute hash for: \(sourceURL.lastPathComponent)", category: "files")
            return nil
        }

        // Check if any existing file has matching hash
        if let existing = sameSizeFiles.first(where: { $0.sha256 == hash }) {
            Logger.files.infoCapture("Duplicate detected: \(sourceURL.lastPathComponent) matches \(existing.filename)", category: "files")
            return .duplicate(existingFile: existing, hash: hash)
        }

        return .noDuplicate(hash: hash)
    }

    /// Check if data would be a duplicate of an existing attachment.
    ///
    /// Uses a two-phase approach for efficiency:
    /// 1. File size pre-check: Skip hash computation if no existing files match size
    /// 2. SHA256 comparison: Only compute hash when size matches
    ///
    /// The computed hash is returned in both cases so it can be reused during import,
    /// avoiding redundant hash computation.
    ///
    /// - Parameters:
    ///   - data: The file data to check
    ///   - publication: The publication to check against
    /// - Returns: Result indicating duplicate status and computed hash
    public func checkForDuplicate(
        data: Data,
        in publication: CDPublication
    ) -> DuplicateCheckResult {
        let dataSize = Int64(data.count)

        // Find existing files with matching size (fast pre-check)
        let existingFiles = publication.linkedFiles ?? []
        let sameSizeFiles = existingFiles.filter { $0.fileSize == dataSize && $0.sha256 != nil }

        // Compute hash
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()

        // No files with same size = no duplicate possible
        guard !sameSizeFiles.isEmpty else {
            return .noDuplicate(hash: hash)
        }

        // Check if any existing file has matching hash
        if let existing = sameSizeFiles.first(where: { $0.sha256 == hash }) {
            Logger.files.infoCapture("Duplicate detected: data matches \(existing.filename)", category: "files")
            return .duplicate(existingFile: existing, hash: hash)
        }

        return .noDuplicate(hash: hash)
    }

    // MARK: - Private Helpers

    /// Resolve the Papers directory for a library.
    ///
    /// With iCloud-only storage, all PDFs are stored in the app container at:
    /// `~/Library/Application Support/imbib/Libraries/{UUID}/Papers/`
    ///
    /// This eliminates sandbox complexity since files in the app container
    /// are always accessible without security-scoped bookmarks.
    private func resolvePapersDirectory(for library: CDLibrary?) throws -> URL {
        let papersURL: URL

        if let library = library {
            // Use the library's container-based Papers directory
            papersURL = library.papersContainerURL
        } else {
            // Fall back to default Papers directory in app support
            guard let appSupport = applicationSupportURL else {
                throw PDFError.noPapersDirectory
            }
            papersURL = appSupport.appendingPathComponent("DefaultLibrary/\(papersFolderName)")
        }

        // Create directory if needed
        if !fileManager.fileExists(atPath: papersURL.path) {
            try fileManager.createDirectory(at: papersURL, withIntermediateDirectories: true)
            Logger.files.infoCapture("Created Papers directory: \(papersURL.path)", category: "files")
        }

        return papersURL
    }

    /// Application support directory.
    private var applicationSupportURL: URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("imbib")
    }

    /// Truncate title to max length without breaking words.
    private func truncateTitle(_ title: String, maxLength: Int) -> String {
        // Remove leading articles
        var cleaned = title
        for article in ["The ", "A ", "An "] {
            if cleaned.hasPrefix(article) {
                cleaned = String(cleaned.dropFirst(article.count))
                break
            }
        }

        // Remove special characters and convert to camelCase-ish
        let words = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.capitalized }

        var result = ""
        for word in words {
            if result.count + word.count > maxLength {
                break
            }
            result += word
        }

        return result.isEmpty ? "Untitled" : result
    }

    /// Sanitize filename by removing invalid characters.
    private func sanitizeFilename(_ name: String) -> String {
        // Invalid characters: / \ : * ? " < > |
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")

        var sanitized = name.components(separatedBy: invalidChars).joined()

        // Replace spaces and other whitespace
        sanitized = sanitized.replacingOccurrences(of: " ", with: "")

        // Normalize unicode
        sanitized = sanitized.precomposedStringWithCanonicalMapping

        // Limit length (filesystem limits)
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }

        return sanitized
    }

    /// Resolve filename collision by adding numeric suffix.
    private func resolveCollision(_ filename: String, in directory: URL) -> String {
        var candidate = filename
        var counter = 1

        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            // Einstein_1905_Electrodynamics.pdf → Einstein_1905_Electrodynamics_2.pdf
            let name = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            candidate = "\(name)_\(counter + 1).\(ext)"
            counter += 1

            // Safety limit
            if counter > 1000 {
                // Fall back to UUID
                candidate = "\(name)_\(UUID().uuidString.prefix(8)).\(ext)"
                break
            }
        }

        if candidate != filename {
            Logger.files.debugCapture("Resolved collision: \(filename) → \(candidate)", category: "files")
        }

        return candidate
    }

    /// Compute SHA256 hash of a file using streaming (memory-efficient for large files).
    ///
    /// Reads file in 64KB chunks to avoid loading entire file into memory.
    /// Safe for files of any size.
    private func computeSHA256(for url: URL) -> String? {
        let bufferSize = 64 * 1024  // 64KB chunks
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                hasher.update(data: Data(buffer[0..<bytesRead]))
            } else if bytesRead < 0 {
                // Read error
                return nil
            }
        }

        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - MIME Type Detection

    /// Detect MIME type for a file URL using UTType.
    private func detectMIMEType(for url: URL) -> String? {
        // Try to get UTType from file extension
        guard let utType = UTType(filenameExtension: url.pathExtension) else {
            return nil
        }
        return utType.preferredMIMEType
    }

    /// Detect MIME type from file data and extension.
    private func detectMIMEType(fromData data: Data, fileExtension: String) -> String? {
        // Check magic bytes for common formats
        if let magic = detectFromMagicBytes(data) {
            return magic
        }

        // Fall back to UTType from extension
        guard let utType = UTType(filenameExtension: fileExtension) else {
            return nil
        }
        return utType.preferredMIMEType
    }

    /// Detect MIME type from file magic bytes (file signature).
    private func detectFromMagicBytes(_ data: Data) -> String? {
        guard data.count >= 8 else { return nil }

        let bytes = Array(data.prefix(8))

        // PDF: %PDF
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "application/pdf"
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }

        // JPEG: FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }

        // GIF: GIF87a or GIF89a
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }

        // ZIP (also includes .docx, .xlsx, .epub, etc.): 50 4B 03 04
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return "application/zip"
        }

        // GZIP: 1F 8B
        if bytes.starts(with: [0x1F, 0x8B]) {
            return "application/gzip"
        }

        // TAR: "ustar" at offset 257 (check if we have enough data)
        if data.count >= 262 {
            let tarMagic = Array(data[257..<262])
            if tarMagic == [0x75, 0x73, 0x74, 0x61, 0x72] { // "ustar"
                return "application/x-tar"
            }
        }

        // BZ2: BZ
        if bytes.starts(with: [0x42, 0x5A]) {
            return "application/x-bzip2"
        }

        // TIFF: II or MM
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }

        return nil
    }
}

// MARK: - Duplicate Check Result

/// Result of checking for duplicate attachments by content hash.
public enum DuplicateCheckResult {
    /// No duplicate found. Returns the computed hash for reuse during import.
    case noDuplicate(hash: String)
    /// Duplicate found. Returns the existing file and computed hash.
    case duplicate(existingFile: CDLinkedFile, hash: String)
}

// MARK: - Attachment Error

/// Errors that can occur during attachment operations.
public enum AttachmentError: LocalizedError {
    case copyFailed(URL, Error)
    case writeFailed(URL, Error)
    case downloadFailed(URL, Error?)
    case emptyDownload(URL)
    case noPapersDirectory
    case fileNotFound(String)
    case unsupportedFileType(String)

    public var errorDescription: String? {
        switch self {
        case .copyFailed(let url, let error):
            return "Failed to copy file from \(url.lastPathComponent): \(error.localizedDescription)"
        case .writeFailed(let url, let error):
            return "Failed to write file to \(url.lastPathComponent): \(error.localizedDescription)"
        case .downloadFailed(let url, let error):
            if let error {
                return "Failed to download file from \(url.host ?? url.absoluteString): \(error.localizedDescription)"
            }
            return "Failed to download file from \(url.host ?? url.absoluteString)"
        case .emptyDownload(let url):
            return "Downloaded empty file from \(url.host ?? url.absoluteString)"
        case .noPapersDirectory:
            return "No Papers directory configured"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unsupportedFileType(let ext):
            return "Unsupported file type: \(ext)"
        }
    }
}

// MARK: - PDF Error (Backward Compatible)

/// Type alias for backward compatibility.
public typealias PDFError = AttachmentError
