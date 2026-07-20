//
//  PaneLayout.swift
//  imprint
//
//  Declarative pane-layout system: the visible panes of the editor window are
//  described by a small Codable state value, captured from / applied to the
//  live AppState. Users arrange panes, then save the arrangement under a name
//  ("Writing", "Review", "Two-up", …) and switch layouts from the View menu,
//  keyboard, or command palette — the developer stops making layout decisions
//  for them. Additive: the existing AppState flags remain the live source of
//  truth; this file only snapshots and restores them.
//

#if os(macOS)
import Foundation
import SwiftUI
import ImpressLogging

// MARK: - Layout state

/// A complete, serializable description of the editor window's pane
/// arrangement. Everything the user can toggle lives here.
struct PaneLayoutState: Codable, Equatable {
    var editMode: String = EditMode.splitView.rawValue
    var showOutline = true
    var showComments = false
    var showAIChat = false
    var showThroughline = false
    var splitEditor = false
    /// `true` = second editor beside the first, `false` = stacked below.
    var splitEditorSideBySide = false

    /// Per-surface appearance overrides ("system" | "light" | "dark" for the
    /// app surface; "follow" | "light" | "dark" for editor and PDF).
    var editorAppearance = "follow"
    var pdfAppearance = "follow"

    init() {}

    /// Lenient decoding: every field falls back to its default when absent,
    /// so layouts saved by older builds keep decoding after new panes are
    /// added (synthesized Codable would throw and silently reset the user's
    /// saved layouts).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editMode = try c.decodeIfPresent(String.self, forKey: .editMode) ?? EditMode.splitView.rawValue
        showOutline = try c.decodeIfPresent(Bool.self, forKey: .showOutline) ?? true
        showComments = try c.decodeIfPresent(Bool.self, forKey: .showComments) ?? false
        showAIChat = try c.decodeIfPresent(Bool.self, forKey: .showAIChat) ?? false
        showThroughline = try c.decodeIfPresent(Bool.self, forKey: .showThroughline) ?? false
        splitEditor = try c.decodeIfPresent(Bool.self, forKey: .splitEditor) ?? false
        splitEditorSideBySide = try c.decodeIfPresent(Bool.self, forKey: .splitEditorSideBySide) ?? false
        editorAppearance = try c.decodeIfPresent(String.self, forKey: .editorAppearance) ?? "follow"
        pdfAppearance = try c.decodeIfPresent(String.self, forKey: .pdfAppearance) ?? "follow"
    }

    /// Capture the current live arrangement.
    @MainActor
    static func capture(from appState: AppState) -> PaneLayoutState {
        var s = PaneLayoutState()
        s.editMode = appState.editMode.rawValue
        s.showOutline = appState.showingOutline
        s.showComments = appState.showingComments
        s.showAIChat = appState.showingAIAssistant
        s.showThroughline = appState.showingThroughline
        s.splitEditor = appState.isEditorSplit
        s.splitEditorSideBySide = appState.editorSplitSideBySide
        s.editorAppearance = UserDefaults.standard.string(forKey: "editorAppearance") ?? "follow"
        s.pdfAppearance = UserDefaults.standard.string(forKey: "pdfAppearance") ?? "follow"
        return s
    }

    /// Apply this arrangement to the live window state.
    @MainActor
    func apply(to appState: AppState) {
        if let mode = EditMode(rawValue: editMode) { appState.editMode = mode }
        appState.showingOutline = showOutline
        appState.showingComments = showComments
        appState.showingAIAssistant = showAIChat
        appState.showingThroughline = showThroughline
        appState.isEditorSplit = splitEditor
        appState.editorSplitSideBySide = splitEditorSideBySide
        UserDefaults.standard.set(editorAppearance, forKey: "editorAppearance")
        UserDefaults.standard.set(pdfAppearance, forKey: "pdfAppearance")
    }
}

/// A user-named saved layout.
struct SavedLayout: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var state: PaneLayoutState
}

// MARK: - Store

/// Persists named layouts and restores the last-used arrangement across
/// launches. JSON in UserDefaults (small payload).
@MainActor
@Observable
final class LayoutStore {
    static let shared = LayoutStore()

    private static let layoutsKey = "imprint.layout.saved"
    private static let lastStateKey = "imprint.layout.last"

    private(set) var layouts: [SavedLayout] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.layoutsKey),
           let decoded = try? JSONDecoder().decode([SavedLayout].self, from: data) {
            layouts = decoded
        } else {
            layouts = Self.builtInLayouts
        }
    }

    /// Starter layouts so the feature is discoverable before the user saves
    /// their own. Fully editable/deletable — they are ordinary saved layouts.
    private static var builtInLayouts: [SavedLayout] {
        var writing = PaneLayoutState()
        writing.editMode = EditMode.textOnly.rawValue
        writing.showOutline = true

        var review = PaneLayoutState()
        review.editMode = EditMode.splitView.rawValue
        review.showComments = true

        var twoUp = PaneLayoutState()
        twoUp.editMode = EditMode.textOnly.rawValue
        twoUp.splitEditor = true

        return [
            SavedLayout(name: "Writing", state: writing),
            SavedLayout(name: "Review", state: review),
            SavedLayout(name: "Two-up", state: twoUp),
        ]
    }

    func saveCurrent(named name: String, from appState: AppState) {
        let state = PaneLayoutState.capture(from: appState)
        if let idx = layouts.firstIndex(where: { $0.name == name }) {
            layouts[idx].state = state
        } else {
            layouts.append(SavedLayout(name: name, state: state))
        }
        persist()
        logInfo("Layout saved: '\(name)'", category: "layout")
    }

    func apply(_ layout: SavedLayout, to appState: AppState) {
        layout.state.apply(to: appState)
        rememberCurrent(appState)
        logInfo("Layout applied: '\(layout.name)'", category: "layout")
    }

    func delete(_ layout: SavedLayout) {
        layouts.removeAll { $0.id == layout.id }
        persist()
    }

    /// Persist the live arrangement so a new window / next launch restores it.
    func rememberCurrent(_ appState: AppState) {
        let state = PaneLayoutState.capture(from: appState)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.lastStateKey)
        }
    }

    /// The arrangement to start a window with (last used, else defaults).
    func lastState() -> PaneLayoutState {
        if let data = UserDefaults.standard.data(forKey: Self.lastStateKey),
           let decoded = try? JSONDecoder().decode(PaneLayoutState.self, from: data) {
            return decoded
        }
        return PaneLayoutState()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(layouts) {
            UserDefaults.standard.set(data, forKey: Self.layoutsKey)
        }
    }
}
#endif // os(macOS)
