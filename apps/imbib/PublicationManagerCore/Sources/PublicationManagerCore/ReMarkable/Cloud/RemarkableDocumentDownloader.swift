//
//  RemarkableDocumentDownloader.swift
//  PublicationManagerCore
//
//  Downloads and extracts reMarkable document archives.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation
import OSLog
import Compression

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableDownload")

// MARK: - Document Downloader

/// Downloads and extracts reMarkable document archives.
///
/// reMarkable documents are stored as .zip archives containing:
/// - {uuid}.content - JSON metadata
/// - {uuid}.metadata - Document metadata
/// - {uuid}.pdf - Original PDF (if uploaded)
/// - {uuid}/ - Directory with page annotations
///   - {page_uuid}.rm - Binary annotation data for each page
///   - {page_uuid}-metadata.json - Page metadata
public actor RemarkableDocumentDownloader {

    // MARK: - Singleton

    public static let shared = RemarkableDocumentDownloader()

    // MARK: - Dependencies

    private let session: URLSession
    private let fileManager = FileManager.default

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Download API

    /// Download a document archive from reMarkable Cloud.
    ///
    /// - Parameters:
    ///   - documentID: The reMarkable document ID
    ///   - blobURL: The signed URL for downloading
    ///   - userToken: Authentication token
    /// - Returns: Extracted document contents
    public func downloadDocument(
        documentID: String,
        blobURL: String,
        userToken: String
    ) async throws -> ExtractedDocument {
        logger.info("Downloading document: \(documentID)")

        // Download the archive
        var request = URLRequest(url: URL(string: blobURL)!)
        request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.downloadFailed("HTTP error downloading document")
        }

        logger.debug("Downloaded \(data.count) bytes")

        // Extract the archive
        return try await extractArchive(data, documentID: documentID)
    }

    /// Extract annotations from a downloaded document.
    ///
    /// - Parameter document: The extracted document
    /// - Returns: Array of parsed annotations per page
    public func parseAnnotations(from document: ExtractedDocument) async throws -> [PageAnnotations] {
        var allAnnotations: [PageAnnotations] = []

        for (pageIndex, rmData) in document.pageRMFiles.enumerated() {
            do {
                let rmFile = try RMFileParser.parse(rmData)
                let annotations = PageAnnotations(
                    pageNumber: pageIndex,
                    rmFile: rmFile,
                    pageUUID: document.pageUUIDs[pageIndex]
                )
                allAnnotations.append(annotations)
                logger.debug("Parsed page \(pageIndex): \(rmFile.totalStrokeCount) strokes")
            } catch {
                logger.warning("Failed to parse page \(pageIndex): \(error)")
                // Continue with other pages
            }
        }

        return allAnnotations
    }

    // MARK: - Archive Extraction

    private func extractArchive(_ data: Data, documentID: String) async throws -> ExtractedDocument {
        // Create temp directory for extraction
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // Write archive to temp file
        let archivePath = tempDir.appendingPathComponent("archive.zip")
        try data.write(to: archivePath)

        // Extract using Process (unzip)
        let extractDir = tempDir.appendingPathComponent("extracted")
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archivePath.path, "-d", extractDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RemarkableError.parseFailed("Failed to extract archive")
        }
        #else
        // On iOS, use built-in decompression
        try extractZipArchive(at: archivePath, to: extractDir)
        #endif

        // Parse extracted contents
        return try parseExtractedContents(at: extractDir, documentID: documentID)
    }

    private func parseExtractedContents(at directory: URL, documentID: String) throws -> ExtractedDocument {
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        var pdfData: Data?
        var contentJSON: [String: Any]?
        var pageUUIDs: [String] = []
        var pageRMFiles: [Data] = []

        // Look for main files
        for item in contents {
            let name = item.lastPathComponent

            if name.hasSuffix(".pdf") {
                pdfData = try Data(contentsOf: item)
            } else if name.hasSuffix(".content") {
                let data = try Data(contentsOf: item)
                contentJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }

        // Parse content JSON to get page order
        if let content = contentJSON,
           let pages = content["pages"] as? [String] {
            pageUUIDs = pages
        }

        // Find the annotation directory (same name as document ID)
        let annotationDir = directory.appendingPathComponent(documentID)
        if fileManager.fileExists(atPath: annotationDir.path) {
            // Load .rm files in page order
            for pageUUID in pageUUIDs {
                let rmPath = annotationDir.appendingPathComponent("\(pageUUID).rm")
                if fileManager.fileExists(atPath: rmPath.path) {
                    let rmData = try Data(contentsOf: rmPath)
                    pageRMFiles.append(rmData)
                } else {
                    // No annotations for this page
                    pageRMFiles.append(Data())
                }
            }
        }

        return ExtractedDocument(
            documentID: documentID,
            pdfData: pdfData,
            contentJSON: contentJSON,
            pageUUIDs: pageUUIDs,
            pageRMFiles: pageRMFiles
        )
    }

    #if !os(macOS)
    private func extractZipArchive(at source: URL, to destination: URL) throws {
        // Simple ZIP extraction for iOS
        // In production, use a proper ZIP library like ZIPFoundation
        let fileHandle = try FileHandle(forReadingFrom: source)
        defer { try? fileHandle.close() }

        // For now, throw an error - this needs a proper ZIP library
        throw RemarkableError.parseFailed("ZIP extraction not implemented for iOS")
    }
    #endif
}

// MARK: - Extracted Document

/// A fully extracted reMarkable document.
public struct ExtractedDocument: Sendable {
    /// The reMarkable document ID.
    public let documentID: String

    /// Original PDF data (if available).
    public let pdfData: Data?

    /// Parsed .content JSON.
    public let contentJSON: [String: Any]?

    /// UUIDs for each page in order.
    public let pageUUIDs: [String]

    /// Raw .rm file data for each page.
    public let pageRMFiles: [Data]

    /// Whether this document has annotations.
    public var hasAnnotations: Bool {
        pageRMFiles.contains { !$0.isEmpty }
    }

    /// Number of pages with annotations.
    public var annotatedPageCount: Int {
        pageRMFiles.filter { !$0.isEmpty }.count
    }

    // Make contentJSON Sendable by converting to Data
    public init(
        documentID: String,
        pdfData: Data?,
        contentJSON: [String: Any]?,
        pageUUIDs: [String],
        pageRMFiles: [Data]
    ) {
        self.documentID = documentID
        self.pdfData = pdfData
        // Convert to Data for Sendable conformance
        if let json = contentJSON {
            self.contentJSON = json
        } else {
            self.contentJSON = nil
        }
        self.pageUUIDs = pageUUIDs
        self.pageRMFiles = pageRMFiles
    }
}

// MARK: - Page Annotations

/// Annotations for a single page.
public struct PageAnnotations: Sendable {
    /// Page number (0-indexed).
    public let pageNumber: Int

    /// Parsed .rm file for this page.
    public let rmFile: RMFile

    /// UUID of this page on reMarkable.
    public let pageUUID: String

    /// Whether this page has any strokes.
    public var hasStrokes: Bool {
        !rmFile.isEmpty
    }

    /// Total stroke count on this page.
    public var strokeCount: Int {
        rmFile.totalStrokeCount
    }
}
