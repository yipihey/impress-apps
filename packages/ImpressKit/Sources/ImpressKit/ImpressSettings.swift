//
//  ImpressSettings.swift
//  ImpressKit
//
//  The settings registry as Swift reads it (ADR-0036 D5, plan-self-reflective-
//  layer R1): one handle on Rust's `SharedSettings`, one `@ImpressSetting`
//  property wrapper that replaces `@AppStorage` at a call site.
//
//  A setting's type, default, scope and legacy `UserDefaults` keys are the
//  registry's (`crates/impress-settings`), never this file's: a key the
//  registry does not declare is a runtime error at the wrapper's first read,
//  logged under `settings`, and the property answers its type's zero value
//  rather than a guessed default — nothing here invents one.
//
//  ## Migration without loss (D-R5)
//
//  On the first read of a key whose file has no value, `ImpressSettings` asks
//  each `legacyStores` entry (the app's standard domain, then the suite's app
//  group) for each declared legacy key in order, writes the first value found
//  into the file through Rust (`import_legacy_json`, which writes only when
//  nothing is stored), and logs `migrated <legacy> → <key> = <value>`. It
//  NEVER removes the `UserDefaults` value: an older build keeps reading it.
//
//  ## Change feed
//
//  Rust's files are written by every app, the daemon and the CLI. This class
//  polls `changed_since` (a `stat` per scope file, 250 ms) once anyone has
//  read a value, and posts `ImpressSettings.didChange` when a file moved, so a
//  `settings-service_set` from the CLI reaches every `@ImpressSetting` view.
//

import Foundation
import ImpressLogging
import ImpressRustCore
import SwiftUI

/// A Swift type a setting can be read as. The four registry types.
public protocol ImpressSettingValue: Sendable {
    /// Decode the registry's JSON text (`30`, `true`, `"…"`).
    static func fromSettingsJSON(_ json: String) -> Self?
    /// Encode as the JSON text Rust accepts.
    var settingsJSON: String { get }
    /// What a misdeclared key answers — never a guessed default.
    static var settingsZero: Self { get }
}

extension Bool: ImpressSettingValue {
    public static func fromSettingsJSON(_ json: String) -> Bool? {
        switch json.trimmingCharacters(in: .whitespaces) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
    public var settingsJSON: String { self ? "true" : "false" }
    public static var settingsZero: Bool { false }
}

extension Int: ImpressSettingValue {
    public static func fromSettingsJSON(_ json: String) -> Int? {
        if let value = Int(json.trimmingCharacters(in: .whitespaces)) { return value }
        if let double = Double(json.trimmingCharacters(in: .whitespaces)),
           double == double.rounded(), abs(double) < 1e15 {
            return Int(double)
        }
        return nil
    }
    public var settingsJSON: String { String(self) }
    public static var settingsZero: Int { 0 }
}

extension Double: ImpressSettingValue {
    public static func fromSettingsJSON(_ json: String) -> Double? {
        Double(json.trimmingCharacters(in: .whitespaces))
    }
    public var settingsJSON: String { String(self) }
    public static var settingsZero: Double { 0 }
}

extension String: ImpressSettingValue {
    public static func fromSettingsJSON(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data)
        else { return nil }
        return decoded
    }
    public var settingsJSON: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return text
    }
    public static var settingsZero: String { "" }
}

/// The process's one handle on the settings registry.
@MainActor
public final class ImpressSettings {

    public static let shared = ImpressSettings()

    /// Posted on the main queue whenever a scope file changed under this
    /// process (its own writes included). `object` is nil.
    public static let didChange = Notification.Name("ImpressSettingsDidChange")

    /// Where legacy values are looked for, in order: the app's standard
    /// domain, then the suite's app group. A test replaces this with a
    /// scratch suite.
    public var legacyStores: [UserDefaults] = [.standard, SharedDefaults.suite]

    /// The workspace the files live beside. Set before the first read to
    /// point a test at a scratch directory; the default is the suite's.
    public var workspaceDirectory: URL = SharedWorkspace.workspaceDirectory

    private var handle: SharedSettings?
    private var openFailed = false
    private var migrationAttempted: Set<String> = []
    private var cursor: Int64 = 0
    private var poll: Timer?

    private init() {}

    /// The Rust handle, opened on first use. `nil` when the workspace
    /// cannot be opened; every read then answers the zero value and logs.
    public var rust: SharedSettings? {
        if let handle { return handle }
        guard !openFailed else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: workspaceDirectory, withIntermediateDirectories: true)
            let opened = try SharedSettings.open(workspacePath: workspaceDirectory.path)
            handle = opened
            cursor = opened.updatedAtMs()
            startPolling()
            logInfo("settings: opened registry at \(opened.directory())", category: "settings")
            return opened
        } catch {
            openFailed = true
            logError("settings: could not open the registry — \(error)", category: "settings")
            return nil
        }
    }

    /// Every key the registry declares.
    public var knownKeys: [String] { rust?.knownKeys() ?? [] }

    // MARK: Reads

    /// The current value of `key` as `T`: stored, else migrated from a
    /// legacy key, else the registry default. An undeclared key, a type
    /// that does not match the declaration, or a closed registry logs an
    /// error and answers `T.settingsZero`.
    public func value<T: ImpressSettingValue>(_ key: String, as type: T.Type = T.self) -> T {
        guard let rust else { return T.settingsZero }
        do {
            var record = try rust.get(key: key)
            if record.source == "default", !record.legacy.isEmpty, !migrationAttempted.contains(key) {
                migrationAttempted.insert(key)
                if migrateLegacy(record, through: rust) {
                    record = try rust.get(key: key)
                }
            }
            guard let value = T.fromSettingsJSON(record.valueJson) else {
                logError(
                    "settings: \(key) is declared as \(record.ty), not \(T.self) — answering zero",
                    category: "settings")
                return T.settingsZero
            }
            return value
        } catch {
            logError("settings: read of \(key) failed — \(error)", category: "settings")
            return T.settingsZero
        }
    }

    /// The registry record for `key`, or nil (logged) when undeclared.
    public func record(_ key: String) -> SharedSettingValue? {
        guard let rust else { return nil }
        do {
            return try rust.get(key: key)
        } catch {
            logError("settings: \(key) — \(error)", category: "settings")
            return nil
        }
    }

    // MARK: Writes

    /// Store `value` for `key`. A refused write (wrong type, unknown key)
    /// is logged and changes nothing.
    public func set<T: ImpressSettingValue>(_ key: String, _ value: T) {
        guard let rust else { return }
        logInfo("settings: set \(key) = \(value.settingsJSON)", category: "settings")
        do {
            let stored = try rust.setJson(key: key, valueJson: value.settingsJSON)
            logInfo(
                "settings: save \(key) = \(stored.valueJson) in \(stored.scope)",
                category: "settings")
            noteChanged()
        } catch {
            logError("settings: set \(key) refused — \(error)", category: "settings")
        }
    }

    /// Forget the stored value so `key` answers its default.
    public func reset(_ key: String) {
        guard let rust else { return }
        do {
            _ = try rust.reset(key: key)
            noteChanged()
        } catch {
            logError("settings: reset \(key) refused — \(error)", category: "settings")
        }
    }

    // MARK: Migration

    /// Look each declared legacy key up in each legacy store and import the
    /// first value found, leaving it where it was (D-R5). Answers whether a
    /// value was written.
    private func migrateLegacy(_ record: SharedSettingValue, through rust: SharedSettings) -> Bool {
        for legacyKey in record.legacy {
            for store in legacyStores {
                guard let raw = store.object(forKey: legacyKey),
                      let json = Self.legacyJSON(raw, as: record.ty)
                else { continue }
                do {
                    if try rust.importLegacyJson(key: record.key, valueJson: json) {
                        logInfo(
                            "settings: migrated \(legacyKey) → \(record.key) = \(json) "
                                + "(the UserDefaults value stays)",
                            category: "settings")
                        noteChanged()
                        return true
                    }
                    return false
                } catch {
                    logError(
                        "settings: migration of \(legacyKey) → \(record.key) failed — \(error)",
                        category: "settings")
                    return false
                }
            }
        }
        return false
    }

    /// A `UserDefaults` object as the JSON text the registry type takes,
    /// or nil when it cannot be read as one.
    static func legacyJSON(_ raw: Any, as type: String) -> String? {
        switch type {
        case "bool":
            if let number = raw as? NSNumber { return number.boolValue ? "true" : "false" }
            return (raw as? String).flatMap(Bool.fromSettingsJSON)?.settingsJSON
        case "integer":
            if let number = raw as? NSNumber { return Int(truncating: number).settingsJSON }
            return (raw as? String).flatMap(Int.fromSettingsJSON)?.settingsJSON
        case "number":
            if let number = raw as? NSNumber { return number.doubleValue.settingsJSON }
            return (raw as? String).flatMap(Double.fromSettingsJSON)?.settingsJSON
        case "string":
            return (raw as? String)?.settingsJSON
        default:
            return nil
        }
    }

    // MARK: The generated pane

    /// Store (or refresh) the generated pane for `section` as a surface row
    /// the `surface` view kind renders, reseeded with the current values.
    /// Answers the surface id.
    public func installSectionSurface(surface: SharedSurface, section: String) throws -> String {
        guard let rust else {
            throw SharedSettingsError.Storage(message: "the settings registry is not open")
        }
        let id = try rust.installSectionSurface(surface: surface, section: section)
        logInfo("settings: installed pane \(section) as surface \(id)", category: "settings")
        return id
    }

    // MARK: Change feed

    private func noteChanged() {
        cursor = handle?.updatedAtMs() ?? cursor
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func startPolling() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func tick() {
        guard let handle, handle.changedSince(updatedAtMs: cursor) else { return }
        cursor = handle.updatedAtMs()
        logInfo("settings: a scope file changed — re-reading", category: "settings")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Test seam: forget the handle so the next read opens `workspaceDirectory`.
    public func _resetForTesting() {
        poll?.invalidate()
        poll = nil
        handle = nil
        openFailed = false
        migrationAttempted = []
        cursor = 0
    }
}

/// `SharedSettings` and `SharedSurface` are `Arc`s over Rust objects that
/// are `Send + Sync`; UniFFI does not mark generated classes `Sendable`.
extension SharedSettings: @retroactive @unchecked Sendable {}

// MARK: - @ImpressSetting

/// `@ImpressSetting("imbib.retention.inbox_days") var days: Int` — the
/// `@AppStorage` replacement. The type is checked against the registry at
/// the first read; the default is the registry's, never the declaration's.
@propertyWrapper
@MainActor
public struct ImpressSetting<Value: ImpressSettingValue>: DynamicProperty {

    private let key: String
    @StateObject private var observer = SettingsChangeObserver()

    public init(_ key: String) {
        self.key = key
    }

    public var wrappedValue: Value {
        get {
            _ = observer.generation
            return ImpressSettings.shared.value(key, as: Value.self)
        }
        nonmutating set {
            ImpressSettings.shared.set(key, newValue)
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// Re-renders every `@ImpressSetting` view when a scope file changes.
@MainActor
final class SettingsChangeObserver: ObservableObject {
    @Published private(set) var generation = 0
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: ImpressSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.generation += 1 }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
