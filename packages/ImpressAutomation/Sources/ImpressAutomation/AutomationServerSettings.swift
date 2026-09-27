//
//  AutomationServerSettings.swift
//  ImpressAutomation
//
//  The one settings shape every app's automation server is configured from
//  (P0, SEC-4). Until 2026-09-26 only imbib passed `allowNetworkAccess` and
//  `authToken` into `HTTPServerConfiguration`; the other five apps hard-coded
//  `logRequests: true` and left the network fields at their defaults, so the
//  network bearer existed in one app and the shared settings section showed
//  no network controls at all. Now the section edits these fields, the loader
//  reads them, and `HTTPServerConfiguration.init(settings:)` is the only way
//  an app builds its configuration — the same six keys in every app.
//
//  imbib keeps its own `AutomationSettings` record (it predates this and has
//  more in it) and maps it onto this struct; the other apps read the
//  `UserDefaults` keys below, which `SimpleAutomationSettingsView` writes.
//

import Foundation

/// What an app's automation server is configured from.
public struct AutomationServerSettings: Sendable, Equatable {
    /// Whether the HTTP server runs at all.
    public var httpEnabled: Bool
    /// The port to bind. `0` lets the system choose (tests).
    public var port: UInt16
    /// Log every request at info level.
    public var logRequests: Bool
    /// Accept non-loopback peers (the user's tailnet). Requires BOTH a
    /// network token and an explicit bind address, or the server refuses to
    /// start (SEC-5).
    public var allowNetworkAccess: Bool
    /// The bearer a non-loopback peer must present.
    public var networkAuthToken: String?
    /// The interface address to bind in network mode — the tailnet address,
    /// spelled as the caller will dial it. Never "all interfaces".
    public var networkBindAddress: String?

    public init(
        httpEnabled: Bool = true,
        port: UInt16,
        logRequests: Bool = true,
        allowNetworkAccess: Bool = false,
        networkAuthToken: String? = nil,
        networkBindAddress: String? = nil
    ) {
        self.httpEnabled = httpEnabled
        self.port = port
        self.logRequests = logRequests
        self.allowNetworkAccess = allowNetworkAccess
        self.networkAuthToken = networkAuthToken
        self.networkBindAddress = networkBindAddress
    }

    /// The `UserDefaults` keys the shared settings section reads and writes.
    /// `httpAutomationEnabled` and `httpAutomationPort` are the two every
    /// app already used (and registers defaults for); the rest are new.
    public enum Keys {
        public static let enabled = "httpAutomationEnabled"
        public static let port = "httpAutomationPort"
        public static let logRequests = "httpAutomationLogRequests"
        public static let allowNetworkAccess = "httpAutomationAllowNetworkAccess"
        public static let networkAuthToken = "httpAutomationNetworkAuthToken"
        public static let networkBindAddress = "httpAutomationNetworkBindAddress"
    }

    /// Read the settings from `defaults`.
    ///
    /// - `port`: the saved or launch-argument `httpAutomationPort` when it is
    ///   a valid port, else `defaultPort` (the app's row of the port table).
    ///   The launch-argument form (`-httpAutomationPort 23181`) is how a
    ///   second instance runs beside the user's without taking its socket.
    /// - `httpEnabled` and `logRequests` default to true when the key was
    ///   never written, which is what every app's registered defaults say.
    public static func load(
        from defaults: UserDefaults = .standard,
        defaultPort: UInt16
    ) -> AutomationServerSettings {
        let savedPort = defaults.integer(forKey: Keys.port)
        let port = (1...Int(UInt16.max)).contains(savedPort) ? UInt16(savedPort) : defaultPort
        return AutomationServerSettings(
            httpEnabled: defaults.object(forKey: Keys.enabled) as? Bool ?? true,
            port: port,
            logRequests: defaults.object(forKey: Keys.logRequests) as? Bool ?? true,
            allowNetworkAccess: defaults.bool(forKey: Keys.allowNetworkAccess),
            networkAuthToken: defaults.string(forKey: Keys.networkAuthToken),
            networkBindAddress: defaults.string(forKey: Keys.networkBindAddress)
        )
    }

    /// Apply process-only overrides to an app's legacy settings record.
    /// Saved values stay in that record; a proof's port never persists.
    public func applyingLaunchOverrides(
        from defaults: UserDefaults = .standard
    ) -> AutomationServerSettings {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var result = self
        if arguments[Keys.port] != nil {
            result.port = Self.load(from: defaults, defaultPort: port).port
        }
        if arguments[Keys.enabled] != nil {
            result.httpEnabled = defaults.bool(forKey: Keys.enabled)
        }
        if arguments[Keys.logRequests] != nil {
            result.logRequests = defaults.bool(forKey: Keys.logRequests)
        }
        return result
    }
}

extension HTTPServerConfiguration {
    /// The configuration every app builds: from the shared settings, plus the
    /// app's logger subsystem.
    public init(
        settings: AutomationServerSettings,
        loggerSubsystem: String,
        loggerCategory: String = "httpServer"
    ) {
        self.init(
            port: settings.port,
            loggerSubsystem: loggerSubsystem,
            loggerCategory: loggerCategory,
            logRequests: settings.logRequests,
            allowNetworkAccess: settings.allowNetworkAccess,
            authToken: settings.networkAuthToken,
            bindAddress: settings.networkBindAddress
        )
    }
}
