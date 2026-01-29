//
//  EInkDevice.swift
//  PublicationManagerCore
//
//  Protocol defining the interface for E-Ink device backends.
//  Supports reMarkable, Supernote, and Kindle Scribe.
//

import Foundation

// MARK: - Device Protocol

/// Protocol for E-Ink device sync backends.
///
/// Implementations include:
/// - `RemarkableCloudDevice`: reMarkable Cloud API
/// - `RemarkableLocalDevice`: reMarkable local folder sync
/// - `SupernoteDevice`: Supernote folder/cloud sync
/// - `KindleScribeDevice`: Kindle Scribe USB/email sync
public protocol EInkDevice: Actor {

    /// Unique identifier for this device instance.
    var deviceID: String { get }

    /// Human-readable display name.
    var displayName: String { get }

    /// The type of E-Ink device.
    var deviceType: EInkDeviceType { get }

    /// The sync method used by this device.
    var syncMethod: EInkSyncMethod { get }

    /// Capabilities of this device backend.
    var capabilities: EInkSyncCapabilities { get }

    // MARK: - Availability & Authentication

    /// Check if this device is currently available.
    func isAvailable() async -> Bool

    /// Authenticate with the device (may involve user interaction).
    func authenticate() async throws

    /// Disconnect from the device.
    func disconnect() async

    // MARK: - Document Operations

    /// List all documents on the device.
    func listDocuments() async throws -> [EInkDocumentInfo]

    /// List all folders on the device.
    func listFolders() async throws -> [EInkFolderInfo]

    /// Upload a PDF to the device.
    ///
    /// - Parameters:
    ///   - data: PDF file data
    ///   - filename: Display name for the document
    ///   - parentFolder: Optional folder ID to place the document in
    /// - Returns: The ID of the created document
    func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String

    /// Download raw annotation data for a document.
    ///
    /// - Parameter documentID: The document ID on the device
    /// - Returns: Raw annotation data in device-native format
    func downloadAnnotations(documentID: String) async throws -> Data

    /// Download a complete document bundle (PDF + annotations + metadata).
    ///
    /// - Parameter documentID: The document ID on the device
    /// - Returns: The complete document bundle
    func downloadDocument(documentID: String) async throws -> EInkDocumentBundle

    /// Create a folder on the device.
    ///
    /// - Parameters:
    ///   - name: Folder name
    ///   - parent: Optional parent folder ID (nil for root)
    /// - Returns: The ID of the created folder
    func createFolder(name: String, parent: String?) async throws -> String

    /// Delete a document from the device.
    ///
    /// - Parameter documentID: The document ID on the device
    func deleteDocument(documentID: String) async throws

    /// Get device information (name, storage, etc.).
    func getDeviceInfo() async throws -> EInkDeviceInfo
}

// MARK: - Default Implementations

public extension EInkDevice {
    /// Default: folders not supported.
    func listFolders() async throws -> [EInkFolderInfo] {
        return []
    }

    /// Default: folder creation not supported.
    func createFolder(name: String, parent: String?) async throws -> String {
        throw EInkError.unsupportedSyncMethod(syncMethod)
    }

    /// Default: deletion not supported.
    func deleteDocument(documentID: String) async throws {
        throw EInkError.unsupportedSyncMethod(syncMethod)
    }
}

// MARK: - Device Manager

/// Manages available E-Ink devices.
@MainActor
@Observable
public final class EInkDeviceManager {

    // MARK: - Singleton

    public static let shared = EInkDeviceManager()

    // MARK: - State

    /// All registered devices.
    public private(set) var registeredDevices: [any EInkDevice] = []

    /// The currently active device.
    public private(set) var activeDevice: (any EInkDevice)?

    /// Device ID to device mapping for fast lookup.
    private var deviceIdMap: [String: any EInkDevice] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Device Management

    /// Register a device for use.
    public func registerDevice(_ device: any EInkDevice) async {
        let deviceID = await device.deviceID
        // Avoid duplicates
        if deviceIdMap[deviceID] == nil {
            registeredDevices.append(device)
            deviceIdMap[deviceID] = device
        }
    }

    /// Unregister a device.
    public func unregisterDevice(_ deviceID: String) async {
        if let activeDeviceID = await activeDevice?.deviceID,
           activeDeviceID == deviceID {
            activeDevice = nil
        }
        deviceIdMap.removeValue(forKey: deviceID)
        var toRemove: [Int] = []
        for (index, device) in registeredDevices.enumerated() {
            if await device.deviceID == deviceID {
                toRemove.append(index)
            }
        }
        for index in toRemove.reversed() {
            registeredDevices.remove(at: index)
        }
    }

    /// Select a device by its ID.
    public func selectDevice(_ deviceID: String) async throws {
        guard let device = deviceIdMap[deviceID] else {
            throw EInkError.deviceNotFound(deviceID)
        }

        guard await device.isAvailable() else {
            throw EInkError.deviceUnavailable(deviceID)
        }

        activeDevice = device
        EInkSettingsStore.shared.activeDeviceID = deviceID
    }

    /// Get the active device, throwing if none is configured.
    public func requireActiveDevice() throws -> any EInkDevice {
        guard let device = activeDevice else {
            throw EInkError.noDeviceConfigured
        }
        return device
    }

    /// Check if any device is available and configured.
    public var isAnyDeviceAvailable: Bool {
        activeDevice != nil
    }

    /// Get all devices of a specific type.
    public func devices(ofType type: EInkDeviceType) async -> [any EInkDevice] {
        var result: [any EInkDevice] = []
        for device in registeredDevices {
            if await device.deviceType == type {
                result.append(device)
            }
        }
        return result
    }

    /// Find a device by ID.
    public func device(withID id: String) -> (any EInkDevice)? {
        deviceIdMap[id]
    }
}

// Note: The existing RemarkableSyncBackend protocol and RemarkableBackendManager
// in the ReMarkable/ directory continue to work for reMarkable-specific backends.
// This EInkDevice protocol provides a unified interface for multi-device support
// and can be implemented by adapters wrapping existing backends.
