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

@MainActor
public struct RecordSidebarView: View {

    // MARK: - Inputs

    private let configuration: AppShellConfiguration
    private let dataSource: RecordSidebarDataSource
    private let collectionActions: RecordCollectionActions
    /// The host's store version — the sidebar rebuilds when it changes.
    private let dataVersion: Int
    private let title: String

    @Binding private var selection: RecordSidebarScope?

    public init(
        configuration: AppShellConfiguration,
        dataSource: RecordSidebarDataSource,
        collectionActions: RecordCollectionActions = RecordCollectionActions(),
        dataVersion: Int = 0,
        selection: Binding<RecordSidebarScope?>,
        title: String? = nil
    ) {
        self.configuration = configuration
        self.dataSource = dataSource
        self.collectionActions = collectionActions
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
        Section {
            if !isCollapsed {
                ForEach(section.nodes.flattened(expanded: expandedFolders), id: \.node.id) { entry in
                    nodeRow(entry.node, depth: entry.depth, section: section)
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
                        Text(section.title).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.section.\(section.section.rawValue)")
                Spacer()
                if section.canOrganizeFolders, let kind = section.kind {
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
            }
            Label {
                Text(node.title).lineLimit(1)
            } icon: {
                nodeIcon(node)
            }
            Spacer(minLength: 4)
            if let count = node.count, count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .tag(node.scope)
        .accessibilityIdentifier("sidebar.node.\(node.scope.scopeKey)")
        .contextMenu { folderMenu(for: node, section: section) }
        .swipeActions(edge: .trailing) {
            if isOrganizableFolder(node, section: section) {
                Button(role: .destructive) {
                    deleteFolder(node)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
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
            guard configuration.recordKinds[kind]?.collection != nil else { continue }
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
        if selection == nil {
            selection = sections
                .first { $0.section == configuration.defaultSection }?
                .nodes.first?.scope
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
