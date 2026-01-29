//
//  KindleScribeDevice.swift
//  PublicationManagerCore
//
//  E-Ink device backend for Amazon Kindle Scribe.
//  Supports USB export and email-based document transfer.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "kindleScribeDevice")

// MARK: - Kindle Scribe Device

/// E-Ink device implementation for Amazon Kindle Scribe.
///
/// Kindle Scribe devices support:
/// - USB connection for direct file transfer
/// - Email-based document sending ("Send to Kindle")
/// - Annotations embedded directly in PDF files
public actor KindleScribeDevice: EInkDevice {

    // MARK: - Properties

    /// Unique device identifier.
    public nonisolated let deviceID: String

    /// Human-readable display name.
    public nonisolated let displayName: String

    /// Device type (always kindleScribe).
    public nonisolated let deviceType: EInkDeviceType = .kindleScribe

    /// Sync method used by this device.
    public nonisolated let syncMethod: EInkSyncMethod

    /// Capabilities based on sync method.
    public nonisolated var capabilities: EInkSyncCapabilities {
        switch syncMethod {
        case .usb:
            return [.upload, .downloadPDF, .downloadAnnotations]
        case .email:
            return .uploadOnly
        default:
            return .uploadOnly
        }
    }

    /// Mount path for USB connection.
    private var mountPath: URL?

    /// Email address for Send to Kindle.
    private var sendToEmail: String?

    // MARK: - Initialization

    /// Create a Kindle Scribe device with USB sync.
    ///
    /// - Parameters:
    ///   - deviceID: Unique identifier
    ///   - displayName: Human-readable name
    ///   - mountPath: USB mount path
    public init(
        deviceID: String = "kindle-scribe-\(UUID().uuidString.prefix(8))",
        displayName: String = "Kindle Scribe",
        mountPath: URL? = nil
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.mountPath = mountPath
        self.syncMethod = .usb
        self.sendToEmail = nil
    }

    /// Create a Kindle Scribe device with email sync.
    ///
    /// - Parameters:
    ///   - deviceID: Unique identifier
    ///   - displayName: Human-readable name
    ///   - email: Send to Kindle email address
    public init(
        deviceID: String = "kindle-scribe-\(UUID().uuidString.prefix(8))",
        displayName: String = "Kindle Scribe",
        email: String
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.sendToEmail = email
        self.syncMethod = .email
        self.mountPath = nil
    }

    // MARK: - Configuration

    /// Configure for USB sync.
    public func configureUSB(mountPath: URL) async {
        self.mountPath = mountPath
        self.sendToEmail = nil

        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.deviceType = .kindleScribe
                settings.syncMethod = .usb
                settings.localFolderPath = mountPath.path
            }
        }

        logger.info("Configured Kindle Scribe for USB: \(mountPath.path)")
    }

    /// Configure for email sync.
    public func configureEmail(address: String) async {
        self.sendToEmail = address
        self.mountPath = nil

        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.deviceType = .kindleScribe
                settings.syncMethod = .email
                settings.sendToEmail = address
            }
        }

        logger.info("Configured Kindle Scribe for email: \(address)")
    }

    // MARK: - Availability & Authentication

    public func isAvailable() async -> Bool {
        switch syncMethod {
        case .usb:
            guard let path = mountPath else { return false }
            return FileManager.default.fileExists(atPath: path.path)
        case .email:
            return sendToEmail != nil && !sendToEmail!.isEmpty
        default:
            return false
        }
    }

    public func authenticate() async throws {
        switch syncMethod {
        case .usb:
            guard let path = mountPath else {
                throw EInkError.localFolderNotConfigured
            }
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw EInkError.localFolderNotFound(path.path)
            }

        case .email:
            guard let email = sendToEmail, !email.isEmpty else {
                throw EInkError.notConfigured("Send to Kindle email not set")
            }
            // Basic email validation
            guard email.contains("@") && email.contains(".") else {
                throw EInkError.notConfigured("Invalid email address")
            }

        default:
            throw EInkError.unsupportedSyncMethod(syncMethod)
        }

        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.isAuthenticated = true
            }
        }

        logger.info("Kindle Scribe device authenticated")
    }

    public func disconnect() async {
        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.isAuthenticated = false
            }
        }

        logger.info("Kindle Scribe device disconnected")
    }

    // MARK: - Document Operations

    public func listDocuments() async throws -> [EInkDocumentInfo] {
        guard syncMethod == .usb else {
            throw EInkError.unsupportedSyncMethod(syncMethod)
        }

        guard let path = mountPath else {
            throw EInkError.localFolderNotConfigured
        }

        var documents: [EInkDocumentInfo] = []
        let fileManager = FileManager.default

        // Kindle Scribe stores documents in the "documents" folder
        let documentsFolder = path.appendingPathComponent("documents", isDirectory: true)

        guard fileManager.fileExists(atPath: documentsFolder.path) else {
            logger.warning("Kindle documents folder not found")
            return []
        }

        // Recursively find PDF files
        let enumerator = fileManager.enumerator(
            at: documentsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "pdf" else { continue }

            let name = url.deletingPathExtension().lastPathComponent
            let relativePath = url.path.replacingOccurrences(of: documentsFolder.path + "/", with: "")

            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let modDate = attributes?[.modificationDate] as? Date ?? Date()
            let fileSize = attributes?[.size] as? Int64

            // Kindle Scribe embeds annotations in the PDF itself
            let docInfo = EInkDocumentInfo(
                id: relativePath,
                deviceType: .kindleScribe,
                name: name,
                parentFolderID: url.deletingLastPathComponent().lastPathComponent,
                lastModified: modDate,
                version: 1,
                pageCount: 0,
                hasAnnotations: true,  // Assume all PDFs might have annotations
                fileSize: fileSize
            )

            documents.append(docInfo)
        }

        logger.debug("Found \(documents.count) documents on Kindle Scribe")
        return documents
    }

    public func listFolders() async throws -> [EInkFolderInfo] {
        guard syncMethod == .usb else {
            throw EInkError.unsupportedSyncMethod(syncMethod)
        }

        guard let path = mountPath else {
            throw EInkError.localFolderNotConfigured
        }

        var folders: [EInkFolderInfo] = []
        let fileManager = FileManager.default

        let documentsFolder = path.appendingPathComponent("documents", isDirectory: true)

        guard fileManager.fileExists(atPath: documentsFolder.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: documentsFolder,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        for url in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let folderInfo = EInkFolderInfo(
                id: url.lastPathComponent,
                deviceType: .kindleScribe,
                name: url.lastPathComponent,
                parentFolderID: nil
            )

            folders.append(folderInfo)
        }

        return folders
    }

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        switch syncMethod {
        case .usb:
            return try await uploadViaUSB(data, filename: filename, parentFolder: parentFolder)
        case .email:
            return try await uploadViaEmail(data, filename: filename)
        default:
            throw EInkError.unsupportedSyncMethod(syncMethod)
        }
    }

    private func uploadViaUSB(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        guard let path = mountPath else {
            throw EInkError.localFolderNotConfigured
        }

        var targetFolder = path.appendingPathComponent("documents", isDirectory: true)

        if let parent = parentFolder {
            targetFolder = targetFolder.appendingPathComponent(parent, isDirectory: true)
        }

        // Ensure folder exists
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)

        // Write the PDF
        let targetURL = targetFolder.appendingPathComponent(filename)
        try data.write(to: targetURL)

        logger.info("Uploaded document to Kindle Scribe via USB: \(filename)")
        return filename
    }

    private func uploadViaEmail(_ data: Data, filename: String) async throws -> String {
        guard let email = sendToEmail else {
            throw EInkError.notConfigured("Send to Kindle email not set")
        }

        // Email sending requires system integration
        // This is a stub - actual implementation would use MFMailComposeViewController on iOS
        // or NSWorkspace on macOS to compose an email with attachment

        logger.warning("Email upload not yet fully implemented - email: \(email)")

        // For now, we'll throw an informative error
        throw EInkError.uploadFailed(
            "Email upload requires system email integration. " +
            "Please manually send '\(filename)' to \(email)"
        )
    }

    public func downloadAnnotations(documentID: String) async throws -> Data {
        guard syncMethod == .usb else {
            throw EInkError.unsupportedSyncMethod(syncMethod)
        }

        guard let path = mountPath else {
            throw EInkError.localFolderNotConfigured
        }

        // Kindle Scribe stores annotations embedded in the PDF
        // We return the entire PDF data and let the normalizer extract annotations
        let documentsFolder = path.appendingPathComponent("documents", isDirectory: true)
        let pdfURL = documentsFolder.appendingPathComponent(documentID)

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw EInkError.documentNotFound(documentID)
        }

        // Return the PDF data - annotations are embedded within
        return try Data(contentsOf: pdfURL)
    }

    public func downloadDocument(documentID: String) async throws -> EInkDocumentBundle {
        guard syncMethod == .usb else {
            throw EInkError.unsupportedSyncMethod(syncMethod)
        }

        guard let path = mountPath else {
            throw EInkError.localFolderNotConfigured
        }

        let documentsFolder = path.appendingPathComponent("documents", isDirectory: true)
        let pdfURL = documentsFolder.appendingPathComponent(documentID)

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw EInkError.documentNotFound(documentID)
        }

        let pdfData = try Data(contentsOf: pdfURL)

        let attributes = try? FileManager.default.attributesOfItem(atPath: pdfURL.path)
        let modDate = attributes?[.modificationDate] as? Date ?? Date()

        let name = pdfURL.deletingPathExtension().lastPathComponent

        let docInfo = EInkDocumentInfo(
            id: documentID,
            deviceType: .kindleScribe,
            name: name,
            parentFolderID: nil,
            lastModified: modDate,
            version: 1,
            pageCount: 0,
            hasAnnotations: true
        )

        // For Kindle Scribe, annotation data IS the PDF data
        return EInkDocumentBundle(
            documentInfo: docInfo,
            pdfData: pdfData,
            rawAnnotationData: pdfData  // Annotations are in the PDF
        )
    }

    public func createFolder(name: String, parent: String?) async throws -> String {
        guard syncMethod == .usb else {
            throw EInkError.unsupportedSyncMethod(syncMethod)
        }

        guard let path = mountPath else {
            throw EInkError.localFolderNotConfigured
        }

        var targetFolder = path.appendingPathComponent("documents", isDirectory: true)

        if let parent = parent {
            targetFolder = targetFolder.appendingPathComponent(parent, isDirectory: true)
        }

        let newFolder = targetFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)

        logger.info("Created folder on Kindle Scribe: \(name)")
        return name
    }

    public func deleteDocument(documentID: String) async throws {
        guard syncMethod == .usb else {
            throw EInkError.unsupportedSyncMethod(syncMethod)
        }

        guard let path = mountPath else {
            throw EInkError.localFolderNotConfigured
        }

        let documentsFolder = path.appendingPathComponent("documents", isDirectory: true)
        let pdfURL = documentsFolder.appendingPathComponent(documentID)

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw EInkError.documentNotFound(documentID)
        }

        try FileManager.default.removeItem(at: pdfURL)

        // Also remove sidecar files if present
        let sdrFolder = pdfURL.deletingPathExtension().appendingPathExtension("sdr")
        try? FileManager.default.removeItem(at: sdrFolder)

        logger.info("Deleted document from Kindle Scribe: \(documentID)")
    }

    public func getDeviceInfo() async throws -> EInkDeviceInfo {
        var storageUsed: Int64? = nil
        var storageTotal: Int64? = nil

        if let path = mountPath {
            let values = try? path.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            storageTotal = values?.volumeTotalCapacity.map { Int64($0) }
            let available = values?.volumeAvailableCapacity.map { Int64($0) }
            if let total = storageTotal, let avail = available {
                storageUsed = total - avail
            }
        }

        return EInkDeviceInfo(
            deviceID: deviceID,
            deviceType: .kindleScribe,
            deviceName: displayName,
            modelName: "Kindle Scribe",
            storageUsed: storageUsed,
            storageTotal: storageTotal
        )
    }
}
