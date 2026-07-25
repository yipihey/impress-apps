//
//  SyncSettings.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase D): user-facing switch + persisted diagnostics for
//  the CloudKit sync engine.
//
//  Everything lives in the App Group suite (`SharedDefaults.suite`) rather
//  than the app's own defaults: the flag gates a background engine that
//  touches the *shared* store, so a sibling app (and the automation API in
//  Phase E) must be able to read the same answer.
//
//  The flag DEFAULTS OFF and stays off until the user opts in. `UserDefaults`
//  returns `false` for a missing bool key, which is exactly the default we
//  want — no registration needed, and a fresh install can never start syncing
//  on its own.
//

import Foundation
import ImpressKit

/// Persisted settings and diagnostics for CloudKit sync.
public enum SyncSettings {

    private enum Keys {
        static let enabled = "sync.cloudkit.enabled"
        static let lastPush = "sync.cloudkit.lastPushAt"
        static let lastPull = "sync.cloudkit.lastPullAt"
        static let lastError = "sync.cloudkit.lastError"
        static let lastErrorAt = "sync.cloudkit.lastErrorAt"
    }

    /// The CloudKit container this suite syncs through (plan decision 6).
    /// A single custom zone inside its private database holds the whole graph.
    public static let containerIdentifier = "iCloud.com.impress.suite"

    /// The custom zone holding every synced record.
    public static let zoneName = "ImpressGraph"

    // MARK: - Master switch

    /// Whether the user has turned CloudKit sync on. **Default: false.**
    ///
    /// This is the outermost gate in `CloudSyncAvailability` — when false,
    /// nothing else is evaluated and no CloudKit type is ever constructed.
    public static var isEnabled: Bool {
        get { SharedDefaults.suite.bool(forKey: Keys.enabled) }
        set { SharedDefaults.suite.set(newValue, forKey: Keys.enabled) }
    }

    // MARK: - Diagnostics (surfaced in Settings + /api/sync/status)

    /// When the engine last successfully pushed records.
    public static var lastPushAt: Date? {
        get { SharedDefaults.suite.object(forKey: Keys.lastPush) as? Date }
        set { SharedDefaults.suite.set(newValue, forKey: Keys.lastPush) }
    }

    /// When the engine last successfully applied a fetched batch.
    public static var lastPullAt: Date? {
        get { SharedDefaults.suite.object(forKey: Keys.lastPull) as? Date }
        set { SharedDefaults.suite.set(newValue, forKey: Keys.lastPull) }
    }

    /// The most recent sync error, human-readable, or nil if the last cycle
    /// was clean. Cleared on the next success.
    public static var lastError: String? {
        get { SharedDefaults.suite.string(forKey: Keys.lastError) }
        set { SharedDefaults.suite.set(newValue, forKey: Keys.lastError) }
    }

    /// When `lastError` was recorded.
    public static var lastErrorAt: Date? {
        get { SharedDefaults.suite.object(forKey: Keys.lastErrorAt) as? Date }
        set { SharedDefaults.suite.set(newValue, forKey: Keys.lastErrorAt) }
    }

    /// Record a failure for the Settings pane.
    public static func recordError(_ message: String) {
        lastError = message
        lastErrorAt = Date()
    }

    /// Clear the sticky error after a clean cycle.
    public static func clearError() {
        lastError = nil
        lastErrorAt = nil
    }

    /// Wipe every diagnostic (used when sync is turned off or the iCloud
    /// account changes). Never touches user data — only these breadcrumbs.
    public static func resetDiagnostics() {
        let suite = SharedDefaults.suite
        for key in [Keys.lastPush, Keys.lastPull, Keys.lastError, Keys.lastErrorAt] {
            suite.removeObject(forKey: key)
        }
    }
}
