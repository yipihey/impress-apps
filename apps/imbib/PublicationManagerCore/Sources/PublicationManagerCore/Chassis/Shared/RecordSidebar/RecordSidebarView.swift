#if os(iOS)
// Chassis view — iOS. The DATA it renders (`RecordSidebarBuilder`,
// `RecordSidebarModel`) is cross-platform and ungated; only this renderer is
// platform-shaped, exactly like the macOS `SidebarOutlineView` half.
//
//  RecordSidebarView.swift
//  PublicationManagerCore
//
//  The iOS sidebar for ANY impress app. It takes an `AppShellConfiguration`
//  and a `RecordSidebarDataSource` and renders whatever those say: sections
//  from `visibleSections`, per-section record kinds from `sectionBindings`,
//  status smart-children from the kind's `triage.statuses`, and a folder TREE
//  from the kind's `collection` capability.
//
//  There is no `if section == .manuscripts` anywhere below, and no app id.
//  imprint-iOS adopts it by passing `.imprint`; imbib-iOS adopts it by
//  passing `.imbib` and a data source over `RustStoreAdapter`.
//
//  TWO MODES, and only impress uses the second one.
//
//    * FLAT — `init(configuration:…)`. One preset, one list of sections. This
//      is what imbib-iOS, imprint-iOS and impart-iOS pass and NOTHING about it
//      changed when the grouped mode landed: the same rows, the same
//      accessibility identifiers (`sidebar.section.<section>` /
//      `sidebar.node.<scopeKey>`), the same collapse store.
//    * GROUPED — `init(composition:host:…)`. A `SidebarComposition`: one
//      collapsible group per app, each rendering that app's OWN preset. Rows
//      and headers are namespaced by group (`sidebar.group.<app>`,
//      `sidebar.section.<app>.<section>`, `sidebar.node.<app>.<scopeKey>`),
//      because a composed sidebar genuinely has two rows called Flagged and
//      `.citedInManuscripts` appears twice with the SAME scope — an unqualified
//      identifier would resolve to whichever of the two SwiftUI reached first,
//      and a duplicate `ForEach` id is undefined behaviour rather than a
//      cosmetic problem.
//
//  Selection stays a plain `RecordSidebarScope?` in both modes. Two rows in
//  different groups that carry the SAME scope (imbib's and imprint's Cited in
//  Manuscripts, both publication-bound) therefore highlight together and route
//  identically — which is honest: they are two doors onto one destination, and
//  making them distinguishable would mean inventing a per-group scope the five
//  sibling apps have no use for.
//

import ImpressFTUI
import SwiftUI

// MARK: - Host chrome

/// The VIEWS a host hangs off rows and section headers that the chassis has no
/// business knowing about.
///
/// `RecordSidebarDataSource` answers "which rows"; this answers "what verbs
/// does this host offer ON a row". They are separate because one is data
/// (cross-platform, unit-testable) and one is SwiftUI.
///
/// It exists because of the second adopter. imprint's sidebar rows need
/// exactly one menu — the shared organise grammar (`RecordFolderMenu`) — and
/// the chassis renders it from the declarations. imbib's rows carry verbs that
/// are not folder verbs and never will be: "Delete Library", "Open on SciX",
/// "Refresh" a remote shelf, "Hide" a search form, "Edit"/"Delete" a saved
/// search, and a per-library `+` that creates a collection IN that library.
/// None of those are expressible as a capability of a record kind, and all of
/// them worked in the hand-written sidebar this replaces — so the choice was
/// this seam or a regression.
///
/// Every closure defaults to nil, so imprint's call site is unchanged and its
/// rows render exactly as before.
@MainActor
public struct RecordSidebarHostChrome {

    /// A trailing accessory INSIDE a row (imbib's per-library `+` menu).
    /// Rendered after the badge; must be a compact control.
    public var nodeAccessory: ((RecordSidebarNode) -> AnyView?)?

    /// Extra context-menu entries for a row, appended after whatever the
    /// declarations already offer for it.
    public var nodeMenu: ((RecordSidebarNode) -> AnyView?)?

    /// Extra trailing swipe actions for a row, appended after the shared ones.
    public var nodeSwipeActions: ((RecordSidebarNode) -> AnyView?)?

    /// A trailing accessory in a section HEADER (imbib's inbox unread badge +
    /// retention label, and its "show hidden search forms" menu).
    public var sectionAccessory: ((SidebarSectionType) -> AnyView?)?

    /// Drag-to-reorder within a section. Indices are into the section's
    /// rendered rows, so hosts only enable it for FLAT sections (the view
    /// refuses it for a section with any expandable row, where an index does
    /// not identify a sibling position).
    public var onMoveNodes: ((RecordSidebarSectionModel, IndexSet, Int) -> Void)?

    public init(
        nodeAccessory: ((RecordSidebarNode) -> AnyView?)? = nil,
        nodeMenu: ((RecordSidebarNode) -> AnyView?)? = nil,
        nodeSwipeActions: ((RecordSidebarNode) -> AnyView?)? = nil,
        sectionAccessory: ((SidebarSectionType) -> AnyView?)? = nil,
        onMoveNodes: ((RecordSidebarSectionModel, IndexSet, Int) -> Void)? = nil
    ) {
        self.nodeAccessory = nodeAccessory
        self.nodeMenu = nodeMenu
        self.nodeSwipeActions = nodeSwipeActions
        self.sectionAccessory = sectionAccessory
        self.onMoveNodes = onMoveNodes
    }
}

@MainActor
public struct RecordSidebarView: View {

    // MARK: - Inputs

    private let configuration: AppShellConfiguration
    /// Non-nil = GROUPED mode. See the file header.
    private let composition: SidebarComposition?
    private let dataSource: RecordSidebarDataSource
    private let collectionActions: RecordCollectionActions
    private let chrome: RecordSidebarHostChrome
    /// The host's store version — the sidebar rebuilds when it changes.
    private let dataVersion: Int
    private let title: String

    @Binding private var selection: RecordSidebarScope?

    public init(
        configuration: AppShellConfiguration,
        dataSource: RecordSidebarDataSource,
        collectionActions: RecordCollectionActions = RecordCollectionActions(),
        chrome: RecordSidebarHostChrome = RecordSidebarHostChrome(),
        dataVersion: Int = 0,
        selection: Binding<RecordSidebarScope?>,
        title: String? = nil
    ) {
        self.configuration = configuration
        self.composition = nil
        self.dataSource = dataSource
        self.collectionActions = collectionActions
        self.chrome = chrome
        self.dataVersion = dataVersion
        self._selection = selection
        self.title = title ?? configuration.appID
    }

    /// The COMPOSED sidebar: one collapsible group per app in `composition`.
    ///
    /// - Parameters:
    ///   - composition: which apps, in what order, with which presets.
    ///   - host: the shell this is rendering IN. Only two of its fields matter
    ///     here — `presentableKinds`, which narrows every group to the kinds
    ///     this build has panes for, and `defaultSection`, which decides where
    ///     a regular-width launch lands. The section list and bindings come
    ///     from each GROUP's preset, never from this one.
    public init(
        composition: SidebarComposition,
        host: AppShellConfiguration,
        dataSource: RecordSidebarDataSource,
        collectionActions: RecordCollectionActions = RecordCollectionActions(),
        chrome: RecordSidebarHostChrome = RecordSidebarHostChrome(),
        dataVersion: Int = 0,
        selection: Binding<RecordSidebarScope?>,
        title: String? = nil
    ) {
        self.configuration = host
        self.composition = composition
        self.dataSource = dataSource
        self.collectionActions = collectionActions
        self.chrome = chrome
        self.dataVersion = dataVersion
        self._selection = selection
        self.title = title ?? host.appID
    }

    // MARK: - State

    @State private var sections: [RecordSidebarSectionModel] = []
    @State private var groups: [RecordSidebarGroupModel] = []
    /// Grouped mode's collapse state: group keys AND per-group section keys, in
    /// one persisted set. Empty = everything expanded, which is the launch state
    /// "collate their sidebars" asks for.
    @State private var collapsedComposition: Set<SidebarCompositionKey> =
        SidebarCompositionCollapsedStore.loadCollapsedSync()
    /// Flat folder list per kind — the organise menus need the whole tree,
    /// not just the visible rows.
    @State private var foldersByKind: [RecordKindID: [RecordFolder]] = [:]
    @State private var expandedFolders: Set<UUID> = []
    /// Folder trees start EXPANDED on first build — a collapsed tree on a
    /// touch device reads as "there are no subfolders". After that the user's
    /// toggles own the state.
    @State private var didSeedExpansion = false
    @State private var collapsedSections: Set<SidebarSectionType> =
        SidebarCollapsedStateStore.loadCollapsedSync()

    @State private var newFolderRequest: NewFolderRequest?
    @State private var renameRequest: RenameFolderRequest?

    /// In COMPACT width a `NavigationSplitView` is a stack, so writing a
    /// selection does not "land" anywhere — it PUSHES, and the sidebar the user
    /// launched into disappears behind the content pane. The default-section
    /// seed below is therefore regular-width only; on a phone the root list is
    /// the destination.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // MARK: - Body

    public var body: some View {
        List(selection: $selection) {
            if composition == nil {
                ForEach(sections) { section in
                    sectionView(section)
                }
            } else {
                ForEach(groups) { group in
                    groupView(group)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(title)
        .task { rebuild() }
        .onChange(of: dataVersion) { _, _ in rebuild() }
        .sheet(item: $newFolderRequest) { request in
            RecordFolderNameSheet(
                title: request.parent == nil
                    ? "New Folder"
                    : "New Folder in “\(request.parent?.name ?? "")”",
                initialName: "",
                confirmLabel: "Create"
            ) { name in
                if let created = collectionActions.createFolder(name, request.parent?.id) {
                    if let parent = request.parent { expandedFolders.insert(
                        RecordSidebarScope.folder(request.kind, parent.id).stableViewID) }
                    selection = .folder(request.kind, created)
                }
                rebuild()
            }
        }
        .sheet(item: $renameRequest) { request in
            RecordFolderNameSheet(
                title: "Rename Folder",
                initialName: request.folder.name,
                confirmLabel: "Save"
            ) { name in
                collectionActions.renameFolder(request.folder.id, name)
                rebuild()
            }
        }
    }

    // MARK: - Sections (flat mode)

    @ViewBuilder
    private func sectionView(_ section: RecordSidebarSectionModel) -> some View {
        let isCollapsed = collapsedSections.contains(section.section)
        let rows = section.nodes.flattened(expanded: expandedFolders)
        Section {
            if !isCollapsed {
                let content = ForEach(rows, id: \.node.id) { entry in
                    nodeRow(entry.node, depth: entry.depth, section: section, groupID: nil)
                }
                // Reorder only where an index IS a sibling position.
                if let onMove = chrome.onMoveNodes,
                   section.nodes.allSatisfy({ $0.children.isEmpty }) {
                    content.onMove { source, destination in
                        onMove(section, source, destination)
                    }
                } else {
                    content
                }
            }
        } header: {
            sectionHeader(
                section,
                groupID: nil,
                isCollapsed: isCollapsed,
                toggle: { toggleCollapsed(section.section) })
        }
    }

    /// The header chrome, shared by both modes: disclosure chevron, title (its
    /// own tap target when the header is a destination), host accessory and the
    /// root-folder button. `groupID` namespaces every identifier and is nil in
    /// flat mode, where the identifiers are exactly what they have always been.
    @ViewBuilder
    private func sectionHeader(
        _ section: RecordSidebarSectionModel,
        groupID: String?,
        isCollapsed: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        let suffix = groupID.map { "\($0).\(section.section.rawValue)" }
            ?? section.section.rawValue
        HStack(spacing: 6) {
            // ONE rendering for both modes, and the `groupID` only namespaces
            // the identifier. An earlier version of this file added
            // `.accessibilityElement(children: .combine)` here for composed
            // mode, so that a test could read the disclosure state back the way
            // it does from a GROUP header — and combining made the button stop
            // toggling. A section header inside a group is an ordinary `List`
            // row, and merging its children into one accessibility element
            // changed what the row hit-tests to: the sidebar looked right and
            // the affordance was dead. Group state is queryable (the group
            // header IS a `List` section header, which behaves differently);
            // per-section state is asserted on ROWS instead, which is what a
            // user experiences anyway.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    // A header that IS a destination keeps the disclosure
                    // triangle as the collapse target and gives the TITLE
                    // its own tap, so one gesture never means both.
                    if section.headerScope == nil {
                        Text(section.title).foregroundStyle(.primary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.section.\(suffix)")
            if let headerScope = section.headerScope {
                Text(section.title)
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = headerScope }
                    .accessibilityIdentifier("sidebar.sectionSelect.\(suffix)")
            }
            Spacer()
            if let accessory = chrome.sectionAccessory?(section.section) {
                accessory
            }
            // `collectionActions.canOrganize` is the third condition and it was
            // MISSING, which the composed sidebar made impossible to ignore.
            // The row-level organise gate (`isOrganizableFolder`) has always
            // asked the HOST as well as the section; this one asked only the
            // section, so a host that wires up no organise verbs still got a
            // `folder.badge.plus` on every publication-bound section — Inbox,
            // Flagged, Cited in Manuscripts, Dismissed — and tapping it opened
            // a sheet whose Create called the default no-op closure. Four dead
            // buttons in one group, in a sidebar whose reported defect was that
            // it was "hit and miss".
            //
            // No sibling changes: imbib-iOS and imprint-iOS both pass
            // `canOrganize: true` (imprint's derived from the descriptor), and
            // impart-iOS passes no actions but binds `.mail` to a kind with no
            // `CollectionCapability`, so its sections never reached this line.
            if section.offersRootFolderCreation, section.canOrganizeFolders,
               collectionActions.canOrganize,
               let kind = section.kind {
                Button {
                    newFolderRequest = NewFolderRequest(kind: kind, parent: nil)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.newFolder.\(suffix)")
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Groups (composed mode)

    /// One app's sidebar: a `List` `Section` carrying the APP header, followed
    /// by one `Section` per app-section.
    ///
    /// `Section`s rather than `DisclosureGroup`s: the two collapse identically
    /// for the user, but `Section`s keep every row a direct child of the one
    /// lazy `List`, which is what makes a 45-row composed sidebar scroll (and
    /// what lets a UI test sweep it). A `DisclosureGroup` per app would nest
    /// five `List`s' worth of rows inside five container views.
    ///
    /// And a `Section` PER APP-SECTION rather than one Section per group with
    /// the section headers as rows, which is what this rendered first: a
    /// disclosure Button in an ordinary `List` row does not receive the tap on
    /// iOS, so every per-section chevron in the composed sidebar was dead while
    /// looking exactly right. A `Section` HEADER does receive it — that is the
    /// mechanism the flat sidebar and the group header have always used. The
    /// bug was invisible to the first version of the test, which asserted the
    /// rows were GONE and passed because tapping the row pushed the detail
    /// column over the sidebar instead.
    @ViewBuilder
    private func groupView(_ group: RecordSidebarGroupModel) -> some View {
        let isCollapsed = collapsedComposition.contains(.group(group.id))
        Section {
            EmptyView()
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    toggleComposition(.group(group.id))
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Label(group.title, systemImage: group.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.group.\(group.id)")
            // The disclosure STATE, published rather than inferred. VoiceOver
            // should announce a disclosure control's state, and automation has
            // no other way to read it: the chevron is a rotation, and "does
            // this group show any rows" is answerable only for the part of the
            // list currently on screen — which is how the real-store suite
            // first COLLAPSED a group it had scrolled to while meaning to
            // expand it.
            .accessibilityValue(isCollapsed ? Self.collapsedValue : Self.expandedValue)
        }
        if !isCollapsed {
            ForEach(group.sections) { section in
                groupedSection(section, group: group)
            }
        }
    }

    /// Accessibility values for a disclosure header. Public-by-convention
    /// strings: the UI suites mirror them locally (they must not link PMC).
    static let collapsedValue = "collapsed"
    static let expandedValue = "expanded"

    /// One section INSIDE a group — its own `List` `Section`, indented under the
    /// app header, keyed by `(group, section)` so the two Flagged sections
    /// collapse independently.
    ///
    /// No `chrome.onMoveNodes` here, deliberately. Drag-reorder is expressed as
    /// indices into a section's rendered rows; no composing host asks for it
    /// (imbib-iOS is the only one that supplies `onMoveNodes`), so this is a
    /// declined capability rather than a missing one.
    @ViewBuilder
    private func groupedSection(
        _ section: RecordSidebarSectionModel, group: RecordSidebarGroupModel
    ) -> some View {
        let key = SidebarCompositionKey.section(group.id, section.section)
        let isCollapsed = collapsedComposition.contains(key)
        Section {
            if !isCollapsed {
                ForEach(groupedRows(section, group: group)) { row in
                    nodeRow(row.node, depth: row.depth, section: section, groupID: group.id)
                }
            }
        } header: {
            sectionHeader(
                section,
                groupID: group.id,
                isCollapsed: isCollapsed,
                toggle: { toggleComposition(key) })
                .font(.footnote)
                .padding(.leading, 10)
        }
    }

    /// A group's rows, re-identified by `<group>.<scopeKey>`.
    ///
    /// The composed sidebar renders the SAME scope twice — imbib and imprint
    /// both declare Cited in Manuscripts and both resolve it to `.publication`,
    /// so `RecordSidebarNode.id` (which is `scope.stableViewID`) collides across
    /// groups. Feeding SwiftUI two rows with one id is not a cosmetic problem;
    /// it is the case `ForEach` documents as undefined.
    private func groupedRows(
        _ section: RecordSidebarSectionModel, group: RecordSidebarGroupModel
    ) -> [GroupedRow] {
        section.nodes.flattened(expanded: expandedFolders).map { entry in
            GroupedRow(
                id: "\(group.id).\(entry.node.scope.scopeKey)",
                node: entry.node,
                depth: entry.depth)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func nodeRow(
        _ node: RecordSidebarNode, depth: Int, section: RecordSidebarSectionModel,
        groupID: String?
    ) -> some View {
        let isExpanded = expandedFolders.contains(node.id)
        // `<group>.` in composed mode, empty in flat mode — see the file header.
        let ident = groupID.map { "\($0).\(node.scope.scopeKey)" } ?? node.scope.scopeKey
        HStack(spacing: 4) {
            // Composed rows sit one level under their section header, which
            // itself sits under the app header.
            if groupID != nil { Spacer().frame(width: 14) }
            if depth > 0 { Spacer().frame(width: CGFloat(depth) * 14) }
            if node.children.isEmpty {
                Spacer().frame(width: 12)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedFolders.remove(node.id)
                        } else {
                            expandedFolders.insert(node.id)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.disclose.\(ident)")
            }
            // `sidebar.node.<scopeKey>` names the SELECTABLE part of the row,
            // not the whole HStack. It used to sit on the HStack, and a row with
            // a disclosure triangle then resolved that identifier to the
            // TRIANGLE: automation aiming at "the Test Library row" collapsed
            // the library instead of selecting it, which is not what the same
            // tap does for a person. The chevron and any host accessory get
            // their own identifiers so each affordance is addressable once.
            Label {
                Text(node.title).lineLimit(1)
            } icon: {
                nodeIcon(node)
            }
            // `.combine` before the identifier: a bare `Label` is TWO
            // accessibility elements (icon + title) and the identifier lands on
            // the icon, an 18×23 glyph that reports itself not hittable. One
            // combined element is both the correct VoiceOver reading of a
            // sidebar row and a tap target that behaves like the row.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.node.\(ident)")
            Spacer(minLength: 4)
            if let count = node.count, count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let accessory = chrome.nodeAccessory?(node) {
                accessory
            }
        }
        .contentShape(Rectangle())
        .tag(node.scope)
        .contextMenu {
            folderMenu(for: node, section: section)
            if let menu = chrome.nodeMenu?(node) {
                menu
            }
        }
        .swipeActions(edge: .trailing) {
            if isOrganizableFolder(node, section: section) {
                Button(role: .destructive) {
                    deleteFolder(node)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if let actions = chrome.nodeSwipeActions?(node) {
                actions
            }
        }
    }

    /// A row's glyph. A flag row is tinted from the SHARED cross-platform
    /// mapping (`FlagColor.displayColor`, ImpressFTUI) — the same property
    /// macOS's sidebar and imbib-iOS use, never a switch statement local to
    /// this file. Every other row keeps the platform's default tint.
    @ViewBuilder
    private func nodeIcon(_ node: RecordSidebarNode) -> some View {
        if let flag = node.flagColor {
            Image(systemName: node.systemImage)
                .foregroundStyle(flag.displayColor)
        } else {
            Image(systemName: node.systemImage)
        }
    }

    @ViewBuilder
    private func folderMenu(
        for node: RecordSidebarNode, section: RecordSidebarSectionModel
    ) -> some View {
        if isOrganizableFolder(node, section: section),
           let kind = section.kind,
           let folderID = node.scope.folderID,
           let folders = foldersByKind[kind],
           let folder = folders.first(where: { $0.id == folderID }) {
            RecordFolderMenu.organize(
                folder: folder,
                folders: folders,
                actions: collectionActions,
                onRename: { renameRequest = RenameFolderRequest(kind: kind, folder: $0) },
                onNewSubfolder: { newFolderRequest = NewFolderRequest(kind: kind, parent: $0) })
        }
    }

    private func isOrganizableFolder(
        _ node: RecordSidebarNode, section: RecordSidebarSectionModel
    ) -> Bool {
        node.isFolder && section.canOrganizeFolders && collectionActions.canOrganize
    }

    private func deleteFolder(_ node: RecordSidebarNode) {
        guard let folderID = node.scope.folderID else { return }
        if selection == node.scope { selection = nil }
        collectionActions.deleteFolder(folderID)
        rebuild()
    }

    // MARK: - Data

    private func rebuild() {
        let order = SidebarSectionOrderStore.loadOrderSync()
        if let composition {
            groups = RecordSidebarBuilder.groups(
                composition: composition,
                host: configuration,
                order: order,
                dataSource: dataSource)
            // The flat concatenation, in group order, is kept for the two
            // things below that are about the sidebar as a WHOLE rather than
            // about any group: the folder-tree read (one per kind, whichever
            // group first bound it) and the regular-width landing seed. The
            // seed lands on the FIRST group that declares the host's
            // `defaultSection` — `.inbox` in imbib, which is first, so impress
            // opens where imbib opens.
            sections = groups.flatMap(\.sections)
        } else {
            groups = []
            sections = RecordSidebarBuilder.sections(
                configuration: configuration,
                order: order,
                dataSource: dataSource)
        }
        var folders: [RecordKindID: [RecordFolder]] = [:]
        for section in sections {
            guard let kind = section.kind, folders[kind] == nil else { continue }
            // The kind's DECLARED folder tree, or a host-resolved one the
            // section vouches for. imbib's publications declare no
            // `CollectionCapability` (their containers are libraries, and each
            // library owns its own collections) yet its collection rows are
            // real folders with real organise verbs — gating this read on the
            // descriptor alone left the organise menu permanently empty.
            guard section.canOrganizeFolders
                || configuration.recordKinds[kind]?.collection != nil
            else { continue }
            folders[kind] = dataSource.folders(kind)
        }
        foldersByKind = folders
        if !didSeedExpansion {
            didSeedExpansion = true
            expandedFolders = Set(
                sections.flatMap { $0.nodes.flattened(expanded: []) }
                    .map(\.node)
                    .flatMap(Self.expandableIDs))
        }
        if selection == nil, horizontalSizeClass != .compact {
            // A section whose HEADER is a destination lands there rather than
            // on its first row: imbib's default section is Inbox, whose header
            // means "the inbox library" and whose first row is "Recent" — a
            // different list. macOS's `resolveSelectedTab` makes the same call.
            let landing = sections.first { $0.section == configuration.defaultSection }
                ?? sections.first
            selection = landing?.headerScope
                ?? landing?.nodes.first?.scope
                ?? sections.first?.nodes.first?.scope
        }
    }

    /// Every node id in the subtree that has children (i.e. is expandable).
    private static func expandableIDs(_ node: RecordSidebarNode) -> [UUID] {
        guard !node.children.isEmpty else { return [] }
        return [node.id] + node.children.flatMap(expandableIDs)
    }

    private func toggleCollapsed(_ section: SidebarSectionType) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
        let snapshot = collapsedSections
        Task { await SidebarCollapsedStateStore.shared.save(snapshot) }
    }

    /// Toggle a group or a per-group section, and persist. One key space, one
    /// store — the two levels differ only in the key they build.
    private func toggleComposition(_ key: SidebarCompositionKey) {
        if collapsedComposition.contains(key) {
            collapsedComposition.remove(key)
        } else {
            collapsedComposition.insert(key)
        }
        let snapshot = collapsedComposition
        Task { await SidebarCompositionCollapsedStore.shared.save(snapshot) }
    }
}

// MARK: - Composed rows

/// A composed sidebar's row, re-identified by group. See `groupedRows`.
private struct GroupedRow: Identifiable {
    let id: String
    let node: RecordSidebarNode
    let depth: Int
}

// MARK: - Sheet requests

private struct NewFolderRequest: Identifiable {
    let kind: RecordKindID
    let parent: RecordFolder?
    var id: String { "\(kind.rawValue).\(parent?.id.uuidString ?? "root")" }
}

private struct RenameFolderRequest: Identifiable {
    let kind: RecordKindID
    let folder: RecordFolder
    var id: UUID { folder.id }
}

// MARK: - Name sheet

/// The one text prompt the organise verbs need. Public because a host that
/// builds its own folder chrome (a toolbar "+" outside the sidebar) should
/// use the same sheet rather than a second one.
public struct RecordFolderNameSheet: View {
    private let title: String
    private let confirmLabel: String
    private let onConfirm: (String) -> Void

    @State private var name: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    public init(
        title: String,
        initialName: String = "",
        confirmLabel: String = "Save",
        onConfirm: @escaping (String) -> Void
    ) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        self._name = State(initialValue: initialName)
    }

    public var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(confirm)
                    .accessibilityIdentifier("folderName.field")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel, action: confirm)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("folderName.confirm")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}
#endif
