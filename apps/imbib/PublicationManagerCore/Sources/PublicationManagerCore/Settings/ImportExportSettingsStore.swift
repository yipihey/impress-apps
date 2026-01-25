//
//  ImportExportSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-18.
//

import Foundation
import OSLog

// MARK: - Import/Export Settings

/// Settings for import and export behavior.
public struct ImportExportSettings: Equatable, Sendable {
    /// Whether to auto-generate cite keys when importing entries with missing/generic cite keys
    public var autoGenerateCiteKeys: Bool

    /// Default entry type for entries without a specified type
    public var defaultEntryType: String

    /// Whether to preserve original BibTeX formatting when exporting
    public var exportPreserveRawBibTeX: Bool

    /// Whether to open PDFs in external viewer instead of built-in viewer
    public var openPDFExternally: Bool

    public init(
        autoGenerateCiteKeys: Bool = true,
        defaultEntryType: String = "article",
        exportPreserveRawBibTeX: Bool = true,
        openPDFExternally: Bool = false
    ) {
        self.autoGenerateCiteKeys = autoGenerateCiteKeys
        self.defaultEntryType = defaultEntryType
        self.exportPreserveRawBibTeX = exportPreserveRawBibTeX
        self.openPDFExternally = openPDFExternally
    }

    public static let `default` = ImportExportSettings()
}

// MARK: - Import/Export Settings Store

/// Actor for reading and updating import/export settings.
/// Most settings sync via iCloud; openPDFExternally is device-specific.
public actor ImportExportSettingsStore {

    // MARK: - Shared Instance

    public static let shared = ImportExportSettingsStore(defaults: .forCurrentEnvironment)

    // MARK: - Keys (for device-specific settings)

    private enum LocalKeys {
        static let openPDFExternally = "openPDFInExternalViewer"
    }

    // MARK: - Properties

    private let defaults: UserDefaults
    private var syncObserver: NSObjectProtocol?

    // MARK: - Initialization

    public init(defaults: UserDefaults = .forCurrentEnvironment) {
        self.defaults = defaults

        // Register defaults for device-specific settings only
        defaults.register(defaults: [
            LocalKeys.openPDFExternally: false
        ])
    }

    /// Set up observer for sync changes from other devices
    public func setupSyncObserver() {
        syncObserver = NotificationCenter.default.addObserver(
            forName: .syncedSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let changedKeys = notification.userInfo?["changedKeys"] as? [String] else { return }

            let importKeys: [String] = [
                SyncedSettingsKey.importAutoGenerateCiteKeys.rawValue,
                SyncedSettingsKey.importDefaultEntryType.rawValue,
                SyncedSettingsKey.exportPreserveRawBibTeX.rawValue
            ]

            if changedKeys.contains(where: { importKeys.contains($0) }) {
                Logger.settings.info("Import/export settings reloaded from sync")
            }
        }
    }

    // MARK: - Current Settings

    /// Get the current settings
    public var settings: ImportExportSettings {
        let store = SyncedSettingsStore.shared
        return ImportExportSettings(
            autoGenerateCiteKeys: store.bool(forKey: .importAutoGenerateCiteKeys) ?? true,
            defaultEntryType: store.string(forKey: .importDefaultEntryType) ?? "article",
            exportPreserveRawBibTeX: store.bool(forKey: .exportPreserveRawBibTeX) ?? true,
            openPDFExternally: defaults.bool(forKey: LocalKeys.openPDFExternally)  // Device-specific
        )
    }

    // MARK: - Individual Properties

    /// Whether to auto-generate cite keys for entries with missing/generic cite keys
    public var autoGenerateCiteKeys: Bool {
        SyncedSettingsStore.shared.bool(forKey: .importAutoGenerateCiteKeys) ?? true
    }

    /// Default entry type for entries without a specified type
    public var defaultEntryType: String {
        SyncedSettingsStore.shared.string(forKey: .importDefaultEntryType) ?? "article"
    }

    /// Whether to preserve raw BibTeX on export
    public var exportPreserveRawBibTeX: Bool {
        SyncedSettingsStore.shared.bool(forKey: .exportPreserveRawBibTeX) ?? true
    }

    /// Whether to open PDFs in external viewer (device-specific, NOT synced)
    public var openPDFExternally: Bool {
        defaults.bool(forKey: LocalKeys.openPDFExternally)
    }

    // MARK: - Update Methods

    public func updateAutoGenerateCiteKeys(_ value: Bool) {
        SyncedSettingsStore.shared.set(value, forKey: .importAutoGenerateCiteKeys)
        Logger.settings.infoCapture(
            "Auto-generate cite keys \(value ? "enabled" : "disabled")",
            category: "settings"
        )
    }

    public func updateDefaultEntryType(_ value: String) {
        SyncedSettingsStore.shared.set(value, forKey: .importDefaultEntryType)
        Logger.settings.infoCapture(
            "Default entry type set to '\(value)'",
            category: "settings"
        )
    }

    public func updateExportPreserveRawBibTeX(_ value: Bool) {
        SyncedSettingsStore.shared.set(value, forKey: .exportPreserveRawBibTeX)
        Logger.settings.infoCapture(
            "Preserve raw BibTeX on export \(value ? "enabled" : "disabled")",
            category: "settings"
        )
    }

    public func updateOpenPDFExternally(_ value: Bool) {
        // Device-specific - stays in local UserDefaults
        defaults.set(value, forKey: LocalKeys.openPDFExternally)
        Logger.settings.infoCapture(
            "Open PDFs externally \(value ? "enabled" : "disabled")",
            category: "settings"
        )
    }

    public func update(_ settings: ImportExportSettings) {
        let store = SyncedSettingsStore.shared
        store.set(settings.autoGenerateCiteKeys, forKey: .importAutoGenerateCiteKeys)
        store.set(settings.defaultEntryType, forKey: .importDefaultEntryType)
        store.set(settings.exportPreserveRawBibTeX, forKey: .exportPreserveRawBibTeX)
        // openPDFExternally is device-specific
        defaults.set(settings.openPDFExternally, forKey: LocalKeys.openPDFExternally)
    }

    // MARK: - Reset

    public func resetToDefaults() {
        let store = SyncedSettingsStore.shared
        store.remove(forKey: .importAutoGenerateCiteKeys)
        store.remove(forKey: .importDefaultEntryType)
        store.remove(forKey: .exportPreserveRawBibTeX)
        defaults.removeObject(forKey: LocalKeys.openPDFExternally)
        Logger.settings.infoCapture(
            "Import/export settings reset to defaults",
            category: "settings"
        )
    }
}
