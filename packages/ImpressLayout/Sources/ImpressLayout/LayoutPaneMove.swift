#if os(macOS)
// Kit file (ImpressLayout) — macOS-only.
//
//  LayoutPaneMove.swift
//  ImpressLayout
//
//  How a person rearranges the tree from the window: a pane header drag, the
//  header's context menu (`LayoutPaneActions`), and the pure half of the
//  View ▸ arrange menu.
//
//  Every gesture is one existing verb, so ⌥⌘Z undoes it. The drag commits
//  `move-tile` once, on drop — the same rule as the divider's `resizeShare`.
//  Nothing here is layout state: the drag session is discarded when the drop
//  lands. A drop of a pane onto its own center is not a verb. An edge drop
//  of a pane that shares a tab strip splits that strip. A detail tab that
//  does not exist as a pane yet is a `split` whose `new` spec is that tab.
//

import AppKit
import ImpressRustCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Menu verbs

/// One arrange-menu action, as the verb it applies.
///
/// Move is not a case: a menu move needs a neighbour from the live tree
/// (`LayoutPaneMove.verb`), and a drag names its target by where it was
/// dropped. Both still end at `LayoutVerb.move`.
public enum LayoutArrange: Equatable, Sendable {
    case splitRight
    case splitBelow
    case close
    case maximize
    case restore
    case show(ViewKindID)
    case applySaved(String)
    case deleteSaved(String)

    /// The same verb aimed at `target`. Saved-layout actions name no pane.
    public func verb(targeting target: LayoutPaneRef) -> LayoutVerb {
        switch self {
        case .splitRight:
            .split(target: target, dir: .horizontal, after: true, new: nil)
        case .splitBelow:
            .split(target: target, dir: .vertical, after: true, new: nil)
        case .close:
            .close(target: target)
        case .maximize:
            .maximize(target: target)
        case .restore:
            .restore
        case .show(let kind):
            .setViewKind(target: target, viewKind: kind)
        case .applySaved(let nameOrId):
            .applyLayout(nameOrOrdinal: nameOrId)
        case .deleteSaved(let nameOrId):
            .deleteLayout(nameOrId: nameOrId)
        }
    }

    public var verb: LayoutVerb { verb(targeting: .focused) }
}

/// One row of the pane menu. `verb` is nil when the tree cannot accept it;
/// the row stays, disabled, so the menu is the vocabulary rather than a
/// second list of what happens to be possible.
public struct LayoutPaneAction: Equatable, Sendable, Identifiable {
    public enum Section: String, CaseIterable, Sendable {
        case open, arrange, move, show, role
    }

    public var id: String
    public var title: String
    public var section: Section
    /// Nil when this row cannot be applied to the pane as the tree stands.
    public var verb: LayoutVerb?
    public var checked: Bool
}

/// Every verb the host can apply to one pane without asking for a free
/// argument, in menu order.
///
/// The walk is the vocabulary: each split axis and side, the unary pane
/// verbs, every `LayoutPlacement`, the registered view kinds, and the preset
/// roles. `select`, `resizeShare`, undo, and the saved-layout verbs stay out
/// — a click does not carry a selection, a share, or a name. The View menu's
/// show and move items and a pane header's context menu both render this
/// list, so they cannot drift.
public enum LayoutPaneActions {
    /// `impress_layout::Role` consts in `crates/impress-layout/src/ids.rs`.
    /// Roles are open-ended; these are the ones the presets assign.
    public static let roles = ["navigator", "list", "detail", "preview", "console"]

    /// Registered kinds in the vocabulary's order, then any extra the host
    /// registered, sorted by id. An unregistered kind renders as a placeholder,
    /// so it is not offered.
    public static func orderedKinds(registered: Set<ViewKindID>) -> [ViewKindID] {
        let known = ViewKindID.vocabulary.filter { registered.contains($0) }
        let extra = registered.subtracting(Set(known)).sorted { $0.rawValue < $1.rawValue }
        return known + extra
    }

    /// - Parameters:
    ///   - target: the pane reference the verbs name. A header passes
    ///     `.id(tile)`; the View menu passes `.focused`.
    ///   - tile: the leaf a move steps from, and the leaf close and collapse
    ///     are checked against. Nil disables those checks' verbs.
    public static func actions(
        targeting target: LayoutPaneRef,
        tile: UInt64?,
        tree: LayoutTree?,
        kinds: [ViewKindID],
        currentKind: String? = nil,
        currentRole: String? = nil
    ) -> [LayoutPaneAction] {
        var items: [LayoutPaneAction] = []
        func add(
            _ id: String,
            _ title: String,
            _ section: LayoutPaneAction.Section,
            _ verb: LayoutVerb?,
            checked: Bool = false
        ) {
            items.append(
                LayoutPaneAction(
                    id: id, title: title, section: section, verb: verb, checked: checked))
        }

        if let tree {
            let registered = Set(kinds.map(\.rawValue))
            for pane in LayoutRoleSpec.missing(in: tree, around: tile) {
                if pane.role == "list" {
                    guard registered.contains("list") else { continue }
                    add("open-list", "Open \(pane.title)", .open, .openList)
                    continue
                }
                guard let spec = pane.spec else { continue }
                let kind = spec["view_kind"]?.stringValue ?? ""
                guard registered.contains(kind) else { continue }
                add(
                    "open-\(pane.role)",
                    "Open \(pane.title)",
                    .open,
                    .split(target: target, dir: .horizontal, after: true, new: spec))
            }
        }

        for direction in LayoutLinearDirection.allCases {
            for after in [false, true] {
                let id: String
                let title: String
                switch (direction, after) {
                case (.horizontal, false):
                    id = "split-left"
                    title = "Split Left"
                case (.horizontal, true):
                    id = "split-right"
                    title = "Split Right"
                case (.vertical, false):
                    id = "split-above"
                    title = "Split Above"
                case (.vertical, true):
                    id = "split-below"
                    title = "Split Below"
                }
                add(id, title, .arrange, .split(target: target, dir: direction, after: after, new: nil))
            }
        }
        add("close", "Close Pane", .arrange, closeVerb(targeting: target, tile: tile, tree: tree))
        add("maximize", "Maximize Pane", .arrange, .maximize(target: target))
        add("restore", "Restore Pane", .arrange, .restore)
        let collapsed = collapsedShare(tile: tile, tree: tree)
        add(
            "collapse",
            collapsed == true ? "Expand Pane" : "Collapse Pane",
            .arrange,
            collapsed == nil ? nil : .setCollapsed(target: target, collapsed: nil))
        add("focus", "Focus Pane", .arrange, .focus(target: target))

        for placement in LayoutPlacement.allCases {
            let verb: LayoutVerb?
            if let tile, let tree {
                verb = LayoutPaneMove.verb(placement: placement, tree: tree, focused: tile)
            } else {
                verb = nil
            }
            add("move-\(placement.rawValue)", moveTitle(placement), .move, verb)
        }

        for kind in kinds {
            add(
                "show-\(kind.rawValue)",
                LayoutViewKindTitle.title(kind),
                .show,
                showVerb(
                    kind, targeting: target, tile: tile, tree: tree),
                checked: currentKind == kind.rawValue)
        }

        for role in roles {
            add(
                "role-\(role)",
                LayoutViewKindTitle.title(ViewKindID(role)),
                .role,
                .setRole(target: target, role: role),
                checked: currentRole == role)
        }
        let cleared = currentRole == nil || currentRole?.isEmpty == true
        add("role-clear", "Clear Role", .role, .setRole(target: target, role: nil), checked: cleared)
        return items
    }

    /// Close is refused for the last pane of the window. When the tree does
    /// not say, the verb stays — Rust still refuses it.
    private static func closeVerb(
        targeting target: LayoutPaneRef, tile: UInt64?, tree: LayoutTree?
    ) -> LayoutVerb? {
        guard let tile, let tree,
              let root = tree.windows.first(where: { tree.subtree($0.root, contains: tile) })?.root
        else {
            return .close(target: target)
        }
        return tree.leaves(of: root).count > 1 ? .close(target: target) : nil
    }

    /// `true` when the pane is collapsed in a split, `false` when it can be
    /// collapsed, nil when it is not the child of a split (Rust refuses
    /// `set-collapsed` with `not-in-a-split`).
    private static func collapsedShare(tile: UInt64?, tree: LayoutTree?) -> Bool? {
        guard let tile, let tree, let share = tree.share(of: tile) else { return nil }
        return LayoutShare.isCollapsed(share)
    }

    /// Show → List on the sidebar, or on a copy of it, is `open-list`.
    /// The sidebar's query stays what it is. The verb focuses a list the
    /// window already has, or splits one in beside the navigator.
    private static func showVerb(
        _ kind: ViewKindID,
        targeting target: LayoutPaneRef,
        tile: UInt64?,
        tree: LayoutTree?
    ) -> LayoutVerb? {
        guard kind.rawValue == "list", let tile, let tree, let spec = tree.pane(tile),
              LayoutRoleSpec.isCollectionsQuery(spec)
        else {
            return .setViewKind(target: target, viewKind: kind)
        }
        return .openList
    }

    private static func moveTitle(_ placement: LayoutPlacement) -> String {
        switch placement {
        case .left: "Left"
        case .right: "Right"
        case .above: "Above"
        case .below: "Below"
        case .intoTabs: "Into Tabs"
        }
    }
}

/// The check mark and the disabled row, once, for both menus.
public struct LayoutPaneActionButton: View {
    let action: LayoutPaneAction
    let apply: (LayoutVerb) -> Void

    public init(action: LayoutPaneAction, apply: @escaping (LayoutVerb) -> Void) {
        self.action = action
        self.apply = apply
    }

    public var body: some View {
        Button {
            if let verb = action.verb { apply(verb) }
        } label: {
            if action.checked {
                Label(action.title, systemImage: "checkmark")
            } else {
                Text(action.title)
            }
        }
        .disabled(action.verb == nil)
    }
}

/// Menu titles for view kinds. The raw id stays the verb's argument.
public enum LayoutViewKindTitle {
    public static func title(_ kind: ViewKindID) -> String {
        switch kind.rawValue {
        case "pdf": return "PDF"
        case "bibtex": return "BibTeX"
        default:
            guard let first = kind.rawValue.first else { return kind.rawValue }
            return first.uppercased() + kind.rawValue.dropFirst()
        }
    }
}

/// A pane the window no longer has, ready to be split back in.
public struct LayoutOpenPane: Equatable, Sendable {
    public var role: String
    public var title: String
    /// The split's `new` pane. Nil for the list: that row is `open-list`,
    /// which builds the pane in Rust.
    public var spec: LayoutJSONValue?
}

/// The sidebar, the list, and the detail, rebuilt when a close removed them.
///
/// Show changes only the view kind. Splitting the sidebar therefore copies
/// the outline query — collections and libraries — and Show → List is a list
/// of those, not of the papers. The list's kinds live on a remaining detail
/// pane (its query is the list's kinds, scoped to `$item`), or, when no
/// detail remains, on the cold-start list. They are never the sidebar's.
public enum LayoutRoleSpec {
    /// Roles absent from the window that contains `tile` (or the key window).
    /// Order is the one a person looks for after a close: the list, then the
    /// detail, then the sidebar.
    public static func missing(in tree: LayoutTree, around tile: UInt64?) -> [LayoutOpenPane] {
        guard let window = window(in: tree, around: tile) else { return [] }
        let panes = tree.leaves(of: window.root).compactMap { tree.pane($0) }
        let present = Set(panes.compactMap(\.role).filter { !$0.isEmpty })
        var opened: [LayoutOpenPane] = []
        if !present.contains("list") {
            opened.append(LayoutOpenPane(
                role: "list", title: listTitle(titleKinds(panes)), spec: nil))
        }
        if !present.contains("detail"), let spec = detailSpec(panes) {
            opened.append(LayoutOpenPane(role: "detail", title: "Detail", spec: spec))
        }
        if !present.contains("navigator"), let spec = coldStartPane(role: "navigator") {
            opened.append(LayoutOpenPane(role: "navigator", title: "Sidebar", spec: spec))
        }
        return opened
    }

    private static func window(in tree: LayoutTree, around tile: UInt64?) -> LayoutWindow? {
        if let tile,
           let window = tree.windows.first(where: { tree.subtree($0.root, contains: tile) }) {
            return window
        }
        return tree.currentWindow
    }

    /// Kinds for the Open row's title. The verb decides the pane: a remaining
    /// detail, else the cold-start list. A sidebar's collections are neither.
    private static func titleKinds(_ panes: [LayoutPaneSpec]) -> [String] {
        if let kinds = kindsForList(panes), !kinds.isEmpty { return kinds }
        if let pane = coldStartPane(role: "list") {
            let kinds = kinds(of: pane)
            if !kinds.isEmpty { return kinds }
        }
        return ["publication"]
    }

    private static func kindsForList(_ panes: [LayoutPaneSpec]) -> [String]? {
        if let detail = panes.first(where: { $0.role == "detail" && !$0.queryKinds.isEmpty }) {
            return detail.queryKinds
        }
        if let item = panes.first(where: { isItemScope($0) && !$0.queryKinds.isEmpty }) {
            return item.queryKinds
        }
        return nil
    }

    /// A remaining list's kinds, scoped to `$item`. A manuscript list opens
    /// the source; everything else opens info. With no list left, the
    /// cold-start detail.
    private static func detailSpec(_ panes: [LayoutPaneSpec]) -> LayoutJSONValue? {
        guard let list = listPane(in: panes) else { return coldStartPane(role: "detail") }
        let kinds = list.queryKinds
        guard let kind = kinds.first else { return coldStartPane(role: "detail") }
        let query: LayoutJSONValue = .object([
            "kinds": .array(kinds.map { .string($0) }),
            "scope": .object([
                "scope": .string("item"),
                "id": .object(["ref": .string("param"), "name": .string("item")]),
            ]),
        ])
        let param: LayoutJSONValue = .object([
            "decl": .object([
                "name": .string("item"),
                "kind": .string(kind),
                "required": .bool(false),
            ]),
            "source": .object([
                "source": .string("channel"),
                "channel": .object(["number": .int(1)]),
            ]),
        ])
        let viewKind = kind == "manuscript" ? "source" : "info"
        return LayoutPaneSpecJSON.make(
            query: query, viewKind: viewKind, params: [param], role: "detail")
    }

    /// The paper list, not a sidebar whose view kind was changed to `list`.
    private static func listPane(in panes: [LayoutPaneSpec]) -> LayoutPaneSpec? {
        if let listed = panes.first(where: { $0.role == "list" && !$0.queryKinds.isEmpty }) {
            return listed
        }
        return panes.first {
            $0.viewKind == "list" && !$0.queryKinds.isEmpty && !isSidebarQuery($0)
        }
    }

    /// The navigator's query: collections and libraries, and not the papers
    /// or manuscripts a list shows. Public so Show → List can tell a sidebar
    /// copy from a paper list.
    public static func isCollectionsQuery(_ spec: LayoutPaneSpec) -> Bool {
        let kinds = Set(spec.queryKinds)
        return kinds.contains("collection") && kinds.contains("library")
            && !kinds.contains("publication") && !kinds.contains("manuscript")
    }

    private static func isSidebarQuery(_ spec: LayoutPaneSpec) -> Bool {
        isCollectionsQuery(spec)
    }

    private static func isItemScope(_ spec: LayoutPaneSpec) -> Bool {
        spec.query["scope"]?["scope"]?.stringValue == "item"
    }

    private static func kinds(of spec: LayoutJSONValue) -> [String] {
        spec["query"]?["kinds"]?.stringArrayValue ?? []
    }

    private static func listTitle(_ kinds: [String]) -> String {
        switch kinds.first {
        case "publication": return "Papers"
        case "manuscript": return "Manuscripts"
        case "figure": return "Figures"
        case "message": return "Messages"
        default:
            guard let first = kinds.first, let head = first.first else { return "List" }
            return String(head).uppercased() + first.dropFirst()
        }
    }

    private static let coldStart: LayoutJSONValue? = {
        try? LayoutJSONValue.decode(coldStartLayoutJson())
    }()

    private static func coldStartPane(role: String) -> LayoutJSONValue? {
        guard let tiles = coldStart?["tiles"]?.objectValue else { return nil }
        for tile in tiles.values {
            if let pane = tile["pane"], pane["role"]?.stringValue == role {
                return pane
            }
        }
        return nil
    }
}

/// A pane spec for `split`'s `new` field. `paneSpecJson` is Rust's shape;
/// this adds the role, the parameters, and the tab the split is opening.
public enum LayoutPaneSpecJSON {
    public static func make(
        query: LayoutJSONValue,
        viewKind: String,
        viewState: LayoutJSONValue? = nil,
        params: [LayoutJSONValue] = [],
        channel: LayoutChannel = .number(1),
        role: String? = nil
    ) -> LayoutJSONValue? {
        guard let queryJSON = try? query.jsonString(),
              let raw = try? paneSpecJson(queryJson: queryJSON, viewKind: viewKind),
              var object = (try? LayoutJSONValue.decode(raw))?.objectValue
        else { return nil }
        if let viewState, !viewState.isNull {
            object["view_state"] = viewState
        }
        if !params.isEmpty {
            object["params"] = .array(params)
        }
        object["channel"] = channelJSON(channel)
        if let role, !role.isEmpty {
            object["role"] = .string(role)
        } else {
            object["role"] = nil
        }
        return .object(object)
    }

    /// The same query, parameters, and channel as `spec`, rendered as
    /// `viewKind`, with no role. A detail tab pulled out into its own pane.
    public static func spawned(
        from spec: LayoutPaneSpec, viewKind: String, tab: String?
    ) -> LayoutJSONValue? {
        var state = spec.viewState.objectValue ?? [:]
        if let tab { state["tab"] = .string(tab) }
        let viewState: LayoutJSONValue? = state.isEmpty ? nil : .object(state)
        return make(
            query: spec.query,
            viewKind: viewKind,
            viewState: viewState,
            params: spec.params.map(paramJSON),
            channel: spec.channel,
            role: nil)
    }

    private static func channelJSON(_ channel: LayoutChannel) -> LayoutJSONValue {
        switch channel {
        case .number(let number):
            .object(["number": .int(Int(number))])
        case .follow:
            .string("follow")
        }
    }

    private static func paramJSON(_ binding: LayoutParamBinding) -> LayoutJSONValue {
        let source: LayoutJSONValue
        switch binding.source {
        case .channel(let channel):
            source = .object([
                "source": .string("channel"),
                "channel": channelJSON(channel),
            ])
        case .fixed(let item):
            source = .object(["source": .string("fixed"), "item": .string(item)])
        case .defaulted:
            source = .object(["source": .string("default")])
        }
        return .object([
            "decl": .object([
                "name": .string(binding.name),
                "kind": .string(binding.kind),
                "required": .bool(binding.required),
            ]),
            "source": source,
        ])
    }
}

// MARK: - Where a drop lands

/// Edge bands of a pane, and the center that means tabs.
public enum LayoutPaneDrop {
    /// Points from an edge that still count as that edge. The center is tabs.
    public static let edge: CGFloat = 36

    /// A drop of a tab onto the center of the pane it already lives in is a
    /// reorder, handled by that pane's tab strip. Anywhere else is a split.
    public static func commitsSplit(
        spawnTile: UInt64?, target: UInt64, placement: LayoutPlacement
    ) -> Bool {
        !(spawnTile == target && placement == .intoTabs)
    }

    /// A pane that does not exist yet cannot join a tab strip. The center of
    /// another pane splits it out to the right.
    public static func spawnPlacement(_ placement: LayoutPlacement) -> LayoutPlacement {
        placement == .intoTabs ? .right : placement
    }

    /// `split` of `spec` onto `target`'s edge. `intoTabs` opens to the right.
    public static func spawnVerb(
        spec: LayoutJSONValue, target: UInt64, placement: LayoutPlacement
    ) -> LayoutVerb {
        let (direction, after) = KoineGesture.splitAxes(placement)
        return .split(target: .id(target), dir: direction, after: after, new: spec)
    }

    /// `point` is in the pane's own coordinates, origin top-left.
    /// Ties keep the earlier edge: left, then right, then above, then below.
    public static func placement(
        at point: CGPoint, in size: CGSize, edge: CGFloat = LayoutPaneDrop.edge
    ) -> LayoutPlacement {
        let distances: [(LayoutPlacement, CGFloat)] = [
            (.left, max(point.x, 0)),
            (.right, max(size.width - point.x, 0)),
            (.above, max(point.y, 0)),
            (.below, max(size.height - point.y, 0)),
        ]
        let nearest = distances.min { lhs, rhs in lhs.1 < rhs.1 }
            ?? (.intoTabs, .greatestFiniteMagnitude)
        if nearest.1 > edge { return .intoTabs }
        return nearest.0
    }
}

/// The keyboard form of a pane drag: one step toward the neighbour leaf.
public enum LayoutPaneMove {
    /// The leaf a menu move uses as its target, or nil when the focused pane
    /// has no neighbour that way (it is already the first or the last).
    public static func neighbor(
        placement: LayoutPlacement, tree: LayoutTree, focused: UInt64
    ) -> UInt64? {
        let root = tree.windows.first { tree.subtree($0.root, contains: focused) }?.root
            ?? tree.firstWindow?.root
        guard let root else { return nil }
        let leaves = tree.leaves(of: root)
        guard let index = leaves.firstIndex(of: focused) else { return nil }
        switch placement {
        case .left, .above:
            return index > 0 ? leaves[index - 1] : nil
        case .right, .below:
            return index + 1 < leaves.count ? leaves[index + 1] : nil
        case .intoTabs:
            if index + 1 < leaves.count { return leaves[index + 1] }
            if index > 0 { return leaves[index - 1] }
            return nil
        }
    }

    /// `move-tile` of the focused pane onto that neighbour, or nil when there
    /// is nowhere to put it.
    public static func verb(
        placement: LayoutPlacement, tree: LayoutTree, focused: UInt64
    ) -> LayoutVerb? {
        guard let target = neighbor(placement: placement, tree: tree, focused: focused) else {
            return nil
        }
        return .move(tile: .id(focused), target: .id(target), placement: placement)
    }

    /// The verb a drop applies.
    ///
    /// A drop on a different pane is `move-tile` onto that pane. A drop of a
    /// pane onto its own center is not a verb. A drop of a pane onto its own
    /// edge is a verb only when that pane shares a tab strip: the edge names
    /// where it should sit, and the target is the neighbouring tab, so the
    /// strip becomes a split again. Two panes tabbed together have no other
    /// pane to drop on.
    public static func dropVerb(
        source: UInt64, target: UInt64, placement: LayoutPlacement, tree: LayoutTree
    ) -> LayoutVerb? {
        let gesture = KoineGesture.drag(
            element: .tile(source), target: .tile(target), placement: placement)
        if let verb = gesture.layoutVerb() { return verb }
        guard source == target,
              let sibling = tabSplitTarget(of: source, placement: placement, tree: tree)
        else { return nil }
        return KoineGesture
            .drag(element: .tile(source), target: .tile(sibling), placement: placement)
            .layoutVerb()
    }

    /// The tab a self-drop splits out beside, or nil when `tile` is not in a
    /// tab strip (or the drop is the center, which means "stay tabbed").
    ///
    /// Left and above prefer the previous tab; right and below prefer the
    /// next. A tab at the end of the strip still splits: it uses the tab on
    /// the other side, and the edge the pointer chose stays the placement.
    static func tabSplitTarget(
        of tile: UInt64, placement: LayoutPlacement, tree: LayoutTree
    ) -> UInt64? {
        guard let parent = tree.parent(of: tile),
              let container = tree.container(parent),
              case .tabs(let children, _) = container,
              let index = children.firstIndex(of: tile)
        else { return nil }
        return KoineGesture.tabSplitTarget(
            children: children, index: index, placement: placement)
    }
}

// MARK: - In-flight drag

struct LayoutPaneHover: Equatable {
    var tile: UInt64
    var placement: LayoutPlacement
}

/// Discarded when the drop lands. Not layout state: the tree is unchanged
/// until `performDrop` applies one verb.
@MainActor
@Observable
public final class LayoutPaneDragSession {
    /// A session no header writes. Used when a pane is drawn outside a window.
    public static let unused = LayoutPaneDragSession()

    /// The pane being moved. Mutually exclusive with `spawn`.
    public var source: UInt64?
    /// A pane that does not exist yet — a detail tab being pulled out into
    /// its own pane. The drop is a `split` whose `new` spec is this value.
    public var spawn: LayoutJSONValue?
    /// The pane the spawned tab already lives in. A drop on that pane's
    /// center reorders the tab; it does not split.
    public var spawnTile: UInt64?
    var hover: LayoutPaneHover?

    public func beginMoving(_ tile: UInt64) {
        source = tile
        spawn = nil
        spawnTile = nil
    }

    public func beginSpawning(_ spec: LayoutJSONValue, from tile: UInt64) {
        source = nil
        spawn = spec
        spawnTile = tile
    }
}

private struct LayoutPaneDragKey: EnvironmentKey {
    static let defaultValue: LayoutPaneDragSession? = nil
}

public extension EnvironmentValues {
    var layoutPaneDrag: LayoutPaneDragSession? {
        get { self[LayoutPaneDragKey.self] }
        set { self[LayoutPaneDragKey.self] = newValue }
    }
}

// MARK: - Header

/// The grip a pane is dragged by. Not focusable: the window root is the one
/// focus target, and a focusable wrapper here would sit above the pane's text.
@MainActor
struct LayoutPaneHeader: View {
    let controller: LayoutController
    let tile: UInt64
    let spec: LayoutPaneSpec

    @Environment(\.layoutPaneDrag) private var session
    @Environment(\.layoutToolbarBand) private var toolbarBand
    @Environment(\.viewKindRegistry) private var registry

    private static let barHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: Self.barHeight - 1)
            Divider()
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight)
        .background(Color.primary.opacity(0.06))
        .contentShape(Rectangle())
        .offset(y: headerOffset)
        .contextMenu {
            LayoutPaneContextMenu(
                controller: controller, tile: tile, spec: spec, registry: registry)
        }
        .onDrag {
            session?.beginMoving(tile)
            return NSItemProvider(object: NSString(string: String(tile)))
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                guard controller.focused != tile else { return }
                controller.apply(.focus(target: .id(tile)))
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Move \(title)")
        .accessibilityHint("Drag onto an edge to split this pane out, or onto a center to stack tabs. Secondary click lists this pane’s verbs")
        .accessibilityIdentifier("layout.pane.header.\(tile)")
        .help("Drag to an edge to split, or to a pane’s center for tabs. Secondary click lists this pane’s verbs")
    }

    /// The first visible row, just below the window toolbar. The band is the
    /// part of the pane that sits under that toolbar (`ignoresSafeArea`);
    /// a grip placed inside it is covered and cannot be dragged.
    private var headerOffset: CGFloat {
        toolbarBand
    }

    private var title: String {
        if let role = spec.role, !role.isEmpty {
            return LayoutViewKindTitle.title(ViewKindID(role))
        }
        return LayoutViewKindTitle.title(ViewKindID(spec.viewKind))
    }
}

/// Secondary click on a pane handle. Every row is `LayoutPaneActions` for
/// this tile, so the menu cannot drift from the View menu's show and move.
@MainActor
private struct LayoutPaneContextMenu: View {
    let controller: LayoutController
    let tile: UInt64
    let spec: LayoutPaneSpec
    let registry: ViewKindRegistry

    private var actions: [LayoutPaneAction] {
        LayoutPaneActions.actions(
            targeting: .id(tile),
            tile: tile,
            tree: controller.tree,
            kinds: LayoutPaneActions.orderedKinds(registered: registry.registeredKinds),
            currentKind: spec.viewKind,
            currentRole: spec.role)
    }

    var body: some View {
        let opened = actions.filter { $0.section == .open }
        if !opened.isEmpty {
            ForEach(opened) { action in
                LayoutPaneActionButton(action: action) { controller.apply($0) }
            }
            Divider()
        }
        ForEach(actions.filter { $0.section == .arrange }) { action in
            LayoutPaneActionButton(action: action) { controller.apply($0) }
        }
        Divider()
        submenu("Move", .move)
        submenu("Show", .show)
        submenu("Role", .role)
    }

    @ViewBuilder
    private func submenu(_ title: String, _ section: LayoutPaneAction.Section) -> some View {
        let items = actions.filter { $0.section == section }
        if !items.isEmpty {
            Menu(title) {
                ForEach(items) { action in
                    LayoutPaneActionButton(action: action) { controller.apply($0) }
                }
            }
        }
    }
}

// MARK: - Drop

struct LayoutPaneDropDelegate: DropDelegate {
    let tile: UInt64
    let size: CGSize
    let controller: LayoutController
    let session: LayoutPaneDragSession

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let placement = LayoutPaneDrop.placement(at: info.location, in: size)
        let tile = tile
        let session = session
        let controller = controller
        MainActor.assumeIsolated {
            let shown = session.spawn == nil ? placement : LayoutPaneDrop.spawnPlacement(placement)
            let accepted: Bool
            if session.spawn != nil {
                accepted = LayoutPaneDrop.commitsSplit(
                    spawnTile: session.spawnTile, target: tile, placement: placement)
            } else if let source = session.source, let tree = controller.tree {
                accepted = LayoutPaneMove.dropVerb(
                    source: source, target: tile, placement: shown, tree: tree) != nil
            } else {
                accepted = true
            }
            session.hover = accepted ? LayoutPaneHover(tile: tile, placement: shown) : nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        let tile = tile
        let session = session
        MainActor.assumeIsolated {
            if session.hover?.tile == tile { session.hover = nil }
        }
    }

    /// One verb, on drop. A pane dropped on its own center is not a move.
    /// A pane dropped on its own edge splits out of a tab strip
    /// (`LayoutPaneMove.dropVerb`).
    func performDrop(info: DropInfo) -> Bool {
        let placement = LayoutPaneDrop.placement(at: info.location, in: size)
        let tile = tile
        let controller = controller
        let session = session
        return MainActor.assumeIsolated {
            let source = session.source
            let spawn = session.spawn
            let spawnTile = session.spawnTile
            session.source = nil
            session.spawn = nil
            session.spawnTile = nil
            session.hover = nil
            if let spawn {
                guard LayoutPaneDrop.commitsSplit(
                    spawnTile: spawnTile, target: tile, placement: placement)
                else { return false }
                return controller.apply(
                    LayoutPaneDrop.spawnVerb(
                        spec: spawn, target: tile, placement: placement))
            }
            guard let source, let tree = controller.tree,
                  let verb = LayoutPaneMove.dropVerb(
                    source: source, target: tile, placement: placement, tree: tree)
            else { return false }
            return controller.apply(verb)
        }
    }
}

struct LayoutPaneDropHighlight: View {
    let placement: LayoutPlacement

    var body: some View {
        switch placement {
        case .intoTabs:
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(LayoutPaneDrop.edge)
                .overlay {
                    Text("Tabs")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
        case .left, .right, .above, .below:
            Color.accentColor.opacity(0.28)
                .frame(
                    width: placement == .left || placement == .right ? LayoutPaneDrop.edge : nil,
                    height: placement == .above || placement == .below ? LayoutPaneDrop.edge : nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }

    private var alignment: Alignment {
        switch placement {
        case .left: .leading
        case .right: .trailing
        case .above: .top
        case .below: .bottom
        case .intoTabs: .center
        }
    }
}
#endif
