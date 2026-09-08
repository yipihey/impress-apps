//
//  EInkSettingsStore.swift
//  PublicationManagerCore
//
//  User preferences for E-Ink device integration.
//

import Foundation
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "einkSettings")

// MARK: - Settings Store

/// Stores user preferences for E-Ink device integration.
@MainActor
@Observable
public final class EInkSettingsStore {

    // MARK: - Singleton

    public static let shared = EInkSettingsStore()

    // MARK: - Device Settings

    /// The ID of the currently active device.
    @ObservationIgnored
    @AppStorage("eink.activeDeviceID")
    public var activeDeviceID: String?

    /// Configured device settings by device ID.
    public var deviceSettings: [String: EInkDeviceSettings] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "eink.deviceSettings"),
                  let settings = try? JSONDecoder().decode([String: EInkDeviceSettings].self, from: data)
            else { return [:] }
            return settings
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "eink.deviceSettings")
            }
        }
    }

    // MARK: - Device-Specific Settings

    /// Get settings for a specific device.
    public func settings(for deviceID: String) -> EInkDeviceSettings {
        deviceSettings[deviceID] ?? EInkDeviceSettings()
    }

    /// Update settings for a specific device.
    public func updateSettings(for deviceID: String, _ update: (inout EInkDeviceSettings) -> Void) {
        var settings = settings(for: deviceID)
        update(&settings)
        var all = deviceSettings
        all[deviceID] = settings
        deviceSettings = all
    }

    // MARK: - Credential Management

    private let keychainServicePrefix = "com.imbib.eink"

    /// Store a credential for a device in Keychain.
    public func storeCredential(_ value: String, for deviceID: String, key: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let service = "\(keychainServicePrefix).\(deviceID)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Delete any existing
        SecItemDelete(query as CFDictionary)

        // Add new
        var addQuery = query
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EInkError.authFailed("Failed to store credential in Keychain")
        }

        logger.info("Stored credential for device \(deviceID)")
    }

    /// Retrieve a credential for a device from Keychain.
    public func retrieveCredential(for deviceID: String, key: String) -> String? {
        let service = "\(keychainServicePrefix).\(deviceID)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    /// Clear all credentials for a device.
    public func clearCredentials(for deviceID: String) {
        let service = "\(keychainServicePrefix).\(deviceID)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        SecItemDelete(query as CFDictionary)
        logger.info("Cleared credentials for device \(deviceID)")
    }

    /// Clear all E-Ink credentials.
    public func clearAllCredentials() {
        for deviceID in deviceSettings.keys {
            clearCredentials(for: deviceID)
        }
    }

    // MARK: - Computed Properties

    /// Whether any E-Ink device is available.
    public var isAnyDeviceAvailable: Bool {
        activeDeviceID != nil
    }

    /// Display name for the current device.
    public var currentDeviceDisplayName: String? {
        guard let deviceID = activeDeviceID,
              let settings = deviceSettings[deviceID]
        else { return nil }
        return settings.displayName
    }
}

// MARK: - Device Settings

/// Settings for a specific E-Ink device.
public struct EInkDeviceSettings: Codable, Sendable {
    public var deviceType: EInkDeviceType?
    public var syncMethod: EInkSyncMethod?
    public var displayName: String?
    public var isAuthenticated: Bool = false
    public var lastSyncDate: Date?

    /// Local folder path (for folder sync).
    public var localFolderPath: String?

    /// Security-scoped bookmark data for local folder.
    public var localFolderBookmark: Data?

    /// Email address (for Kindle Scribe email sync).
    public var sendToEmail: String?

    public init() {}
}

// Note: `RemarkableSettingsStore` in ReMarkable/ keeps the reMarkable's own
// connection state (cloud pairing, Wi-Fi). The organisation / annotation /
// auto-sync preferences both stores once held live on the device record
// (`imbib/eink-device`, ADR-025); `EInkSettingsMigration` carries the legacy
// `eink.*` keys across once and removes them.
