#if os(macOS)
// Chassis file — macOS-only. ADR-0031 work package L6.
//
//  LayoutTreeView.swift
//  PublicationManagerCore
//
//  The renderer: one walk of the Rust-owned tree (ADR-0031 D4/D9).
//
//  `Linear` → a split, `Tabs` → a tab strip, `Grid` → a grid, `Pane` → the
//  view kind the registry resolves. Nothing here decides anything about the
//  layout: every gesture is a verb on `LayoutController`, and the only state
//  any of these views hold is the IN-FLIGHT divider drag (see
//  `LayoutLinearSplit.drag`, which is discarded on release).
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
//  with a 10 pt invisible hit area and the same `NSCursor` push/pop, the same
//  `ZStack`-free `.clipped()` children, and the same
//  `.ignoresSafeArea(.container, edges: .top)` on the pane that sits under
//  the window toolbar (CLAUDE.md § macOS Toolbar & Split View Layout — the
//  rule that stops a dead strip appearing above the content).
//

import AppKit
import Foundation
import ImpressAutomation
import ImpressKeyboard
import ImpressLogging
import ImpressRustCore
import SwiftUI

// MARK: - Host

/// Opens `SharedLayout` for one app and renders its first window.
///
/// The store is warmed off-main first, exactly as `ChassisRootView` does —
/// `SharedLayout.open` needs an open `SharedStore`, and the open itself can
/// block on a TCC prompt or a WAL lock.
@MainActor
public struct LayoutTreeHost: View {

    private let appID: String

    @State private var controller: LayoutController?
    @State private var failure: String?

    public init(appID: String) {
        self.appID = appID
    }

    public var body: some View {
        Group {
            if let controller {
                LayoutWindowView(controller: controller)
            } else if let failure {
                ChassisEmptyState(
                    id: "layout-unavailable",
                    title: "Layout Unavailable",
                    systemImage: "rectangle.split.3x1",
                    message: failure
                )
                .view
            } else {
                ChassisRootLoadingView()
            }
        }
        .task {
            guard controller == nil else { return }
            await RustStoreAdapter.warmOffMain()
            guard let store = RustStoreAdapter.shared.layoutSharedStore() else {
                failure =
                    "The shared store handle the layout tree needs is not open. "
                    + "Relaunch once the workspace is reachable."
                logError("layout host: no SharedStore handle — tree not rendered", category: "layout")
                return
            }
            // `device: nil` = this machine. Window geometry is device-scoped
            // (ADR-0019 D2); the logical tree is not.
            let layout = SharedLayout.open(store: store, appId: appID, device: nil)
            // Bind the local, not the `@State` read-back: a freshly written
            // `@State` is not guaranteed to read back as the new value inside
            // the same closure, and the runtime pointer would then be nil.
            let opened = LayoutController(layout: layout, appID: appID)
            controller = opened
            LayoutTreeRuntime.shared.controller = opened
            // The HTTP automation surface drives THIS controller or answers
            // 409. Registered here, beside the runtime handle, so "a tree is
            // rendering" and "layout automation works" are one fact.
            LayoutAutomation.shared.host = opened
            logInfo("layout host: tree opened for \(appID)", category: "layout")
        }
        .onDisappear {
            controller?.stop()
            LayoutTreeRuntime.shared.controller = nil
            LayoutAutomation.shared.host = nil
        }
    }
}

/// The one live controller of this process, for the menu chords.
///
/// `Commands` values are built outside any window's environment, so ⌃⌘S /
/// ⌥⌘0 / ⌘0 / ⌃⌘1–9 cannot reach a controller through `@Environment`. It
/// holds no layout state of its own: it is a pointer to the object that asks
/// Rust.
@MainActor
public final class LayoutTreeRuntime {
    public static let shared = LayoutTreeRuntime()
    public weak var controller: LayoutController?
    private init() {}
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
            // `.focusable()` belongs on the OUTERMOST container and nowhere
            // else (CLAUDE.md § Keyboard Shortcuts): a `.focusable()` wrapper
            // around an AppKit text view swallows keys before the responder
            // chain sees them, which is why individual panes must never get
            // one.
            .focusable()
            .keyboardGuarded { press in handleCharacter(press) }
            .onKeyPress(keys: ["z", "Z"]) { press in handleUndoChord(press) }
            // h / l pressed INSIDE a pane that claims them first. `DetailView`
            // (the `info` pane) and the publication list (in a `legacy` pane)
            // answer h/l as `.handled` and post `.cycleFocusLeft/Right` for
            // imbib's pre-chassis `ContentView` to cycle its own pane focus.
            // In a chassis window nobody else observes them, so before W5 the
            // key was swallowed there and focus never moved. The tree is the
            // only root now, so they route to the one place focus lives.
            .onReceive(NotificationCenter.default.publisher(for: .cycleFocusLeft)) { _ in
                controller.apply(.focusDirection(.left))
            }
            .onReceive(NotificationCenter.default.publisher(for: .cycleFocusRight)) { _ in
                controller.apply(.focusDirection(.right))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let window = controller.tree?.firstWindow {
            // Zoom is a window view state, not a mutation: maximizing shows
            // one tile and leaves every share and session as they were.
            LayoutTileView(controller: controller, tile: window.maximized ?? window.root)
        } else {
            ChassisEmptyState(
                id: "layout-empty",
                title: "No Layout",
                systemImage: "rectangle.split.3x1",
                message: controller.lastError ?? "This app has no layout yet."
            )
            .view
        }
    }

    /// h / l over the tree — the same `TriageKeyGrammar` commands every list
    /// surface returns `.ignored` for, because pane focus is window-scoped.
    private func handleCharacter(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        switch TriageKeyGrammar.command(forCharacters: press.characters) {
        case .focusPaneLeft:
            controller.apply(.focusDirection(.left))
            return .handled
        case .focusPaneRight:
            controller.apply(.focusDirection(.right))
            return .handled
        default:
            return .ignored
        }
    }

    /// ⌘Z / ⇧⌘Z / ⌥⌘Z / ⌥⇧⌘Z, routed by the focused leaf (ADR-0031 D7).
    ///
    /// Modified keys, so `.onKeyPress` is the right modifier here rather than
    /// `.keyboardGuarded` (CLAUDE.md lists modified chords as the exception).
    /// The session ring is NOT ours: when the focused pane is session-bearing
    /// this returns `.ignored` and the editor's own undo manager gets the
    /// chord through the responder chain.
    private func handleUndoChord(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        let isRedo = press.modifiers.contains(.shift)
        if press.modifiers.contains(.option) {
            // The arrangement ring is always ours: it is the window's shape,
            // which no editor has an opinion about.
            if isRedo { controller.redoArrangement() } else { controller.undoArrangement() }
            return .handled
        }
        guard !controller.focusedPaneIsSessionBearing else { return .ignored }
        if isRedo {
            controller.redoInFocus()
        } else {
            controller.undoInFocus()
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
            ChassisEmptyState(
                id: "layout-missing-tile",
                title: "Missing Tile",
                systemImage: "questionmark.square.dashed",
                message: "Tile \(String(tile)) is not in the arena."
            )
            .view
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

extension EnvironmentValues {
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

    @ViewBuilder
    private func laidOut(sizes: [CGFloat], axis: CGFloat, band: CGFloat) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { index, tile in
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
                    .onHover { inside in
                        if inside {
                            if dir == .horizontal {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.resizeUpDown.push()
                            }
                        } else {
                            NSCursor.pop()
                        }
                    }
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
    /// appear and when the tree or the pane's data changes, never inside
    /// `body`.
    @State private var resolved: SharedPane?

    var body: some View {
        Group {
            if let resolved {
                registry.make(
                    PaneContext(
                        tile: tile, pane: resolved, spec: spec, controller: controller))
            } else {
                ChassisEmptyState(
                    id: "pane-unresolved",
                    title: "Pane Unavailable",
                    systemImage: "rectangle.dashed",
                    message: controller.lastError
                        ?? "This pane's query has not resolved yet."
                )
                .view
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(focusRing)
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
        .onAppear { resolve() }
        .onChange(of: controller.version) { _, _ in resolve() }
        .onChange(of: controller.refreshToken) { _, _ in resolve() }
    }

    @ViewBuilder
    private var focusRing: some View {
        if controller.focused == tile {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                .allowsHitTesting(false)
        }
    }

    private func resolve() {
        resolved = controller.pane(tile)
    }
}
#endif
