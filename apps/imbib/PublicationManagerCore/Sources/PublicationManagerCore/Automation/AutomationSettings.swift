//
//  AutomationSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
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

    /// Default settings (automation disabled for security)
    public static let `default` = AutomationSettings(
        isEnabled: false,
        logRequests: true
    )

    public init(
        isEnabled: Bool = false,
        logRequests: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.logRequests = logRequests
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
