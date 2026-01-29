//
//  EInkTypes.swift
//  PublicationManagerCore
//
//  Unified types for E-Ink device integration.
//  Supports reMarkable, Supernote, and Kindle Scribe.
//

import Foundation

// MARK: - Device Types

/// Supported E-Ink device types.
public enum EInkDeviceType: String, Codable, CaseIterable, Sendable {
    case remarkable = "remarkable"
    case supernote = "supernote"
    case kindleScribe = "kindle_scribe"

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .remarkable: return "reMarkable"
        case .supernote: return "Supernote"
        case .kindleScribe: return "Kindle Scribe"
        }
    }

    /// SF Symbol icon name.
    public var iconName: String {
        switch self {
        case .remarkable: return "rectangle.portrait"
        case .supernote: return "note.text"
        case .kindleScribe: return "book"
        }
    }

    /// Supported sync methods for this device type.
    public var supportedSyncMethods: [EInkSyncMethod] {
        switch self {
        case .remarkable:
            return [.cloudApi, .folderSync, .usb]
        case .supernote:
            return [.folderSync, .cloudApi]
        case .kindleScribe:
            return [.usb, .email]
        }
    }

    /// File extensions used for annotation data.
    public var annotationFileExtensions: [String] {
        switch self {
        case .remarkable: return ["rm"]
        case .supernote: return ["note", "mark"]
        case .kindleScribe: return ["pdf"]  // Annotations embedded in PDF
        }
    }
}

// MARK: - Sync Methods

/// Methods for syncing with E-Ink devices.
public enum EInkSyncMethod: String, Codable, CaseIterable, Sendable {
    case cloudApi = "cloud_api"
    case folderSync = "folder_sync"
    case usb = "usb"
    case email = "email"

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .cloudApi: return "Cloud API"
        case .folderSync: return "Folder Sync"
        case .usb: return "USB Connection"
        case .email: return "Email"
        }
    }

    /// Description of this sync method.
    public var methodDescription: String {
        switch self {
        case .cloudApi: return "Sync via official cloud service"
        case .folderSync: return "Monitor a local folder for changes"
        case .usb: return "Direct USB connection to device"
        case .email: return "Send documents via email"
        }
    }

    /// Whether this method requires authentication.
    public var requiresAuthentication: Bool {
        switch self {
        case .cloudApi: return true
        case .folderSync: return false
        case .usb: return false
        case .email: return true  // Email address required
        }
    }

    /// Whether this method supports bidirectional sync.
    public var supportsBidirectionalSync: Bool {
        switch self {
        case .cloudApi: return true
        case .folderSync: return true  // If folder is mounted
        case .usb: return true
        case .email: return false  // Upload only
        }
    }
}

// MARK: - Sync Capabilities

/// Capabilities of an E-Ink device or backend.
public struct EInkSyncCapabilities: OptionSet, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Can upload documents to the device.
    public static let upload = EInkSyncCapabilities(rawValue: 1 << 0)

    /// Can download PDF documents from the device.
    public static let downloadPDF = EInkSyncCapabilities(rawValue: 1 << 1)

    /// Can download annotations from the device.
    public static let downloadAnnotations = EInkSyncCapabilities(rawValue: 1 << 2)

    /// Can create folders on the device.
    public static let createFolders = EInkSyncCapabilities(rawValue: 1 << 3)

    /// Can delete documents from the device.
    public static let deleteDocuments = EInkSyncCapabilities(rawValue: 1 << 4)

    /// Supports full bidirectional sync.
    public static let bidirectionalSync = EInkSyncCapabilities(rawValue: 1 << 5)

    /// Supports real-time sync notifications.
    public static let realtimeSync = EInkSyncCapabilities(rawValue: 1 << 6)

    /// Full capabilities.
    public static let full: EInkSyncCapabilities = [
        .upload, .downloadPDF, .downloadAnnotations,
        .createFolders, .deleteDocuments, .bidirectionalSync
    ]

    /// Read-only capabilities.
    public static let readOnly: EInkSyncCapabilities = [
        .downloadPDF, .downloadAnnotations
    ]

    /// Upload-only capabilities.
    public static let uploadOnly: EInkSyncCapabilities = [.upload]
}

// MARK: - Document Info

/// Information about a document on an E-Ink device.
public struct EInkDocumentInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let deviceType: EInkDeviceType
    public let name: String
    public let parentFolderID: String?
    public let lastModified: Date
    public let version: Int
    public let pageCount: Int
    public let hasAnnotations: Bool
    public let fileSize: Int64?

    public init(
        id: String,
        deviceType: EInkDeviceType,
        name: String,
        parentFolderID: String?,
        lastModified: Date,
        version: Int = 1,
        pageCount: Int = 0,
        hasAnnotations: Bool = false,
        fileSize: Int64? = nil
    ) {
        self.id = id
        self.deviceType = deviceType
        self.name = name
        self.parentFolderID = parentFolderID
        self.lastModified = lastModified
        self.version = version
        self.pageCount = pageCount
        self.hasAnnotations = hasAnnotations
        self.fileSize = fileSize
    }
}

/// Information about a folder on an E-Ink device.
public struct EInkFolderInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let deviceType: EInkDeviceType
    public let name: String
    public let parentFolderID: String?
    public let documentCount: Int

    public init(
        id: String,
        deviceType: EInkDeviceType,
        name: String,
        parentFolderID: String?,
        documentCount: Int = 0
    ) {
        self.id = id
        self.deviceType = deviceType
        self.name = name
        self.parentFolderID = parentFolderID
        self.documentCount = documentCount
    }
}

// MARK: - Device Info

/// Information about a connected E-Ink device.
public struct EInkDeviceInfo: Codable, Sendable {
    public let deviceID: String
    public let deviceType: EInkDeviceType
    public let deviceName: String
    public let modelName: String?
    public let firmwareVersion: String?
    public let storageUsed: Int64?
    public let storageTotal: Int64?

    public init(
        deviceID: String,
        deviceType: EInkDeviceType,
        deviceName: String,
        modelName: String? = nil,
        firmwareVersion: String? = nil,
        storageUsed: Int64? = nil,
        storageTotal: Int64? = nil
    ) {
        self.deviceID = deviceID
        self.deviceType = deviceType
        self.deviceName = deviceName
        self.modelName = modelName
        self.firmwareVersion = firmwareVersion
        self.storageUsed = storageUsed
        self.storageTotal = storageTotal
    }

    /// Formatted storage usage string.
    public var formattedStorage: String? {
        guard let used = storageUsed, let total = storageTotal else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: used)) / \(formatter.string(fromByteCount: total))"
    }
}

// MARK: - Document Bundle

/// A complete document bundle downloaded from an E-Ink device.
public struct EInkDocumentBundle: Sendable {
    public let documentInfo: EInkDocumentInfo
    public let pdfData: Data
    public let rawAnnotationData: Data?
    public let metadata: [String: String]

    public init(
        documentInfo: EInkDocumentInfo,
        pdfData: Data,
        rawAnnotationData: Data? = nil,
        metadata: [String: String] = [:]
    ) {
        self.documentInfo = documentInfo
        self.pdfData = pdfData
        self.rawAnnotationData = rawAnnotationData
        self.metadata = metadata
    }
}

// MARK: - Sync State

/// Sync state for an E-Ink document.
public enum EInkSyncState: String, Codable, CaseIterable, Sendable {
    case notSynced = "notSynced"
    case pending = "pending"
    case syncing = "syncing"
    case synced = "synced"
    case conflict = "conflict"
    case error = "error"

    public var displayName: String {
        switch self {
        case .notSynced: return "Not Synced"
        case .pending: return "Pending"
        case .syncing: return "Syncing"
        case .synced: return "Synced"
        case .conflict: return "Conflict"
        case .error: return "Error"
        }
    }

    public var icon: String {
        switch self {
        case .notSynced: return "circle.dashed"
        case .pending: return "arrow.triangle.2.circlepath"
        case .syncing: return "arrow.triangle.2.circlepath.circle"
        case .synced: return "checkmark.circle.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Conflict Resolution

/// Resolution strategy for annotation conflicts.
public enum EInkConflictResolution: String, Codable, CaseIterable, Sendable {
    case preferDevice = "preferDevice"
    case preferLocal = "preferLocal"
    case keepBoth = "keepBoth"
    case ask = "ask"

    public var displayName: String {
        switch self {
        case .preferDevice: return "Prefer E-Ink Device"
        case .preferLocal: return "Prefer imbib"
        case .keepBoth: return "Keep both versions"
        case .ask: return "Ask each time"
        }
    }
}

// MARK: - Errors

/// Errors that can occur during E-Ink operations.
public enum EInkError: LocalizedError, Sendable {
    case notAuthenticated
    case authTimeout
    case authFailed(String)
    case notConfigured(String)
    case noDeviceConfigured
    case deviceNotFound(String)
    case deviceUnavailable(String)
    case unsupportedDevice(EInkDeviceType)
    case noPDFAvailable
    case localFolderNotConfigured
    case localFolderNotFound(String)
    case localFolderNotAccessible
    case documentNotFound(String)
    case annotationSyncNotSupported(device: String)
    case uploadFailed(String)
    case downloadFailed(String)
    case parseFailed(String)
    case networkError(Error)
    case unsupportedSyncMethod(EInkSyncMethod)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in. Please connect your account in Settings."
        case .authTimeout:
            return "Authentication timed out. Please try again."
        case .authFailed(let reason):
            return "Authentication failed: \(reason)"
        case .notConfigured(let reason):
            return "Not configured: \(reason)"
        case .noDeviceConfigured:
            return "No E-Ink device configured. Please set one up in Settings."
        case .deviceNotFound(let id):
            return "Device '\(id)' not found."
        case .deviceUnavailable(let id):
            return "Device '\(id)' is not available."
        case .unsupportedDevice(let type):
            return "Device type '\(type.displayName)' is not yet supported."
        case .noPDFAvailable:
            return "No PDF available for this publication."
        case .localFolderNotConfigured:
            return "Local folder path not configured."
        case .localFolderNotFound(let path):
            return "Local folder not found at: \(path)"
        case .localFolderNotAccessible:
            return "Cannot access the configured local folder."
        case .documentNotFound(let id):
            return "Document not found: \(id)"
        case .annotationSyncNotSupported(let device):
            return "Annotation sync is not supported for '\(device)'."
        case .uploadFailed(let reason):
            return "Failed to upload document: \(reason)"
        case .downloadFailed(let reason):
            return "Failed to download: \(reason)"
        case .parseFailed(let reason):
            return "Failed to parse data: \(reason)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .unsupportedSyncMethod(let method):
            return "Sync method '\(method.displayName)' is not supported for this device."
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the authentication code should be shown to the user.
    static let einkShowAuthCode = Notification.Name("einkShowAuthCode")

    /// Posted when E-Ink sync state changes.
    static let einkSyncStateChanged = Notification.Name("einkSyncStateChanged")

    /// Posted when annotations are imported from an E-Ink device.
    static let einkAnnotationsImported = Notification.Name("einkAnnotationsImported")

    /// Posted when a new device is connected.
    static let einkDeviceConnected = Notification.Name("einkDeviceConnected")

    /// Posted when a device is disconnected.
    static let einkDeviceDisconnected = Notification.Name("einkDeviceDisconnected")
}

// Note: The existing RemarkableTypes.swift in ReMarkable/ continues to provide
// RemarkableDocumentInfo, RemarkableFolderInfo, RemarkableDeviceInfo, etc.
// This module provides new unified types for multi-device E-Ink support.
// Future work may bridge existing types to these unified types.
