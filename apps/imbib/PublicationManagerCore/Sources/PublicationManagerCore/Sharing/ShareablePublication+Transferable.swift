//
//  ShareablePublication+Transferable.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import UniformTypeIdentifiers
import CoreTransferable

// MARK: - ShareablePublication Transferable

extension ShareablePublication: Transferable {

    /// Transfer representations for sharing a single publication.
    ///
    /// Priority order:
    /// 1. BibTeX file (.bib) - Universal academic format, AirDrop shows filename
    /// 2. Plain text citation - For Messages, Notes, etc.
    /// 3. URL - DOI or arXiv link for pasting
    public static var transferRepresentation: some TransferRepresentation {
        // 1. BibTeX file for AirDrop, Mail attachments, etc.
        FileRepresentation(exportedContentType: .bibtex) { publication in
            let tempURL = try await publication.writeTempBibFile()
            return SentTransferredFile(tempURL)
        }

        // 2. Plain text citation for Messages, Notes, clipboard
        DataRepresentation(exportedContentType: .plainText) { publication in
            guard let data = publication.formattedCitation.data(using: .utf8) else {
                throw TransferError.encodingFailed
            }
            return data
        }

        // 3. URL representation for link pasting (only if URL exists)
        DataRepresentation(exportedContentType: .url) { publication in
            guard let url = publication.primaryURL,
                  let data = url.absoluteString.data(using: .utf8) else {
                throw TransferError.encodingFailed
            }
            return data
        }
    }
}

// MARK: - ShareablePublications Transferable

extension ShareablePublications: Transferable {

    /// Transfer representations for sharing multiple publications.
    ///
    /// Priority order:
    /// 1. imbib bundle (.imbib) - Rich format with all data and PDFs
    /// 2. Combined BibTeX file (.bib) - Universal format for all publications
    /// 3. Plain text citations - For Messages, Notes, etc.
    public static var transferRepresentation: some TransferRepresentation {
        // 1. Rich imbib bundle for imbib-to-imbib sharing
        FileRepresentation(exportedContentType: .imbibBundle) { container in
            let bundleURL = try await container.writeBundle()
            return SentTransferredFile(bundleURL)
        }

        // 2. Combined BibTeX file
        FileRepresentation(exportedContentType: .bibtex) { container in
            let tempURL = try await container.writeCombinedBibFile()
            return SentTransferredFile(tempURL)
        }

        // 3. Plain text citations
        DataRepresentation(exportedContentType: .plainText) { container in
            let citations = container.publications
                .map { $0.formattedCitation }
                .joined(separator: "\n\n")
            guard let data = citations.data(using: .utf8) else {
                throw TransferError.encodingFailed
            }
            return data
        }
    }
}

// MARK: - Transfer Errors

enum TransferError: LocalizedError {
    case encodingFailed
    case fileWriteFailed(Error)
    case bundleCreationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode data for transfer"
        case .fileWriteFailed(let error):
            return "Failed to write file: \(error.localizedDescription)"
        case .bundleCreationFailed(let error):
            return "Failed to create bundle: \(error.localizedDescription)"
        }
    }
}

// MARK: - File Writing Helpers

extension ShareablePublication {

    /// Write BibTeX to a temporary file for sharing.
    func writeTempBibFile() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = suggestedBibFilename
        let fileURL = tempDir.appendingPathComponent(filename)

        let bibtexString = bibtex
        guard let data = bibtexString.data(using: .utf8) else {
            throw TransferError.encodingFailed
        }

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            throw TransferError.fileWriteFailed(error)
        }
    }
}

extension ShareablePublications {

    /// Write combined BibTeX to a temporary file for sharing.
    func writeCombinedBibFile() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = suggestedBibFilename
        let fileURL = tempDir.appendingPathComponent(filename)

        let bibtexString = combinedBibTeX
        guard let data = bibtexString.data(using: .utf8) else {
            throw TransferError.encodingFailed
        }

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            throw TransferError.fileWriteFailed(error)
        }
    }

    /// Write an imbib bundle for sharing.
    ///
    /// Bundle structure:
    /// ```
    /// Papers.imbib/
    /// ├── manifest.json      # Metadata and version
    /// ├── publications.json  # Array of ShareablePublication
    /// ├── bibliography.bib   # Combined BibTeX
    /// └── files/
    ///     └── {citeKey}.pdf  # Embedded PDFs
    /// ```
    func writeBundle() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let bundleName = libraryName?.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } ?? "Papers"
        let bundleURL = tempDir.appendingPathComponent("\(bundleName).imbib")

        let fileManager = FileManager.default

        // Remove existing bundle if present
        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }

        // Create bundle directory
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Create files directory
        let filesDir = bundleURL.appendingPathComponent("files")
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true)

        // Write manifest.json
        let manifest = ImbibBundleManifest(
            version: version,
            exportDate: exportDate,
            libraryName: libraryName,
            publicationCount: publications.count,
            hasPDFFiles: hasPDFData
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))

        // Write publications.json (without PDF data to keep it small)
        let pubsWithoutPDF = publications.map { pub in
            ShareablePublication(
                id: pub.id,
                citeKey: pub.citeKey,
                title: pub.title,
                authors: pub.authors,
                year: pub.year,
                venue: pub.venue,
                abstract: pub.abstract,
                entryType: pub.entryType,
                doi: pub.doi,
                arxivID: pub.arxivID,
                bibcode: pub.bibcode,
                pmid: pub.pmid,
                rawBibTeX: pub.rawBibTeX,
                fields: pub.fields,
                pdfData: nil,  // Exclude from JSON
                pdfFilename: pub.pdfFilename
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let pubsData = try encoder.encode(pubsWithoutPDF)
        try pubsData.write(to: bundleURL.appendingPathComponent("publications.json"))

        // Write bibliography.bib
        let bibtex = combinedBibTeX
        if let bibtexData = bibtex.data(using: .utf8) {
            try bibtexData.write(to: bundleURL.appendingPathComponent("bibliography.bib"))
        }

        // Write PDF files
        for pub in publications {
            if let pdfData = pub.pdfData {
                let pdfFilename = pub.suggestedPDFFilename
                let pdfURL = filesDir.appendingPathComponent(pdfFilename)
                try pdfData.write(to: pdfURL)
            }
        }

        return bundleURL
    }
}

// MARK: - Bundle Manifest

/// Manifest file for imbib bundle format.
struct ImbibBundleManifest: Codable {
    let version: String
    let exportDate: Date
    let libraryName: String?
    let publicationCount: Int
    let hasPDFFiles: Bool

    /// Bundle format version
    static let currentVersion = "1.0"
}
