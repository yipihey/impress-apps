// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a protocol, an
// environment value and an in-memory fallback. No AppKit.
//
//  HostWindowPanes.swift
//  PublicationManagerCore
//
//  Which of the legacy section views' panes a HOST window shows. imbib's
//  pre-chassis window keeps its own layout model (sidebar / list / detail
//  visibility and the detail tab, driven by ⌘0 / ⌥⌘0 / ⌃⌘S, its saved layouts
//  and `/api/layout`) in its own app target, and hands it to these views
//  through the environment. Inside the layout tree nobody sets it: the tree
//  decides what is on screen, so a hosted section view shows its list and its
//  detail, and a whole hosted `TabContentView` keeps its own panes in memory
//  (`OwnWindowPanes`).
//

import Observation
import SwiftUI

/// A host window's pane model, as the legacy section views read and write it.
///
/// `@Observable` conformers are what make a change redraw: a view reads these
/// properties in `body`, and Observation tracks the reads through the
/// existential.
@MainActor
public protocol HostWindowPanes: AnyObject, Sendable {
    /// The leading sidebar column (⌃⌘S).
    var sidebarVisible: Bool { get set }
    /// The list pane, the middle column of every route (⌥⌘0).
    var listPaneVisible: Bool { get set }
    /// The detail pane (⌘0).
    var detailPaneVisible: Bool { get set }
    /// The selected detail tab, a `DetailTab` raw value.
    var detailTab: String { get set }
}

/// Panes nobody else owns: every pane shown, kept in memory for the life of
/// the view that made it. A `TabContentView` hosted by the layout tree uses
/// one, so its list toggle still hides its own list.
@MainActor
@Observable
final class OwnWindowPanes: HostWindowPanes {
    var sidebarVisible = true
    var listPaneVisible = true
    var detailPaneVisible = true
    var detailTab = DetailTab.info.rawValue
}

private struct HostWindowPanesKey: EnvironmentKey {
    static var defaultValue: (any HostWindowPanes)? { nil }
}

public extension EnvironmentValues {
    /// The host window's pane model, or nil inside the layout tree.
    var hostWindowPanes: (any HostWindowPanes)? {
        get { self[HostWindowPanesKey.self] }
        set { self[HostWindowPanesKey.self] = newValue }
    }
}
