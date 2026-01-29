//
//  RemarkableSettingsStore.swift
//  PublicationManagerCore
//
//  User preferences for reMarkable integration.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableSettings")

// MARK: - Settings Store

/// Stores user preferences for reMarkable integration.
@MainActor @Observable
public final class RemarkableSettingsStore {

    // MARK: - Singleton

    public static let shared = RemarkableSettingsStore()

    // MARK: - Connection Settings

    /// The ID of the currently active sync backend.
    @ObservationIgnored
    @AppStorage("remarkable.activeBackendID")
    public var activeBackendID: String = "cloud"

    /// Whether the user is authenticated with reMarkable Cloud.
    @ObservationIgnored
    @AppStorage("remarkable.isAuthenticated")
    public var isAuthenticated: Bool = false

    /// The name of the connected device.
    @ObservationIgnored
    @AppStorage("remarkable.deviceName")
    public var deviceName: String?

    /// The ID of the connected device.
    @ObservationIgnored
    @AppStorage("remarkable.deviceID")
    public var deviceID: String?

    // MARK: - Local Folder Backend

    /// Path to the local reMarkable folder (for USB/local sync).
    @ObservationIgnored
    @AppStorage("remarkable.localFolderPath")
    public var localFolderPath: String?

    /// Security-scoped bookmark for the local folder.
    public var localFolderBookmark: Data? {
        get {
            UserDefaults.standard.data(forKey: "remarkable.localFolderBookmark")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "remarkable.localFolderBookmark")
        }
    }

    // MARK: - Sync Options

    /// Whether automatic sync is enabled.
    @ObservationIgnored
    @AppStorage("remarkable.autoSyncEnabled")
    public var autoSyncEnabled: Bool = true

    /// Sync interval in seconds.
    @ObservationIgnored
    @AppStorage("remarkable.syncInterval")
    public var syncInterval: TimeInterval = 3600  // 1 hour

    /// Conflict resolution strategy.
    @ObservationIgnored
    @AppStorage("remarkable.conflictResolution")
    private var conflictResolutionRaw: String = ConflictResolution.ask.rawValue

    public var conflictResolution: ConflictResolution {
        get { ConflictResolution(rawValue: conflictResolutionRaw) ?? .ask }
        set { conflictResolutionRaw = newValue.rawValue }
    }

    // MARK: - Organization Options

    /// Whether to create folders on reMarkable based on imbib collections.
    @ObservationIgnored
    @AppStorage("remarkable.createFoldersByCollection")
    public var createFoldersByCollection: Bool = true

    /// Whether to create a "Reading Queue" folder for Inbox papers.
    @ObservationIgnored
    @AppStorage("remarkable.useReadingQueueFolder")
    public var useReadingQueueFolder: Bool = true

    /// Name of the root folder on reMarkable for imbib documents.
    @ObservationIgnored
    @AppStorage("remarkable.rootFolderName")
    public var rootFolderName: String = "imbib"

    // MARK: - Annotation Options

    /// Whether to import highlights from reMarkable.
    @ObservationIgnored
    @AppStorage("remarkable.importHighlights")
    public var importHighlights: Bool = true

    /// Whether to import handwritten ink notes from reMarkable.
    @ObservationIgnored
    @AppStorage("remarkable.importInkNotes")
    public var importInkNotes: Bool = true

    /// Whether to run OCR on handwritten notes.
    @ObservationIgnored
    @AppStorage("remarkable.enableOCR")
    public var enableOCR: Bool = true

    // MARK: - Credential Management

    private let keychainService = "com.imbib.remarkable"
    private let keychainAccount = "deviceToken"

    /// Store the reMarkable authentication token in Keychain.
    public func storeToken(_ token: String) throws {
        let data = token.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]

        // Delete any existing token
        SecItemDelete(query as CFDictionary)

        // Add the new token
        var addQuery = query
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RemarkableError.authFailed("Failed to store token in Keychain")
        }

        logger.info("Stored reMarkable token in Keychain")
    }

    /// Retrieve the reMarkable authentication token from Keychain.
    public func retrieveToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            if status == errSecItemNotFound {
                return nil
            }
            logger.warning("Failed to retrieve token from Keychain: \(status)")
            return nil
        }

        return token
    }

    /// Clear all reMarkable credentials and reset connection state.
    public func clearCredentials() {
        // Delete from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)

        // Reset connection state
        isAuthenticated = false
        deviceName = nil
        deviceID = nil

        logger.info("Cleared reMarkable credentials")
    }

    // MARK: - Computed Properties

    /// Whether reMarkable integration is available.
    public var isAvailable: Bool {
        isAuthenticated || !localFolderPath.isNilOrEmpty
    }

    /// Display name for the current backend.
    public var currentBackendDisplayName: String {
        switch activeBackendID {
        case "cloud": return "reMarkable Cloud"
        case "local": return "Local Folder"
        case "dropbox": return "Dropbox"
        default: return "Unknown"
        }
    }
}

// MARK: - Optional String Extension

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}
