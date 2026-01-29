//
//  SupernoteDevice.swift
//  PublicationManagerCore
//
//  E-Ink device backend for Supernote tablets.
//  Supports folder sync and cloud API (when available).
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "supernoteDevice")

// MARK: - Supernote Device

/// E-Ink device implementation for Supernote tablets.
///
/// Supernote devices support:
/// - Folder sync via Supernote Cloud or local folder
/// - .note files for notebooks
/// - .mark files for PDF annotations
public actor SupernoteDevice: EInkDevice {

    // MARK: - Properties

    /// Unique device identifier.
    public nonisolated let deviceID: String

    /// Human-readable display name.
    public nonisolated let displayName: String

    /// Device type (always supernote).
    public nonisolated let deviceType: EInkDeviceType = .supernote

    /// Sync method used by this device.
    public nonisolated let syncMethod: EInkSyncMethod

    /// Capabilities based on sync method.
    public nonisolated var capabilities: EInkSyncCapabilities {
        switch syncMethod {
        case .folderSync:
            return [.upload, .downloadPDF, .downloadAnnotations, .createFolders]
        case .cloudApi:
            return .full
        default:
            return .readOnly
        }
    }

    /// Watched folder URL for folder sync.
    private var watchedFolder: URL?

    // MARK: - Initialization

    /// Create a Supernote device with folder sync.
    ///
    /// - Parameters:
    ///   - deviceID: Unique identifier for this device
    ///   - displayName: Human-readable name
    ///   - folderPath: Path to the Supernote sync folder
    public init(
        deviceID: String = "supernote-\(UUID().uuidString.prefix(8))",
        displayName: String = "Supernote",
        folderPath: URL? = nil
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.watchedFolder = folderPath
        self.syncMethod = .folderSync
    }

    // MARK: - Configuration

    /// Configure the watched folder for sync.
    public func configure(folderPath: URL) async {
        self.watchedFolder = folderPath

        // Store in settings
        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.deviceType = .supernote
                settings.syncMethod = .folderSync
                settings.localFolderPath = folderPath.path
            }
        }

        logger.info("Configured Supernote folder: \(folderPath.path)")
    }

    // MARK: - Availability & Authentication

    public func isAvailable() async -> Bool {
        guard let folder = watchedFolder else {
            return false
        }

        return FileManager.default.fileExists(atPath: folder.path)
    }

    public func authenticate() async throws {
        // Folder sync doesn't require authentication
        // Just verify the folder exists

        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw EInkError.localFolderNotFound(folder.path)
        }

        // Mark as authenticated
        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.isAuthenticated = true
            }
        }

        logger.info("Supernote device authenticated (folder exists)")
    }

    public func disconnect() async {
        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.isAuthenticated = false
            }
        }

        logger.info("Supernote device disconnected")
    }

    // MARK: - Document Operations

    public func listDocuments() async throws -> [EInkDocumentInfo] {
        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        var documents: [EInkDocumentInfo] = []
        let fileManager = FileManager.default

        // Supernote stores documents in Document/ subfolder
        let documentFolder = folder.appendingPathComponent("Document", isDirectory: true)

        guard fileManager.fileExists(atPath: documentFolder.path) else {
            logger.warning("Supernote Document folder not found")
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: documentFolder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )

        for url in contents {
            // Look for PDF files with associated .mark annotation files
            guard url.pathExtension.lowercased() == "pdf" else { continue }

            let name = url.deletingPathExtension().lastPathComponent
            let id = url.lastPathComponent

            // Check for annotation file
            let markFile = url.deletingPathExtension().appendingPathExtension("mark")
            let hasAnnotations = fileManager.fileExists(atPath: markFile.path)

            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let modDate = attributes?[.modificationDate] as? Date ?? Date()
            let fileSize = attributes?[.size] as? Int64

            let docInfo = EInkDocumentInfo(
                id: id,
                deviceType: .supernote,
                name: name,
                parentFolderID: nil,
                lastModified: modDate,
                version: 1,
                pageCount: 0,  // Would need PDF parsing to determine
                hasAnnotations: hasAnnotations,
                fileSize: fileSize
            )

            documents.append(docInfo)
        }

        logger.debug("Found \(documents.count) documents on Supernote")
        return documents
    }

    public func listFolders() async throws -> [EInkFolderInfo] {
        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        var folders: [EInkFolderInfo] = []
        let fileManager = FileManager.default

        let documentFolder = folder.appendingPathComponent("Document", isDirectory: true)

        guard fileManager.fileExists(atPath: documentFolder.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: documentFolder,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        for url in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let folderInfo = EInkFolderInfo(
                id: url.lastPathComponent,
                deviceType: .supernote,
                name: url.lastPathComponent,
                parentFolderID: nil
            )

            folders.append(folderInfo)
        }

        return folders
    }

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        var targetFolder = folder.appendingPathComponent("Document", isDirectory: true)

        if let parent = parentFolder {
            targetFolder = targetFolder.appendingPathComponent(parent, isDirectory: true)
        }

        // Ensure folder exists
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)

        // Write the PDF
        let targetURL = targetFolder.appendingPathComponent(filename)
        try data.write(to: targetURL)

        logger.info("Uploaded document to Supernote: \(filename)")
        return filename
    }

    public func downloadAnnotations(documentID: String) async throws -> Data {
        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        // Supernote stores annotations in .mark files alongside PDFs
        let documentFolder = folder.appendingPathComponent("Document", isDirectory: true)
        let pdfURL = documentFolder.appendingPathComponent(documentID)
        let markURL = pdfURL.deletingPathExtension().appendingPathExtension("mark")

        guard FileManager.default.fileExists(atPath: markURL.path) else {
            logger.warning("No annotation file found for: \(documentID)")
            return Data()
        }

        return try Data(contentsOf: markURL)
    }

    public func downloadDocument(documentID: String) async throws -> EInkDocumentBundle {
        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        let documentFolder = folder.appendingPathComponent("Document", isDirectory: true)
        let pdfURL = documentFolder.appendingPathComponent(documentID)

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw EInkError.documentNotFound(documentID)
        }

        let pdfData = try Data(contentsOf: pdfURL)

        // Try to get annotations
        let annotationData = try? await downloadAnnotations(documentID: documentID)

        let attributes = try? FileManager.default.attributesOfItem(atPath: pdfURL.path)
        let modDate = attributes?[.modificationDate] as? Date ?? Date()

        let docInfo = EInkDocumentInfo(
            id: documentID,
            deviceType: .supernote,
            name: pdfURL.deletingPathExtension().lastPathComponent,
            parentFolderID: nil,
            lastModified: modDate,
            version: 1,
            pageCount: 0,
            hasAnnotations: annotationData != nil && !annotationData!.isEmpty
        )

        return EInkDocumentBundle(
            documentInfo: docInfo,
            pdfData: pdfData,
            rawAnnotationData: annotationData
        )
    }

    public func createFolder(name: String, parent: String?) async throws -> String {
        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        var targetFolder = folder.appendingPathComponent("Document", isDirectory: true)

        if let parent = parent {
            targetFolder = targetFolder.appendingPathComponent(parent, isDirectory: true)
        }

        let newFolder = targetFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)

        logger.info("Created folder on Supernote: \(name)")
        return name
    }

    public func deleteDocument(documentID: String) async throws {
        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        let documentFolder = folder.appendingPathComponent("Document", isDirectory: true)
        let pdfURL = documentFolder.appendingPathComponent(documentID)

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw EInkError.documentNotFound(documentID)
        }

        try FileManager.default.removeItem(at: pdfURL)

        // Also remove annotation file if present
        let markURL = pdfURL.deletingPathExtension().appendingPathExtension("mark")
        try? FileManager.default.removeItem(at: markURL)

        logger.info("Deleted document from Supernote: \(documentID)")
    }

    public func getDeviceInfo() async throws -> EInkDeviceInfo {
        guard let folder = watchedFolder else {
            throw EInkError.localFolderNotConfigured
        }

        // Try to get storage info
        let values = try? folder.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = values?.volumeTotalCapacity.map { Int64($0) }
        let available = values?.volumeAvailableCapacity.map { Int64($0) }
        let used = total != nil && available != nil ? total! - available! : nil

        return EInkDeviceInfo(
            deviceID: deviceID,
            deviceType: .supernote,
            deviceName: displayName,
            modelName: "Supernote",
            storageUsed: used,
            storageTotal: total
        )
    }
}
