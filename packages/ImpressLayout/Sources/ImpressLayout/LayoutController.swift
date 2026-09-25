#if os(macOS)
// Kit file (ImpressLayout) — macOS-only. ADR-0031 work package L6.
//
//  LayoutController.swift
//  ImpressLayout
//
//  The ONE object between SwiftUI and `SharedLayout`.
//
//  ## What it is allowed to hold
//
//  A decoded copy of the tree, the version it came from, the focused leaf and
//  which panes are stale. All four are DERIVED: every one of them is replaced
//  wholesale from the value Rust hands back after a verb, and none of them is
//  ever edited in place. There is no
//  `@State`, no `@AppStorage` and no `@SceneStorage` anywhere in this folder
//  for anything the tree holds — ADR-0019 D3 / ADR-0031 invariant 1: "no view
//  may hold layout state; the tree is the only source". A width, a hidden
//  pane, a selected tab and the focused pane are all tree values now.
//
//  ## What goes through `apply(_:)`
//
//  Everything. `LayoutVerb` is the closed vocabulary of ADR-0031 D8 in Swift
//  spelling; the tree-shaped cases serialize to `impress_layout::Verb` JSON
//  and go through `SharedLayout.apply(verbJson:actor:)`, and the rest are the
//  typed FFI spellings of the same vocabulary (`focusDirection`, `select`,
//  `resizeShare`, `undo`, `redo`, `saveLayout`, `applyLayout`). There is no
//  Swift-only layout operation (invariant 6), so there is nothing to look for
//  in a view when a layout misbehaves: the verb log is the whole story.
//
//  ## Three-point trace
//
//  Every mutation logs the REQUEST (category `layout`), the RESULT Rust
//  returned (version + affected panes), and what the renderer then read back
//  (tile count + focus) — CLAUDE.md's mutation / save / display trace, which
//  is the only way an async tree bug is visible at all. Watch it live:
//  `curl 'http://localhost:23120/api/logs?category=layout&limit=50'`.
//
//  ## A verb redraws the panes Rust names, and no others
//
//  Every applied verb carries `affected_panes`: for `select`, the publishing
//  pane plus every pane whose bindings the publication changed; for any other
//  verb, the panes its patch touched. A focus or a divider drag touches no
//  pane, so it names none. The controller turns that list into one refresh
//  token PER TILE (`refreshToken(for:)`), and a pane host re-resolves — and a
//  rows pane re-runs its query — only when its own token moves. Until wave 7
//  one global counter moved on every verb, so every pane in the window
//  re-compiled its query and re-ran it on every keystroke that moved focus
//  (review PH-H1 = SK-K6). The global `refreshToken` survives for hosts that
//  have not adopted the per-tile token; it now moves only when at least one
//  pane went stale, never on a verb that made none stale.
//
//  ## Errors say what failed
//
//  A refused verb is `lastRefusal` (named after the verb); a pane whose spec
//  or query would not resolve keeps ITS error (`paneError(for:)`), cleared by
//  that pane's next success; a tree Rust handed back that Swift could not
//  decode is `treeError`, sticky until a tree decodes. There used to be one
//  `lastError` for all three, cleared only by the next successful verb, so a
//  pane showed whichever refusal happened last anywhere (SK-K7 / PH-M3).
//

import Foundation
import ImpressLogging
import ImpressRustCore
import Observation

// MARK: - Pane references

/// `impress_layout::PaneRef` — how a verb names a pane. Resolution happens
/// once, in Rust; this is only the spelling.
public enum LayoutPaneRef: Sendable, Hashable {
    case id(UInt64)
    case role(String)
    case direction(LayoutFocusDirection)
    case focused

    /// The serde form: internally tagged on `"ref"`, kebab-case variants.
    public var json: LayoutJSONValue {
        switch self {
        case .id(let tile):
            return .object(["ref": .string("id"), "tile": .int(Int(tile))])
        case .role(let role):
            return .object(["ref": .string("role"), "role": .string(role)])
        case .direction(let direction):
            return .object([
                "ref": .string("direction"),
                "direction": .string(direction.rawValue),
            ])
        case .focused:
            return .object(["ref": .string("focused")])
        }
    }
}

/// Which undo ring a chord acts on (ADR-0031 D7). The editor session's own
/// ring is the third, and it is NOT here: it belongs to the responder chain.
public enum LayoutUndoStack: String, Sendable, Hashable {
    case arrangement
    case exploration
}

// MARK: - Verbs

/// Every layout gesture the Swift host can make, as a value.
///
/// The split between `verbJSON`-bearing cases and typed ones mirrors the FFI
/// exactly: `SharedLayout.apply` takes the serde form of
/// `impress_layout::Verb`, while `focus_direction` / `select` /
/// `resize_share` / `undo` / `redo` / `save_layout` / `apply_layout` /
/// `delete_layout` are typed methods on the same object (the last five are
/// service verbs — they touch the store or a ring — so they are not `Verb`
/// variants at all).
public enum LayoutVerb: Sendable, Hashable {

    // ---- arrangement (tree verbs) ----
    /// `new` is the spec of the pane created by the split; `nil` asks the
    /// service to duplicate the pane being split (its "bare split" arm).
    case split(target: LayoutPaneRef, dir: LayoutLinearDirection, after: Bool, new: LayoutJSONValue?)
    case close(target: LayoutPaneRef)
    case move(tile: LayoutPaneRef, target: LayoutPaneRef, placement: LayoutPlacement)
    case maximize(target: LayoutPaneRef)
    case restore

    // ---- content (tree verbs) ----
    case setViewKind(target: LayoutPaneRef, viewKind: ViewKindID)
    case setRole(target: LayoutPaneRef, role: String?)

    // ---- focus (tree verb) ----
    case focus(target: LayoutPaneRef)

    // ---- typed FFI spellings of the same vocabulary ----
    case focusDirection(LayoutFocusDirection)
    case select(pane: UInt64, kind: String, ids: [String])
    case resizeShare(pane: UInt64, share: Double)
    case undo(stack: LayoutUndoStack, pane: UInt64?)
    case redo(stack: LayoutUndoStack, pane: UInt64?)
    case saveLayout(name: String, purpose: String?)
    case applyLayout(nameOrOrdinal: String)
    case deleteLayout(nameOrId: String)

    /// The serde form of `impress_layout::Verb`, or nil for the cases that
    /// have a typed FFI method of their own.
    ///
    /// Tags come from `verb.rs`: the enum is `#[serde(tag = "verb",
    /// rename_all = "kebab-case")]`, so the VARIANT names are kebab-case
    /// (`move-tile`, `set-view-kind`) while the FIELD names are Rust's own
    /// snake_case (`view_kind`) — `rename_all` on an enum does not touch
    /// struct-variant fields. `LayoutVerbEncodingTests` pins every string.
    public var verbJSON: LayoutJSONValue? {
        switch self {
        case .split(let target, let dir, let after, let new):
            var object: [String: LayoutJSONValue] = [
                "verb": .string("split"),
                "target": target.json,
                "dir": .string(dir.rawValue),
                "after": .bool(after),
            ]
            if let new { object["new"] = new }
            return .object(object)

        case .close(let target):
            return .object(["verb": .string("close"), "target": target.json])

        case .move(let tile, let target, let placement):
            return .object([
                "verb": .string("move-tile"),
                "tile": tile.json,
                "target": target.json,
                "placement": .string(placement.rawValue),
            ])

        case .maximize(let target):
            return .object(["verb": .string("maximize"), "target": target.json])

        case .restore:
            return .object(["verb": .string("restore")])

        case .setViewKind(let target, let viewKind):
            return .object([
                "verb": .string("set-view-kind"),
                "target": target.json,
                "view_kind": .string(viewKind.rawValue),
            ])

        case .setRole(let target, let role):
            return .object([
                "verb": .string("set-role"),
                "target": target.json,
                "role": role.map { LayoutJSONValue.string($0) } ?? .null,
            ])

        case .focus(let target):
            return .object(["verb": .string("focus"), "target": target.json])

        case .focusDirection, .select, .resizeShare, .undo, .redo, .saveLayout, .applyLayout,
            .deleteLayout:
            return nil
        }
    }

    /// A one-line description for the request half of the three-point trace.
    public var traceDescription: String {
        switch self {
        case .split(_, let dir, _, _): return "split(\(dir.rawValue))"
        case .close: return "close"
        case .move(_, _, let placement): return "move(\(placement.rawValue))"
        case .maximize: return "maximize"
        case .restore: return "restore"
        case .setViewKind(_, let kind): return "set-view-kind(\(kind.rawValue))"
        case .setRole(_, let role): return "set-role(\(role ?? "nil"))"
        case .focus: return "focus"
        case .focusDirection(let direction): return "focus-direction(\(direction.rawValue))"
        case .select(let pane, let kind, let ids):
            return "select(pane \(pane), \(kind) × \(ids.count))"
        case .resizeShare(let pane, let share):
            return "resize-share(pane \(pane) → \(share))"
        case .undo(let stack, let pane):
            let target = pane == nil ? "focused" : String(pane!)
            return "undo(\(stack.rawValue), pane \(target))"
        case .redo(let stack, let pane):
            let target = pane == nil ? "focused" : String(pane!)
            return "redo(\(stack.rawValue), pane \(target))"
        case .saveLayout(let name, _): return "save-layout(\(name))"
        case .applyLayout(let name): return "apply-layout(\(name))"
        case .deleteLayout(let nameOrId): return "delete-layout(\(nameOrId))"
        }
    }
}

// MARK: - The invalidation bridge

/// `SharedLayoutListener` on the Rust side calls back on the FEED's thread,
/// never the caller's. This class does nothing but hop to the main actor —
/// it touches no SwiftUI state itself, which is why it can be `@unchecked
/// Sendable` honestly rather than hopefully.
final class LayoutInvalidationBridge: SharedLayoutListener, @unchecked Sendable {

    private let onPanesInvalidated: @MainActor @Sendable ([UInt64]) -> Void
    private let onLayoutChanged: @MainActor @Sendable (UInt64) -> Void

    init(
        onPanesInvalidated: @escaping @MainActor @Sendable ([UInt64]) -> Void,
        onLayoutChanged: @escaping @MainActor @Sendable (UInt64) -> Void
    ) {
        self.onPanesInvalidated = onPanesInvalidated
        self.onLayoutChanged = onLayoutChanged
    }

    func panesInvalidated(panes: [UInt64]) {
        let hop = onPanesInvalidated
        Task { @MainActor in hop(panes) }
    }

    func layoutChanged(version: UInt64) {
        let hop = onLayoutChanged
        Task { @MainActor in hop(version) }
    }
}

// MARK: - The controller

@MainActor
@Observable
public final class LayoutController {

    /// `human` | `agent` | `system` — what the operation log attributes a
    /// gesture to. The GUI is always `human`.
    public static let guiActor = "human"

    /// The decoded tree. Replaced wholesale; never edited.
    public private(set) var tree: LayoutTree?

    /// The counter every snapshot and applied verb carries. A view that has
    /// rendered this version has rendered this tree.
    public private(set) var version: UInt64 = 0

    /// The focused leaf of the current window — a TREE value, which is why
    /// there is no `@FocusState` pane enum anywhere in this folder.
    public private(set) var focused: UInt64?

    /// Panes marked stale and not yet re-run. A rows pane clears its own id
    /// with `didRefresh(_:)` after it re-ran its query. Diagnostic: what a
    /// view WATCHES is its tile's token, `refreshToken(for:)`.
    public private(set) var invalidatedPanes: Set<UInt64> = []

    /// The outcome of the most recent fallible call on this controller — a
    /// verb, a pane read, a query run — or nil when it succeeded. Kept for a
    /// caller that reads it straight after its own call (`rows()` then
    /// `lastError`); anything drawn later reads the scoped values below,
    /// because by then another pane's call may have replaced this one.
    public private(set) var lastError: String?

    /// The last verb Rust refused, with the verb named. Cleared by the next
    /// verb that applies. A refused verb is a typed refusal, never a silently
    /// empty tree.
    public private(set) var lastRefusal: String?

    /// A tree Rust handed back that Swift could not decode, or a snapshot
    /// that failed. Sticky until a tree decodes again: while it is set, the
    /// window shows an older tree than Rust holds and says so (SK-K8).
    public private(set) var treeError: String?

    /// Compatibility token: moves once whenever AT LEAST ONE pane went stale,
    /// and never on a verb that made none stale (a focus, a resize). A pane
    /// view should watch its own `refreshToken(for:)` instead — this one
    /// still reloads every pane that watches it when any one pane changes.
    public private(set) var refreshToken: UInt64 = 0

    /// Per-tile token and error, each in its own observable slot so a view
    /// that reads tile 3's token is not invalidated when tile 5's moves.
    @ObservationIgnored private var slots: [UInt64: PaneSlot] = [:]

    private let layout: SharedLayout
    public let appID: String
    /// The store the layout was opened on — what a pane that opens a Rust
    /// handle of its own (the `surface` view kind's `SharedSurface`) opens it
    /// on, so the kit never asks a host-specific adapter for it. `nil` only
    /// for a controller built without one (tests).
    public let store: SharedStore?
    public private(set) var isSubscribed = false

    /// Closes a session-bearing pane's session when its pane leaves the tree
    /// (SK-K23). Set by the host view; see `closedSessions(from:to:)`.
    @ObservationIgnored public var onSessionsClosed: (@MainActor ([String]) -> Void)?

    /// Key handlers the focused pane registered for the root's j / k / ⏎ / ⎋
    /// (SK-K14): the root is the one `.focusable()` in the window, so a pane
    /// cannot listen for keys itself without putting a second focus target
    /// around its own text fields.
    @ObservationIgnored private var keyHandlers:
        [UInt64: (owner: ObjectIdentifier, handle: @MainActor (PaneKey) -> Bool)] = [:]

    /// - Parameter startupGraceSecs: how long the invalidation feed holds its
    ///   deliveries (CLAUDE.md's startup render-loop guard). The host passes
    ///   what is LEFT of the launch window, so a window opened ten minutes in
    ///   is not deaf for 90 s (SK-K10).
    public init(
        layout: SharedLayout, appID: String, store: SharedStore? = nil,
        startupGraceSecs: UInt32 = 90
    ) {
        self.layout = layout
        self.appID = appID
        self.store = store

        // CLAUDE.md's startup render-loop guard, applied AT THE SOURCE
        // (ADR-0019 D6): the feed collects invalidations for the first 90
        // seconds and delivers nothing, so no background mutation can wake
        // SwiftUI while the window is still settling. Must be set BEFORE
        // `subscribeInvalidations`.
        layout.setStartupGraceSecs(secs: startupGraceSecs)

        reload()
        start()
    }

    /// Start (or restart) the invalidation feed. Idempotent. The host calls
    /// it every time its window appears, so a window SwiftUI hid and showed
    /// again does not stay deaf (SK-K18).
    public func start() {
        guard !isSubscribed else { return }
        subscribe()
    }

    /// Stop the invalidation feed. Called when the host's window goes away
    /// rather than from `deinit`: a `@MainActor` class cannot touch its
    /// stored properties from a nonisolated `deinit` under strict
    /// concurrency, and `SharedLayout`'s own `Drop` stops the feed anyway —
    /// this only makes the background thread go away at window close rather
    /// than whenever the last Arc is released.
    public func stop() {
        guard isSubscribed else { return }
        layout.unsubscribeInvalidations()
        isSubscribed = false
        logInfo("layout invalidation feed stopped", category: "layout")
    }

    // MARK: Reading

    /// Re-read the whole tree from Rust. The DISPLAY leg of the trace.
    ///
    /// A reload replaces the tree wholesale — another process or another
    /// window wrote it — so every pane in it is stale.
    public func reload() {
        do {
            let snapshot = try layout.snapshot()
            guard adopt(layoutJSON: snapshot.layoutJson, version: snapshot.version, focused: snapshot.focused)
            else { return }
            markStale(tree.map { tree in tree.windows.flatMap { tree.leaves(of: $0.root) } } ?? [])
            let focusText = snapshot.focused == nil ? "none" : String(snapshot.focused!)
            let tileCount = tree?.tiles.count ?? 0
            logInfo(
                "layout display: version \(snapshot.version), \(tileCount) tiles, "
                    + "focus \(focusText), \(snapshot.leaves.count) leaves",
                category: "layout")
        } catch {
            let text = Self.describe(error)
            lastError = text
            treeError = "layout snapshot failed: \(text)"
            logError("layout snapshot failed: \(text)", category: "layout")
        }
    }

    /// One pane's spec, compiled query and resolved bindings, or nil with
    /// the reason kept as the pane's error.
    public func pane(_ tile: UInt64) -> SharedPane? {
        try? resolvePane(tile)
    }

    /// `pane(_:)`, throwing what Rust refused.
    public func resolvePane(_ tile: UInt64) throws -> SharedPane {
        do {
            let pane = try layout.pane(id: tile)
            succeeded(tile)
            return pane
        } catch {
            failed(tile, "pane \(tile) did not resolve: \(Self.describe(error))")
            throw error
        }
    }

    /// Run a pane's compiled query. `limit` of 0 keeps the pane's own limit.
    ///
    /// An EMPTY array means the query ran and matched nothing, or it failed —
    /// tell them apart with `paneError(for:)`, or call `loadRows`, which
    /// throws instead.
    public func rows(for tile: UInt64, offset: UInt32 = 0, limit: UInt32 = 500) -> [SharedItemRow] {
        (try? loadRows(for: tile, offset: offset, limit: limit)) ?? []
    }

    /// `rows(for:)`, throwing what Rust refused.
    public func loadRows(
        for tile: UInt64, offset: UInt32 = 0, limit: UInt32 = 500
    ) throws -> [SharedItemRow] {
        do {
            let rows = try layout.runPane(id: tile, offset: offset, limit: limit)
            succeeded(tile)
            return rows
        } catch {
            failed(tile, "pane \(tile) query did not run: \(Self.describe(error))")
            throw error
        }
    }

    /// Which tile carries `role` right now (ADR-0031 D5). Asked of RUST, not
    /// of the decoded copy: the chords act on the authoritative tree.
    public func paneWithRole(_ role: String) -> UInt64? {
        do {
            let tile = try layout.paneWithRole(role: role)
            lastError = nil
            return tile
        } catch {
            let text = Self.describe(error)
            lastError = text
            logWarning("layout paneWithRole(\(role)) failed: \(text)", category: "layout")
            return nil
        }
    }

    public func savedLayouts() -> [SharedLayoutRow] {
        do {
            return try layout.listLayouts()
        } catch {
            logWarning("layout listLayouts failed: \(Self.describe(error))", category: "layout")
            return []
        }
    }

    /// The pane view calls this once it has re-run its query.
    public func didRefresh(_ tile: UInt64) {
        invalidatedPanes.remove(tile)
    }

    /// Tile `tile`'s refresh token: moves exactly when Rust says this pane is
    /// stale — a verb named it, the feed invalidated it, or the whole tree
    /// was reloaded. What a pane view watches to know when to re-run.
    public func refreshToken(for tile: UInt64) -> UInt64 {
        slot(tile).token
    }

    /// Why tile `tile`'s spec or query last failed, or nil once it succeeded.
    public func paneError(for tile: UInt64) -> String? {
        slot(tile).error
    }

    // MARK: Mutating

    /// THE mutation path. Every gesture in this folder ends up here.
    @discardableResult
    public func apply(_ verb: LayoutVerb) -> Bool {
        // 1. MUTATION — what was requested.
        logInfo("layout verb: \(verb.traceDescription)", category: "layout")
        do {
            let applied = try perform(verb)
            // 2. SAVE — what Rust actually did with it.
            logInfo(
                "layout applied: \(verb.traceDescription) → version \(applied.version), "
                    + "stale panes \(applied.affectedPanes), \(applied.changedTiles.count) tiles changed",
                category: "layout")
            adoptApplied(applied)
            return true
        } catch {
            // A refused verb is a REFUSAL, not an empty tree: say so.
            refused(verb.traceDescription, error)
            return false
        }
    }

    /// - Parameter actor: who asked. `guiActor` for a keystroke; the HTTP
    ///   automation surface passes its own, so the log and the undo rings can
    ///   tell a script's split from a person's (ADR-0031 D7).
    private func perform(
        _ verb: LayoutVerb, actor: String = LayoutController.guiActor
    ) throws -> SharedAppliedVerb {
        if let json = verb.verbJSON {
            return try layout.apply(verbJson: json.jsonString(), actor: actor)
        }
        switch verb {
        case .focusDirection(let direction):
            return try layout.focusDirection(dir: direction.rawValue, actor: actor)
        case .select(let pane, let kind, let ids):
            return try layout.select(pane: pane, kind: kind, ids: ids, actor: actor)
        case .resizeShare(let pane, let share):
            return try layout.resizeShare(
                pane: pane, share: Float(share), actor: actor)
        case .undo(let stack, let pane):
            return try layout.undo(stack: stack.rawValue, pane: pane, actor: actor)
        case .redo(let stack, let pane):
            return try layout.redo(stack: stack.rawValue, pane: pane, actor: actor)
        case .saveLayout(let name, let purpose):
            return try layout.saveLayout(name: name, purpose: purpose, actor: actor)
        case .applyLayout(let nameOrOrdinal):
            return try layout.applyLayout(nameOrOrdinal: nameOrOrdinal, actor: actor)
        case .deleteLayout(let nameOrId):
            return try layout.deleteLayout(nameOrId: nameOrId, actor: actor)
        default:
            // Unreachable: every case without a `verbJSON` is handled above.
            throw SharedLayoutError.Layout(message: "unroutable verb \(verb.traceDescription)")
        }
    }

    // MARK: The automation seam (ADR-0031 D8 over HTTP)

    /// Apply one `impress_layout::Verb` given as JSON, from `actor`.
    ///
    /// The door the HTTP surface comes through, and deliberately the SAME
    /// door `perform` uses for every tree-shaped verb — so there is no verb
    /// an agent can reach that a keystroke cannot, and none the log spells
    /// differently. Throws what Rust refused; the caller reports it.
    public func applyVerbJSON(_ json: String, actor: String) throws -> SharedAppliedVerb {
        logInfo("layout verb (\(actor)): \(json)", category: "layout")
        do {
            let applied = try layout.apply(verbJson: json, actor: actor)
            logInfo(
                "layout applied (\(actor)) → version \(applied.version), "
                    + "stale panes \(applied.affectedPanes)",
                category: "layout")
            adoptApplied(applied)
            return applied
        } catch {
            refused("verb (\(actor)) \(json)", error)
            throw error
        }
    }

    /// The typed half: the operations that are not `Verb` cases (undo, redo,
    /// resize-share, save-layout, apply-layout).
    public func performForAutomation(_ verb: LayoutVerb, actor: String) throws -> SharedAppliedVerb {
        logInfo("layout verb (\(actor)): \(verb.traceDescription)", category: "layout")
        do {
            let applied = try perform(verb, actor: actor)
            logInfo(
                "layout applied (\(actor)): \(verb.traceDescription) → version \(applied.version), "
                    + "stale panes \(applied.affectedPanes)",
                category: "layout")
            adoptApplied(applied)
            return applied
        } catch {
            refused("\(verb.traceDescription) (\(actor))", error)
            throw error
        }
    }

    /// The live tree as a decoded JSON object, for a caller that wants to ship
    /// it over the wire rather than render it.
    public func liveSnapshot() throws -> [String: Any] {
        let snapshot = try layout.snapshot()
        guard
            let object = try JSONSerialization.jsonObject(
                with: Data(snapshot.layoutJson.utf8)) as? [String: Any]
        else {
            throw SharedLayoutError.Layout(message: "layout JSON is not an object")
        }
        return object
    }

    /// Adopt what one verb returned: the tree, the version, the focus, the
    /// stale panes. One place, because a caller that adopted three of the four
    /// would render a tree that disagrees with the one Rust holds.
    ///
    /// Only the panes Rust NAMED go stale (PH-H1 / SK-K6). If the tree does
    /// not decode, nothing is adopted and the version stays where it was, so
    /// the feed's report of this very version reloads the tree instead of
    /// being taken for one already on screen (SK-K8).
    private func adoptApplied(_ applied: SharedAppliedVerb) {
        lastRefusal = nil
        lastError = nil
        let previous = tree
        guard adopt(layoutJSON: applied.layoutJson, version: applied.version, focused: applied.focused)
        else { return }
        // A verb that left the tree as it was redraws nothing, whatever it
        // names: an undo on an empty ring answers `ok` with EVERY pane
        // affected (Rust's "no patch means a new tree"), and a pane's data
        // cannot change without its spec, bindings or the store changing —
        // the last is the invalidation feed's to report.
        guard tree != previous else {
            logInfo("layout: verb left the tree unchanged — no pane redrawn", category: "layout")
            return
        }
        markStale(applied.affectedPanes)
        if let previous, let current = tree {
            let closed = Self.closedSessions(from: previous, to: current)
            if !closed.isEmpty {
                logInfo("layout: sessions of closed panes \(closed) released", category: "layout")
                onSessionsClosed?(closed)
            }
        }
    }

    /// Session ids a pane in `old` carried that no pane in `new` carries —
    /// the sessions a verb just closed (SK-K23). A session that MOVED to
    /// another pane (a move, a swap) is still in `new` and is not closed.
    public nonisolated static func closedSessions(from old: LayoutTree, to new: LayoutTree) -> [String] {
        func sessions(_ tree: LayoutTree) -> Set<String> {
            Set(tree.tiles.values.compactMap { $0.paneSpec?.session })
        }
        return sessions(old).subtracting(sessions(new)).sorted()
    }

    // MARK: Staleness and errors

    /// Mark `tiles` stale: each one's token moves, and the compatibility
    /// token moves once if any did.
    func markStale(_ tiles: [UInt64]) {
        guard !tiles.isEmpty else { return }
        for tile in tiles {
            invalidatedPanes.insert(tile)
            slot(tile).token &+= 1
        }
        refreshToken &+= 1
    }

    private func slot(_ tile: UInt64) -> PaneSlot {
        if let existing = slots[tile] { return existing }
        let created = PaneSlot()
        slots[tile] = created
        return created
    }

    private func succeeded(_ tile: UInt64) {
        lastError = nil
        let slot = slot(tile)
        if slot.error != nil { slot.error = nil }
    }

    private func failed(_ tile: UInt64, _ text: String) {
        lastError = text
        slot(tile).error = text
        logWarning("layout \(text)", category: "layout")
    }

    private func refused(_ what: String, _ error: Error) {
        let text = "\(what) refused: \(Self.describe(error))"
        lastRefusal = text
        lastError = text
        logWarning("layout verb \(text)", category: "layout")
    }

    /// The message a `SharedLayoutError` carries, rather than
    /// `String(describing:)`'s `Layout(message: "…")`.
    nonisolated static func describe(_ error: Error) -> String {
        guard let layoutError = error as? SharedLayoutError else { return String(describing: error) }
        switch layoutError {
        case .Layout(let message): return message
        case .Query(let message): return "query: \(message)"
        case .Store(let message): return "store: \(message)"
        case .Json(let message): return "json: \(message)"
        }
    }

    // MARK: Pane keys (SK-K14)

    /// Register what tile `tile` does with the root's j / k / ⏎ / ⎋ while it
    /// is focused. `owner` is the object whose lifetime the handler belongs
    /// to, so a view tearing down late cannot remove its successor's.
    public func setKeyHandler(
        for tile: UInt64, owner: AnyObject, _ handler: @escaping @MainActor (PaneKey) -> Bool
    ) {
        keyHandlers[tile] = (ObjectIdentifier(owner), handler)
    }

    /// Remove tile `tile`'s key handler if `owner` registered it.
    public func removeKeyHandler(for tile: UInt64, owner: AnyObject) {
        guard keyHandlers[tile]?.owner == ObjectIdentifier(owner) else { return }
        keyHandlers[tile] = nil
    }

    /// Offer `key` to the focused pane. False when it has no handler or did
    /// not use the key, so the caller can let the key go on.
    public func routeKeyToFocusedPane(_ key: PaneKey) -> Bool {
        guard let focused, let handler = keyHandlers[focused] else { return false }
        return handler.handle(key)
    }

    // MARK: Roles (the universal chords, ADR-0031 D5)

    /// ⌃⌘S / ⌥⌘0 / ⌘0: hide or show whichever pane carries `role`.
    ///
    /// Hiding is a RESIZE, never a close: closing would take the pane's
    /// session and its place in the tree with it, and a "hidden roles" set
    /// kept beside the tree would be exactly the view-held layout state
    /// ADR-0019 D3 exists to remove. So the pane stays in the tree with no
    /// width.
    ///
    /// The remembered width also lives in the tree: un-collapsing restores to
    /// the SIBLING AVERAGE rather than to a Swift-held "last share", because
    /// a Swift-held one would be a second source of truth for a layout value
    /// (and would be wrong after an `applyLayout`, an undo, or a sync from
    /// another device).
    public func toggleRole(_ role: String) {
        guard let tile = paneWithRole(role) else {
            logInfo("layout role toggle: no pane carries role '\(role)'", category: "layout")
            return
        }
        guard let current = tree?.share(of: tile) else {
            // A pane that is a window's whole root has no share to set, and
            // Rust refuses the resize rather than inventing a parent.
            logInfo(
                "layout role toggle: pane \(tile) ('\(role)') is not inside a split",
                category: "layout")
            return
        }
        if LayoutShare.isCollapsed(current) {
            let restored = tree?.siblingAverageShare(of: tile) ?? 1
            apply(.resizeShare(pane: tile, share: restored))
        } else {
            apply(.resizeShare(pane: tile, share: LayoutShare.collapsed))
        }
    }

    /// Is the pane carrying `role` currently collapsed? (Menu check marks.)
    public func roleIsCollapsed(_ role: String) -> Bool {
        guard let tile = tree?.paneWithRole(role), let share = tree?.share(of: tile) else {
            return false
        }
        return LayoutShare.isCollapsed(share)
    }

    // MARK: Undo routing (ADR-0031 D7)

    /// The view kind of the focused leaf, for the ⌘Z routing decision.
    public var focusedViewKind: ViewKindID? {
        guard let focused, let spec = tree?.pane(focused) else { return nil }
        return ViewKindID(spec.viewKind)
    }

    /// Does the focused pane own an editor session with its own undo manager?
    /// If so ⌘Z is NOT ours: it belongs to the responder chain (D7 stack 1).
    public var focusedPaneIsSessionBearing: Bool {
        guard let kind = focusedViewKind else { return false }
        return ViewKindRegistry.builtin.isSessionBearing(kind)
    }

    /// ⌘Z. Returns false when the chord belongs to the responder chain.
    @discardableResult
    public func undoInFocus() -> Bool {
        guard !focusedPaneIsSessionBearing else { return false }
        return apply(.undo(stack: .exploration, pane: focused))
    }

    /// ⇧⌘Z, same routing.
    @discardableResult
    public func redoInFocus() -> Bool {
        guard !focusedPaneIsSessionBearing else { return false }
        return apply(.redo(stack: .exploration, pane: focused))
    }

    /// ⌥⌘Z — the window's shape, always ours.
    @discardableResult
    public func undoArrangement() -> Bool {
        apply(.undo(stack: .arrangement, pane: nil))
    }

    /// ⌥⇧⌘Z.
    @discardableResult
    public func redoArrangement() -> Bool {
        apply(.redo(stack: .arrangement, pane: nil))
    }

    /// ⌘Z / ⇧⌘Z from ANY source — the Edit menu, its key equivalent, or a
    /// key press — routed per ADR-0031 D7. Returns true when the tree took
    /// the chord; false means "pass it down the responder chain", where the
    /// window's own undo manager answers it:
    ///
    /// - a text view is first responder (typing has its own undo) → false;
    /// - the focused pane is session-bearing (the editor's stack) → false;
    /// - otherwise the focused pane's EXPLORATION ring; if Rust refuses (the
    ///   ring is empty), false, so an app-level undo such as a deleted row
    ///   still answers ⌘Z instead of the chord doing nothing.
    public func routeUndoChord(redo: Bool, textIsFirstResponder: Bool) -> Bool {
        let chord = redo ? "⇧⌘Z" : "⌘Z"
        if textIsFirstResponder {
            logInfo("layout \(chord): a text view has focus → responder chain", category: "layout")
            return false
        }
        if focusedPaneIsSessionBearing {
            logInfo(
                "layout \(chord): focused pane is session-bearing → its own undo manager",
                category: "layout")
            return false
        }
        // Rust answers an empty ring with `ok` and the tree as it was, so
        // "the step did something" is "the tree changed".
        let before = tree
        let applied = (redo ? redoInFocus() : undoInFocus()) && tree != before
        if !applied {
            logInfo(
                "layout \(chord): exploration ring had nothing to take → responder chain",
                category: "layout")
        }
        return applied
    }

    // MARK: Private

    /// Should a version the invalidation feed delivers reload the tree?
    ///
    /// Only when it is NEWER than what this controller already shows. The
    /// feed reports every version the layout passes through, and each report
    /// hops to the main actor in its own `Task`, so it lands AFTER the local
    /// `apply` that caused it has already adopted a later snapshot. A gesture
    /// that applies two verbs (an outline row: `select`, then `set-query`)
    /// moved 101 → 103 locally, then received 101 and 102 — and the old test,
    /// `version != self.version`, reloaded and redrew the whole tree for each
    /// (the "layout changed elsewhere" lines after every click, 2026-09-24).
    ///
    /// `>` is exact, not a heuristic: the counter is one `AtomicU64` per
    /// `SharedLayout` that only ever `fetch_add`s, and a change made
    /// elsewhere bumps the same counter — so a real external change always
    /// arrives with a version above anything this process has adopted, and a
    /// version at or below it is already in the snapshot on screen.
    nonisolated static func isNewer(_ delivered: UInt64, than current: UInt64) -> Bool {
        delivered > current
    }

    /// Adopt a tree, its version and its focus — all three, or none.
    ///
    /// Returns false, and changes nothing but `treeError`, when the tree does
    /// not decode. Advancing `version` over a tree that is not on screen
    /// would make `isNewer` refuse the feed's reload of that same version,
    /// and the drift would outlive the moment with nothing showing it (SK-K8).
    @discardableResult
    func adopt(layoutJSON: String, version: UInt64, focused: UInt64?) -> Bool {
        let decoded: LayoutTree
        do {
            decoded = try LayoutTree.decode(layoutJSON)
        } catch {
            let text =
                "layout version \(version) did not decode — the Swift mirror and the Rust wire "
                + "form have diverged (LayoutModelTests is the gate for this): \(error)"
            treeError = text
            lastError = text
            logError(text, category: "layout")
            return false
        }
        tree = decoded
        treeError = nil
        self.version = version
        // Prefer the window's own focused leaf when the snapshot carries one;
        // both come from the same value, and the tree's is the one the
        // renderer draws the focus ring from.
        self.focused = focused ?? decoded.firstWindow?.focused
        return true
    }

    private func subscribe() {
        guard !isSubscribed else { return }
        let bridge = LayoutInvalidationBridge(
            onPanesInvalidated: { [weak self] panes in
                guard let self else { return }
                logInfo("layout invalidation: panes \(panes) stale", category: "layout")
                self.markStale(panes)
            },
            onLayoutChanged: { [weak self] version in
                guard let self, Self.isNewer(version, than: self.version) else { return }
                logInfo("layout changed elsewhere → version \(version)", category: "layout")
                self.reload()
            })
        do {
            try layout.subscribeInvalidations(listener: bridge)
            isSubscribed = true
            logInfo("layout invalidation feed started", category: "layout")
        } catch {
            lastError = Self.describe(error)
            logWarning(
                "layout invalidation feed did not start: \(error) — panes will only refresh "
                    + "on a verb",
                category: "layout")
        }
    }
}

// MARK: - Per-pane state

/// The keys the window root hands to the focused pane (SK-K14): the ADR-0033
/// widget grammar, j / k / ⏎ / ⎋, for a pane kind that has widgets to walk.
public enum PaneKey: Sendable, Hashable {
    /// j
    case down
    /// k
    case up
    /// ⏎
    case activate
    /// ⎋
    case leave
}

/// One tile's refresh token and error. A class of its own so a view that
/// reads tile 3's token depends on tile 3's slot, not on every tile's.
@MainActor
@Observable
final class PaneSlot {
    var token: UInt64 = 0
    var error: String?
}
#endif
