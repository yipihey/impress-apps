//
//  RemarkableTypes.swift
//  PublicationManagerCore
//
//  Data transfer objects and common types for reMarkable integration.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation

// MARK: - Document Types

/// Information about a document on the reMarkable device.
public struct RemarkableDocumentInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let parentFolderID: String?
    public let lastModified: Date
    public let version: Int
    public let pageCount: Int
    public let hasAnnotations: Bool

    public init(
        id: String,
        name: String,
        parentFolderID: String?,
        lastModified: Date,
        version: Int,
        pageCount: Int = 0,
        hasAnnotations: Bool = false
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.lastModified = lastModified
        self.version = version
        self.pageCount = pageCount
        self.hasAnnotations = hasAnnotations
    }
}

/// Information about a folder on the reMarkable device.
public struct RemarkableFolderInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let parentFolderID: String?
    public let documentCount: Int

    public init(id: String, name: String, parentFolderID: String?, documentCount: Int = 0) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.documentCount = documentCount
    }
}

// MARK: - Annotation Types

/// Raw annotation data from reMarkable before conversion.
public struct RemarkableRawAnnotation: Codable, Identifiable, Sendable {
    public let id: String
    public let pageNumber: Int
    public let layerName: String?
    public let type: AnnotationType
    public let strokeData: Data?
    public let boundsX: CGFloat
    public let boundsY: CGFloat
    public let boundsWidth: CGFloat
    public let boundsHeight: CGFloat
    public let color: String?
    public let ocrText: String?

    public enum AnnotationType: String, Codable, Sendable {
        case highlight
        case ink
        case text
    }

    /// The bounds as a CGRect.
    public var bounds: CGRect {
        CGRect(x: boundsX, y: boundsY, width: boundsWidth, height: boundsHeight)
    }

    public init(
        id: String,
        pageNumber: Int,
        layerName: String? = nil,
        type: AnnotationType,
        strokeData: Data? = nil,
        bounds: CGRect,
        color: String?,
        ocrText: String? = nil
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.layerName = layerName
        self.type = type
        self.strokeData = strokeData
        self.boundsX = bounds.origin.x
        self.boundsY = bounds.origin.y
        self.boundsWidth = bounds.size.width
        self.boundsHeight = bounds.size.height
        self.color = color
        self.ocrText = ocrText
    }
}

// MARK: - Document Bundle

/// A complete document bundle downloaded from reMarkable.
public struct RemarkableDocumentBundle: Sendable {
    public let documentInfo: RemarkableDocumentInfo
    public let pdfData: Data
    public let annotations: [RemarkableRawAnnotation]
    public let metadata: [String: String]

    public init(
        documentInfo: RemarkableDocumentInfo,
        pdfData: Data,
        annotations: [RemarkableRawAnnotation],
        metadata: [String: String]
    ) {
        self.documentInfo = documentInfo
        self.pdfData = pdfData
        self.annotations = annotations
        self.metadata = metadata
    }
}

// MARK: - Device Info

/// Information about the connected reMarkable device.
public struct RemarkableDeviceInfo: Codable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let storageUsed: Int64?
    public let storageTotal: Int64?

    public init(
        deviceID: String,
        deviceName: String,
        storageUsed: Int64? = nil,
        storageTotal: Int64? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.storageUsed = storageUsed
        self.storageTotal = storageTotal
    }

    /// Formatted storage usage string (e.g., "1.2 GB / 8 GB")
    public var formattedStorage: String? {
        guard let used = storageUsed, let total = storageTotal else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: used)) / \(formatter.string(fromByteCount: total))"
    }
}

// MARK: - Conflict Resolution

/// Resolution strategy for annotation conflicts.
public enum ConflictResolution: String, Codable, CaseIterable, Sendable {
    case preferRemarkable = "preferRemarkable"
    case preferLocal = "preferLocal"
    case keepBoth = "keepBoth"
    case ask = "ask"

    public var displayName: String {
        switch self {
        case .preferRemarkable: return "Prefer reMarkable"
        case .preferLocal: return "Prefer imbib"
        case .keepBoth: return "Keep both versions"
        case .ask: return "Ask each time"
        }
    }
}

// MARK: - Sync State

/// Sync state for a reMarkable document.
public enum RemarkableSyncState: String, Codable, CaseIterable, Sendable {
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

// MARK: - Errors

/// Errors that can occur during reMarkable operations.
public enum RemarkableError: LocalizedError, Sendable {
    case notAuthenticated
    case authTimeout
    case authFailed(String)
    case notConfigured(String)
    case noBackendConfigured
    case backendNotFound(String)
    case backendUnavailable(String)
    case noPDFAvailable
    case localFolderNotConfigured
    case localFolderNotFound(String)
    case localFolderNotAccessible
    case documentNotFound(String)
    case dropboxFolderNotFound
    case annotationSyncNotSupported(backend: String)
    case uploadFailed(String)
    case downloadFailed(String)
    case parseFailed(String)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to reMarkable. Please connect your account in Settings."
        case .authTimeout:
            return "Authentication timed out. Please try again."
        case .authFailed(let reason):
            return "Authentication failed: \(reason)"
        case .notConfigured(let reason):
            return "Not configured: \(reason)"
        case .noBackendConfigured:
            return "No reMarkable sync method configured. Please set one up in Settings."
        case .backendNotFound(let id):
            return "Sync backend '\(id)' not found."
        case .backendUnavailable(let id):
            return "Sync backend '\(id)' is not available."
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
        case .dropboxFolderNotFound:
            return "Dropbox reMarkable folder not found."
        case .annotationSyncNotSupported(let backend):
            return "Annotation sync is not supported for the '\(backend)' backend."
        case .uploadFailed(let reason):
            return "Failed to upload document: \(reason)"
        case .downloadFailed(let reason):
            return "Failed to download: \(reason)"
        case .parseFailed(let reason):
            return "Failed to parse reMarkable data: \(reason)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - CGRect Encoding Helpers

/// Helper for encoding CGRect to JSON (since CGRect isn't Codable by default).
public struct CodableRect: Codable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

extension RemarkableRawAnnotation {
    /// Encode bounds to JSON string.
    public var boundsJSONString: String {
        let codable = CodableRect(bounds)
        guard let data = try? JSONEncoder().encode(codable),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    /// Decode bounds from JSON string.
    public static func decodeBounds(from json: String) -> CGRect {
        guard let data = json.data(using: .utf8),
              let codable = try? JSONDecoder().decode(CodableRect.self, from: data)
        else {
            return CGRect(x: 0, y: 0, width: 0, height: 0)
        }
        return codable.cgRect
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the authentication code should be shown to the user.
    static let remarkableShowAuthCode = Notification.Name("remarkableShowAuthCode")

    /// Posted when reMarkable sync state changes.
    static let remarkableSyncStateChanged = Notification.Name("remarkableSyncStateChanged")

    /// Posted when annotations are imported from reMarkable.
    static let remarkableAnnotationsImported = Notification.Name("remarkableAnnotationsImported")
}
