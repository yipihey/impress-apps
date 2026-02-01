//
//  SyncedSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import OSLog

/// Keys for synced settings stored in iCloud
public enum SyncedSettingsKey: String, CaseIterable {
    // PDF Settings
    case pdfSourcePriority = "sync.pdf.sourcePriority"
    case pdfProxyURL = "sync.pdf.proxyURL"
    case pdfProxyEnabled = "sync.pdf.proxyEnabled"
    case pdfAutoDownloadEnabled = "sync.pdf.autoDownloadEnabled"
    case pdfDarkModeEnabled = "sync.pdf.darkModeEnabled"

    // iOS PDF Sync Settings
    // When true, all PDFs are downloaded to iOS. When false (default), PDFs are on-demand only.
    case iosSyncAllPDFs = "sync.ios.syncAllPDFs"

    // Inbox Settings
    case inboxAgeLimit = "sync.inbox.ageLimit"
    case inboxSaveLibraryID = "sync.inbox.saveLibraryID"
    // Note: Muted items are stored in Core Data (CDMutedItem) and sync via CloudKit

    // Smart Search Settings
    case smartSearchMaxResults = "sync.smartSearch.maxResults"

    // Enrichment Settings
    case enrichmentPreferredSource = "sync.enrichment.preferredSource"
    case enrichmentSourcePriority = "sync.enrichment.sourcePriority"
    case enrichmentAutoSyncEnabled = "sync.enrichment.autoSyncEnabled"
    case enrichmentRefreshIntervalDays = "sync.enrichment.refreshIntervalDays"

    // Quick Annotation Settings
    case quickAnnotationFields = "sync.quickAnnotation.fields"

    // Import/Export Settings (excluding openPDFExternally which is device-specific)
    case importAutoGenerateCiteKeys = "sync.import.autoGenerateCiteKeys"
    case importDefaultEntryType = "sync.import.defaultEntryType"
    case exportPreserveRawBibTeX = "sync.export.preserveRawBibTeX"

    // Cite Key Format Settings
    case citeKeyFormatPreset = "sync.citeKey.preset"
    case citeKeyFormatCustom = "sync.citeKey.customFormat"
    case citeKeyFormatLowercase = "sync.citeKey.lowercase"

    // Recommendation Settings (ADR-020)
    case recommendationEnabled = "sync.recommendation.enabled"
    case recommendationWeights = "sync.recommendation.weights"
    case recommendationSerendipityFrequency = "sync.recommendation.serendipityFrequency"
    case recommendationDecayDays = "sync.recommendation.decayDays"
    case recommendationReRankThrottleMinutes = "sync.recommendation.reRankThrottleMinutes"
    case recommendationEngineType = "sync.recommendation.engineType"

    // Onboarding Settings
    case onboardingCompletedVersion = "sync.onboarding.completedVersion"

    // Exploration Settings
    case explorationRetention = "sync.exploration.retention"
}

/// Notification posted when synced settings change from another device
public extension Notification.Name {
    static let syncedSettingsDidChange = Notification.Name("syncedSettingsDidChange")
}

/// Actor that manages iCloud-synced settings using NSUbiquitousKeyValueStore.
///
/// This provides a simple key-value store that syncs across devices via iCloud.
/// Settings stored here will be available on all devices signed into the same iCloud account.
///
/// ## Usage
/// ```swift
/// // Write a setting
/// SyncedSettingsStore.shared.set("value", forKey: .pdfSourcePriority)
///
/// // Read a setting
/// let value = SyncedSettingsStore.shared.string(forKey: .pdfSourcePriority)
/// ```
///
/// ## Sync Behavior
/// - Changes are pushed to iCloud automatically
/// - Changes from other devices trigger `syncedSettingsDidChange` notification
/// - Initial sync happens on first access
///
/// ## UI Testing Mode
/// When `--uitesting` launch argument is present, uses local UserDefaults instead
/// of iCloud to ensure test isolation and reproducibility.
///
/// ## Thread Safety
/// - NSUbiquitousKeyValueStore is thread-safe, similar to UserDefaults
/// - This class can be called from any actor context
public final class SyncedSettingsStore: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = SyncedSettingsStore()

    // MARK: - Properties

    /// The backing store - either iCloud or local UserDefaults depending on environment
    private let store: NSUbiquitousKeyValueStore?
    private let localStore: UserDefaults?
    private let isUITesting: Bool
    private var observer: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        self.isUITesting = UITestingEnvironment.isUITesting

        if isUITesting {
            // Use isolated local UserDefaults for UI testing
            self.store = nil
            self.localStore = UserDefaults.forCurrentEnvironment
            Logger.settings.info("SyncedSettingsStore initialized in UI testing mode (local storage)")
        } else {
            // Use iCloud sync for production
            self.store = NSUbiquitousKeyValueStore.default
            self.localStore = nil
            setupObserver()
            // Trigger initial sync
            store?.synchronize()
            Logger.settings.info("SyncedSettingsStore initialized (iCloud sync)")
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Observer

    private func setupObserver() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            self?.handleExternalChange(notification)
        }
    }

    private func handleExternalChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }

        let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []

        switch reason {
        case NSUbiquitousKeyValueStoreServerChange:
            Logger.settings.info("Synced settings changed from server: \(changedKeys)")
        case NSUbiquitousKeyValueStoreInitialSyncChange:
            Logger.settings.info("Initial sync completed: \(changedKeys)")
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            Logger.settings.warning("iCloud quota exceeded for settings sync")
        case NSUbiquitousKeyValueStoreAccountChange:
            Logger.settings.info("iCloud account changed")
        default:
            Logger.settings.debug("Unknown sync change reason: \(reason)")
        }

        // Post notification for interested parties to refresh their caches
        NotificationCenter.default.post(
            name: .syncedSettingsDidChange,
            object: nil,
            userInfo: ["changedKeys": changedKeys]
        )
    }

    // MARK: - String

    public func string(forKey key: SyncedSettingsKey) -> String? {
        if isUITesting {
            return localStore?.string(forKey: key.rawValue)
        }
        return store?.string(forKey: key.rawValue)
    }

    public func set(_ value: String?, forKey key: SyncedSettingsKey) {
        if isUITesting {
            if let value = value {
                localStore?.set(value, forKey: key.rawValue)
            } else {
                localStore?.removeObject(forKey: key.rawValue)
            }
        } else {
            if let value = value {
                store?.set(value, forKey: key.rawValue)
            } else {
                store?.removeObject(forKey: key.rawValue)
            }
            store?.synchronize()
        }
    }

    // MARK: - Bool

    public func bool(forKey key: SyncedSettingsKey) -> Bool? {
        if isUITesting {
            guard localStore?.object(forKey: key.rawValue) != nil else { return nil }
            return localStore?.bool(forKey: key.rawValue)
        }
        guard store?.object(forKey: key.rawValue) != nil else { return nil }
        return store?.bool(forKey: key.rawValue)
    }

    public func set(_ value: Bool, forKey key: SyncedSettingsKey) {
        if isUITesting {
            localStore?.set(value, forKey: key.rawValue)
        } else {
            store?.set(value, forKey: key.rawValue)
            store?.synchronize()
        }
    }

    // MARK: - Int

    public func int(forKey key: SyncedSettingsKey) -> Int? {
        if isUITesting {
            guard localStore?.object(forKey: key.rawValue) != nil else { return nil }
            return localStore?.integer(forKey: key.rawValue)
        }
        guard store?.object(forKey: key.rawValue) != nil else { return nil }
        return Int(store?.longLong(forKey: key.rawValue) ?? 0)
    }

    public func set(_ value: Int, forKey key: SyncedSettingsKey) {
        if isUITesting {
            localStore?.set(value, forKey: key.rawValue)
        } else {
            store?.set(Int64(value), forKey: key.rawValue)
            store?.synchronize()
        }
    }

    // MARK: - Double

    public func double(forKey key: SyncedSettingsKey) -> Double? {
        if isUITesting {
            guard localStore?.object(forKey: key.rawValue) != nil else { return nil }
            return localStore?.double(forKey: key.rawValue)
        }
        guard store?.object(forKey: key.rawValue) != nil else { return nil }
        return store?.double(forKey: key.rawValue)
    }

    public func set(_ value: Double, forKey key: SyncedSettingsKey) {
        if isUITesting {
            localStore?.set(value, forKey: key.rawValue)
        } else {
            store?.set(value, forKey: key.rawValue)
            store?.synchronize()
        }
    }

    // MARK: - Data

    public func data(forKey key: SyncedSettingsKey) -> Data? {
        if isUITesting {
            return localStore?.data(forKey: key.rawValue)
        }
        return store?.data(forKey: key.rawValue)
    }

    public func set(_ value: Data?, forKey key: SyncedSettingsKey) {
        if isUITesting {
            if let value = value {
                localStore?.set(value, forKey: key.rawValue)
            } else {
                localStore?.removeObject(forKey: key.rawValue)
            }
        } else {
            if let value = value {
                store?.set(value, forKey: key.rawValue)
            } else {
                store?.removeObject(forKey: key.rawValue)
            }
            store?.synchronize()
        }
    }

    // MARK: - Codable

    public func decodable<T: Decodable>(forKey key: SyncedSettingsKey, as type: T.Type) -> T? {
        guard let data = self.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func set<T: Encodable>(_ value: T?, forKey key: SyncedSettingsKey) {
        if let value = value,
           let data = try? JSONEncoder().encode(value) {
            self.set(data, forKey: key)
        } else {
            remove(forKey: key)
        }
    }

    // MARK: - Array

    public func stringArray(forKey key: SyncedSettingsKey) -> [String]? {
        if isUITesting {
            return localStore?.array(forKey: key.rawValue) as? [String]
        }
        return store?.array(forKey: key.rawValue) as? [String]
    }

    public func set(_ value: [String]?, forKey key: SyncedSettingsKey) {
        if isUITesting {
            if let value = value {
                localStore?.set(value, forKey: key.rawValue)
            } else {
                localStore?.removeObject(forKey: key.rawValue)
            }
        } else {
            if let value = value {
                store?.set(value, forKey: key.rawValue)
            } else {
                store?.removeObject(forKey: key.rawValue)
            }
            store?.synchronize()
        }
    }

    // MARK: - Remove

    public func remove(forKey key: SyncedSettingsKey) {
        if isUITesting {
            localStore?.removeObject(forKey: key.rawValue)
        } else {
            store?.removeObject(forKey: key.rawValue)
            store?.synchronize()
        }
    }

    // MARK: - Sync

    /// Force synchronization with iCloud (no-op in UI testing mode)
    @discardableResult
    public func synchronize() -> Bool {
        if isUITesting {
            return true  // Always "succeeds" in UI testing mode
        }
        return store?.synchronize() ?? false
    }

    // MARK: - Export/Import

    /// Export all settings as a dictionary for backup.
    /// Values are converted to JSON-compatible types.
    public func exportAllSettings() -> [String: Any] {
        var settings: [String: Any] = [:]

        // Export all known keys
        for key in SyncedSettingsKey.allCases {
            if let value = store?.object(forKey: key.rawValue) ?? localStore?.object(forKey: key.rawValue) {
                // Convert to JSON-compatible type
                settings[key.rawValue] = toJSONCompatible(value)
            }
        }

        return settings
    }

    /// Convert a value to a JSON-compatible type.
    private func toJSONCompatible(_ value: Any) -> Any {
        switch value {
        case let date as Date:
            return date.timeIntervalSince1970
        case let data as Data:
            return data.base64EncodedString()
        case let array as [Any]:
            return array.map { toJSONCompatible($0) }
        case let dict as [String: Any]:
            return dict.mapValues { toJSONCompatible($0) }
        case is String, is Int, is Double, is Float, is Bool, is NSNumber, is NSNull:
            return value
        default:
            // For unknown types, convert to string representation
            return String(describing: value)
        }
    }

    /// Import settings from a backup dictionary.
    public func importSettings(_ settings: [String: Any]) {
        for (key, value) in settings {
            if isUITesting {
                localStore?.set(value, forKey: key)
            } else {
                store?.set(value, forKey: key)
            }
        }
        store?.synchronize()
        Logger.settings.info("Imported \(settings.count) settings from backup")
    }

    // MARK: - Migration

    /// Migrate a value from local UserDefaults to synced storage if not already synced.
    /// This is useful for one-time migration when adding sync support.
    /// No-op in UI testing mode.
    public func migrateFromUserDefaults(
        localKey: String,
        syncKey: SyncedSettingsKey,
        defaults: UserDefaults = .standard
    ) {
        // Skip migration in UI testing mode
        guard !isUITesting else { return }

        // Only migrate if synced value doesn't exist
        guard store?.object(forKey: syncKey.rawValue) == nil else { return }

        // Copy from local if exists
        if let value = defaults.object(forKey: localKey) {
            store?.set(value, forKey: syncKey.rawValue)
            store?.synchronize()
            Logger.settings.info("Migrated \(localKey) to synced storage")
        }
    }

    // MARK: - Testing

    #if DEBUG
    /// Clear all synced settings (for testing)
    public func clearAll() {
        for key in SyncedSettingsKey.allCases {
            if isUITesting {
                localStore?.removeObject(forKey: key.rawValue)
            } else {
                store?.removeObject(forKey: key.rawValue)
            }
        }
        if !isUITesting {
            store?.synchronize()
        }
    }
    #endif

    // MARK: - Exploration Retention

    /// Get the exploration retention setting
    public var explorationRetention: ExplorationRetention {
        get {
            if let rawValue = string(forKey: .explorationRetention),
               let retention = ExplorationRetention(rawValue: rawValue) {
                return retention
            }
            return .oneMonth  // Default
        }
        set {
            set(newValue.rawValue, forKey: .explorationRetention)
        }
    }
}

// MARK: - Exploration Retention

/// How long exploration results (References, Citations, Similar, Co-Reads) are kept.
public enum ExplorationRetention: String, CaseIterable, Codable, Sendable {
    case sessionOnly = "session"    // While app is open
    case oneWeek = "1week"
    case oneMonth = "1month"
    case oneYear = "1year"
    case forever = "forever"

    /// Display name for UI
    public var displayName: String {
        switch self {
        case .sessionOnly: return "While App is Open"
        case .oneWeek: return "1 Week"
        case .oneMonth: return "1 Month"
        case .oneYear: return "1 Year"
        case .forever: return "Forever"
        }
    }

    /// Number of days to keep items.
    /// - Returns: `nil` for forever (keep all), `0` for session only (delete all on quit), or the number of days.
    public var days: Int? {
        switch self {
        case .sessionOnly: return 0
        case .oneWeek: return 7
        case .oneMonth: return 30
        case .oneYear: return 365
        case .forever: return nil
        }
    }
}
