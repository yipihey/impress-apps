#if os(macOS)
// Kit file (ImpressLayout) — macOS-only. ADR-0031 work package L6.
//
//  LayoutTreeView.swift
//  ImpressLayout
//
//  The renderer: one walk of the Rust-owned tree (ADR-0031 D4/D9).
//
//  `Linear` → a split, `Tabs` → a tab strip, `Grid` → a grid, `Pane` → the
//  view kind the registry resolves. Nothing here decides anything about the
//  layout: every gesture is a verb on `LayoutController`, and the only state
//  any of these views hold is the IN-FLIGHT divider drag (see
//  `LayoutLinearSplit.drag`, which is discarded on release).
//
//  ## What the host supplies (plan wave 6, W6)
//
//  The kit opens no store of its own and knows no app: `LayoutHostServices`
//  is how a host hands in the `SharedStore` to open the layout on, and what
//  to do when a controller opens or closes (PublicationManagerCore registers
//  it as the HTTP automation host there). With the defaults — an in-memory
//  store, no hooks — the tree renders on its own.
//
//  ## The only chassis root
//
//  Since plan wave 6 W5 this is what `ChassisRootView` renders for every
//  chassis app (impress, impel, implore, impart, imprint's main window) —
//  there is no switch. The `impress.layoutTree.enabled` defaults key and
//  `AppShellConfiguration.usesLayoutTree` that gated it through L6–L8 are
//  gone. imbib's own window is its pre-chassis `ContentView`, which never
//  rendered this tree and is out of W5's scope.
//
//  ## Why the split primitive is not `ImpressSplitView`
//
//  `ImpressSplitView` is a TWO-pane value (`list` + `detail`, one persisted
//  fraction, one divider) and a linear container holds N children with N
//  relative weights that live in the tree rather than in `UserDefaults`.
//  Its conventions are kept, deliberately and visibly: the same 1 pt divider
//  with a 10 pt invisible hit area (with a system pointer style rather than
//  its `NSCursor` push/pop, which could come unbalanced — SK-K25), the same
//  `ZStack`-free `.clipped()` children, and the same
//  `.ignoresSafeArea(.container, edges: .top)` on the pane that sits under
//  the window toolbar (CLAUDE.md § macOS Toolbar & Split View Layout — the
//  rule that stops a dead strip appearing above the content).
//

import AppKit
import Foundation
import ImpressKeyboard
import ImpressLogging
import ImpressRustCore
import SwiftUI

// MARK: - Host

/// What a host hands the kit so the tree can open: where the store comes
/// from, and what to do when the controller opens and closes.
///
/// Closures, not a protocol, because the host's answers are three one-liners
/// and the kit calls each exactly once per window.
public struct LayoutHostServices: Sendable {

    /// The open `SharedStore` the layout lives in, or nil when it cannot be
    /// opened (the host says why in its own log). Called once, off the first
    /// render: a store open can block on a TCC prompt or a WAL lock, so a host
    /// warms it off-main here.
    public var openStore: @MainActor @Sendable () async -> SharedStore?

    /// This controller is now the process's CURRENT tree: it just opened,
    /// its window became key, or the window that was current closed and it
    /// took over. PublicationManagerCore registers it as
    /// `LayoutAutomation.shared.host` here, so "a tree is rendering" and
    /// "layout automation works" stay one fact. May be called more than once
    /// for one controller (see `LayoutTreeRuntime`).
    public var didOpen: @MainActor @Sendable (LayoutController) -> Void

    /// This controller's window is going away; its feed has already stopped.
    /// While another tree is still open, `didOpen` for that one follows at
    /// once — so a host may clear a single "current host" slot here.
    public var didClose: @MainActor @Sendable (LayoutController) -> Void

    /// Shown while `openStore` runs.
    public var loading: @MainActor @Sendable () -> AnyView

    public init(
        openStore: @escaping @MainActor @Sendable () async -> SharedStore?,
        didOpen: @escaping @MainActor @Sendable (LayoutController) -> Void = { _ in },
        didClose: @escaping @MainActor @Sendable (LayoutController) -> Void = { _ in },
        loading: @escaping @MainActor @Sendable () -> AnyView = { AnyView(ProgressView()) }
    ) {
        self.openStore = openStore
        self.didOpen = didOpen
        self.didClose = didClose
        self.loading = loading
    }

    /// A scratch store in memory and no hooks — the kit on its own.
    public static let standalone = LayoutHostServices(openStore: {
        try? SharedStore.openInMemory()
    })
}

/// Opens `SharedLayout` for one app and renders its first window.
///
/// The host's `openStore` runs first — `SharedLayout.open` needs an open
/// `SharedStore`, and the open itself can block on a TCC prompt or a WAL
/// lock, which is why it is async.
@MainActor
public struct LayoutTreeHost: View {

    private let appID: String
    private let services: LayoutHostServices

    @State private var controller: LayoutController?
    @State private var failure: String?

    public init(appID: String, services: LayoutHostServices = .standalone) {
        self.appID = appID
        self.services = services
    }

    public var body: some View {
        Group {
            if let controller {
                LayoutWindowView(controller: controller)
            } else if let failure {
                LayoutUnavailable(
                    "Layout Unavailable", systemImage: "rectangle.split.3x1", message: failure)
            } else {
                services.loading()
            }
        }
        // Setup and teardown are one task's lifetime (SK-K18 / AC-F17). The
        // task opens the controller once, then — on EVERY appearance — starts
        // its feed and registers it, and when SwiftUI cancels the task (the
        // window closed, or a remount hid it) stops the feed and unregisters.
        // The old shape opened in `.task` and stopped in `onDisappear`, so a
        // remount that kept `@State` found the controller, returned early,
        // and left a tree whose feed was off and whose chords were dead.
        .task {
            let opened: LayoutController
            if let existing = controller {
                opened = existing
            } else {
                guard let store = await services.openStore() else {
                    failure =
                        "The shared store handle the layout tree needs is not open. "
                        + "Relaunch once the workspace is reachable."
                    logError(
                        "layout host: no SharedStore handle — tree not rendered", category: "layout")
                    return
                }
                // `device: nil` = this machine. Window geometry is
                // device-scoped (ADR-0019 D2); the logical tree is not.
                let layout = SharedLayout.open(store: store, appId: appID, device: nil)
                // Bind the local, not the `@State` read-back: a freshly
                // written `@State` is not guaranteed to read back as the new
                // value inside the same closure.
                opened = LayoutController(
                    layout: layout, appID: appID, store: store,
                    startupGraceSecs: LayoutTreeRuntime.shared.remainingStartupGrace())
                opened.onSessionsClosed = { ids in PaneSessionRegistries.release(ids) }
                controller = opened
                logInfo("layout host: tree opened for \(appID)", category: "layout")
            }
            await attend(opened)
        }
    }

    /// The window's lifetime for `controller`: feed on and registered until
    /// the task is cancelled, then feed off and unregistered — by identity,
    /// so another window's registration is untouched (SK-K10).
    private func attend(_ controller: LayoutController) async {
        controller.start()
        LayoutTreeRuntime.shared.register(controller, services: services)
        logInfo("layout host: \(appID) window attached", category: "layout")
        // Not a sleep loop that swallows cancellation (CLAUDE.md): the
        // condition is checked every time the sleep ends, and a cancelled
        // sleep ends at once.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        controller.stop()
        LayoutTreeRuntime.shared.unregister(controller)
        logInfo("layout host: \(appID) window detached", category: "layout")
    }
}

// MARK: - Window

/// One window's tree, plus the keyboard grammar that acts on it.
@MainActor
public struct LayoutWindowView: View {

    let controller: LayoutController

    public init(controller: LayoutController) {
        self.controller = controller
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { treeErrorBanner }
            // Knows the NSWindow: installs the ⌘Z routing and makes this
            // controller current when the window becomes key.
            .background(LayoutWindowAnchor(controller: controller))
            // `.focusable()` belongs on the OUTERMOST container and nowhere
            // else (CLAUDE.md § Keyboard Shortcuts): a `.focusable()` wrapper
            // around an AppKit text view swallows keys before the responder
            // chain sees them, which is why individual panes must never get
            // one — a pane that wants keys registers a handler for the root
            // to call instead (`LayoutController.setKeyHandler`).
            .focusable()
            .keyboardGuarded { press in handleCharacter(press) }
            // Special keys, so `.onKeyPress` (CLAUDE.md's exception list): a
            // focused text field keeps its own Return and Escape, and only
            // an unclaimed one reaches here.
            .onKeyPress(keys: [.return]) { _ in
                controller.routeKeyToFocusedPane(.activate) ? .handled : .ignored
            }
            .onKeyPress(keys: [.escape]) { _ in
                controller.routeKeyToFocusedPane(.leave) ? .handled : .ignored
            }
            // ⌥⌘Z / ⌥⇧⌘Z while the root has focus. Plain ⌘Z / ⇧⌘Z are Edit
            // ▸ Undo / Redo's key equivalents, which AppKit handles before
            // any key press: `LayoutWindowResponder` routes those (and these,
            // when the root does not have focus).
            .onKeyPress(keys: ["z", "Z"]) { press in handleArrangementChord(press) }
            // h / l pressed INSIDE a pane that claims them first (a hosted
            // domain view that answers them itself) reach the tree through
            // the host: PublicationManagerCore's `ChassisRootView` routes
            // `.cycleFocusLeft/Right` to `LayoutTreeRuntime`'s controller.
    }

    @ViewBuilder
    private var content: some View {
        if let window = controller.tree?.firstWindow {
            // Zoom is a window view state, not a mutation: maximizing shows
            // one tile and leaves every share and session as they were.
            LayoutTileView(controller: controller, tile: window.maximized ?? window.root)
        } else {
            LayoutUnavailable(
                "No Layout", systemImage: "rectangle.split.3x1",
                message: controller.treeError ?? "This app has no layout yet.")
        }
    }

    /// A tree Rust holds that this build could not decode: the window shows
    /// the last tree that did, and says so rather than looking current.
    @ViewBuilder
    private var treeErrorBanner: some View {
        if controller.tree != nil, let treeError = controller.treeError {
            Label(treeError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 6)
                .allowsHitTesting(false)
        }
    }

    /// h / l over the tree — the same `TriageKeyGrammar` commands every list
    /// surface returns `.ignored` for, because pane focus is window-scoped —
    /// and j / k, offered to the focused pane if it registered for them.
    private func handleCharacter(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        switch TriageKeyGrammar.command(forCharacters: press.characters) {
        case .focusPaneLeft:
            controller.apply(.focusDirection(.left))
            return .handled
        case .focusPaneRight:
            controller.apply(.focusDirection(.right))
            return .handled
        case .navigateDown:
            return controller.routeKeyToFocusedPane(.down) ? .handled : .ignored
        case .navigateUp:
            return controller.routeKeyToFocusedPane(.up) ? .handled : .ignored
        default:
            return .ignored
        }
    }

    /// ⌥⌘Z / ⌥⇧⌘Z: the window's arrangement ring (ADR-0031 D7), always the
    /// tree's — the window's shape is nothing an editor has an opinion about.
    private func handleArrangementChord(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), press.modifiers.contains(.option) else {
            return .ignored
        }
        if press.modifiers.contains(.shift) {
            controller.redoArrangement()
        } else {
            controller.undoArrangement()
        }
        return .handled
    }
}

// MARK: - Tiles

/// One tile: a pane or a container.
///
/// The recursion goes through `AnyView` on purpose. A `View` whose `body`
/// names its own type makes the opaque result type infinitely recursive;
/// erasing the children is the standard way out and costs one box per
/// container (a window has tens of tiles, not thousands).
@MainActor
struct LayoutTileView: View {

    let controller: LayoutController
    let tile: UInt64

    var body: some View {
        // `.some(…)` spelled out: the subject is an `Optional<LayoutTile>`,
        // and a bare `case .pane` does not match through the optional.
        switch controller.tree?.tile(tile) {
        case .some(.pane(let spec)):
            LayoutPaneHost(controller: controller, tile: tile, spec: spec)
        case .some(.container(let container)):
            containerView(container)
        case .none:
            LayoutUnavailable(
                "Missing Tile", systemImage: "questionmark.square.dashed",
                message: "Tile \(String(tile)) is not in the arena.")
        }
    }

    @ViewBuilder
    private func containerView(_ container: LayoutContainer) -> some View {
        switch container {
        case .linear(let dir, let children, _):
            LayoutLinearSplit(
                controller: controller,
                dir: dir,
                children: children,
                shares: container.shares(count: children.count))
        case .tabs(let children, let active):
            LayoutTabsView(controller: controller, children: children, active: active)
        case .grid(let children, let columns):
            LayoutGridView(controller: controller, children: children, columns: columns)
        }
    }

    /// The erased child every container builds its children with.
    @MainActor
    static func child(_ controller: LayoutController, _ tile: UInt64) -> AnyView {
        AnyView(LayoutTileView(controller: controller, tile: tile))
    }
}

// MARK: - Toolbar band

/// How much of a tile's top edge sits under the window toolbar band, because
/// a split above it reclaimed that band with `.ignoresSafeArea(.top)`. 0 for a
/// tile that is not under the toolbar. View geometry, not layout state: it is
/// measured, never stored in the tree.
private struct LayoutToolbarBandKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    /// Read by any pane with a control at its top edge (every detail pane's
    /// tab picker, the list pane's first row) — see `LayoutLinearSplit`.
    var layoutToolbarBand: CGFloat {
        get { self[LayoutToolbarBandKey.self] }
        set { self[LayoutToolbarBandKey.self] = newValue }
    }
}

// MARK: - Linear

/// `Container::Linear` — N children, N relative weights, N−1 dividers.
@MainActor
struct LayoutLinearSplit: View {

    let controller: LayoutController
    let dir: LayoutLinearDirection
    let children: [UInt64]
    let shares: [Double]

    /// The IN-FLIGHT divider drag, and nothing else.
    ///
    /// This is not layout state: it is discarded on release, it is never
    /// read after the verb lands, and the tree remains the only source of a
    /// pane's width (ADR-0031 invariant 1). Its existence is what lets the
    /// drag be COALESCED — `resizeShare` is called exactly once, in
    /// `onEnded`, rather than on every mouse-move. A verb per frame would
    /// write an `Ephemeral` operation per frame and wake every pane
    /// subscription behind it.
    @State private var drag: DragState?

    private struct DragState: Equatable {
        var index: Int
        var translation: CGFloat
    }

    private let dividerThickness: CGFloat = 1
    private let dividerHitLength: CGFloat = 10
    /// A drag may not shrink either neighbour below this.
    private let minimumPaneLength: CGFloat = 80

    /// The toolbar band this split's own top edge already sits under — set
    /// by an enclosing split that reclaimed it for us.
    @Environment(\.layoutToolbarBand) private var inheritedBand

    var body: some View {
        GeometryReader { geo in
            let axis = dir == .horizontal ? geo.size.width : geo.size.height
            // Measured HERE, before any child ignores it: once a child has
            // reclaimed the band its own safe area reads 0, so the height of
            // what it now sits under is only knowable from outside it.
            stack(sizes: sizes(along: axis), axis: axis, band: geo.safeAreaInsets.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func stack(sizes: [CGFloat], axis: CGFloat, band: CGFloat) -> some View {
        if dir == .horizontal {
            HStack(spacing: 0) { laidOut(sizes: sizes, axis: axis, band: band) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) { laidOut(sizes: sizes, axis: axis, band: band) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Children are identified by TILE ID, not position (SK-K11). After a
    /// close, move or split the view at index i shows a different tile; by
    /// position it kept that position's `@State` — a pane host's resolved
    /// pane, a surface pane's model, a field's draft — and for one render
    /// built tile B with tile A's view kind. Tile ids are unique within a
    /// container, and this is not `.id(tile)` on the host: a session-bearing
    /// pane keeps its host across siblings closing, which is the point of
    /// ADR-0031 D6.
    @ViewBuilder
    private func laidOut(sizes: [CGFloat], axis: CGFloat, band: CGFloat) -> some View {
        ForEach(Array(children.enumerated()), id: \.element) { index, tile in
            childView(
                tile: tile, index: index,
                size: sizes.indices.contains(index) ? sizes[index] : 0,
                band: band)
            if index + 1 < children.count,
               sizes.indices.contains(index + 1),
               sizes[index] > 0,
               sizes[index + 1] > 0 {
                divider(index: index, axis: axis)
            }
        }
    }

    /// A child with a share at or below the collapsed threshold renders with
    /// ZERO length and its divider is hidden. That is how a role toggle
    /// (⌃⌘S / ⌥⌘0 / ⌘0) hides a pane without closing it: the pane, its
    /// session and its place in the tree all survive.
    ///
    /// `band` is the toolbar band this split still sees as safe area. A child
    /// that reclaims it is told how tall it is (`layoutToolbarBand`), because
    /// a pane with a control at its top edge — every record detail pane's tab
    /// picker — has to clear it, and the section views' fixed 40 pt is the
    /// wrong number for a pane that is not under the toolbar at all.
    @ViewBuilder
    private func childView(tile: UInt64, index: Int, size: CGFloat, band: CGFloat) -> some View {
        let content = LayoutTileView.child(controller, tile)
        if dir == .horizontal {
            content
                .frame(width: max(size, 0))
                .frame(maxHeight: .infinity)
                .clipped()
                // Every pane but the first sits under the window toolbar's
                // dead strip; reclaiming it is the documented pattern.
                .ignoresSafeArea(
                    .container, edges: index == 0 ? Edge.Set() : Edge.Set.top)
                .environment(
                    \.layoutToolbarBand, index == 0 ? inheritedBand : inheritedBand + band)
        } else {
            content
                .frame(height: max(size, 0))
                .frame(maxWidth: .infinity)
                .clipped()
                // Only the top child's top edge is the split's top edge.
                .environment(\.layoutToolbarBand, index == 0 ? inheritedBand : 0)
        }
    }

    private func divider(index: Int, axis: CGFloat) -> some View {
        Divider()
            .frame(
                width: dir == .horizontal ? dividerThickness : nil,
                height: dir == .vertical ? dividerThickness : nil
            )
            .overlay(
                Color.clear
                    .frame(
                        width: dir == .horizontal ? dividerHitLength : nil,
                        height: dir == .vertical ? dividerHitLength : nil
                    )
                    .contentShape(Rectangle())
                    // The system owns the cursor stack (SK-K25): a pointer
                    // style has nothing to push or pop, so a drag that leaves
                    // the 10 pt hit area keeps the resize cursor, and a
                    // divider that vanishes under the pointer (⌃⌘S collapsing
                    // its neighbour) cannot leave it stuck.
                    .pointerStyle(
                        .frameResize(position: dir == .horizontal ? .trailing : .bottom))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .local)
                            .onChanged { value in
                                drag = DragState(
                                    index: index,
                                    translation: dir == .horizontal
                                        ? value.translation.width : value.translation.height)
                            }
                            .onEnded { _ in
                                commitDrag(index: index, axis: axis)
                                drag = nil
                            }
                    )
            )
    }

    /// Lengths along the axis, from the tree's relative weights plus the
    /// in-flight drag.
    private func sizes(along axis: CGFloat) -> [CGFloat] {
        let count = children.count
        guard count > 0, axis > 0 else { return Array(repeating: 0, count: count) }

        let weights: [Double] = (0..<count).map { index in
            let share = shares.indices.contains(index) ? shares[index] : 1
            return LayoutShare.isCollapsed(share) ? 0 : share
        }
        let visible = weights.filter { $0 > 0 }.count
        let available = max(0, axis - CGFloat(max(0, visible - 1)) * dividerThickness)
        let total = weights.reduce(0, +)

        var sizes: [CGFloat]
        if total > 0 {
            sizes = weights.map { CGFloat($0 / total) * available }
        } else {
            sizes = Array(repeating: available / CGFloat(count), count: count)
        }

        if let drag, drag.index + 1 < count, sizes[drag.index] > 0, sizes[drag.index + 1] > 0 {
            let upper = sizes[drag.index + 1] - minimumPaneLength
            let lower = -(sizes[drag.index] - minimumPaneLength)
            let delta = min(max(drag.translation, lower), upper)
            sizes[drag.index] += delta
            sizes[drag.index + 1] -= delta
        }
        return sizes
    }

    /// ONE verb per drag, on release.
    ///
    /// `resizeShare` sets one child's weight and leaves its siblings alone,
    /// so the new weight is expressed RELATIVE to the neighbour that gave up
    /// the space: the ratio on screen becomes the ratio in the tree.
    private func commitDrag(index: Int, axis: CGFloat) {
        let sizes = sizes(along: axis)
        guard index + 1 < children.count,
              sizes.indices.contains(index + 1),
              sizes[index + 1] > 0
        else { return }
        let neighbourShare = shares.indices.contains(index + 1) ? shares[index + 1] : 1
        let ratio = Double(sizes[index] / sizes[index + 1])
        let newShare = max(neighbourShare * ratio, LayoutShare.collapsed)
        controller.apply(.resizeShare(pane: children[index], share: newShare))
    }
}

// MARK: - Tabs

/// `Container::Tabs` — a strip of buttons plus the visible child.
@MainActor
struct LayoutTabsView: View {

    let controller: LayoutController
    let children: [UInt64]
    let active: UInt64?

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider()
            if let visible = visibleChild {
                LayoutTileView.child(controller, visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var strip: some View {
        HStack(spacing: 2) {
            ForEach(children, id: \.self) { tile in
                Button {
                    controller.apply(.focus(target: .id(tile)))
                } label: {
                    Text(title(of: tile))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tile == visibleChild ? Color.accentColor.opacity(0.18) : Color.clear))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    /// WHICH TAB IS VISIBLE IS DERIVED, and it has to be: the D8 vocabulary
    /// has no "set active tab" verb, and `Verb::Focus` does not activate a
    /// tab in `impress_layout::apply` today (only `move_tile … into-tabs`
    /// does). So the focused leaf's own tab wins, falling back to the
    /// container's `active` and then to the first child. Giving this view a
    /// `@State selectedTab` instead would be exactly the view-held layout
    /// state ADR-0019 D3 forbids. See the L6 note in
    /// docs/chassis-capability-matrix.md.
    private var visibleChild: UInt64? {
        if let focused = controller.focused,
           let tree = controller.tree,
           let owner = children.first(where: { tree.subtree($0, contains: focused) }) {
            return owner
        }
        return active ?? children.first
    }

    private func title(of tile: UInt64) -> String {
        guard let tree = controller.tree else { return String(tile) }
        if let spec = tree.pane(tile) {
            return spec.role ?? spec.viewKind
        }
        if let leaf = tree.leaves(of: tile).first, let spec = tree.pane(leaf) {
            return spec.role ?? spec.viewKind
        }
        return String(tile)
    }
}

// MARK: - Grid

/// `Container::Grid` — `columns` is a hint; `nil` means "renderer chooses".
@MainActor
struct LayoutGridView: View {

    let controller: LayoutController
    let children: [UInt64]
    let columns: Int?

    var body: some View {
        GeometryReader { geo in
            let columnCount = resolvedColumns
            let rowCount = max(1, Int(ceil(Double(children.count) / Double(columnCount))))
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 1), count: columnCount),
                spacing: 1
            ) {
                ForEach(children, id: \.self) { tile in
                    LayoutTileView.child(controller, tile)
                        .frame(height: geo.size.height / CGFloat(rowCount))
                        .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resolvedColumns: Int {
        if let columns, columns > 0 { return columns }
        return max(1, Int(Double(children.count).squareRoot().rounded(.up)))
    }
}

// MARK: - Pane host

/// One pane: the registry's view for its view kind, a focus ring, and a click
/// that focuses it.
///
/// **No `.id(tile)` anywhere on this host, ever.** ADR-0018 D4's invariant,
/// restated by ADR-0031 D6 for every session-bearing pane: view identity is
/// what tears an `NSTextView` (and its undo stack, and its in-flight compile)
/// down, and no layout mutation is allowed to do that. A session is released
/// through `PaneSessionRegistry`'s LRU, never through `.id`.
@MainActor
struct LayoutPaneHost: View {

    let controller: LayoutController
    let tile: UInt64
    let spec: LayoutPaneSpec

    @Environment(\.viewKindRegistry) private var registry

    /// The pane as Rust resolved it — a query COMPILE, so it is fetched on
    /// appear and when RUST SAYS this pane is stale (its own refresh token),
    /// never inside `body` and never because some other pane changed.
    @State private var resolved: SharedPane?

    var body: some View {
        Group {
            // `resolved.tile == tile`: this host's state must never render
            // another tile's pane (SK-K11). Identity is by tile now, so it
            // should always hold; if it ever does not, the pane waits for its
            // own resolve rather than borrowing a neighbour's.
            if let resolved, resolved.tile == tile {
                registry.make(
                    PaneContext(
                        tile: tile, pane: resolved, spec: spec, controller: controller))
            } else {
                LayoutUnavailable(
                    "Pane Unavailable", systemImage: "rectangle.dashed",
                    message: controller.paneError(for: tile)
                        ?? "Pane \(String(tile))'s query has not resolved yet.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A view of its own, so a focus move re-evaluates the ring and not
        // the pane's content.
        .overlay(LayoutFocusRing(controller: controller, tile: tile))
        .contentShape(Rectangle())
        // `simultaneousGesture`, not `onTapGesture`: a click must focus the
        // pane AND still reach the row, the button or the text view it landed
        // on.
        .simultaneousGesture(
            TapGesture().onEnded {
                guard controller.focused != tile else { return }
                controller.apply(.focus(target: .id(tile)))
            }
        )
        .onAppear { resolve("appeared") }
        // THIS tile's token only (PH-H1 / SK-K6). It moves when a verb names
        // the pane in `affected_panes`, when the feed invalidates it, or when
        // the whole tree was reloaded — not on a focus, a resize, or a verb
        // that changed another pane.
        .onChange(of: controller.refreshToken(for: tile)) { _, _ in resolve("stale") }
        // A maximize/restore can hand this position a different tile.
        .onChange(of: tile) { _, _ in resolve("retargeted") }
    }

    private func resolve(_ reason: String) {
        resolved = controller.pane(tile)
        LayoutPaneHost.resolveCount &+= 1
        logInfo(
            "layout pane \(tile) resolved (\(reason)) — \(resolved == nil ? "failed" : "ok")",
            category: "layout")
    }

    /// How many pane resolves this process has run — the redraw counter the
    /// wave-7 proof reads (a focus or a resize must not move it).
    @MainActor static var resolveCount = 0
}

/// The focused pane's ring.
@MainActor
struct LayoutFocusRing: View {
    let controller: LayoutController
    let tile: UInt64

    var body: some View {
        if controller.focused == tile {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                .allowsHitTesting(false)
        }
    }
}
#endif
