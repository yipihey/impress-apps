#if os(macOS)
// Chassis file — macOS-only. Plan wave 7, T4 (review PH-M6, PH-M1).
//
//  LayoutOutlinePaneState.swift
//  PublicationManagerCore
//
//  What an `outline` pane keeps across a re-layout.
//
//  A split wraps a pane in a new container, so SwiftUI rebuilds the pane's
//  host by STRUCTURE and every `@State` in it starts over. For the outline
//  that meant a split collapsed the sidebar's expansion, dropped its
//  selection and filter, re-ran `configure()` (default-leaf selection, folder
//  watchers), re-read the SciX keychain and started a second library pull.
//  The state lives here instead, keyed by (controller, tile) — the pane's
//  identity in the tree, which no split, swap or move changes — the same
//  shape as `PaneSessionRegistry` for the session-bearing kinds (ADR-0031 D6).
//

import Foundation
import ImpressLayout
import ImpressLogging
import Observation

@MainActor
final class LayoutOutlinePaneState {

    /// The chassis sidebar's own view model: expansion, selection, filter.
    let viewModel = ImbibSidebarViewModel()

    /// The tab the last COMPLETED routing acted on — a dedupe, not a
    /// selection: the selection lives in the view model and the tree. Set
    /// only once every verb of a click has applied (PH-M2), so a refused or
    /// undecodable click can be retried by clicking the row again.
    var routedTab: ImbibTab?

    /// The `list` pane's spec as this outline last saw it: after its own
    /// routing, or after reconciling. A different spec on a later version
    /// was written by someone else — an agent's `set-query`, an
    /// `apply-layout`, an undo — and the sidebar is re-read against it
    /// (PH-H5).
    var lastListSpec: LayoutPaneSpec?

    /// A selection change the OUTLINE made to follow the list, so the next
    /// `onChange(of: selectedTab)` it causes must not route it back. Set
    /// only when the selection will change; `.some(nil)` is "deselected to
    /// follow the list".
    var echo: ImbibTab??

    // MARK: Registry

    private struct Key: Hashable {
        let controller: ObjectIdentifier
        let tile: UInt64
    }

    private struct Entry {
        weak var controller: LayoutController?
        let state: LayoutOutlinePaneState
    }

    private static var entries: [Key: Entry] = [:]

    /// The state for the outline at `tile` in `controller`'s tree, made on
    /// first use. Entries whose controller has gone, or whose tile is no
    /// longer in its tree, are dropped on the way.
    static func state(for context: PaneContext) -> LayoutOutlinePaneState {
        let key = Key(controller: ObjectIdentifier(context.controller), tile: context.tile)
        entries = entries.filter { key, entry in
            guard let controller = entry.controller else { return false }
            return controller.tree?.tile(key.tile) != nil
        }
        // No log on a hit: the view calls this from `init`, which SwiftUI
        // runs on every parent re-evaluation. The remount itself is logged
        // once, by the router (`outline: remount — …`).
        if let entry = entries[key] { return entry.state }
        let state = LayoutOutlinePaneState()
        entries[key] = Entry(controller: context.controller, state: state)
        return state
    }

    static var liveCount: Int { entries.count }
}

// MARK: - Feed forms (PH-M1)

/// The feed form a scoped legacy pane should show, when it is one Rust's
/// outline node cannot name.
///
/// Edit Feed… and a library's Add Feed… are both spelled `{"node":"feed-form"}`
/// on the wire, because `impress_layout_service::OutlineNode::FeedForm`
/// carries no feed or library id — so the pane rebuilt the generic
/// `.addFeed` route and editing a feed opened feed CREATION. Until the node
/// carries the ids (an additive Rust field, left to the package that owns
/// `outline.rs`), the outline records the exact tab it routed here, keyed by
/// the pane it routed into, and the pane prefers it over the lossy node.
/// Nothing on the wire changes; an agent sending `feed-form` still gets the
/// generic form, which is what the node says.
@MainActor
@Observable
final class LayoutFeedFormRoutes {

    static let shared = LayoutFeedFormRoutes()

    private var routes: [String: ImbibTab] = [:]

    private static func key(_ controller: LayoutController, _ tile: UInt64) -> String {
        "\(ObjectIdentifier(controller).hashValue)/\(tile)"
    }

    /// Record (or, for a tab that is not a feed form, clear) what `tile`
    /// was routed to.
    func record(_ tab: ImbibTab?, into tile: UInt64, of controller: LayoutController) {
        let key = Self.key(controller, tile)
        switch tab {
        case .editFeed, .addLibraryFeed, .addFeed:
            routes[key] = tab
        default:
            routes[key] = nil
        }
    }

    /// The feed form `tile` shows, if the outline routed one there.
    func route(for tile: UInt64, of controller: LayoutController) -> ImbibTab? {
        routes[Self.key(controller, tile)]
    }

    /// The tab a scoped legacy pane hosts: the node's own, unless it is the
    /// lossy `feed-form` and the outline recorded which form it meant.
    func resolved(_ tab: ImbibTab?, tile: UInt64, controller: LayoutController) -> ImbibTab? {
        guard tab == .addFeed, let recorded = route(for: tile, of: controller) else { return tab }
        return recorded
    }
}
#endif
