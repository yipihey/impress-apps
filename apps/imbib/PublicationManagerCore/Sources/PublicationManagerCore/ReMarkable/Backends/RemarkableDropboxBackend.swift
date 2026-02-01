//
//  RemarkableDropboxBackend.swift
//  PublicationManagerCore
//
//  Dropbox backend for reMarkable sync via Dropbox integration.
//  ADR-019: reMarkable Tablet Integration
//
//  This backend supports reMarkable users who have configured their tablet
//  to sync to Dropbox. It reads/writes documents from the Dropbox folder
//  that reMarkable syncs to.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableDropbox")

// MARK: - Dropbox Backend

/// Backend for syncing with reMarkable via Dropbox.
///
/// Prerequisites:
/// - reMarkable tablet configured to sync to Dropbox
/// - Dropbox folder accessible on the local file system (via Dropbox app)
/// - User has granted access to the Dropbox/reMarkable folder
///
/// The folder structure mirrors the reMarkable's xochitl layout:
/// ```
/// ~/Dropbox/Apps/reMarkable/ (or custom location)
///   {uuid}/ - Document folder
///     {uuid}.metadata - Document metadata JSON
///     {uuid}.content - Content JSON (page list)
///     {uuid}.pdf - Original PDF
///     {page_uuid}.rm - Annotation files
/// ```
public actor RemarkableDropboxBackend: RemarkableSyncBackend {

    // MARK: - Properties

    public let backendID = "dropbox"
    public let displayName = "Dropbox"

    private let fileManager = FileManager.default
    private var dropboxFolder: URL?
    private var metadata: [String: DropboxDocumentMetadata] = [:]
    private var isConnected = false

    // Default Dropbox reMarkable folder path (user can customize)
    private static let defaultDropboxPath = "~/Dropbox/Apps/reMarkable"

    // MARK: - Initialization

    public init() {}

    // MARK: - Configuration

    /// Set the Dropbox folder path where reMarkable syncs to.
    public func setDropboxFolder(_ url: URL) async {
        dropboxFolder = url
        await scanFolder()
    }

    /// Get the currently configured Dropbox folder.
    public func getDropboxFolder() -> URL? {
        dropboxFolder
    }

    /// Attempt to find the default Dropbox reMarkable folder.
    public static func findDefaultFolder() -> URL? {
        let expandedPath = NSString(string: defaultDropboxPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        // Try alternative locations
        let alternatives = [
            "~/Library/CloudStorage/Dropbox/Apps/reMarkable",
            "~/Dropbox/reMarkable"
        ]

        for alt in alternatives {
            let altPath = NSString(string: alt).expandingTildeInPath
            let altURL = URL(fileURLWithPath: altPath)
            if FileManager.default.fileExists(atPath: altURL.path) {
                return altURL
            }
        }

        return nil
    }

    // MARK: - RemarkableSyncBackend

    public func isAvailable() async -> Bool {
        guard let folder = dropboxFolder else {
            // Try to find default folder
            if let defaultFolder = Self.findDefaultFolder() {
                dropboxFolder = defaultFolder
                return true
            }
            return false
        }
        return fileManager.fileExists(atPath: folder.path)
    }

    public func authenticate() async throws {
        // Dropbox backend uses folder access, not API authentication
        // Verify the folder exists and is accessible

        if dropboxFolder == nil {
            if let defaultFolder = Self.findDefaultFolder() {
                dropboxFolder = defaultFolder
            } else {
                throw RemarkableError.notConfigured("Dropbox reMarkable folder not found. Please configure the folder path in settings.")
            }
        }

        guard let folder = dropboxFolder else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        guard fileManager.fileExists(atPath: folder.path) else {
            throw RemarkableError.localFolderNotFound(folder.path)
        }

        // Verify we can read the folder
        guard fileManager.isReadableFile(atPath: folder.path) else {
            throw RemarkableError.localFolderNotAccessible
        }

        isConnected = true
        await scanFolder()

        logger.info("Connected to Dropbox reMarkable folder: \(folder.path)")
    }

    public func disconnect() async {
        isConnected = false
        dropboxFolder = nil
        metadata = [:]
        logger.info("Disconnected from Dropbox")
    }

    public func listDocuments() async throws -> [RemarkableDocumentInfo] {
        guard dropboxFolder != nil else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        await scanFolder()

        return metadata.values.compactMap { meta -> RemarkableDocumentInfo? in
            guard meta.type == "DocumentType" else { return nil }

            return RemarkableDocumentInfo(
                id: meta.uuid,
                name: meta.visibleName,
                parentFolderID: meta.parent,
                lastModified: meta.lastModified,
                version: meta.version,
                pageCount: meta.pageCount,
                hasAnnotations: meta.hasAnnotations
            )
        }
    }

    public func listFolders() async throws -> [RemarkableFolderInfo] {
        guard dropboxFolder != nil else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        await scanFolder()

        return metadata.values.compactMap { meta -> RemarkableFolderInfo? in
            guard meta.type == "CollectionType" else { return nil }

            let documentCount = metadata.values.filter { $0.parent == meta.uuid }.count

            return RemarkableFolderInfo(
                id: meta.uuid,
                name: meta.visibleName,
                parentFolderID: meta.parent,
                documentCount: documentCount
            )
        }
    }

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        guard let folder = dropboxFolder else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        // Generate UUID for new document
        let uuid = UUID().uuidString.lowercased()
        let documentFolder = folder.appendingPathComponent(uuid)

        // Create document folder
        try fileManager.createDirectory(at: documentFolder, withIntermediateDirectories: true)

        // Write PDF
        let pdfPath = documentFolder.appendingPathComponent("\(uuid).pdf")
        try data.write(to: pdfPath)

        // Create metadata
        let now = Date()
        let metadataContent: [String: Any] = [
            "deleted": false,
            "lastModified": ISO8601DateFormatter().string(from: now),
            "lastOpened": "",
            "lastOpenedPage": 0,
            "metadatamodified": false,
            "modified": true,
            "parent": parentFolder ?? "",
            "pinned": false,
            "synced": false,
            "type": "DocumentType",
            "version": 1,
            "visibleName": (filename as NSString).deletingPathExtension
        ]

        let metadataPath = folder.appendingPathComponent("\(uuid).metadata")
        let metadataData = try JSONSerialization.data(withJSONObject: metadataContent, options: .prettyPrinted)
        try metadataData.write(to: metadataPath)

        // Create content file (for page structure)
        let contentData: [String: Any] = [
            "fileType": "pdf",
            "pageCount": 0,
            "pages": [] as [String]
        ]

        let contentPath = documentFolder.appendingPathComponent("\(uuid).content")
        let contentDataJSON = try JSONSerialization.data(withJSONObject: contentData, options: .prettyPrinted)
        try contentDataJSON.write(to: contentPath)

        logger.info("Uploaded document to Dropbox folder: \(uuid)")

        // Refresh metadata
        await scanFolder()

        return uuid
    }

    public func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation] {
        guard let folder = dropboxFolder else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        let documentFolder = folder.appendingPathComponent(documentID)

        guard fileManager.fileExists(atPath: documentFolder.path) else {
            throw RemarkableError.documentNotFound(documentID)
        }

        // Read content file to get page list
        let contentPath = documentFolder.appendingPathComponent("\(documentID).content")
        guard let contentData = fileManager.contents(atPath: contentPath.path),
              let content = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let pages = content["pages"] as? [String] else {
            return []
        }

        var annotations: [RemarkableRawAnnotation] = []

        // Parse each page's .rm file
        for (pageIndex, pageUUID) in pages.enumerated() {
            let rmPath = documentFolder.appendingPathComponent("\(pageUUID).rm")

            guard let rmData = fileManager.contents(atPath: rmPath.path),
                  !rmData.isEmpty else {
                continue
            }

            do {
                let rmFile = try RMFileParser.parse(rmData)

                // Convert strokes to annotations
                for layer in rmFile.layers {
                    for stroke in layer.strokes {
                        if stroke.isEraser { continue }

                        let type: RemarkableRawAnnotation.AnnotationType = stroke.isHighlight ? .highlight : .ink

                        annotations.append(RemarkableRawAnnotation(
                            id: UUID().uuidString,
                            pageNumber: pageIndex,
                            type: type,
                            strokeData: rmData,
                            bounds: stroke.bounds,
                            color: stroke.color.hexColor
                        ))
                    }
                }
            } catch {
                logger.warning("Failed to parse .rm file for page \(pageIndex): \(error)")
            }
        }

        return annotations
    }

    public func downloadDocument(documentID: String) async throws -> RemarkableDocumentBundle {
        guard let folder = dropboxFolder else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        let documentFolder = folder.appendingPathComponent(documentID)

        guard fileManager.fileExists(atPath: documentFolder.path) else {
            throw RemarkableError.documentNotFound(documentID)
        }

        // Read PDF data
        let pdfPath = documentFolder.appendingPathComponent("\(documentID).pdf")
        guard let pdfData = fileManager.contents(atPath: pdfPath.path) else {
            throw RemarkableError.noPDFAvailable
        }

        // Read metadata
        let metadataPath = folder.appendingPathComponent("\(documentID).metadata")
        var metadataDict: [String: String] = [:]
        if let metaData = fileManager.contents(atPath: metadataPath.path),
           let json = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            for (key, value) in json {
                metadataDict[key] = String(describing: value)
            }
        }

        // Ensure we have scanned and have metadata
        if metadata[documentID] == nil {
            await scanFolder()
        }

        guard let docMeta = metadata[documentID] else {
            throw RemarkableError.documentNotFound(documentID)
        }

        let docInfo = RemarkableDocumentInfo(
            id: documentID,
            name: docMeta.visibleName,
            parentFolderID: docMeta.parent,
            lastModified: docMeta.lastModified,
            version: docMeta.version,
            pageCount: docMeta.pageCount,
            hasAnnotations: docMeta.hasAnnotations
        )

        // Get annotations
        let annotations = try await downloadAnnotations(documentID: documentID)

        return RemarkableDocumentBundle(
            documentInfo: docInfo,
            pdfData: pdfData,
            annotations: annotations,
            metadata: metadataDict
        )
    }

    public func createFolder(name: String, parent: String?) async throws -> String {
        guard let folder = dropboxFolder else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        let uuid = UUID().uuidString.lowercased()
        let folderPath = folder.appendingPathComponent(uuid)

        // Create folder directory
        try fileManager.createDirectory(at: folderPath, withIntermediateDirectories: true)

        // Create metadata
        let metadataContent: [String: Any] = [
            "deleted": false,
            "lastModified": ISO8601DateFormatter().string(from: Date()),
            "parent": parent ?? "",
            "pinned": false,
            "synced": false,
            "type": "CollectionType",
            "version": 1,
            "visibleName": name
        ]

        let metadataPath = folder.appendingPathComponent("\(uuid).metadata")
        let metadataData = try JSONSerialization.data(withJSONObject: metadataContent, options: .prettyPrinted)
        try metadataData.write(to: metadataPath)

        logger.info("Created folder in Dropbox: \(uuid)")

        await scanFolder()

        return uuid
    }

    public func deleteDocument(documentID: String) async throws {
        guard let folder = dropboxFolder else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        let documentFolder = folder.appendingPathComponent(documentID)
        let metadataPath = folder.appendingPathComponent("\(documentID).metadata")

        // Remove document folder and metadata
        if fileManager.fileExists(atPath: documentFolder.path) {
            try fileManager.removeItem(at: documentFolder)
        }
        if fileManager.fileExists(atPath: metadataPath.path) {
            try fileManager.removeItem(at: metadataPath)
        }

        metadata.removeValue(forKey: documentID)

        logger.info("Deleted document from Dropbox: \(documentID)")
    }

    public func getDeviceInfo() async throws -> RemarkableDeviceInfo {
        guard let folder = dropboxFolder else {
            throw RemarkableError.notConfigured("No Dropbox folder configured")
        }

        // Use folder name as identifier
        let folderName = folder.lastPathComponent

        // Try to get storage info from the filesystem
        var storageUsed: Int64?
        var storageTotal: Int64?

        // Calculate folder size
        if let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil) {
            var totalSize: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
            storageUsed = totalSize
        }

        // Get filesystem total (approximate, as Dropbox may have quota limits)
        if let attributes = try? fileManager.attributesOfFileSystem(forPath: folder.path) {
            storageTotal = attributes[.systemSize] as? Int64
        }

        return RemarkableDeviceInfo(
            deviceID: "dropbox-\(folderName)",
            deviceName: "Dropbox (\(folderName))",
            storageUsed: storageUsed,
            storageTotal: storageTotal
        )
    }

    // MARK: - Private Methods

    private func scanFolder() async {
        guard let folder = dropboxFolder else { return }

        metadata = [:]

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
            )

            // Find all .metadata files
            for item in contents {
                guard item.pathExtension == "metadata" else { continue }

                let uuid = item.deletingPathExtension().lastPathComponent

                if let meta = parseMetadata(at: item, uuid: uuid) {
                    metadata[uuid] = meta
                }
            }

            logger.debug("Scanned Dropbox folder: found \(self.metadata.count) items")

        } catch {
            logger.error("Failed to scan Dropbox folder: \(error)")
        }
    }

    private func parseMetadata(at url: URL, uuid: String) -> DropboxDocumentMetadata? {
        guard let data = fileManager.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = json["type"] as? String ?? "DocumentType"
        let visibleName = json["visibleName"] as? String ?? "Untitled"
        let parent = json["parent"] as? String
        let version = json["version"] as? Int ?? 1

        var lastModified = Date()
        if let modString = json["lastModified"] as? String {
            lastModified = ISO8601DateFormatter().date(from: modString) ?? Date()
        }

        // Check for annotations
        var pageCount = 0
        var hasAnnotations = false

        if let folder = dropboxFolder {
            let contentPath = folder.appendingPathComponent(uuid).appendingPathComponent("\(uuid).content")
            if let contentData = fileManager.contents(atPath: contentPath.path),
               let content = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
                if let pages = content["pages"] as? [String] {
                    pageCount = pages.count

                    // Check if any page has .rm files
                    let docFolder = folder.appendingPathComponent(uuid)
                    for pageUUID in pages {
                        let rmPath = docFolder.appendingPathComponent("\(pageUUID).rm")
                        if fileManager.fileExists(atPath: rmPath.path) {
                            hasAnnotations = true
                            break
                        }
                    }
                }
            }
        }

        return DropboxDocumentMetadata(
            uuid: uuid,
            type: type,
            visibleName: visibleName,
            parent: parent?.isEmpty == true ? nil : parent,
            version: version,
            lastModified: lastModified,
            pageCount: pageCount,
            hasAnnotations: hasAnnotations
        )
    }
}

// MARK: - Dropbox Document Metadata

private struct DropboxDocumentMetadata {
    let uuid: String
    let type: String
    let visibleName: String
    let parent: String?
    let version: Int
    let lastModified: Date
    let pageCount: Int
    let hasAnnotations: Bool
}

// MARK: - Dropbox Backend Extension for Settings

public extension RemarkableDropboxBackend {

    /// Check if Dropbox integration is likely available (folder exists).
    static var isDropboxAvailable: Bool {
        findDefaultFolder() != nil
    }

    /// Get the recommended folder path for display in settings.
    static var recommendedFolderPath: String {
        if let folder = findDefaultFolder() {
            return folder.path
        }
        return NSString(string: defaultDropboxPath).expandingTildeInPath
    }
}
