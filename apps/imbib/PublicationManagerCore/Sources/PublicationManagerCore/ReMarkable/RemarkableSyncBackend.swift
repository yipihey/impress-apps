//
//  RemarkableSyncBackend.swift
//  PublicationManagerCore
//
//  Protocol defining the interface for reMarkable sync backends.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation

// MARK: - Backend Protocol

/// Protocol for different reMarkable sync backends.
///
/// Implementations include:
/// - `RemarkableCloudBackend`: Official cloud API (requires authentication)
/// - `RemarkableLocalBackend`: Local folder sync (USB or file system)
/// - `RemarkableDropboxBackend`: Dropbox integration bridge
public protocol RemarkableSyncBackend: Actor {

    /// Unique identifier for this backend.
    var backendID: String { get }

    /// Human-readable display name.
    var displayName: String { get }

    // MARK: - Availability & Authentication

    /// Check if this backend is currently available (network, folder exists, etc.).
    func isAvailable() async -> Bool

    /// Authenticate with the backend (may involve user interaction).
    func authenticate() async throws

    /// Disconnect from the backend.
    func disconnect() async

    // MARK: - Document Operations

    /// List all documents on the device.
    func listDocuments() async throws -> [RemarkableDocumentInfo]

    /// List all folders on the device.
    func listFolders() async throws -> [RemarkableFolderInfo]

    /// Upload a PDF to the device.
    ///
    /// - Parameters:
    ///   - data: PDF file data
    ///   - filename: Display name for the document
    ///   - parentFolder: Optional folder ID to place the document in
    /// - Returns: The ID of the created document
    func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String

    /// Download annotations for a document.
    ///
    /// - Parameter documentID: The reMarkable document ID
    /// - Returns: Array of raw annotations for conversion
    func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation]

    /// Download a complete document bundle (PDF + annotations + metadata).
    ///
    /// - Parameter documentID: The reMarkable document ID
    /// - Returns: The complete document bundle
    func downloadDocument(documentID: String) async throws -> RemarkableDocumentBundle

    /// Create a folder on the device.
    ///
    /// - Parameters:
    ///   - name: Folder name
    ///   - parent: Optional parent folder ID (nil for root)
    /// - Returns: The ID of the created folder
    func createFolder(name: String, parent: String?) async throws -> String

    /// Delete a document from the device.
    ///
    /// - Parameter documentID: The reMarkable document ID
    func deleteDocument(documentID: String) async throws

    /// Get device information (name, storage, etc.).
    func getDeviceInfo() async throws -> RemarkableDeviceInfo
}

// MARK: - Backend Manager

/// Manages available reMarkable sync backends.
@MainActor @Observable
public final class RemarkableBackendManager {

    // MARK: - Singleton

    public static let shared = RemarkableBackendManager()

    // MARK: - State

    /// All registered backends.
    public private(set) var availableBackends: [any RemarkableSyncBackend] = []

    /// The currently active backend.
    public private(set) var activeBackend: (any RemarkableSyncBackend)?

    // MARK: - Initialization

    private init() {
        // Register built-in backends
        // Note: Actual backend instances are created lazily when needed
    }

    // MARK: - Backend Management

    /// Register a backend for use.
    public func registerBackend(_ backend: any RemarkableSyncBackend) {
        availableBackends.append(backend)
    }

    /// Select a backend by its ID.
    public func selectBackend(_ backendID: String) async throws {
        var foundBackend: (any RemarkableSyncBackend)?

        for backend in availableBackends {
            let id = await backend.backendID
            if id == backendID {
                foundBackend = backend
                break
            }
        }

        guard let backend = foundBackend else {
            throw RemarkableError.backendNotFound(backendID)
        }

        guard await backend.isAvailable() else {
            throw RemarkableError.backendUnavailable(backendID)
        }

        activeBackend = backend
        RemarkableSettingsStore.shared.activeBackendID = backendID
    }

    /// Get the active backend, throwing if none is configured.
    public func requireActiveBackend() throws -> any RemarkableSyncBackend {
        guard let backend = activeBackend else {
            throw RemarkableError.noBackendConfigured
        }
        return backend
    }

    /// Check if any backend is available and authenticated.
    public var isAnyBackendAvailable: Bool {
        activeBackend != nil
    }
}
