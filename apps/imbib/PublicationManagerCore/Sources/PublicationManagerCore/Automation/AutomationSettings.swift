//
//  AutomationSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import ImpressAutomation
import ImpressKit
import OSLog

private let automationLogger = Logger(subsystem: "com.imbib.app", category: "automation")

// MARK: - Automation Settings

/// Settings for the automation API.
///
/// Controls whether external programs and AI agents can control the app via URL schemes.
public struct AutomationSettings: Codable, Equatable, Sendable {
    /// Whether the automation API is enabled
    public var isEnabled: Bool

    /// Whether to log automation requests to the console
    public var logRequests: Bool

    /// Whether the HTTP server is enabled for browser extension integration
    public var isHTTPServerEnabled: Bool

    /// Port number for the HTTP server (default: `SiblingApp.imbib.httpPort`)
    public var httpServerPort: UInt16

    /// Opt-in: accept non-loopback peers (the user's tailnet) on the HTTP
    /// server, gated by `networkAuthToken`. Default OFF — loopback only.
    public var allowNetworkAccess: Bool

    /// Bearer token required from non-loopback peers. Generated on first
    /// enable; regenerable in Settings. nil = never enabled.
    public var networkAuthToken: String?

    /// Default settings (automation enabled for MCP integration)
    /// HTTP server only accepts localhost connections for security.
    public static let `default` = AutomationSettings(
        isEnabled: true,
        logRequests: true,
        isHTTPServerEnabled: true,
        httpServerPort: SiblingApp.imbib.httpPort
    )

    public init(
        isEnabled: Bool = true,
        logRequests: Bool = true,
        isHTTPServerEnabled: Bool = true,
        httpServerPort: UInt16 = SiblingApp.imbib.httpPort,
        allowNetworkAccess: Bool = false,
        networkAuthToken: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.logRequests = logRequests
        self.isHTTPServerEnabled = isHTTPServerEnabled
        self.httpServerPort = httpServerPort
        self.allowNetworkAccess = allowNetworkAccess
        self.networkAuthToken = networkAuthToken
    }

    /// Lenient decoding: every field falls back to its default when absent.
    /// Without this, ADDING a field made the store's `try? decode` fail on
    /// previously persisted JSON and silently reset ALL settings to
    /// `.default` (a pre-existing footgun this feature would have tripped —
    /// losing the user's port override on upgrade).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutomationSettings.default
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        self.logRequests = try c.decodeIfPresent(Bool.self, forKey: .logRequests) ?? d.logRequests
        self.isHTTPServerEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .isHTTPServerEnabled) ?? d.isHTTPServerEnabled
        self.httpServerPort =
            try c.decodeIfPresent(UInt16.self, forKey: .httpServerPort) ?? d.httpServerPort
        self.allowNetworkAccess =
            try c.decodeIfPresent(Bool.self, forKey: .allowNetworkAccess) ?? false
        self.networkAuthToken = try c.decodeIfPresent(String.self, forKey: .networkAuthToken)
    }
}

// MARK: - Automation Settings Store

/// Actor for persisting automation settings to UserDefaults.
public actor AutomationSettingsStore {
    public static let shared = AutomationSettingsStore()

    private let defaults = UserDefaults.standard
    private let settingsKey = "automation.settings"

    /// In-memory cache for fast access
    private var cachedSettings: AutomationSettings?

    private init() {}

    /// Get current settings
    public var settings: AutomationSettings {
        get async {
            if let cached = cachedSettings {
                return cached
            }
            let loaded = loadFromDefaults()
            cachedSettings = loaded
            return loaded
        }
    }

    /// Update settings
    public func update(_ settings: AutomationSettings) async {
        cachedSettings = settings
        saveToDefaults(settings)
        automationLogger.info("Automation settings updated: enabled=\(settings.isEnabled), logging=\(settings.logRequests)")
    }

    /// Check if automation is enabled
    public var isEnabled: Bool {
        get async {
            await settings.isEnabled
        }
    }

    /// Check if logging is enabled
    public var shouldLog: Bool {
        get async {
            await settings.logRequests
        }
    }

    /// Alias for shouldLog (for consistency with iOS settings view)
    public var isLoggingEnabled: Bool {
        get async {
            await settings.logRequests
        }
    }

    /// Enable or disable automation
    public func setEnabled(_ enabled: Bool) async {
        var current = await settings
        current.isEnabled = enabled
        await update(current)
    }

    /// Enable or disable logging
    public func setLoggingEnabled(_ enabled: Bool) async {
        var current = await settings
        current.logRequests = enabled
        await update(current)
    }

    /// Check if HTTP server is enabled
    public var isHTTPServerEnabled: Bool {
        get async {
            await settings.isHTTPServerEnabled
        }
    }

    /// Get HTTP server port
    public var httpServerPort: UInt16 {
        get async {
            await settings.httpServerPort
        }
    }

    /// Enable or disable HTTP server
    public func setHTTPServerEnabled(_ enabled: Bool) async {
        var current = await settings
        current.isHTTPServerEnabled = enabled
        await update(current)
    }

    /// Set HTTP server port
    public func setHTTPServerPort(_ port: UInt16) async {
        var current = await settings
        current.httpServerPort = port
        await update(current)
    }

    /// Whether non-loopback (tailnet) access is enabled.
    public var allowNetworkAccess: Bool {
        get async { await settings.allowNetworkAccess }
    }

    /// The network bearer token, if one has ever been generated.
    public var networkAuthToken: String? {
        get async { await settings.networkAuthToken }
    }

    /// Enable/disable network access. First enable generates a token if none
    /// exists yet. Returns the active token when enabling.
    @discardableResult
    public func setAllowNetworkAccess(_ enabled: Bool) async -> String? {
        var current = await settings
        current.allowNetworkAccess = enabled
        if enabled && (current.networkAuthToken ?? "").isEmpty {
            current.networkAuthToken = ImpressAutomation.HTTPAuthPolicy.generateToken()
        }
        await update(current)
        return current.networkAuthToken
    }

    /// Replace the network token with a fresh one (invalidates the old one
    /// immediately on the next server restart).
    public func regenerateNetworkToken() async -> String {
        var current = await settings
        let token = ImpressAutomation.HTTPAuthPolicy.generateToken()
        current.networkAuthToken = token
        await update(current)
        return token
    }

    /// Reset settings to defaults (for testing or first-run reset)
    public func reset() {
        defaults.removeObject(forKey: settingsKey)
        cachedSettings = nil
        automationLogger.info("Automation settings reset to defaults")
    }

    // MARK: - Persistence

    private func loadFromDefaults() -> AutomationSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AutomationSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    private func saveToDefaults(_ settings: AutomationSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }
}

// MARK: - Automation Result

/// Result of executing an automation command.
public struct AutomationResult: Codable, Sendable {
    /// Whether the command succeeded
    public let success: Bool

    /// The command that was executed
    public let command: String

    /// Error message if the command failed
    public let error: String?

    /// Result data (command-specific)
    public let result: [String: AnyCodable]?

    public init(
        success: Bool,
        command: String,
        error: String? = nil,
        result: [String: AnyCodable]? = nil
    ) {
        self.success = success
        self.command = command
        self.error = error
        self.result = result
    }

    /// Create a success result
    public static func success(command: String, result: [String: AnyCodable]? = nil) -> AutomationResult {
        AutomationResult(success: true, command: command, result: result)
    }

    /// Create an error result
    public static func failure(command: String, error: String) -> AutomationResult {
        AutomationResult(success: false, command: command, error: error)
    }
}

// MARK: - AnyCodable for Flexible JSON Results

/// Type-erased Codable wrapper for arbitrary JSON values.
public struct AnyCodable: Codable, Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AnyCodable"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Cannot encode value of type \(type(of: value))"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }
}
