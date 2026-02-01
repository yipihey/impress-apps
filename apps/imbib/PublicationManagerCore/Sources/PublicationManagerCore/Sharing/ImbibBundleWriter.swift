//
//  ImbibBundleWriter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import OSLog

// MARK: - Bundle Writer

/// Writes and reads imbib bundle files for sharing publications.
///
/// Bundle format:
/// ```
/// Papers.imbib/
/// ├── manifest.json      # Metadata, version
/// ├── publications.json  # Array of ShareablePublication
/// ├── bibliography.bib   # Combined BibTeX
/// └── files/
///     └── {citeKey}.pdf  # Embedded PDFs
/// ```
public actor ImbibBundleWriter {

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Writing

    /// Write publications to an imbib bundle.
    ///
    /// - Parameters:
    ///   - publications: The publications to include
    ///   - libraryName: Optional library name for the bundle
    ///   - destination: Where to write the bundle (directory)
    ///   - includePDFs: Whether to include PDF data
    /// - Returns: URL to the created bundle
    public func writeBundle(
        publications: ShareablePublications,
        to destination: URL
    ) async throws -> URL {
        let bundleName = publications.libraryName?
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            ?? "Papers"
        let bundleURL = destination.appendingPathComponent("\(bundleName).imbib")

        // Remove existing bundle if present
        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }

        // Create bundle directory structure
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let filesDir = bundleURL.appendingPathComponent("files")
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true)

        // Write manifest
        let manifest = BundleManifest(
            version: BundleManifest.currentVersion,
            exportDate: publications.exportDate,
            libraryName: publications.libraryName,
            publicationCount: publications.count,
            hasPDFFiles: publications.hasPDFData,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))

        // Write publications (without embedded PDF data)
        let publicationsWithoutPDF = publications.publications.map { pub in
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
                pdfData: nil,
                pdfFilename: pub.pdfFilename
            )
        }

        let pubsData = try encoder.encode(publicationsWithoutPDF)
        try pubsData.write(to: bundleURL.appendingPathComponent("publications.json"))

        // Write combined BibTeX
        let bibtex = publications.combinedBibTeX
        if let bibtexData = bibtex.data(using: .utf8) {
            try bibtexData.write(to: bundleURL.appendingPathComponent("bibliography.bib"))
        }

        // Write PDF files
        for pub in publications.publications {
            if let pdfData = pub.pdfData {
                let pdfFilename = pub.suggestedPDFFilename
                let pdfURL = filesDir.appendingPathComponent(pdfFilename)
                try pdfData.write(to: pdfURL)
            }
        }

        Logger.sharing.info("Created imbib bundle at \(bundleURL.path) with \(publications.count) publications")

        return bundleURL
    }

    // MARK: - Reading

    /// Read an imbib bundle from disk.
    ///
    /// - Parameter url: URL to the bundle
    /// - Returns: Parsed ShareablePublications with PDF data loaded
    public func readBundle(from url: URL) async throws -> ShareablePublications {
        guard fileManager.fileExists(atPath: url.path) else {
            throw BundleError.bundleNotFound
        }

        // Read manifest
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw BundleError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BundleManifest.self, from: manifestData)

        // Read publications
        let pubsURL = url.appendingPathComponent("publications.json")
        guard fileManager.fileExists(atPath: pubsURL.path) else {
            throw BundleError.missingPublications
        }

        let pubsData = try Data(contentsOf: pubsURL)
        var publications = try decoder.decode([ShareablePublication].self, from: pubsData)

        // Load PDF data if available
        let filesDir = url.appendingPathComponent("files")
        if fileManager.fileExists(atPath: filesDir.path) {
            publications = publications.map { pub in
                var mutablePub = pub
                let pdfFilename = pub.suggestedPDFFilename
                let pdfURL = filesDir.appendingPathComponent(pdfFilename)

                if fileManager.fileExists(atPath: pdfURL.path),
                   let pdfData = try? Data(contentsOf: pdfURL) {
                    mutablePub = ShareablePublication(
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
                        pdfData: pdfData,
                        pdfFilename: pub.pdfFilename
                    )
                }

                return mutablePub
            }
        }

        Logger.sharing.info("Read imbib bundle from \(url.path) with \(publications.count) publications")

        return ShareablePublications(
            publications: publications,
            libraryName: manifest.libraryName,
            exportDate: manifest.exportDate,
            version: manifest.version
        )
    }

    /// Check if a URL is a valid imbib bundle.
    public func isValidBundle(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "imbib" else {
            return false
        }

        let manifestURL = url.appendingPathComponent("manifest.json")
        let pubsURL = url.appendingPathComponent("publications.json")

        return fileManager.fileExists(atPath: manifestURL.path) &&
               fileManager.fileExists(atPath: pubsURL.path)
    }

    /// Get bundle info without fully loading it.
    public func getBundleInfo(from url: URL) async throws -> BundleManifest {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw BundleError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BundleManifest.self, from: manifestData)
    }
}

// MARK: - Bundle Manifest

/// Manifest for imbib bundle format.
public struct BundleManifest: Codable, Sendable {
    /// Format version
    public let version: String

    /// When the bundle was created
    public let exportDate: Date

    /// Source library name
    public let libraryName: String?

    /// Number of publications
    public let publicationCount: Int

    /// Whether the bundle contains PDF files
    public let hasPDFFiles: Bool

    /// App version that created the bundle
    public let appVersion: String?

    /// Current format version
    public static let currentVersion = "1.0"

    public init(
        version: String = currentVersion,
        exportDate: Date = Date(),
        libraryName: String? = nil,
        publicationCount: Int = 0,
        hasPDFFiles: Bool = false,
        appVersion: String? = nil
    ) {
        self.version = version
        self.exportDate = exportDate
        self.libraryName = libraryName
        self.publicationCount = publicationCount
        self.hasPDFFiles = hasPDFFiles
        self.appVersion = appVersion
    }
}

// MARK: - Bundle Errors

public enum BundleError: LocalizedError {
    case bundleNotFound
    case missingManifest
    case missingPublications
    case invalidFormat(String)
    case writeFailed(Error)
    case readFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .bundleNotFound:
            return "Bundle not found"
        case .missingManifest:
            return "Bundle is missing manifest.json"
        case .missingPublications:
            return "Bundle is missing publications.json"
        case .invalidFormat(let detail):
            return "Invalid bundle format: \(detail)"
        case .writeFailed(let error):
            return "Failed to write bundle: \(error.localizedDescription)"
        case .readFailed(let error):
            return "Failed to read bundle: \(error.localizedDescription)"
        }
    }
}

// MARK: - Logger

extension Logger {
    static let sharing = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "Sharing")
}
