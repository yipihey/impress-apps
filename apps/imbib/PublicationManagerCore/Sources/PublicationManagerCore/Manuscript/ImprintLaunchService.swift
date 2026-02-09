//
//  ImprintLaunchService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-27.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ImprintLaunchService

/// Service for launching imprint from imbib.
///
/// On macOS, opens the .imprint document directly in imprint.
/// On iOS/iPadOS, uses URL scheme to open imprint.
public actor ImprintLaunchService {

    public static let shared = ImprintLaunchService()

    // MARK: - Constants

    /// Bundle identifier for imprint macOS app
    private let imprintBundleID = "com.imbib.imprint"

    /// URL scheme for imprint
    private let imprintScheme = "imprint"

    // MARK: - Launch Methods

    /// Opens a manuscript's linked imprint document.
    ///
    /// - Parameter publication: The manuscript with a linked imprint document
    /// - Returns: True if the document was opened, false otherwise
    @discardableResult
    public func openLinkedDocument(for publication: PublicationModel) async -> Bool {
        // First try to resolve the document URL from the stored path
        if let pathStr = publication.fields[ManuscriptMetadataKey.imprintDocumentPath.rawValue],
           !pathStr.isEmpty {
            let url = URL(fileURLWithPath: pathStr)
            if FileManager.default.fileExists(atPath: url.path) {
                return await openDocument(at: url)
            }
        }

        // Fall back to URL scheme if we have the document UUID
        if let docUUID = publication.fields[ManuscriptMetadataKey.imprintDocumentUUID.rawValue],
           !docUUID.isEmpty,
           let url = URL(string: "imprint://open/document/\(docUUID)") {
            return await openURL(url)
        }

        return false
    }

    /// Opens an imprint document at the specified file URL.
    ///
    /// On macOS, opens the document directly in imprint.
    /// On iOS, this is not supported (use URL scheme instead).
    ///
    /// - Parameter url: The file URL to the .imprint document
    /// - Returns: True if successful
    @discardableResult
    public func openDocument(at url: URL) async -> Bool {
        #if os(macOS)
        return await MainActor.run {
            // Start accessing security-scoped resource if needed
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            // Try to open with imprint specifically
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            // First check if imprint is installed
            if let imprintURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: imprintBundleID) {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: imprintURL,
                    configuration: configuration
                )
                return true
            }

            // Fall back to default handler for .imprint files
            return NSWorkspace.shared.open(url)
        }
        #else
        // iOS doesn't support direct file opening across apps
        // Use URL scheme instead
        return false
        #endif
    }

    /// Opens imprint via URL scheme.
    ///
    /// - Parameter url: The imprint:// URL to open
    /// - Returns: True if the URL was opened
    @discardableResult
    public func openURL(_ url: URL) async -> Bool {
        #if os(macOS)
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #else
        return await MainActor.run {
            guard UIApplication.shared.canOpenURL(url) else {
                return false
            }

            UIApplication.shared.open(url, options: [:]) { _ in }
            return true
        }
        #endif
    }

    // MARK: - imprint Availability

    /// Checks if imprint is installed on the device.
    public func isImprintInstalled() async -> Bool {
        #if os(macOS)
        return await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: imprintBundleID) != nil
        }
        #else
        return await MainActor.run {
            let testURL = URL(string: "imprint://")!
            return UIApplication.shared.canOpenURL(testURL)
        }
        #endif
    }

    // MARK: - Link Document

    /// Opens a file picker to select an imprint document to link.
    ///
    /// - Returns: The selected URL, or nil if cancelled
    @MainActor
    public func pickImprintDocument() async -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Select imprint Document"
        panel.allowedContentTypes = [.init(filenameExtension: "imprint")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let response = await panel.beginSheetModal(for: NSApp.keyWindow!)
        guard response == .OK, let url = panel.url else {
            return nil
        }

        return url
        #else
        // On iOS, document picking would be handled by UIDocumentPickerViewController
        // which needs to be coordinated with SwiftUI
        return nil
        #endif
    }

    /// Reads the document UUID from an imprint document's metadata.
    ///
    /// - Parameter url: The file URL to the .imprint document
    /// - Returns: The document UUID if readable
    public func readDocumentUUID(from url: URL) throws -> UUID {
        // Start accessing security-scoped resource if needed
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Read metadata.json from the package
        let metadataURL = url.appendingPathComponent("metadata.json")

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ImprintLaunchError.metadataNotFound
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()

        // Simple struct to decode just the id
        struct MetadataID: Decodable {
            let id: UUID
        }

        let metadata = try decoder.decode(MetadataID.self, from: data)
        return metadata.id
    }

    /// Creates a new imprint document for a manuscript.
    ///
    /// - Parameters:
    ///   - publication: The manuscript to create a document for
    ///   - destinationURL: Where to create the document
    /// - Returns: The UUID of the created document
    public func createDocument(
        for publication: PublicationModel,
        at destinationURL: URL
    ) throws -> UUID {
        let documentID = UUID()

        // Create package directory
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let title = publication.title
        let citeKey = publication.citeKey

        // Create main.typ with title
        let source = """
        // imprint document
        // \(title)

        = \(title)

        This document was created from imbib for manuscript "\(citeKey)".

        Start writing here, or use Cmd+Shift+K to insert citations.
        """
        try source.write(to: destinationURL.appendingPathComponent("main.typ"), atomically: true, encoding: .utf8)

        // Create metadata.json
        let metadata: [String: Any] = [
            "id": documentID.uuidString,
            "title": title,
            "authors": publication.authors.map(\.displayName),
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "modifiedAt": ISO8601DateFormatter().string(from: Date()),
            "linkedImbibManuscriptID": publication.id.uuidString
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try metadataData.write(to: destinationURL.appendingPathComponent("metadata.json"))

        // Create empty bibliography.bib
        try "".write(to: destinationURL.appendingPathComponent("bibliography.bib"), atomically: true, encoding: .utf8)

        return documentID
    }
}

// MARK: - Errors

public enum ImprintLaunchError: LocalizedError {
    case imprintNotInstalled
    case documentNotFound
    case metadataNotFound
    case invalidMetadata

    public var errorDescription: String? {
        switch self {
        case .imprintNotInstalled:
            return "imprint is not installed"
        case .documentNotFound:
            return "The linked imprint document could not be found"
        case .metadataNotFound:
            return "The imprint document metadata could not be read"
        case .invalidMetadata:
            return "The imprint document metadata is invalid"
        }
    }
}
