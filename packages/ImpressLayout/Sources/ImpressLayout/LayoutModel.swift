#if os(macOS)
// Kit file (ImpressLayout) — macOS-only (the layout host renders macOS window contents;
// iOS keeps its own shells). ADR-0031 work package L6.
//
//  LayoutModel.swift
//  ImpressLayout
//
//  The Swift MIRROR of the ADR-0031 layout wire value: `serde_json` of
//  `impress_layout::Layout`, handed over UniFFI as
//  `SharedLayoutSnapshot.layoutJson` / `SharedAppliedVerb.layoutJson`.
//
//  Three properties are deliberate, and each is load-bearing:
//
//  1. **Decode-only.** Nothing here is `Encodable` towards the store. Swift
//     never writes a tree — every mutation is a verb (ADR-0031 D8 invariant
//     6), and a type that could serialize a `Layout` back is the first step
//     towards a second, Swift-side source of truth (ADR-0019 D3 / ADR-0031
//     invariant 1). `LayoutJSONValue` alone is `Codable`, because the verb
//     builder in `LayoutController` needs to WRITE opaque JSON (a pane spec
//     for `split`), never a whole tree.
//
//  2. **Explicit `CodingKeys`, never `.convertFromSnakeCase`.** A key
//     strategy would rewrite the keys INSIDE `query` and `view_state`, which
//     are opaque values this layer must hand back byte-for-byte. The Rust
//     field spellings (`view_kind`, `default_channel`, `next_tile`) are
//     therefore written out by hand, once, here.
//
//  3. **Opaque where Rust is opaque.** `query` and `view_state` stay
//     `LayoutJSONValue`; only what the renderer actually branches on
//     (`view_kind`, `role`, `channel`, `session`, `params`) is typed. The
//     pane query algebra is Rust's (ADR-0031 D2) and mirroring it here would
//     be a second definition of it.
//
//  The mirror is pinned by `LayoutModelTests`, which decodes
//  `crates/impress-layout/tests/golden/three_column.json` — the same golden
//  the Rust side asserts against — so a serde change on either side fails a
//  test instead of silently producing an empty window.
//

import Foundation
import ImpressSurface

// MARK: - Opaque JSON

/// An arbitrary JSON value: what the layout keeps opaque (`query`,
/// `view_state`, a `ParamSource`'s payload) and what the verb builder emits.
///
/// The same type as `ImpressSurface.SurfaceJSONValue`, under the name the
/// layout has always used for it. There used to be two identical enums
/// (review SK-K22); a host that mixes layout and surface values now needs no
/// conversion between them. `jsonString()` sorts keys, so a verb's JSON is
/// byte-stable and can be asserted in a test without a parser.
public typealias LayoutJSONValue = SurfaceJSONValue

// MARK: - Small vocabulary

/// `impress_layout::LinearDir` — the axis a split lays its children out on.
public enum LayoutLinearDirection: String, Codable, Sendable, Hashable {
    case horizontal
    case vertical
}

/// `impress_layout::Direction` — a step from the focused leaf (the h / l
/// grammar). Kebab-case-free: every case is one word in Rust too.
public enum LayoutFocusDirection: String, Codable, Sendable, Hashable {
    case left, right, up, down, next, prev
}

/// `impress_layout::Placement` — where a moved tile lands.
public enum LayoutPlacement: String, Codable, Sendable, Hashable {
    case left, right, above, below
    /// Rust spells this `into-tabs` (the enum is `rename_all = "kebab-case"`).
    case intoTabs = "into-tabs"
}

/// `impress_layout::ContainerKind`.
public enum LayoutContainerKind: String, Codable, Sendable, Hashable {
    case tabs, horizontal, vertical, grid
}

/// `impress_layout::ChannelId` — eight numbered channels plus `follow`
/// (ADR-0031 D3). Serde form: `{"number":1}` or `"follow"`.
public enum LayoutChannel: Decodable, Sendable, Hashable {
    case number(UInt8)
    case follow

    private enum CodingKeys: String, CodingKey { case number }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            guard raw == "follow" else {
                throw DecodingError.dataCorruptedError(
                    in: single, debugDescription: "unknown channel \(raw)")
            }
            self = .follow
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self = .number(try keyed.decode(UInt8.self, forKey: .number))
    }

    /// The concrete channel number, resolving `follow` against a window
    /// default — the Swift spelling of `ChannelId::resolve`.
    public func resolved(windowDefault: LayoutChannel) -> UInt8 {
        switch self {
        case .number(let n): return min(max(n, 1), 8)
        case .follow:
            if case .number(let n) = windowDefault { return min(max(n, 1), 8) }
            return 1
        }
    }
}

// MARK: - Pane spec

/// One of a pane's parameters: its declaration plus where the value comes
/// from (`impress_layout::ParamBinding`).
public struct LayoutParamBinding: Decodable, Sendable, Hashable {
    public var name: String
    public var kind: String
    public var required: Bool
    public var source: LayoutParamSource

    private enum CodingKeys: String, CodingKey { case decl, source }
    private enum DeclKeys: String, CodingKey { case name, kind, required }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decl = try container.nestedContainer(keyedBy: DeclKeys.self, forKey: .decl)
        name = try decl.decode(String.self, forKey: .name)
        kind = try decl.decode(String.self, forKey: .kind)
        required = try decl.decodeIfPresent(Bool.self, forKey: .required) ?? false
        source = try container.decode(LayoutParamSource.self, forKey: .source)
    }
}

/// `impress_layout::ParamSource` — internally tagged on `"source"`.
public enum LayoutParamSource: Decodable, Sendable, Hashable {
    case channel(LayoutChannel)
    case fixed(item: String)
    case defaulted

    private enum CodingKeys: String, CodingKey { case source, channel, item }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .source)
        switch tag {
        case "channel":
            self = .channel(try container.decode(LayoutChannel.self, forKey: .channel))
        case "fixed":
            self = .fixed(item: try container.decode(String.self, forKey: .item))
        case "default":
            self = .defaulted
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .source, in: container,
                debugDescription: "unknown param source \(tag)")
        }
    }
}

/// `impress_layout::PaneSpec` — a query, the view kind that renders it, the
/// parameters that fill the query's blanks, the channel it publishes on, the
/// role universal chords act on, and a session handle for session-bearing
/// view kinds (ADR-0031 D1 / D6).
public struct LayoutPaneSpec: Decodable, Sendable, Hashable {
    /// Opaque: the query algebra lives in Rust (D2).
    public var query: LayoutJSONValue
    public var viewKind: String
    /// Opaque: owned by the view kind.
    public var viewState: LayoutJSONValue
    public var params: [LayoutParamBinding]
    public var channel: LayoutChannel
    public var role: String?
    public var session: String?

    private enum CodingKeys: String, CodingKey {
        case query
        case viewKind = "view_kind"
        case viewState = "view_state"
        case params
        case channel
        case role
        case session
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(LayoutJSONValue.self, forKey: .query) ?? .null
        viewKind = try container.decode(String.self, forKey: .viewKind)
        viewState = try container.decodeIfPresent(LayoutJSONValue.self, forKey: .viewState) ?? .null
        params = try container.decodeIfPresent([LayoutParamBinding].self, forKey: .params) ?? []
        channel = try container.decodeIfPresent(LayoutChannel.self, forKey: .channel) ?? .number(1)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        session = try container.decodeIfPresent(String.self, forKey: .session)
    }

    /// The record kinds the pane's query names, in order. The `select` verb
    /// needs one of these, and a row's own schema ref is NOT it (the verb
    /// takes a `RecordKindId`, not a schema ref).
    public var queryKinds: [String] {
        query["kinds"]?.stringArrayValue ?? []
    }
}

// MARK: - Tiles

/// `impress_layout::Container` — externally tagged (`{"linear": {…}}`).
public enum LayoutContainer: Decodable, Sendable, Hashable {
    case tabs(children: [UInt64], active: UInt64?)
    case linear(dir: LayoutLinearDirection, children: [UInt64], shares: [Double])
    case grid(children: [UInt64], columns: Int?)

    private enum CodingKeys: String, CodingKey { case tabs, linear, grid }
    private enum TabsKeys: String, CodingKey { case children, active }
    private enum LinearKeys: String, CodingKey { case dir, children, shares }
    private enum GridKeys: String, CodingKey { case children, columns }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.linear) {
            let linear = try container.nestedContainer(keyedBy: LinearKeys.self, forKey: .linear)
            self = .linear(
                dir: try linear.decode(LayoutLinearDirection.self, forKey: .dir),
                children: try linear.decodeIfPresent([UInt64].self, forKey: .children) ?? [],
                shares: try linear.decodeIfPresent([Double].self, forKey: .shares) ?? [])
            return
        }
        if container.contains(.tabs) {
            let tabs = try container.nestedContainer(keyedBy: TabsKeys.self, forKey: .tabs)
            self = .tabs(
                children: try tabs.decodeIfPresent([UInt64].self, forKey: .children) ?? [],
                active: try tabs.decodeIfPresent(UInt64.self, forKey: .active))
            return
        }
        if container.contains(.grid) {
            let grid = try container.nestedContainer(keyedBy: GridKeys.self, forKey: .grid)
            self = .grid(
                children: try grid.decodeIfPresent([UInt64].self, forKey: .children) ?? [],
                columns: try grid.decodeIfPresent(Int.self, forKey: .columns))
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .linear, in: container,
            debugDescription: "container is none of tabs / linear / grid")
    }

    public var children: [UInt64] {
        switch self {
        case .tabs(let children, _): return children
        case .linear(_, let children, _): return children
        case .grid(let children, _): return children
        }
    }

    public var kind: LayoutContainerKind {
        switch self {
        case .tabs: return .tabs
        case .linear(let dir, _, _): return dir == .horizontal ? .horizontal : .vertical
        case .grid: return .grid
        }
    }

    /// Relative weights, one per child, for a linear container. A child
    /// without an explicit share weighs 1 — the same fallback
    /// `SharedLayout.resize_share` applies in Rust.
    public func shares(count: Int) -> [Double] {
        guard case .linear(_, _, let shares) = self else {
            return Array(repeating: 1, count: count)
        }
        return (0..<count).map { index in
            let value = index < shares.count ? shares[index] : 1
            return value.isFinite && value > 0 ? value : LayoutShare.collapsed
        }
    }
}

/// `impress_layout::Tile` — externally tagged (`{"pane": {…}}`).
public enum LayoutTile: Decodable, Sendable, Hashable {
    case pane(LayoutPaneSpec)
    case container(LayoutContainer)

    private enum CodingKeys: String, CodingKey { case pane, container }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.pane) {
            self = .pane(try container.decode(LayoutPaneSpec.self, forKey: .pane))
            return
        }
        if container.contains(.container) {
            self = .container(try container.decode(LayoutContainer.self, forKey: .container))
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .pane, in: container,
            debugDescription: "tile is neither a pane nor a container")
    }

    public var paneSpec: LayoutPaneSpec? {
        if case .pane(let spec) = self { return spec }
        return nil
    }

    public var containerValue: LayoutContainer? {
        if case .container(let container) = self { return container }
        return nil
    }
}

/// `impress_layout::Geometry` — device-scoped, opaque to every rule.
public struct LayoutGeometry: Decodable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var display: String?
}

/// `impress_layout::Window`.
public struct LayoutWindow: Decodable, Sendable, Hashable {
    public var id: UInt64
    public var root: UInt64
    public var focused: UInt64?
    public var geometry: LayoutGeometry?
    public var defaultChannel: LayoutChannel
    public var maximized: UInt64?

    private enum CodingKeys: String, CodingKey {
        case id, root, focused, geometry, maximized
        case defaultChannel = "default_channel"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        root = try container.decode(UInt64.self, forKey: .root)
        focused = try container.decodeIfPresent(UInt64.self, forKey: .focused)
        geometry = try container.decodeIfPresent(LayoutGeometry.self, forKey: .geometry)
        defaultChannel =
            try container.decodeIfPresent(LayoutChannel.self, forKey: .defaultChannel) ?? .number(1)
        maximized = try container.decodeIfPresent(UInt64.self, forKey: .maximized)
    }
}

// MARK: - Shares

/// The one place the collapsed-share threshold is spelled in Swift.
public enum LayoutShare {
    /// Rust refuses a share of exactly zero (a weight must be positive and
    /// finite), so `SharedLayout.resize_share` spells "hidden" as `1e-4`
    /// (`impress_store_ffi::layout::MIN_SHARE`). The renderer treats anything
    /// at or below `collapsedThreshold` as zero width.
    public static let collapsed: Double = 1e-4
    public static let collapsedThreshold: Double = 1e-3

    /// Is this share a hidden pane rather than a narrow one?
    public static func isCollapsed(_ share: Double) -> Bool {
        !share.isFinite || share <= collapsedThreshold
    }
}

// MARK: - The tree

/// `impress_layout::Layout`: windows over one shared arena of tiles, plus the
/// channel state panes coordinate through.
public struct LayoutTree: Decodable, Sendable, Hashable {
    public var windows: [LayoutWindow]
    /// The arena. Rust's `BTreeMap<TileId, Tile>` serializes with STRING keys
    /// (JSON has no other kind), which is why this decodes through
    /// `[String: LayoutTile]`.
    public var tiles: [UInt64: LayoutTile]
    /// Per channel number, per record kind, the current selection
    /// (`ChannelState`, `#[serde(transparent)]`).
    public var channels: [String: [String: [String]]]
    public var nextTile: UInt64
    public var nextWindow: UInt64
    /// The key window (`Layout::current`): where a verb with no explicit
    /// window acts, and where roles resolve. Absent for a layout that never
    /// had two windows.
    public var current: UInt64?

    private enum CodingKeys: String, CodingKey {
        case windows, tiles, channels, current
        case nextTile = "next_tile"
        case nextWindow = "next_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decodeIfPresent([LayoutWindow].self, forKey: .windows) ?? []
        let rawTiles = try container.decodeIfPresent([String: LayoutTile].self, forKey: .tiles) ?? [:]
        var tiles: [UInt64: LayoutTile] = [:]
        tiles.reserveCapacity(rawTiles.count)
        for (key, tile) in rawTiles {
            guard let id = UInt64(key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tiles, in: container,
                    debugDescription: "tile id \(key) is not a number")
            }
            tiles[id] = tile
        }
        self.tiles = tiles
        channels =
            try container.decodeIfPresent([String: [String: [String]]].self, forKey: .channels) ?? [:]
        nextTile = try container.decodeIfPresent(UInt64.self, forKey: .nextTile) ?? 0
        nextWindow = try container.decodeIfPresent(UInt64.self, forKey: .nextWindow) ?? 1
        current = try container.decodeIfPresent(UInt64.self, forKey: .current)
    }

    /// Decode a `layoutJson` from `SharedLayoutSnapshot` / `SharedAppliedVerb`.
    public static func decode(_ json: String) throws -> LayoutTree {
        try JSONDecoder().decode(LayoutTree.self, from: Data(json.utf8))
    }

    // MARK: Walks
    //
    // A malformed value (a hand-edited record, a future version, a merge)
    // must not make a walk recurse forever — the same belt-and-braces Rust
    // wears (`impress_layout::MAX_DEPTH` plus a visited set).

    public static let maxDepth = 64

    public func tile(_ id: UInt64) -> LayoutTile? { tiles[id] }

    public func pane(_ id: UInt64) -> LayoutPaneSpec? { tiles[id]?.paneSpec }

    public func container(_ id: UInt64) -> LayoutContainer? { tiles[id]?.containerValue }

    public var firstWindow: LayoutWindow? { windows.first }

    /// `Layout::current_window`: the key window when it names one that
    /// exists, else the first window with a focused leaf, else the first.
    public var currentWindow: LayoutWindow? {
        if let current, let window = windows.first(where: { $0.id == current }) {
            return window
        }
        return windows.first(where: { $0.focused != nil }) ?? windows.first
    }

    /// The parent container of `id`, or nil for a window root.
    public func parent(of id: UInt64) -> UInt64? {
        for (candidate, tile) in tiles {
            if let container = tile.containerValue, container.children.contains(id) {
                return candidate
            }
        }
        return nil
    }

    /// `id`'s own relative share inside its linear parent, if it has one.
    public func share(of id: UInt64) -> Double? {
        guard let parentID = parent(of: id),
              let container = container(parentID),
              case .linear = container,
              let index = container.children.firstIndex(of: id)
        else { return nil }
        return container.shares(count: container.children.count)[index]
    }

    /// The average of `id`'s SIBLINGS' shares — what an un-collapse restores
    /// to. The remembered width lives in the tree (ADR-0031 invariant 1): no
    /// Swift value is kept across the collapse, so the average of what is
    /// actually on screen is the honest answer.
    public func siblingAverageShare(of id: UInt64) -> Double? {
        guard let parentID = parent(of: id),
              let container = container(parentID),
              case .linear = container
        else { return nil }
        let children = container.children
        let shares = container.shares(count: children.count)
        // `map { $0.1 }`, not `map(\.1)`: a key path cannot name a tuple
        // element.
        let siblings = zip(children, shares)
            .filter { $0.0 != id && !LayoutShare.isCollapsed($0.1) }
            .map { $0.1 }
        guard !siblings.isEmpty else { return nil }
        return siblings.reduce(0, +) / Double(siblings.count)
    }

    /// The leaves under `id`, in tree order — the order h / l walks.
    public func leaves(of id: UInt64) -> [UInt64] {
        var result: [UInt64] = []
        var visited: Set<UInt64> = []
        collectLeaves(id, depth: 0, visited: &visited, into: &result)
        return result
    }

    private func collectLeaves(
        _ id: UInt64, depth: Int, visited: inout Set<UInt64>, into result: inout [UInt64]
    ) {
        guard depth < Self.maxDepth, visited.insert(id).inserted else { return }
        switch tiles[id] {
        case .pane:
            result.append(id)
        case .container(let container):
            for child in container.children {
                collectLeaves(child, depth: depth + 1, visited: &visited, into: &result)
            }
        case nil:
            break
        }
    }

    /// Is `descendant` inside `root`'s subtree?
    public func subtree(_ root: UInt64, contains descendant: UInt64) -> Bool {
        if root == descendant { return true }
        return leaves(of: root).contains(descendant)
            || childContainers(of: root).contains(descendant)
    }

    private func childContainers(of root: UInt64) -> Set<UInt64> {
        var found: Set<UInt64> = []
        var frontier = container(root)?.children ?? []
        var depth = 0
        while !frontier.isEmpty, depth < Self.maxDepth {
            var next: [UInt64] = []
            for id in frontier where found.insert(id).inserted {
                next.append(contentsOf: container(id)?.children ?? [])
            }
            frontier = next
            depth += 1
        }
        return found
    }

    /// Which pane carries `role` — the Swift mirror of
    /// `Layout::pane_with_role`, used only for read-side rendering (the
    /// authoritative lookup for a chord is `SharedLayout.paneWithRole`).
    ///
    /// The same rule, not an approximation of it (review SK-K19, RL-L19): the
    /// first pane in tree order among the KEY window's leaves. It used to take
    /// the lowest tile id anywhere in the arena — another window's pane, or an
    /// orphan — so the menu's check mark could describe a different pane from
    /// the one ⌃⌘S resized.
    public func paneWithRole(_ role: String) -> UInt64? {
        guard let window = currentWindow else { return nil }
        return leaves(of: window.root).first { pane($0)?.role == role }
    }

    /// The current selection of `kind` on the channel `pane` publishes on.
    public func selection(onChannelOf pane: UInt64, kind: String) -> [String] {
        guard let spec = self.pane(pane) else { return [] }
        let windowDefault = window(containing: pane)?.defaultChannel ?? .number(1)
        let number = spec.channel.resolved(windowDefault: windowDefault)
        return channels[String(number)]?[kind] ?? []
    }

    /// The window whose subtree holds `tile`.
    public func window(containing tile: UInt64) -> LayoutWindow? {
        windows.first { subtree($0.root, contains: tile) }
    }
}
#endif
