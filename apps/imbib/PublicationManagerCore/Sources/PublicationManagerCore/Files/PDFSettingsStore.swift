//
//  PDFSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - PDF Source Priority

/// User preference for which PDF source to try first
public enum PDFSourcePriority: String, Codable, CaseIterable, Sendable {
    case preprint   // Prefer arXiv, bioRxiv, preprint servers
    case publisher  // Prefer publisher PDFs (via proxy if configured)

    public var displayName: String {
        switch self {
        case .preprint: return "Preprint (arXiv, etc.)"
        case .publisher: return "Publisher"
        }
    }

    public var description: String {
        switch self {
        case .preprint: return "Free and always accessible"
        case .publisher: return "Original version, may require proxy"
        }
    }
}

// MARK: - PDF Settings

/// Settings for PDF viewing and downloading
public struct PDFSettings: Codable, Equatable, Sendable {
    public var sourcePriority: PDFSourcePriority
    public var libraryProxyURL: String
    public var proxyEnabled: Bool
    public var autoDownloadEnabled: Bool  // Auto-download PDFs when viewing PDF tab

    public init(
        sourcePriority: PDFSourcePriority = .preprint,
        libraryProxyURL: String = "",
        proxyEnabled: Bool = false,
        autoDownloadEnabled: Bool = true
    ) {
        self.sourcePriority = sourcePriority
        self.libraryProxyURL = libraryProxyURL
        self.proxyEnabled = proxyEnabled
        self.autoDownloadEnabled = autoDownloadEnabled
    }

    public static let `default` = PDFSettings()

    /// Common library proxy URLs for reference
    public static let commonProxies: [(name: String, url: String)] = [
        // UC California System
        ("UC Berkeley", "https://libproxy.berkeley.edu/login?url="),
        ("UC San Diego", "http://proxy.library.ucsd.edu:2048/login?url="),
        ("UC Santa Barbara", "https://proxy.library.ucsb.edu/login?url="),
        ("UC Santa Cruz", "https://login.oca.ucsc.edu/login?url="),
        ("UC San Francisco", "https://ucsf.idm.oclc.org/login?url="),
        ("UC Hastings Law", "http://uchastings.idm.oclc.org/login?url="),

        // Other US Universities
        ("Stanford", "https://stanford.idm.oclc.org/login?url="),
        ("Harvard", "https://ezp-prod1.hul.harvard.edu/login?url="),
        ("MIT", "https://libproxy.mit.edu/login?url="),
        ("Yale", "https://yale.idm.oclc.org/login?url="),
        ("Princeton", "https://ezproxy.princeton.edu/login?url="),
        ("Columbia", "https://ezproxy.cul.columbia.edu/login?url="),
        ("Chicago", "https://proxy.uchicago.edu/login?url="),
        ("Caltech", "https://clsproxy.library.caltech.edu/login?url="),

        // Max Planck Institutes
        ("MPI Molecular Genetics", "https://login.ezproxy.molgen.mpg.de/login?url="),
        ("MPI Nijmegen", "https://login.ezproxy.mpi.nl/login?url="),
        ("MPI Human Development (Berlin)", "http://ezproxy.mpib-berlin.mpg.de/login?url="),
    ]
}

// MARK: - PDF Settings Store

/// Actor-based store for PDF settings
/// Uses iCloud sync for cross-device consistency
public actor PDFSettingsStore {
    public static let shared = PDFSettingsStore(userDefaults: .forCurrentEnvironment)

    private let userDefaults: UserDefaults
    private let legacySettingsKey = "pdfSettings"
    private var cachedSettings: PDFSettings?
    private var syncObserver: NSObjectProtocol?

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    /// Get current settings (cached or loaded from synced storage)
    public var settings: PDFSettings {
        if let cached = cachedSettings {
            return cached
        }
        let loaded = loadSettings()
        cachedSettings = loaded
        return loaded
    }

    /// Load settings synchronously (for initial SwiftUI state)
    public static func loadSettingsSync() -> PDFSettings {
        let store = SyncedSettingsStore.shared

        let sourcePriority: PDFSourcePriority = {
            if let rawValue = store.string(forKey: .pdfSourcePriority),
               let priority = PDFSourcePriority(rawValue: rawValue) {
                return priority
            }
            return .preprint
        }()

        let libraryProxyURL = store.string(forKey: .pdfProxyURL) ?? ""
        let proxyEnabled = store.bool(forKey: .pdfProxyEnabled) ?? false
        let autoDownloadEnabled = store.bool(forKey: .pdfAutoDownloadEnabled) ?? true

        return PDFSettings(
            sourcePriority: sourcePriority,
            libraryProxyURL: libraryProxyURL,
            proxyEnabled: proxyEnabled,
            autoDownloadEnabled: autoDownloadEnabled
        )
    }

    /// Set up observer for sync changes from other devices
    public func setupSyncObserver() {
        syncObserver = NotificationCenter.default.addObserver(
            forName: .syncedSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let changedKeys = notification.userInfo?["changedKeys"] as? [String] else { return }

            // Check if any PDF settings changed
            let pdfKeys: [String] = [
                SyncedSettingsKey.pdfSourcePriority.rawValue,
                SyncedSettingsKey.pdfProxyURL.rawValue,
                SyncedSettingsKey.pdfProxyEnabled.rawValue,
                SyncedSettingsKey.pdfAutoDownloadEnabled.rawValue
            ]

            if changedKeys.contains(where: { pdfKeys.contains($0) }) {
                Task {
                    await self?.reloadFromSync()
                }
            }
        }
    }

    /// Reload settings from synced storage
    private func reloadFromSync() {
        cachedSettings = nil
        _ = settings  // Trigger reload
        Logger.files.info("PDF settings reloaded from sync")
    }

    /// Load settings from synced storage, migrating from local if needed
    private func loadSettings() -> PDFSettings {
        let store = SyncedSettingsStore.shared

        // Migrate from legacy local storage on first run
        migrateFromLocalIfNeeded()

        let sourcePriority: PDFSourcePriority = {
            if let rawValue = store.string(forKey: .pdfSourcePriority),
               let priority = PDFSourcePriority(rawValue: rawValue) {
                return priority
            }
            return .preprint
        }()

        let libraryProxyURL = store.string(forKey: .pdfProxyURL) ?? ""
        let proxyEnabled = store.bool(forKey: .pdfProxyEnabled) ?? false
        let autoDownloadEnabled = store.bool(forKey: .pdfAutoDownloadEnabled) ?? true

        let settings = PDFSettings(
            sourcePriority: sourcePriority,
            libraryProxyURL: libraryProxyURL,
            proxyEnabled: proxyEnabled,
            autoDownloadEnabled: autoDownloadEnabled
        )

        Logger.files.infoCapture("Loaded PDF settings: priority=\(settings.sourcePriority.rawValue), proxy=\(settings.proxyEnabled)", category: "pdf")
        return settings
    }

    /// Migrate settings from legacy local storage to synced storage
    private func migrateFromLocalIfNeeded() {
        let store = SyncedSettingsStore.shared

        // Only migrate if synced values don't exist and local values do
        guard store.string(forKey: .pdfSourcePriority) == nil,
              let data = userDefaults.data(forKey: legacySettingsKey),
              let legacy = try? JSONDecoder().decode(PDFSettings.self, from: data) else {
            return
        }

        Logger.files.info("Migrating PDF settings from local to synced storage")

        store.set(legacy.sourcePriority.rawValue, forKey: .pdfSourcePriority)
        store.set(legacy.libraryProxyURL, forKey: .pdfProxyURL)
        store.set(legacy.proxyEnabled, forKey: .pdfProxyEnabled)
        store.set(legacy.autoDownloadEnabled, forKey: .pdfAutoDownloadEnabled)

        // Remove legacy local storage after migration
        userDefaults.removeObject(forKey: legacySettingsKey)
    }

    /// Save settings to synced storage
    private func saveSettings(_ settings: PDFSettings) {
        cachedSettings = settings

        let store = SyncedSettingsStore.shared
        store.set(settings.sourcePriority.rawValue, forKey: .pdfSourcePriority)
        store.set(settings.libraryProxyURL, forKey: .pdfProxyURL)
        store.set(settings.proxyEnabled, forKey: .pdfProxyEnabled)
        store.set(settings.autoDownloadEnabled, forKey: .pdfAutoDownloadEnabled)

        Logger.files.infoCapture("Saved PDF settings to sync: priority=\(settings.sourcePriority.rawValue), proxy=\(settings.proxyEnabled)", category: "pdf")
    }

    /// Update PDF source priority
    public func updateSourcePriority(_ priority: PDFSourcePriority) {
        var current = settings
        current.sourcePriority = priority
        saveSettings(current)
    }

    /// Update library proxy settings
    public func updateLibraryProxy(url: String, enabled: Bool) {
        var current = settings
        current.libraryProxyURL = url
        current.proxyEnabled = enabled
        saveSettings(current)
    }

    /// Update auto-download setting
    public func updateAutoDownload(enabled: Bool) {
        var current = settings
        current.autoDownloadEnabled = enabled
        saveSettings(current)
        Logger.files.infoCapture("Updated auto-download setting: \(enabled)", category: "pdf")
    }

    /// Reset settings to defaults
    public func reset() {
        let store = SyncedSettingsStore.shared
        store.remove(forKey: .pdfSourcePriority)
        store.remove(forKey: .pdfProxyURL)
        store.remove(forKey: .pdfProxyEnabled)
        store.remove(forKey: .pdfAutoDownloadEnabled)
        cachedSettings = nil
        Logger.files.infoCapture("Reset PDF settings to defaults", category: "pdf")
    }

    /// Clear cached settings (for testing)
    public func clearCache() {
        cachedSettings = nil
    }
}
