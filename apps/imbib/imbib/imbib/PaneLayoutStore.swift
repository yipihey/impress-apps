//
//  PaneLayoutStore.swift
//  imbib
//
//  imbib's own window's declarative pane layout (ported from imprint): the
//  window's arrangement is one Codable value that views bind to, menus mutate,
//  the HTTP automation API exposes, and users save under a name ("Triage",
//  "Reading", …) and re-apply with ⌃⌘1-9.
//
//  It lives in the app target with the one window that draws it (plan wave 6
//  W5 pass B). A chassis window is the layout tree; the shared views reach
//  this model only through the two hooks PublicationManagerCore declares —
//  `HostWindowPanes` (injected by `ContentView`) and
//  `PreChassisLayoutRoutesHost` (registered at launch) — below.
//

import Foundation
import ImpressLogging
import Observation
import PublicationManagerCore

/// A complete, serializable description of the window's pane arrangement
/// plus per-surface appearance. Everything the user can toggle lives here.
struct PaneLayoutState: Codable, Equatable, Sendable {
    /// Leading sidebar (libraries/search/inbox outline) visibility (⌃⌘S).
    var sidebarVisible = true
    /// List pane (middle column) visibility (⌥⌘0).
    var listPaneVisible = true
    /// Detail pane (info/pdf/notes/bibtex) visibility (⌘0).
    var detailPaneVisible = true
    /// Selected detail tab, `DetailTab` raw value ("info"/"pdf"/"notes"/"bibtex").
    var detailTab = "info"
    /// App-wide appearance, `AppearanceMode` raw value ("system"/"light"/"dark").
    var appAppearance = "system"
    /// PDF viewer dark mode (independent of app appearance).
    var pdfDarkMode = false

    init() {}

    // Custom decode with `decodeIfPresent`: synthesized Codable would throw
    // keyNotFound for layouts persisted before a field existed, silently
    // resetting every saved layout on upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        listPaneVisible = try c.decodeIfPresent(Bool.self, forKey: .listPaneVisible) ?? true
        detailPaneVisible = try c.decodeIfPresent(Bool.self, forKey: .detailPaneVisible) ?? true
        detailTab = try c.decodeIfPresent(String.self, forKey: .detailTab) ?? "info"
        appAppearance = try c.decodeIfPresent(String.self, forKey: .appAppearance) ?? "system"
        pdfDarkMode = try c.decodeIfPresent(Bool.self, forKey: .pdfDarkMode) ?? false
    }
}

/// A user-named saved layout.
struct SavedPaneLayout: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var state: PaneLayoutState

    init(id: UUID = UUID(), name: String, state: PaneLayoutState) {
        self.id = id
        self.name = name
        self.state = state
    }
}

/// Live layout state + named saved layouts, persisted across launches.
///
/// `current` is the value views bind to — mutating it IS the layout change.
/// Appearance fields are mirrors: `pushAppearance()` forwards them to
/// `ThemeSettingsStore` / `PDFSettingsStore` (the authoritative stores) when a
/// layout is applied.
@MainActor
@Observable
final class PaneLayoutStore {
    static let shared = PaneLayoutStore()

    private static let layoutsKey = "imbib.layout.saved"
    private static let lastStateKey = "imbib.layout.last"

    private let defaults: UserDefaults

    /// The live arrangement. Views observe this; menus and the HTTP API set it.
    var current: PaneLayoutState {
        didSet {
            guard current != oldValue else { return }
            persistCurrent()
        }
    }

    private(set) var layouts: [SavedPaneLayout] = []

    /// Designated for tests: inject a scratch `UserDefaults` suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.lastStateKey),
           let decoded = try? JSONDecoder().decode(PaneLayoutState.self, from: data) {
            current = decoded
        } else {
            current = PaneLayoutState()
        }
        if let data = defaults.data(forKey: Self.layoutsKey),
           let decoded = try? JSONDecoder().decode([SavedPaneLayout].self, from: data) {
            layouts = decoded
        } else {
            layouts = Self.builtInLayouts
        }
    }

    /// Starter layouts so the feature is discoverable before the user saves
    /// their own. Ordinary saved layouts — editable and deletable.
    private static var builtInLayouts: [SavedPaneLayout] {
        var triage = PaneLayoutState()
        triage.detailPaneVisible = false

        var reading = PaneLayoutState()
        reading.sidebarVisible = false
        reading.detailTab = "pdf"

        var full = PaneLayoutState()
        full.detailTab = "info"

        return [
            SavedPaneLayout(name: "Triage", state: triage),
            SavedPaneLayout(name: "Reading", state: reading),
            SavedPaneLayout(name: "Full", state: full),
        ]
    }

    // MARK: - Named layouts

    /// Save the live arrangement under `name` (replaces an existing layout of
    /// the same name).
    func saveCurrent(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let idx = layouts.firstIndex(where: { $0.name == trimmed }) {
            layouts[idx].state = current
        } else {
            layouts.append(SavedPaneLayout(name: trimmed, state: current))
        }
        persistLayouts()
        logInfo("Layout saved: '\(trimmed)'", category: "layout")
    }

    /// Apply a saved layout: becomes the live arrangement; appearance mirrors
    /// are forwarded to their authoritative stores unless `pushAppearance` is
    /// false (tests).
    func apply(_ layout: SavedPaneLayout, pushAppearance: Bool = true) {
        current = layout.state
        if pushAppearance { self.pushAppearance() }
        logInfo("Layout applied: '\(layout.name)'", category: "layout")
    }

    /// Apply by name (HTTP API / command palette). Returns false if unknown.
    @discardableResult
    func applyLayout(named name: String, pushAppearance: Bool = true) -> Bool {
        guard let layout = layouts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        apply(layout, pushAppearance: pushAppearance)
        return true
    }

    func delete(_ layout: SavedPaneLayout) {
        layouts.removeAll { $0.id == layout.id }
        persistLayouts()
    }

    // MARK: - Appearance forwarding

    /// Forward the appearance mirrors to the authoritative stores.
    func pushAppearance() {
        let mode = AppearanceMode(rawValue: current.appAppearance) ?? .system
        let pdfDark = current.pdfDarkMode
        Task {
            await ThemeSettingsStore.shared.updateAppearanceMode(mode)
            await PDFSettingsStore.shared.updateDarkMode(enabled: pdfDark)
        }
    }

    // MARK: - Persistence

    private func persistCurrent() {
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: Self.lastStateKey)
        }
    }

    private func persistLayouts() {
        if let data = try? JSONEncoder().encode(layouts) {
            defaults.set(data, forKey: Self.layoutsKey)
        }
    }
}

// MARK: - The shared views' panes

/// What `TabContentView`, `SectionContentView` and the section views read and
/// write; `ContentView` injects `PaneLayoutStore.shared` as the environment's
/// `hostWindowPanes`, and ⌘0 / ⌥⌘0 / ⌃⌘S reach it through
/// `PaneLayoutChordTarget.imbibPreChassisWindow`.
extension PaneLayoutStore: HostWindowPanes {
    var sidebarVisible: Bool {
        get { current.sidebarVisible }
        set { current.sidebarVisible = newValue }
    }

    var listPaneVisible: Bool {
        get { current.listPaneVisible }
        set { current.listPaneVisible = newValue }
    }

    var detailPaneVisible: Bool {
        get { current.detailPaneVisible }
        set { current.detailPaneVisible = newValue }
    }

    var detailTab: String {
        get { current.detailTab }
        set { current.detailTab = newValue }
    }
}

// MARK: - /api/layout, /api/layout/apply, /api/layout/save

extension PaneLayoutStore: PreChassisLayoutRoutesHost {

    /// Every response names the model it drove, so an agent can tell this
    /// window's model from the layout tree's (`/api/layout/tree`).
    static let model = "pane-layout-state"

    static func dict(_ state: PaneLayoutState) -> [String: Any] {
        [
            "sidebarVisible": state.sidebarVisible,
            "detailPaneVisible": state.detailPaneVisible,
            "detailTab": state.detailTab,
            "appAppearance": state.appAppearance,
            "pdfDarkMode": state.pdfDarkMode,
        ]
    }

    func layoutRoute(path: String, method: String, body: Data) -> PreChassisLayoutReply {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch (path, method) {
        case ("/api/layout", "GET"):
            return ok([
                "current": Self.dict(current),
                "layouts": layouts.map { ["name": $0.name, "state": Self.dict($0.state)] },
            ])

        // Set any subset of the live arrangement.
        case ("/api/layout", "POST"):
            guard let json else { return error(400, "Expected JSON object body") }
            var state = current
            if let v = json["sidebarVisible"] as? Bool { state.sidebarVisible = v }
            if let v = json["detailPaneVisible"] as? Bool { state.detailPaneVisible = v }
            if let v = json["detailTab"] as? String { state.detailTab = v }
            if let v = json["appAppearance"] as? String { state.appAppearance = v }
            if let v = json["pdfDarkMode"] as? Bool { state.pdfDarkMode = v }
            current = state
            if json["appAppearance"] != nil || json["pdfDarkMode"] != nil {
                pushAppearance()
            }
            logInfo("HTTP layout update: \(json.keys.sorted().joined(separator: ","))", category: "layout")
            return ok(["current": Self.dict(current)])

        case ("/api/layout/apply", "POST"):
            guard let name = json?["name"] as? String else { return error(400, "Expected {\"name\": ...}") }
            guard applyLayout(named: name) else { return error(404, "No saved layout named '\(name)'") }
            return ok(["applied": name, "current": Self.dict(current)])

        case ("/api/layout/save", "POST"):
            guard let name = json?["name"] as? String,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return error(400, "Expected {\"name\": ...}") }
            saveCurrent(named: name)
            return ok(["saved": name, "layouts": layouts.map(\.name)])

        default:
            return error(405, "\(method) \(path) is not a layout route")
        }
    }

    func appearanceDidChange(appAppearance: String?, pdfDarkMode: Bool?) {
        if let appAppearance { current.appAppearance = appAppearance }
        if let pdfDarkMode { current.pdfDarkMode = pdfDarkMode }
    }

    private func ok(_ fields: [String: Any]) -> PreChassisLayoutReply {
        var object = fields
        object["status"] = "ok"
        object["model"] = Self.model
        return PreChassisLayoutReply(object: object)
    }

    private func error(_ status: Int, _ message: String) -> PreChassisLayoutReply {
        PreChassisLayoutReply(status: status, object: ["status": "error", "error": message])
    }
}
