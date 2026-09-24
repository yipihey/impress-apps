#if os(macOS)
// Kit file (ImpressLayout) — macOS-only. ADR-0031 work package L6.
//
//  ViewKindRegistry.swift
//  ImpressLayout
//
//  `ViewKindId` → the SwiftUI view that renders a pane (ADR-0031 D1/D9).
//
//  ## What the kit registers, and what the host does (plan wave 6, W6)
//
//  `ViewKindRegistry.builtin` starts with TWO factories: `placeholder` and
//  `surface`. Those are the only view kinds that need nothing but the tree,
//  the store and `ImpressSurface`. Every other kind in the vocabulary below —
//  outline, list, info, pdf, notes, bibtex, source, legacy — renders a
//  domain's own views, so the HOST registers it: PublicationManagerCore's
//  `ChassisViewKinds.registerIfNeeded()`, called from `ChassisRootView`
//  before the first pane renders. A kind nobody registered still renders,
//  as the placeholder, which keeps the spec (ADR-0031 D4) — so a host that
//  registers nothing gets a tree of placeholders, the kit's standalone proof.
//
//  This is `RecordViewerRegistry` one level down: that registry answers "what
//  view does this record KIND get", this one answers "what view does this
//  PANE get", and a pane is a query plus a view kind, not a kind. The two
//  coexist on purpose — a `list` pane over publications will eventually build
//  its rows through `RecordViewerRegistry.makeListRow`, and the legacy view
//  kind hosts routes that resolve through it today.
//
//  Registration discipline, copied from `RecordViewerRegistry` verbatim: the
//  registry is a `@unchecked Sendable` final class over a lock, the factories
//  are `@MainActor @Sendable` closures returning `AnyView`, and a MISSING
//  view kind degrades to `placeholder` — which keeps the pane's spec
//  (ADR-0031 D4: "a pane whose view kind the platform cannot render becomes a
//  placeholder that keeps its spec"), so a layout made on a build that has
//  the view kind survives a round trip through one that does not.
//

import Foundation
import ImpressLogging
import ImpressRustCore
import SwiftUI

// MARK: - View kind id

/// `impress_layout::ViewKindId` — the registry key, as a string newtype so an
/// app can register one this file has never heard of.
public struct ViewKindID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    // The builtin vocabulary. The first five are the ones `impress_layout`'s
    // own constants name; `source`, `notes` and `bibtex` are imbib's detail
    // tabs, which become panes in L8.
    public static let outline = ViewKindID("outline")
    public static let list = ViewKindID("list")
    public static let info = ViewKindID("info")
    public static let pdf = ViewKindID("pdf")
    public static let notes = ViewKindID("notes")
    public static let bibtex = ViewKindID("bibtex")
    /// `impress_layout::ViewKindId::SOURCE` — the manuscript editor, the
    /// session-bearing view kind of ADR-0031 D6 (imbib's `DetailTab.source`).
    public static let source = ViewKindID("source")
    /// Hosts a legacy `SectionContentView` route unchanged (ADR-0031 D11).
    public static let legacy = ViewKindID("legacy")
    public static let placeholder = ViewKindID("placeholder")
    /// ADR-0033 — an agent-authored `impress/ui/surface@1.0.0` document,
    /// rendered by `packages/ImpressSurface`'s `SurfaceView`. The pane's
    /// query is `item(id)` of the surface, so this is an ordinary view kind
    /// with no special case anywhere else in the tree (ADR-0033 D1).
    public static let surface = ViewKindID("surface")

    /// The kinds the kit itself has a factory for. The rest of the
    /// vocabulary above is a host's to register (see the file header).
    public static let kitBuiltins: [ViewKindID] = [.placeholder, .surface]
}

// MARK: - Pane context

/// What a view-kind factory is handed: which tile it is, what Rust says that
/// pane is, and the controller every gesture goes back through.
///
/// Not `Sendable` by design — it carries the `@MainActor` controller, and a
/// pane view that wanted to take it off the main actor would be doing
/// something this architecture does not do.
public struct PaneContext {
    public let tile: UInt64
    /// The pane as Rust resolved it: the compiled query, the bindings, the
    /// single item a detail pane short-circuits on.
    public let pane: SharedPane
    /// The same pane's spec, decoded — `nil` only if the wire form and the
    /// Swift mirror have diverged (which `LayoutModelTests` exists to catch).
    public let spec: LayoutPaneSpec?
    public let controller: LayoutController
    /// Parameter name → the item id it resolves to right now.
    public let bindings: [String: String]

    public init(
        tile: UInt64,
        pane: SharedPane,
        spec: LayoutPaneSpec?,
        controller: LayoutController
    ) {
        self.tile = tile
        self.pane = pane
        self.controller = controller
        self.spec =
            spec
            ?? (try? JSONDecoder().decode(LayoutPaneSpec.self, from: Data(pane.specJson.utf8)))
        var bindings: [String: String] = [:]
        if let object = try? LayoutJSONValue.decode(pane.bindingsJson).objectValue {
            for (name, value) in object {
                if let id = value.stringValue { bindings[name] = id }
            }
        }
        self.bindings = bindings
    }

    public var viewKind: ViewKindID { ViewKindID(pane.viewKind) }

    public var role: String? { pane.role }

    /// Set when the pane's scope was a single item and it resolved — what a
    /// detail pane renders.
    public var singleItem: String? { pane.singleItem }

    /// The record kind the pane's query names first — the DEFAULT for a
    /// selection, and only that.
    ///
    /// A pane whose query names several kinds (the navigator asks for
    /// `["collection", "library"]`) publishes rows of more than one kind, and
    /// the verb takes ONE `RecordKindId`. Publishing the query's first kind
    /// for every row meant selecting the "Save" LIBRARY published it as a
    /// collection, so the list pane's `library` parameter never bound and the
    /// list sat on "Nothing Here" while a row was visibly selected. The row's
    /// own kind is what a selection means; see `select(_:kind:)`.
    public var primaryKind: String? { spec?.queryKinds.first }

    /// Run the pane's compiled query.
    @MainActor
    public func rows(limit: UInt32 = 500) -> [SharedItemRow] {
        controller.rows(for: tile, limit: limit)
    }

    /// Publish a selection on this pane's channel — what clicking a row is.
    /// An empty list is a real value ("nothing of that kind is selected"),
    /// which is what a detail pane renders its empty state from.
    @MainActor
    public func select(_ ids: [String]) {
        select(ids, kind: nil)
    }

    /// Publish a selection of `kind` — the kind of the ROWS selected, which a
    /// mixed-kind pane must pass because its query's first kind is not it.
    @MainActor
    public func select(_ ids: [String], kind rowKind: String?) {
        guard let kind = rowKind ?? primaryKind else {
            logWarning(
                "pane \(tile) published no selection: its query names no record kind",
                category: "layout")
            return
        }
        // Selecting IS clicking, so FOCUS FOLLOWS (ADR-0031 D5/D7): the chords
        // and ⌘Z act on the focused pane, and a user who just clicked a row
        // means that pane. The container's `simultaneousGesture` in
        // `LayoutTreeView` cannot do it for a rows pane — the List row
        // consumes the tap first. Verified in the running shell 2026-09-21:
        // clicking a navigator row published `select` and left the focus ring
        // three panes away. A keyboard-driven selection is already in the
        // focused pane, so this is a no-op there rather than a second verb.
        if controller.focused != tile {
            controller.apply(.focus(target: .id(tile)))
        }
        controller.apply(.select(pane: tile, kind: kind, ids: ids))
    }

    /// The current selection on this pane's channel, from the TREE — the pane
    /// holds no selection of its own (ADR-0031 invariant 1).
    @MainActor
    public var currentSelection: Set<String> {
        guard let kind = primaryKind,
              let tree = controller.tree
        else { return [] }
        return Set(tree.selection(onChannelOf: tile, kind: kind))
    }
}

// MARK: - Factory

public struct ViewKindFactory: Identifiable, Sendable {
    public var id: ViewKindID { kind }
    public let kind: ViewKindID
    /// Does this view kind own state that must survive re-layout — an
    /// `NSTextView` and its undo stack, an in-flight compile, a draft
    /// (ADR-0031 D6)? If so its session lives in a `PaneSessionRegistry`,
    /// ⌘Z belongs to the responder chain, and the tree view must never put
    /// `.id(tile)` on its host.
    public let isSessionBearing: Bool
    public let make: @MainActor @Sendable (PaneContext) -> AnyView

    public init(
        kind: ViewKindID,
        isSessionBearing: Bool = false,
        make: @escaping @MainActor @Sendable (PaneContext) -> AnyView
    ) {
        self.kind = kind
        self.isSessionBearing = isSessionBearing
        self.make = make
    }
}

// MARK: - Registry

public final class ViewKindRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var factories: [ViewKindID: ViewKindFactory]

    public init(_ factories: [ViewKindFactory] = []) {
        self.factories = Dictionary(
            factories.map { ($0.kind, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func register(_ factory: ViewKindFactory) {
        lock.withLock { factories[factory.kind] = factory }
    }

    public subscript(kind: ViewKindID) -> ViewKindFactory? {
        lock.withLock { factories[kind] }
    }

    public var registeredKinds: Set<ViewKindID> {
        lock.withLock { Set(factories.keys) }
    }

    public func contains(_ kind: ViewKindID) -> Bool {
        self[kind] != nil
    }

    public func isSessionBearing(_ kind: ViewKindID) -> Bool {
        self[kind]?.isSessionBearing ?? false
    }

    /// The kind that will actually render: `kind` when it is registered,
    /// `.placeholder` otherwise. Pure lookup, so a test can prove the
    /// fallback without building a view (ADR-0031 D4's degradation rule).
    public func resolvedKind(for kind: ViewKindID) -> ViewKindID {
        contains(kind) ? kind : .placeholder
    }

    /// Build the pane's view. Never fails: an unregistered kind gets the
    /// placeholder, which names what is missing and keeps the spec.
    @MainActor
    public func make(_ context: PaneContext) -> AnyView {
        let kind = context.viewKind
        if let factory = self[kind] {
            return factory.make(context)
        }
        logInfo(
            "pane \(context.tile): no view kind '\(kind.rawValue)' in this build — placeholder",
            category: "layout")
        return AnyView(LayoutPlaceholderPaneView(context: context))
    }

    // MARK: Builtin

    /// The registry the tree renders from (the environment's default) and
    /// the one `LayoutController` asks about session-bearing kinds: the kit's
    /// two factories, plus whatever the host `register(_:)`s at startup.
    ///
    /// Shared and mutable on purpose, like `RecordViewerRegistry`: the host
    /// registers once, before the first pane renders, and every lookup after
    /// that sees the host's kinds. A registration replaces an earlier one, so
    /// a host may also override a kit factory (PublicationManagerCore gives
    /// `surface` its suite-aware hooks that way).
    public static let builtin: ViewKindRegistry = ViewKindRegistry([
        ViewKindFactory(kind: .placeholder) { AnyView(LayoutPlaceholderPaneView(context: $0)) },
        ViewKindFactory(kind: .surface) { AnyView(LayoutSurfacePaneView(context: $0)) },
    ])
}

// MARK: - Environment

private struct ViewKindRegistryKey: EnvironmentKey {
    static let defaultValue = ViewKindRegistry.builtin
}

public extension EnvironmentValues {
    var viewKindRegistry: ViewKindRegistry {
        get { self[ViewKindRegistryKey.self] }
        set { self[ViewKindRegistryKey.self] = newValue }
    }
}

// MARK: - Builtin views

/// A view kind this build cannot render. Names the kind and keeps the spec
/// visible, so the pane is diagnosable rather than blank (ADR-0031 D4).
///
/// `@MainActor` on the whole view rather than on `body` alone, as every pane
/// view: they call `@MainActor` members of `PaneContext` / `LayoutController`
/// from helpers and gesture closures, and a nonisolated helper on a `View`
/// struct cannot.
@MainActor
public struct LayoutPlaceholderPaneView: View {

    let context: PaneContext

    public init(context: PaneContext) {
        self.context = context
    }

    public var body: some View {
        // The copy and glyph `ChassisEmptyState`'s "view-kind-unavailable"
        // state used before the move, spelled here because the kit cannot see
        // the chassis' empty-state table.
        ContentUnavailableView {
            Label("View Kind Unavailable", systemImage: LayoutUnavailable.unknownSymbolName)
        } description: {
            Text("This build has no view for \u{201C}\(context.viewKind.rawValue)\u{201D}.")
        } actions: {
            VStack(alignment: .leading, spacing: 4) {
                if let kinds = context.spec?.queryKinds, !kinds.isEmpty {
                    Text("query kinds: \(kinds.joined(separator: ", "))")
                }
                if let role = context.role {
                    Text("role: \(role)")
                }
                Text("tile \(String(context.tile))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - Unavailable states

/// The kit's empty/unavailable state: the same `ContentUnavailableView`
/// PublicationManagerCore's `ChassisEmptyState.view` draws, so a kit pane and
/// a chassis pane read alike. Data, not a table: the kit's handful of states
/// are spelled at their one call site each.
public struct LayoutUnavailable: View {

    /// `RecordKindDescriptor.unknownSymbolName`'s value.
    public static let unknownSymbolName = "questionmark.square.dashed"

    let title: String
    let systemImage: String
    let message: String

    public init(_ title: String, systemImage: String, message: String) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}
#endif
