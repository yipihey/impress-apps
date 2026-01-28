//
//  SharedICloudService.swift
//  imprint
//
//  Created by Claude on 2026-01-27.
//

import Foundation
import os.log

// MARK: - Shared iCloud Service

/// Service for syncing compiled PDFs to the shared iCloud container.
///
/// Both imbib and imprint use the shared container `iCloud.com.imbib.shared`
/// to exchange compiled manuscript PDFs:
/// - imprint writes compiled PDFs after each compile
/// - imbib monitors the folder and imports PDFs as attachments
///
/// Folder structure:
/// ```
/// iCloud.com.imbib.shared/
/// └── CompiledManuscripts/
///     └── {documentUUID}.pdf
/// ```
public actor SharedICloudService {

    // MARK: - Singleton

    public static let shared = SharedICloudService()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.imbib.imprint", category: "SharedICloud")

    /// The shared iCloud container identifier
    private let containerIdentifier = "iCloud.com.imbib.shared"

    /// Subdirectory for compiled manuscripts
    private let compiledManuscriptsFolder = "CompiledManuscripts"

    /// Cached container URL
    private var cachedContainerURL: URL?

    // MARK: - Container Access

    /// Gets the URL for the shared iCloud container.
    ///
    /// - Returns: The container URL if available
    public func containerURL() -> URL? {
        if let cached = cachedContainerURL {
            return cached
        }

        guard let url = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            logger.warning("Shared iCloud container not available")
            return nil
        }

        cachedContainerURL = url
        return url
    }

    /// Gets the URL for the compiled manuscripts folder, creating it if needed.
    ///
    /// - Returns: The folder URL if available
    public func compiledManuscriptsURL() throws -> URL? {
        guard let container = containerURL() else {
            return nil
        }

        let folderURL = container.appendingPathComponent(compiledManuscriptsFolder, isDirectory: true)

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.info("Created compiled manuscripts folder: \(folderURL.path)")
        }

        return folderURL
    }

    // MARK: - PDF Operations

    /// Writes a compiled PDF to the shared container.
    ///
    /// - Parameters:
    ///   - pdfData: The PDF data to write
    ///   - documentUUID: The UUID of the imprint document
    /// - Returns: The URL where the PDF was written
    @discardableResult
    public func writeCompiledPDF(
        _ pdfData: Data,
        forDocumentUUID documentUUID: UUID
    ) throws -> URL {
        guard let folderURL = try compiledManuscriptsURL() else {
            throw SharedICloudError.containerNotAvailable
        }

        let pdfURL = folderURL.appendingPathComponent("\(documentUUID.uuidString).pdf")

        try pdfData.write(to: pdfURL, options: .atomic)
        logger.info("Wrote compiled PDF: \(pdfURL.lastPathComponent)")

        // Set metadata for iCloud syncing
        try setICloudMetadata(forPDFAt: pdfURL, documentUUID: documentUUID)

        return pdfURL
    }

    /// Gets the URL for a compiled PDF if it exists.
    ///
    /// - Parameter documentUUID: The UUID of the imprint document
    /// - Returns: The PDF URL if it exists
    public func compiledPDFURL(forDocumentUUID documentUUID: UUID) throws -> URL? {
        guard let folderURL = try compiledManuscriptsURL() else {
            return nil
        }

        let pdfURL = folderURL.appendingPathComponent("\(documentUUID.uuidString).pdf")

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            return nil
        }

        return pdfURL
    }

    /// Deletes a compiled PDF from the shared container.
    ///
    /// - Parameter documentUUID: The UUID of the imprint document
    public func deleteCompiledPDF(forDocumentUUID documentUUID: UUID) throws {
        guard let url = try compiledPDFURL(forDocumentUUID: documentUUID) else {
            return
        }

        try FileManager.default.removeItem(at: url)
        logger.info("Deleted compiled PDF: \(url.lastPathComponent)")
    }

    /// Lists all compiled PDF UUIDs in the shared container.
    ///
    /// - Returns: Array of document UUIDs with compiled PDFs
    public func listCompiledPDFs() throws -> [UUID] {
        guard let folderURL = try compiledManuscriptsURL() else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { url -> UUID? in
            guard url.pathExtension == "pdf" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            return UUID(uuidString: name)
        }
    }

    // MARK: - Metadata

    /// Sets extended attributes on the PDF for imbib to identify it.
    private func setICloudMetadata(forPDFAt url: URL, documentUUID: UUID) throws {
        // Store document UUID as extended attribute
        let uuidData = documentUUID.uuidString.data(using: .utf8)!

        try url.withUnsafeFileSystemRepresentation { path in
            guard let path = path else { return }
            let result = setxattr(
                path,
                "com.imbib.imprint.documentUUID",
                (uuidData as NSData).bytes,
                uuidData.count,
                0,
                0
            )
            if result != 0 {
                logger.warning("Failed to set xattr on \(url.lastPathComponent): \(errno)")
            }
        }
    }

    /// Reads the document UUID from a PDF's extended attributes.
    ///
    /// - Parameter url: The URL of the PDF
    /// - Returns: The document UUID if available
    public func readDocumentUUID(fromPDFAt url: URL) -> UUID? {
        var size = getxattr(url.path, "com.imbib.imprint.documentUUID", nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var data = Data(count: size)
        size = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, "com.imbib.imprint.documentUUID", buffer.baseAddress, size, 0, 0)
        }

        guard size > 0,
              let uuidString = String(data: data, encoding: .utf8) else {
            return nil
        }

        return UUID(uuidString: uuidString)
    }
}

// MARK: - Errors

public enum SharedICloudError: LocalizedError {
    case containerNotAvailable
    case writeFailure(Error)
    case pdfNotFound

    public var errorDescription: String? {
        switch self {
        case .containerNotAvailable:
            return "The shared iCloud container is not available. Please sign in to iCloud."
        case .writeFailure(let error):
            return "Failed to write PDF: \(error.localizedDescription)"
        case .pdfNotFound:
            return "The compiled PDF was not found"
        }
    }
}

// MARK: - Document Integration

public extension SharedICloudService {

    /// Writes the compiled PDF for an ImprintDocument to the shared container.
    ///
    /// - Parameters:
    ///   - pdfData: The compiled PDF data
    ///   - document: The imprint document
    /// - Returns: The URL where the PDF was written
    @discardableResult
    func writeCompiledPDF(
        _ pdfData: Data,
        for documentID: UUID
    ) throws -> URL {
        try writeCompiledPDF(pdfData, forDocumentUUID: documentID)
    }
}
