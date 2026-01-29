//
//  RemarkableDeviceAdapter.swift
//  PublicationManagerCore
//
//  Adapter that wraps existing RemarkableSyncBackend implementations
//  to conform to the unified EInkDevice protocol.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableAdapter")

// MARK: - Remarkable Device Adapter

/// Adapts existing RemarkableSyncBackend implementations to the EInkDevice protocol.
///
/// This adapter wraps the existing reMarkable backends (Cloud, Local, Dropbox)
/// to provide a unified interface for multi-device E-Ink support.
public actor RemarkableDeviceAdapter: EInkDevice {

    // MARK: - Properties

    /// The wrapped backend.
    private let backend: any RemarkableSyncBackend

    /// Unique device identifier.
    public nonisolated let deviceID: String

    /// Human-readable display name (cached at init).
    public nonisolated let displayName: String

    /// The device type (always remarkable for this adapter).
    public nonisolated let deviceType: EInkDeviceType = .remarkable

    /// The sync method used by the wrapped backend.
    public nonisolated let syncMethod: EInkSyncMethod

    /// Capabilities based on sync method.
    public nonisolated var capabilities: EInkSyncCapabilities {
        switch syncMethod {
        case .cloudApi:
            return .full
        case .folderSync:
            return [.upload, .downloadPDF, .downloadAnnotations, .createFolders]
        case .usb:
            return [.upload, .downloadPDF, .downloadAnnotations]
        default:
            return .readOnly
        }
    }

    // MARK: - Initialization

    /// Create an adapter wrapping a RemarkableSyncBackend.
    ///
    /// - Parameters:
    ///   - backend: The backend to wrap
    ///   - syncMethod: The sync method this backend uses
    public init(backend: any RemarkableSyncBackend, syncMethod: EInkSyncMethod) async {
        self.backend = backend
        self.syncMethod = syncMethod
        self.deviceID = "remarkable-\(await backend.backendID)"
        self.displayName = await backend.displayName
    }

    // MARK: - Factory Methods

    /// Create an adapter for the cloud backend.
    public static func cloud(backend: any RemarkableSyncBackend) async -> RemarkableDeviceAdapter {
        await RemarkableDeviceAdapter(backend: backend, syncMethod: .cloudApi)
    }

    /// Create an adapter for a local folder backend.
    public static func local(backend: any RemarkableSyncBackend) async -> RemarkableDeviceAdapter {
        await RemarkableDeviceAdapter(backend: backend, syncMethod: .folderSync)
    }

    // MARK: - Availability & Authentication

    public func isAvailable() async -> Bool {
        await backend.isAvailable()
    }

    public func authenticate() async throws {
        try await backend.authenticate()

        // Update EInk settings on MainActor
        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.deviceType = .remarkable
                settings.syncMethod = syncMethod
                settings.isAuthenticated = true
            }
        }

        logger.info("Authenticated reMarkable device: \(self.deviceID)")
    }

    public func disconnect() async {
        await backend.disconnect()

        // Update EInk settings on MainActor
        await MainActor.run {
            EInkSettingsStore.shared.updateSettings(for: deviceID) { settings in
                settings.isAuthenticated = false
            }
        }

        logger.info("Disconnected reMarkable device: \(self.deviceID)")
    }

    // MARK: - Document Operations

    public func listDocuments() async throws -> [EInkDocumentInfo] {
        let rmDocs = try await backend.listDocuments()

        // Convert RemarkableDocumentInfo to EInkDocumentInfo
        return rmDocs.map { doc in
            EInkDocumentInfo(
                id: doc.id,
                deviceType: .remarkable,
                name: doc.name,
                parentFolderID: doc.parentFolderID,
                lastModified: doc.lastModified,
                version: doc.version,
                pageCount: doc.pageCount,
                hasAnnotations: doc.hasAnnotations
            )
        }
    }

    public func listFolders() async throws -> [EInkFolderInfo] {
        let rmFolders = try await backend.listFolders()

        // Convert RemarkableFolderInfo to EInkFolderInfo
        return rmFolders.map { folder in
            EInkFolderInfo(
                id: folder.id,
                deviceType: .remarkable,
                name: folder.name,
                parentFolderID: folder.parentFolderID,
                documentCount: folder.documentCount
            )
        }
    }

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        try await backend.uploadDocument(data, filename: filename, parentFolder: parentFolder)
    }

    public func downloadAnnotations(documentID: String) async throws -> Data {
        // Get raw annotations and convert to serialized format
        let rmAnnotations = try await backend.downloadAnnotations(documentID: documentID)

        // Serialize to JSON for storage
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(rmAnnotations)
    }

    public func downloadDocument(documentID: String) async throws -> EInkDocumentBundle {
        let rmBundle = try await backend.downloadDocument(documentID: documentID)

        // Convert RemarkableDocumentBundle to EInkDocumentBundle
        let docInfo = EInkDocumentInfo(
            id: rmBundle.documentInfo.id,
            deviceType: .remarkable,
            name: rmBundle.documentInfo.name,
            parentFolderID: rmBundle.documentInfo.parentFolderID,
            lastModified: rmBundle.documentInfo.lastModified,
            version: rmBundle.documentInfo.version,
            pageCount: rmBundle.documentInfo.pageCount,
            hasAnnotations: rmBundle.documentInfo.hasAnnotations
        )

        // Serialize annotations for the bundle
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let annotationData = try? encoder.encode(rmBundle.annotations)

        return EInkDocumentBundle(
            documentInfo: docInfo,
            pdfData: rmBundle.pdfData,
            rawAnnotationData: annotationData,
            metadata: rmBundle.metadata
        )
    }

    public func createFolder(name: String, parent: String?) async throws -> String {
        try await backend.createFolder(name: name, parent: parent)
    }

    public func deleteDocument(documentID: String) async throws {
        try await backend.deleteDocument(documentID: documentID)
    }

    public func getDeviceInfo() async throws -> EInkDeviceInfo {
        let rmInfo = try await backend.getDeviceInfo()

        return EInkDeviceInfo(
            deviceID: rmInfo.deviceID,
            deviceType: .remarkable,
            deviceName: rmInfo.deviceName,
            modelName: "reMarkable",
            storageUsed: rmInfo.storageUsed,
            storageTotal: rmInfo.storageTotal
        )
    }
}

// MARK: - RemarkableDeviceAdapter Factory

public extension RemarkableDeviceAdapter {
    /// Register all available reMarkable backends with the EInkDeviceManager.
    @MainActor
    static func registerWithDeviceManager() async {
        let backendManager = RemarkableBackendManager.shared

        for backend in backendManager.availableBackends {
            let backendID = await backend.backendID
            let syncMethod: EInkSyncMethod

            switch backendID {
            case "cloud":
                syncMethod = .cloudApi
            case "local":
                syncMethod = .folderSync
            case "dropbox":
                syncMethod = .folderSync
            default:
                syncMethod = .folderSync
            }

            let adapter = await RemarkableDeviceAdapter(backend: backend, syncMethod: syncMethod)
            await EInkDeviceManager.shared.registerDevice(adapter)
        }

        logger.info("Registered reMarkable backends with EInkDeviceManager")
    }
}
