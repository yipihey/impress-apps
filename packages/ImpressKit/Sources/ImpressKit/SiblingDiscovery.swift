import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Discovers which sibling apps are installed and/or running.
public struct SiblingDiscovery: Sendable {
    public static let shared = SiblingDiscovery()

    private init() {}

    /// The unified app group identifier shared by all Impress suite apps.
    public static let suiteGroupID = "group.com.impress.suite"

    /// Checks whether a sibling app is installed on this device.
    public func isInstalled(_ app: SiblingApp) -> Bool {
        #if os(macOS)
        return macOSIsInstalled(app)
        #elseif os(iOS)
        return iOSIsInstalled(app)
        #else
        return false
        #endif
    }

    /// Returns all currently installed sibling apps.
    public func installedSiblings() -> [SiblingApp] {
        SiblingApp.allCases.filter { isInstalled($0) }
    }

    /// Returns all sibling apps except the given one (useful for "other apps" lists).
    public func otherSiblings(excluding current: SiblingApp) -> [SiblingApp] {
        SiblingApp.allCases.filter { $0 != current }
    }

    /// Determines the best IPC channel for communicating with a sibling app.
    ///
    /// Prefers HTTP when the app is running (supports request/response).
    /// Falls back to URL scheme (can launch the app but no response).
    public func bestChannel(for app: SiblingApp) -> IPCChannel {
        // HTTP is best when app is running — supports request/response
        if isRunning(app) {
            return .http(port: app.httpPort)
        }
        // URL scheme can launch the app (but no response)
        if isInstalled(app) {
            return .urlScheme
        }
        // Try HTTP anyway (development/debug)
        return .http(port: app.httpPort)
    }

    /// Checks if a sibling app appears to be running (via heartbeat file).
    public func isRunning(_ app: SiblingApp) -> Bool {
        let heartbeatURL = SharedContainer.notificationsDirectory
            .appendingPathComponent("heartbeat.\(app.rawValue).json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: heartbeatURL.path),
              let modified = attributes[.modificationDate] as? Date else {
            return false
        }
        // Consider running if heartbeat was within last 30 seconds
        return Date().timeIntervalSince(modified) < 30
    }

    // MARK: - Platform-specific

    #if os(macOS)
    private func macOSIsInstalled(_ app: SiblingApp) -> Bool {
        let workspace = NSWorkspace.shared
        return workspace.urlForApplication(withBundleIdentifier: app.bundleID) != nil
    }
    #endif

    #if os(iOS)
    private func iOSIsInstalled(_ app: SiblingApp) -> Bool {
        guard let url = URL(string: "\(app.urlScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
    #endif
}

/// Represents the available inter-process communication channels.
public enum IPCChannel: Sendable, Equatable {
    /// Direct URL scheme invocation (launches or foregrounds the app).
    case urlScheme
    /// App Intent invocation (works even if app is in background).
    case appIntent
    /// HTTP API (development/debug channel, requires server to be running).
    case http(port: UInt16)
}
