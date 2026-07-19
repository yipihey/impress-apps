//
//  PaneLayoutStore.swift
//  PublicationManagerCore
//
//  Declarative pane-layout system (ported from imprint): the main window's
//  pane arrangement is one Codable value that views bind to, menus mutate,
//  the HTTP automation API exposes, and users save under a name ("Triage",
//  "Reading", …) and re-apply with ⌃⌘1-9. Single source of truth — the
//  developer stops making layout decisions for the user.
//
//  Lives in Core (no AppKit dependency) so it is testable headlessly with
//  `swift test` and reachable from HTTPAutomationRouter.
//

import Foundation
import Observation

/// A complete, serializable description of the main window's pane arrangement
/// plus per-surface appearance. Everything the user can toggle lives here.
public struct PaneLayoutState: Codable, Equatable, Sendable {
    /// Leading sidebar (libraries/search/inbox outline) visibility (⌃⌘S).
    public var sidebarVisible = true
    /// Detail pane (info/pdf/notes/bibtex) visibility (⌘0).
    public var detailPaneVisible = true
    /// Selected detail tab, `DetailTab` raw value ("info"/"pdf"/"notes"/"bibtex").
    public var detailTab = "info"
    /// App-wide appearance, `AppearanceMode` raw value ("system"/"light"/"dark").
    public var appAppearance = "system"
    /// PDF viewer dark mode (independent of app appearance).
    public var pdfDarkMode = false

    public init() {}
}

/// A user-named saved layout.
public struct SavedPaneLayout: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var state: PaneLayoutState

    public init(id: UUID = UUID(), name: String, state: PaneLayoutState) {
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
public final class PaneLayoutStore {
    public static let shared = PaneLayoutStore()

    private static let layoutsKey = "imbib.layout.saved"
    private static let lastStateKey = "imbib.layout.last"

    private let defaults: UserDefaults

    /// The live arrangement. Views observe this; menus and the HTTP API set it.
    public var current: PaneLayoutState {
        didSet {
            guard current != oldValue else { return }
            persistCurrent()
        }
    }

    public private(set) var layouts: [SavedPaneLayout] = []

    /// Designated for tests: inject a scratch `UserDefaults` suite.
    public init(defaults: UserDefaults = .standard) {
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
    public func saveCurrent(named name: String) {
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
    public func apply(_ layout: SavedPaneLayout, pushAppearance: Bool = true) {
        current = layout.state
        if pushAppearance { self.pushAppearance() }
        logInfo("Layout applied: '\(layout.name)'", category: "layout")
    }

    /// Apply by name (HTTP API / command palette). Returns false if unknown.
    @discardableResult
    public func applyLayout(named name: String, pushAppearance: Bool = true) -> Bool {
        guard let layout = layouts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        apply(layout, pushAppearance: pushAppearance)
        return true
    }

    public func delete(_ layout: SavedPaneLayout) {
        layouts.removeAll { $0.id == layout.id }
        persistLayouts()
    }

    // MARK: - Appearance forwarding

    /// Forward the appearance mirrors to the authoritative stores.
    public func pushAppearance() {
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
