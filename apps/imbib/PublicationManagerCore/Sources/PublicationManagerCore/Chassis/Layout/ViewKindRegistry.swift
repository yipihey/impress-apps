#if os(macOS)
// Chassis file — macOS-only. ADR-0031 work package L6.
//
//  ViewKindRegistry.swift
//  PublicationManagerCore
//
//  `ViewKindId` → the SwiftUI view that renders a pane (ADR-0031 D1/D9).
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
import ImpressFTUI
import ImpressLogging
import ImpressMailStyle
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

    /// Every kind this build registers a factory for.
    public static let builtins: [ViewKindID] = [
        .outline, .list, .info, .pdf, .notes, .bibtex, .source, .legacy, .placeholder, .surface,
    ]
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

    public static let builtin: ViewKindRegistry = ViewKindRegistry([
        // ---- rendered ----
        // The navigator IS the chassis sidebar (plan wave 6, W3):
        // `LayoutOutlinePaneView` hosts `ImbibSidebarColumn` and turns a
        // selected row into Rust's verbs. `LayoutRowsPaneView`'s `.outline`
        // style stays for a host that registers it explicitly.
        ViewKindFactory(kind: .outline) { AnyView(LayoutOutlinePaneView(context: $0)) },
        ViewKindFactory(kind: .list) { AnyView(LayoutRowsPaneView(context: $0, style: .list)) },
        ViewKindFactory(kind: .info) { AnyView(LayoutInfoPaneView(context: $0)) },
        ViewKindFactory(kind: .surface) { AnyView(LayoutSurfacePaneView(context: $0)) },
        ViewKindFactory(kind: .legacy) { AnyView(LayoutLegacyPaneView(context: $0)) },
        ViewKindFactory(kind: .placeholder) { AnyView(LayoutPlaceholderPaneView(context: $0)) },

        // ---- declared, not ported in L6 ----
        //
        // These four render the placeholder ON PURPOSE. Porting them is not a
        // matter of calling the existing tab view: `PDFTab`, `NotesTab` and
        // `BibTeXTab` all take `any PaperRepresentable` plus a `DetailTab`
        // binding and expect the publication detail lifecycle around them,
        // and `source` is session-bearing (D6) — its `NSTextView` and undo
        // stack must come from a `PaneSessionRegistry`, not from view
        // identity. Both are L8 work, one leaf at a time (D11), and a
        // placeholder that keeps the spec is exactly what D4 prescribes in
        // the meantime.
        ViewKindFactory(kind: .pdf) { AnyView(LayoutPlaceholderPaneView(context: $0)) },
        ViewKindFactory(kind: .notes) { AnyView(LayoutPlaceholderPaneView(context: $0)) },
        ViewKindFactory(kind: .bibtex) { AnyView(LayoutPlaceholderPaneView(context: $0)) },
        ViewKindFactory(kind: .source, isSessionBearing: true) {
            AnyView(LayoutPlaceholderPaneView(context: $0))
        },
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
/// `@MainActor` on the whole view (here and in the three below) rather than
/// on `body` alone: every one of them calls a `@MainActor` member of
/// `PaneContext` / `LayoutController` from a helper or a gesture closure, and
/// a nonisolated helper on a `View` struct cannot.
@MainActor
struct LayoutPlaceholderPaneView: View {

    let context: PaneContext

    var body: some View {
        ChassisEmptyState(
            id: "view-kind-unavailable",
            title: "View Kind Unavailable",
            systemImage: RecordKindDescriptor.unknownSymbolName,
            message: "This build has no view for \u{201C}\(context.viewKind.rawValue)\u{201D}."
        )
        // `view(actions:)` with the LABEL, matching `RecordListHostView`'s
        // call: the type also has a `view` PROPERTY, and the labelled form
        // cannot be read as that property plus a trailing closure.
        .view(actions: {
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
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// D11's migration leaf.
///
/// Two shapes, chosen by the pane's `view_state`:
///
/// * **Scoped** (plan wave 6, W3) — `view_state` carries `{"section",
///   "node", "reason"}`, written by the outline for a row the algebra cannot
///   express yet (`outline.rs`, `OutlineTarget::Legacy`): ONE section's route,
///   `LayoutScopedLegacyPaneView`, not the chassis.
/// * **Whole** — no such `view_state`: today's chassis, `TabContentView`,
///   exactly what the flagged-off build renders, for a layout written before
///   the outline existed. It reads the same view models and
///   `AppShellConfiguration` from the environment `ChassisRootView` supplies.
@MainActor
struct LayoutLegacyPaneView: View {

    let context: PaneContext

    private var scope: (section: String?, node: LayoutJSONValue, reason: String?)? {
        guard let state = context.spec?.viewState.objectValue,
              let node = state["node"], node.objectValue != nil
        else { return nil }
        return (state["section"]?.stringValue, node, state["reason"]?.stringValue)
    }

    var body: some View {
        if let scope {
            LayoutScopedLegacyPaneView(
                context: context, section: scope.section, node: scope.node, reason: scope.reason)
        } else {
            TabContentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One row of a `list` / `outline` pane.
///
/// A local value rather than `SharedItemRow` itself: `List(selection:)` needs
/// `Identifiable` + `Hashable`, and the FFI record's conformances are the
/// bindgen's business, not something this file should depend on.
struct LayoutPaneRow: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
    let schemaRef: String
    /// The layout's own kind id for this row (`library`, not `imbib/library`)
    /// — what a `select` verb and a pane parameter speak.
    let layoutKind: String?
    /// The same row in the chassis' own list-row shape, when its id is a UUID.
    ///
    /// This is what a `list` pane RENDERS (`RecordViewerRegistry.makeListRow`
    /// → `MailStyleRow`): read state, flag, star, tags, date column, the
    /// author/title/venue/abstract stack — imbib's list, not a second one.
    /// The plain fields above stay for the `outline` style, which wants one
    /// compact line and no chrome, and as the fallback for a row whose id the
    /// chassis cannot parse.
    let mailStyleRow: KindTaggedRow?

    @MainActor
    init(_ row: SharedItemRow) {
        id = row.id
        schemaRef = row.schemaRef
        let payload = (try? LayoutJSONValue.decode(row.payloadJson))?.objectValue ?? [:]
        var resolvedTitle: String?
        for key in ["title", "name", "subject", "label", "path"] {
            if let value = payload[key]?.stringValue, !value.isEmpty {
                resolvedTitle = value
                break
            }
        }
        title = resolvedTitle ?? row.id
        detail = payload["author"]?.stringValue ?? payload["authors"]?.stringValue
        mailStyleRow = LayoutPaneRowMapper.kindTaggedRow(row)
        layoutKind = LayoutPaneRowMapper.layoutKind(forSchemaRef: row.schemaRef)
    }
}

/// The `list` and `outline` view kinds: the pane's compiled query, run, with
/// selection published on the pane's channel.
///
/// Selection is NOT `@State`. It is read from the channel state in the tree
/// and written with the `select` verb, which is the whole of what "selecting
/// in the list drives the detail pane" means once panes are query-addressed
/// (ADR-0031 D1/D3). The rows themselves are query RESULTS — derived data,
/// re-read when the invalidation feed says this pane is stale.
@MainActor
struct LayoutRowsPaneView: View {

    enum Style {
        case list
        case outline
    }

    let context: PaneContext
    let style: Style

    @State private var rows: [LayoutPaneRow] = []
    @State private var loadFailed = false

    /// The per-kind row factories, from the environment the chassis already
    /// injects — not a lookup of our own, so a host that registered a custom
    /// row gets it in panes too.
    @Environment(\.recordViewerRegistry) private var viewerRegistry

    /// The user's own list settings — venue line, flag stripe, tag chips,
    /// density, how many abstract lines. A pane that ignored them would be a
    /// list that disagrees with the one in the next window, and with the
    /// settings pane that claims to control it.
    @State private var listSettings: ListViewSettings = ListViewSettingsStore.loadSettingsSync()

    /// The toolbar band this pane sits under (`LayoutLinearSplit` reclaims it
    /// for every horizontal child but the first — which is where every
    /// preset's `list` pane is). Without it the first row drew under the
    /// window toolbar: the W2 screenshots of impel, impart and implore all
    /// showed it. Padding OUTSIDE the scroll view, not a content margin: the
    /// band is measured after the first layout, and a content margin that
    /// grows then leaves the scroll origin where it was, so at launch the
    /// first row still sat under the title bar (seen in impress, 2026-09-23)
    /// until the rows were replaced.
    @Environment(\.layoutToolbarBand) private var toolbarBand

    var body: some View {
        styledList
            .padding(.top, toolbarBand)
            .overlay { emptyOverlay.padding(.top, toolbarBand) }
            // The rows are query RESULTS, so they re-run when the
            // invalidation feed marks this pane stale — `refreshToken` is one
            // Equatable value to watch instead of a Set's identity. NOT
            // `.task(id:)`: that closure is `@Sendable` and nonisolated, and
            // everything below it is main-actor work.
            .onChange(of: context.controller.refreshToken) { _, _ in load() }
            .onAppear { load() }
            .onReceive(NotificationCenter.default.publisher(for: .listViewSettingsDidChange)) { _ in
                Task { listSettings = await ListViewSettingsStore.shared.settings }
            }
    }

    /// `listStyle` takes a CONCRETE style type, so the two styles have to be
    /// two branches; a ternary between `.sidebar` and `.inset` does not type
    /// check.
    @ViewBuilder
    private var styledList: some View {
        if style == .outline {
            rowList.listStyle(.sidebar)
        } else {
            rowList.listStyle(.inset)
        }
    }

    private var rowList: some View {
        List(selection: selection) {
            ForEach(rows) { row in
                draggable(rowView(row), row).tag(row.id)
            }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        Group {
            if rows.isEmpty {
                // Empty is not an error and an error is not empty: a refused
                // query says so, an empty result says something else.
                ChassisEmptyState(
                    id: "pane-empty",
                    title: loadFailed ? "Query Refused" : "Nothing Here",
                    systemImage: loadFailed ? "exclamationmark.triangle" : "tray",
                    message: loadFailed
                        ? (context.controller.lastError ?? "The pane's query did not run.")
                        : "This pane's query matched no items."
                )
                .view
            }
        }
    }

    /// A `list` pane shows the chassis' row; an `outline` pane shows one line.
    ///
    /// The list branch goes through `RecordViewerRegistry`, the SAME factory
    /// the heterogeneous list and the store-search results use, so a pane and
    /// a section show one row design and a kind that overrides its row gets
    /// that override here for free. Writing a row here instead is how L6
    /// ended up with a list that shared nothing with imbib's.
    @ViewBuilder
    private func rowView(_ row: LayoutPaneRow) -> some View {
        if style == .list, let mailStyle = row.mailStyleRow {
            // The kind's own row when it has one; otherwise the shared chrome
            // with the user's settings, which is what the registry's default
            // builds too.
            if let factory = viewerRegistry[mailStyle.kind], mailStyle.kind != .publication {
                factory.makeListRow(mailStyle)
            } else {
                MailStyleRow(
                    item: mailStyle, configuration: listSettings.mailStyleConfiguration)
            }
        } else {
            compactRow(row)
        }
    }

    /// A publication row drags what the chassis list drags
    /// (`PublicationDragPayload`): the selection when the row is part of it,
    /// else the row — so a paper can be dropped on an outline collection or
    /// library row, whose drop handler is the sidebar's own
    /// (`handleExternalDrop`). Other kinds' rows are not drag sources here
    /// yet; their payloads live in their list wrappers.
    @ViewBuilder
    private func draggable(_ content: some View, _ row: LayoutPaneRow) -> some View {
        if style == .list, let id = UUID(uuidString: row.id),
            row.mailStyleRow?.kind == .publication
        {
            let context = context
            content.itemProvider {
                let selected = context.currentSelection.compactMap(UUID.init(uuidString:))
                let ids = selected.contains(id) && selected.count > 1 ? selected : [id]
                return PublicationDragPayload.provider(
                    ids: ids, paperRef: nil,
                    suggestedName: ids.count > 1 ? "\(ids.count) publications" : row.title)
            }
        } else {
            content
        }
    }

    /// The `outline` row: a navigator line, not a message row.
    @ViewBuilder
    private func compactRow(_ row: LayoutPaneRow) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName(for: row))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(row.title)
                .font(.body)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }

    /// The record kind's own symbol, so the navigator reads like the sidebar
    /// rather than like an undifferentiated list of strings.
    private func symbolName(for row: LayoutPaneRow) -> String {
        if let kind = row.mailStyleRow?.kind,
            let descriptor = BuiltinRecordKinds.registry[kind]
        {
            return descriptor.symbolName
        }
        // The sidebar kinds have no chassis DESCRIPTOR — they are containers,
        // not record kinds with detail panes — so the descriptor fallback drew
        // `questionmark.square.dashed` next to every library. These are the
        // symbols imbib's own sidebar uses for them.
        switch row.layoutKind {
        case "library": return "books.vertical"
        case "collection": return "folder"
        default: return RecordKindDescriptor.unknownSymbolName
        }
    }

    /// The channel's current selection, written back as a `select` verb.
    private var selection: Binding<Set<String>> {
        let context = context
        return Binding(
            get: { context.currentSelection },
            set: { ids in
                // The kind of what was actually selected, not of the query:
                // the navigator lists collections AND libraries, and the two
                // bind different parameters downstream.
                context.select(Array(ids), kind: kindOfSelection(ids))
            })
    }

    /// The record kind shared by the selected rows, if they agree.
    ///
    /// They disagree only in a multi-selection across kinds, which the `select`
    /// verb cannot express (one kind, many ids); the pane's default kind is
    /// then the honest answer rather than picking one row's kind for all.
    private func kindOfSelection(_ ids: Set<String>) -> String? {
        let kinds = Set(rows.filter { ids.contains($0.id) }.compactMap(\.layoutKind))
        return kinds.count == 1 ? kinds.first : nil
    }

    private func load() {
        let tile = context.tile
        let fetched = context.rows()
        rows = fetched.map(LayoutPaneRow.init)
        loadFailed = fetched.isEmpty && context.controller.lastError != nil
        context.controller.didRefresh(tile)
        logInfo("pane \(tile) display: \(rows.count) rows", category: "layout")
    }
}

/// The `info` view kind: the record kind's EXISTING detail pane, for whatever
/// the pane's `item` parameter currently resolves to.
///
/// Five kinds route here today and every one of them is a view the chassis
/// already ships: `DetailView` is the same failable entry point
/// `SectionContentView` uses for a publication, and `FigureDetailPane`,
/// `MessageDetailPane` and `AgentRecordDetailPane` are the same id-based
/// panes `FigureSectionView` / `MessageSectionView` / `AgentSectionView`
/// build for their own detail half. Nothing was extracted to get here: all
/// four already took an id and a tab binding, because a section's detail
/// pane and a tree's detail pane want exactly the same two things (ADR-0031
/// D11 — map, do not rewrite).
///
/// `topInset` is the toolbar band the tree measured for this pane
/// (`layoutToolbarBand`), not the section views' fixed 40 pt. A layout pane
/// DOES reclaim the band — `LayoutLinearSplit` ignores the top safe area for
/// every horizontal child but the first, which is where every preset's `info`
/// pane sits — so 0 put each detail pane's tab picker under the window
/// toolbar, invisible and unclickable. A pane that is not under the toolbar
/// is told 0 and gets no gap.
///
/// The detail TAB is view state of this view kind, not layout state — in L8
/// it becomes `PaneSpec.view_state`, which is where a per-pane tab belongs
/// (ADR-0031 D1).
@MainActor
struct LayoutInfoPaneView: View {

    /// Which detail the pane shows. A plain enum switched over a plain
    /// `some View`, NOT a `@ViewBuilder` returning `(some View)?` — that
    /// shape does not propagate `nil` through `if let` and silently renders
    /// the wrong branch for every case (impress-swiftui-pitfalls rule 3, a
    /// bug this file is the exact shape of).
    private enum DetailKind {
        case publication
        case figure
        case message
        case task
        case agentRun
        /// A kind this build has no detail pane for — the honest fallback,
        /// unchanged from before the other four existed.
        case unsupported

        /// From the pane's own layout kind — the manifest's short id
        /// (`figure`), which is what a pane query and a `select` verb spell.
        /// NOT the chassis' namespaced `RecordKindID`; see
        /// `LayoutPaneRowMapper.kindBySchemaRef` for why the two are one
        /// string apart on purpose.
        init(layoutKind: String?) {
            switch layoutKind {
            case RecordKindID.publication.rawValue: self = .publication
            case RecordKindID.figure.rawValue: self = .figure
            case RecordKindID.message.rawValue: self = .message
            case RecordKindID.task.rawValue: self = .task
            case RecordKindID.agentRun.rawValue: self = .agentRun
            default: self = .unsupported
            }
        }
    }

    let context: PaneContext

    @State private var selectedTab: DetailTab = .info

    @Environment(\.layoutToolbarBand) private var toolbarBand

    private var itemID: UUID? {
        guard let raw = rawItem else { return nil }
        return UUID(uuidString: raw)
    }

    private var rawItem: String? {
        context.singleItem ?? context.bindings["item"]
    }

    /// The kind the pane's query names. A detail pane's query is
    /// `detail_query(list)` — the list's kinds, scoped to `$item` — so this
    /// is the kind of the thing the parameter resolved to, not a guess.
    private var detailKind: DetailKind {
        DetailKind(layoutKind: context.primaryKind)
    }

    var body: some View {
        Group {
            if let itemID {
                detail(for: itemID)
                    // The leaf's conversion is otherwise invisible: a figure
                    // detail and a "no publication detail" empty state occupy
                    // the same pixels. Naming the branch makes
                    // `?category=layout` the place the proof is read, rather
                    // than a screenshot.
                    .onAppear { logDispatch(itemID) }
                    .onChange(of: itemID) { _, id in logDispatch(id) }
            } else if let raw = rawItem {
                // A bound parameter whose value is not an id at all.
                unavailable(raw)
            } else {
                // An unfilled parameter renders the empty state, NEVER an
                // error (ADR-0031 D3) — this is what a detail pane looks like
                // before the first selection.
                ChassisEmptyState.noRowSelection(
                    kind: RecordKindID(context.primaryKind ?? "")
                ).view
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logDispatch(_ id: UUID) {
        logInfo(
            "pane \(context.tile) info: \(detailKind) detail for \(id.uuidString)",
            category: "layout")
    }

    @ViewBuilder
    private func detail(for id: UUID) -> some View {
        switch detailKind {
        case .publication:
            // Failable: the id may name a row that has since gone.
            if let view = DetailView(publicationID: id, selectedTab: $selectedTab) {
                view
            } else {
                unavailable(id.uuidString)
            }
        case .figure:
            FigureDetailPane(figureID: id, selectedTab: $selectedTab, topInset: toolbarBand)
        case .message:
            MessageDetailPane(messageID: id, selectedTab: $selectedTab, topInset: toolbarBand)
        case .task:
            AgentRecordDetailPane(
                kind: .task, recordID: id, selectedTab: $selectedTab, topInset: toolbarBand)
        case .agentRun:
            AgentRecordDetailPane(
                kind: .run, recordID: id, selectedTab: $selectedTab, topInset: toolbarBand)
        case .unsupported:
            unavailable(id.uuidString)
        }
    }

    /// The parameter resolved to something this build has no detail for.
    /// Names the KIND as well as the id: "no detail for <id>" sent every
    /// earlier reader looking for a missing row when the real answer was a
    /// missing view.
    private func unavailable(_ raw: String) -> some View {
        ChassisEmptyState(
            id: "detail-unavailable",
            title: "Detail Unavailable",
            systemImage: RecordKindDescriptor.unknownSymbolName,
            message: "No \u{201C}\(context.primaryKind ?? "item")\u{201D} detail for "
                + "\u{201C}\(raw)\u{201D}."
        )
        .view
    }
}
#endif
