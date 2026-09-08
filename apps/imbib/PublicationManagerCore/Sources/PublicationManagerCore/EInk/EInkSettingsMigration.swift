//
//  EInkSettingsMigration.swift
//  PublicationManagerCore
//
//  Moves the legacy `eink.*` / `remarkable.*` UserDefaults — folder
//  organisation, annotation import, auto-sync — into the device record
//  (`eink-configure-device`), once (ADR-025 P7). Those keys were read by
//  `EInkSettingsStore` / `RemarkableSettingsStore` and honoured by nothing
//  that still runs; the engine reads the record. After a successful write
//  the keys are removed and `eink.migration.v1` is set, so the pane never
//  shows two answers to one question.
//
//  Which record: the first enabled device, else the first device. With no
//  record at all, a legacy reMarkable configuration (paired, a local folder,
//  a device id) creates one — enabled only when the legacy backend was the
//  USB web interface, the one transport the engine speaks; otherwise the
//  preferences are kept on a disabled record for the pane to show.
//  With neither a record nor a legacy device the keys have nothing to
//  attach to and are simply removed.
//
//  Never in the first 90 s: `EInkSyncCoordinator` runs it when the gate
//  opens; `runIfNeeded()` is also safe to call on demand (idempotent, and a
//  failed write leaves the keys in place for the next attempt).
//

import Foundation
import ImpressLogging
import OSLog

public struct EInkSettingsMigration: Sendable {

    public static let markerKey = "eink.migration.v1"

    /// The keys this migration owns. Connection keys (`remarkable.isAuthenticated`,
    /// `remarkable.localFolderPath`, `eink.activeDeviceID`, `eink.deviceSettings`, …)
    /// stay: Supernote / Kindle / folder / cloud / Wi-Fi still read them.
    public static let legacyKeys: [String] = [
        // organisation
        "eink.createFoldersByCollection", "remarkable.createFoldersByCollection",
        "eink.useReadingQueueFolder", "remarkable.useReadingQueueFolder",
        "eink.rootFolderName", "remarkable.rootFolderName",
        // annotations
        "eink.importHighlights", "remarkable.importHighlights",
        "eink.importInkNotes", "remarkable.importInkNotes",
        "eink.enableOCR", "remarkable.enableOCR",
        "eink.annotationImportMode",
        // sync
        "eink.autoSyncEnabled", "remarkable.autoSyncEnabled",
        "eink.syncInterval", "remarkable.syncInterval",
        "eink.conflictResolution", "remarkable.conflictResolution",
    ]

    /// `UserDefaults` is thread-safe but not marked Sendable; hence unchecked.
    public struct Environment: @unchecked Sendable {
        public var defaults: UserDefaults
        public var devices: @MainActor @Sendable () -> [EInkDeviceRecord]
        /// Write the input; false = the store refused.
        public var configure: @MainActor @Sendable (EInkDeviceConfigInput) -> Bool

        public init(
            defaults: UserDefaults,
            devices: @escaping @MainActor @Sendable () -> [EInkDeviceRecord],
            configure: @escaping @MainActor @Sendable (EInkDeviceConfigInput) -> Bool
        ) {
            self.defaults = defaults
            self.devices = devices
            self.configure = configure
        }

        public static let live = Environment(
            defaults: .standard,
            devices: { RustStoreAdapter.shared.einkDevices() },
            configure: { RustStoreAdapter.shared.einkConfigureDevice($0) != nil }
        )
    }

    public enum Outcome: Sendable, Equatable {
        /// Already migrated, or nothing legacy to migrate (marker set).
        case nothingToDo
        /// Fields were written to the device record; keys removed.
        case migrated(deviceId: String?, created: Bool)
        /// Legacy keys existed but no device (record or legacy) to hold them; keys removed.
        case droppedNoDevice
        /// The store refused the write; keys kept for the next attempt.
        case failed
    }

    private let environment: Environment

    public init(environment: Environment = .live) {
        self.environment = environment
    }

    public var isDone: Bool { environment.defaults.bool(forKey: Self.markerKey) }

    /// The legacy keys currently present.
    public var presentLegacyKeys: [String] {
        Self.legacyKeys.filter { environment.defaults.object(forKey: $0) != nil }
    }

    @MainActor
    @discardableResult
    public func runIfNeeded() -> Outcome {
        let defaults = environment.defaults
        guard !isDone else { return .nothingToDo }

        let present = presentLegacyKeys
        guard !present.isEmpty else {
            defaults.set(true, forKey: Self.markerKey)
            return .nothingToDo
        }

        let devices = environment.devices()
        let target = devices.first(where: \.enabled) ?? devices.first
        var input = Self.input(from: defaults, deviceId: target?.id)
        let creating: Bool
        if target == nil {
            guard Self.legacyDeviceConfigured(in: defaults) else {
                Logger.library.infoCapture(
                    "eink.migration: \(present.count) legacy key(s) but no device to hold them; removed",
                    category: "eink")
                Self.removeLegacyKeys(from: defaults)
                defaults.set(true, forKey: Self.markerKey)
                return .droppedNoDevice
            }
            creating = true
            input.name = defaults.string(forKey: "remarkable.deviceName") ?? "reMarkable"
            input.transport = "usb"
            input.enabled = defaults.string(forKey: "remarkable.activeBackendID") == "usb-web"
        } else {
            creating = false
        }

        Logger.library.infoCapture(
            "eink.migration: writing \(present.count) legacy key(s) to device \(target?.id ?? "new") "
                + "(root=\(input.rootFolderName ?? "-") collections=\(input.mirrorCollections.map(String.init) ?? "-") "
                + "inbox=\(input.includeInbox.map(String.init) ?? "-") highlights=\(input.importHighlights.map(String.init) ?? "-") "
                + "ink=\(input.importInk.map(String.init) ?? "-") ocr=\(input.runOCR.map(String.init) ?? "-") "
                + "autoImport=\(input.autoImportOnConnect.map(String.init) ?? "-"))",
            category: "eink")
        guard environment.configure(input) else {
            Logger.library.errorCapture("eink.migration: store refused the device write; keys kept", category: "eink")
            return .failed
        }
        Self.removeLegacyKeys(from: defaults)
        defaults.set(true, forKey: Self.markerKey)
        Logger.library.infoCapture("eink.migration: done; \(present.count) legacy key(s) removed", category: "eink")
        return .migrated(deviceId: target?.id, created: creating)
    }

    // MARK: - Pure mapping

    /// Map whichever legacy keys are present onto the record's fields
    /// (`eink.*` wins over `remarkable.*` when both exist).
    public static func input(from defaults: UserDefaults, deviceId: String?) -> EInkDeviceConfigInput {
        var input = EInkDeviceConfigInput(id: deviceId)
        func bool(_ keys: String...) -> Bool? {
            for key in keys where defaults.object(forKey: key) != nil { return defaults.bool(forKey: key) }
            return nil
        }
        func string(_ keys: String...) -> String? {
            for key in keys where defaults.object(forKey: key) != nil { return defaults.string(forKey: key) }
            return nil
        }
        if let root = string("eink.rootFolderName", "remarkable.rootFolderName"),
           !root.trimmingCharacters(in: .whitespaces).isEmpty {
            input.rootFolderName = root
        }
        input.mirrorCollections = bool("eink.createFoldersByCollection", "remarkable.createFoldersByCollection")
        input.includeInbox = bool("eink.useReadingQueueFolder", "remarkable.useReadingQueueFolder")
        input.importHighlights = bool("eink.importHighlights", "remarkable.importHighlights")
        input.importInk = bool("eink.importInkNotes", "remarkable.importInkNotes")
        input.runOCR = bool("eink.enableOCR", "remarkable.enableOCR")

        // Auto-import on connect = the old "automatic sync" AND the import
        // mode being automatic (review/manual meant "ask me").
        let autoSync = bool("eink.autoSyncEnabled", "remarkable.autoSyncEnabled")
        let mode = string("eink.annotationImportMode")
        switch (autoSync, mode) {
        case (nil, nil):
            break
        case (let sync?, nil):
            input.autoImportOnConnect = sync
        case (nil, let mode?):
            input.autoImportOnConnect = mode == "auto"
        case (let sync?, let mode?):
            input.autoImportOnConnect = sync && mode == "auto"
        }
        return input
    }

    /// A reMarkable was set up under the old stores.
    static func legacyDeviceConfigured(in defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: "remarkable.isAuthenticated") { return true }
        if let path = defaults.string(forKey: "remarkable.localFolderPath"), !path.isEmpty { return true }
        if defaults.string(forKey: "remarkable.deviceID") != nil { return true }
        if defaults.string(forKey: "eink.activeDeviceID") != nil { return true }
        return false
    }

    static func removeLegacyKeys(from defaults: UserDefaults) {
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
