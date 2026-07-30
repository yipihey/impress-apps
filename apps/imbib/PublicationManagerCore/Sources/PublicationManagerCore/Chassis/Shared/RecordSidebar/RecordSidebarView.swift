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
        self.dataSource = dataSource
        self.collectionActions = collectionActions
        self.chrome = chrome
        self.dataVersion = dataVersion
        self._selection = selection
        self.title = title ?? configuration.appID
    }

    // MARK: - State

    @State private var sections: [RecordSidebarSectionModel] = []
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
            ForEach(sections) { section in
                sectionView(section)
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

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: RecordSidebarSectionModel) -> some View {
        let isCollapsed = collapsedSections.contains(section.section)
        let rows = section.nodes.flattened(expanded: expandedFolders)
        Section {
            if !isCollapsed {
                let content = ForEach(rows, id: \.node.id) { entry in
                    nodeRow(entry.node, depth: entry.depth, section: section)
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
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { toggleCollapsed(section.section) }
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
                .accessibilityIdentifier("sidebar.section.\(section.section.rawValue)")
                if let headerScope = section.headerScope {
                    Text(section.title)
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = headerScope }
                        .accessibilityIdentifier(
                            "sidebar.sectionSelect.\(section.section.rawValue)")
                }
                Spacer()
                if let accessory = chrome.sectionAccessory?(section.section) {
                    accessory
                }
                if section.offersRootFolderCreation, section.canOrganizeFolders,
                   let kind = section.kind {
                    Button {
                        newFolderRequest = NewFolderRequest(kind: kind, parent: nil)
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.newFolder.\(section.section.rawValue)")
                }
            }
            .contentShape(Rectangle())
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func nodeRow(
        _ node: RecordSidebarNode, depth: Int, section: RecordSidebarSectionModel
    ) -> some View {
        let isExpanded = expandedFolders.contains(node.id)
        HStack(spacing: 4) {
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
                .accessibilityIdentifier("sidebar.disclose.\(node.scope.scopeKey)")
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
            .accessibilityIdentifier("sidebar.node.\(node.scope.scopeKey)")
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
        sections = RecordSidebarBuilder.sections(
            configuration: configuration,
            order: SidebarSectionOrderStore.loadOrderSync(),
            dataSource: dataSource)
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
