// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
//  RecordCollectionActions.swift
//  PublicationManagerCore
//
//  The organise verbs (ADR-0022 D3), as an injectable action bag plus the
//  shared MENU grammar built from it — the collection twin of
//  `RecordTriageActions` / `TriageMenu`.
//
//  Why a bag of closures and not a protocol over the store: this folder must
//  not import store types, and the two implementations that exist
//  (`CollectionStoreAdapter` on macOS, `ManuscriptStoreAdapter` in imprint)
//  are on different actors with different undo plumbing. Closures let both
//  hosts hand the same grammar their own kernel calls, and let a test hand it
//  an array.
//
//  The menus are SwiftUI-only (Menu/Button/Label), so they are NOT gated:
//  macOS can adopt "Move to Folder ▸" from here too. On iOS this menu IS the
//  move gesture — there is no sidebar drag target on a touch device.
//

import SwiftUI

// MARK: - Actions

/// Folder structure + membership verbs. Every closure defaults to a no-op, so
/// a host wires up only what it supports and the menus hide the rest.
@MainActor
public struct RecordCollectionActions {

    /// Create a folder under `parentID` (nil = root). Returns the new id.
    public var createFolder: (_ name: String, _ parentID: UUID?) -> UUID?
    public var renameFolder: (_ id: UUID, _ name: String) -> Void
    /// Move a folder under a new parent (nil = make it a root).
    public var reparentFolder: (_ id: UUID, _ newParentID: UUID?) -> Void
    public var deleteFolder: (_ id: UUID) -> Void
    /// File records into a folder.
    public var addRecords: (_ ids: Set<UUID>, _ folderID: UUID) -> Void
    /// Unfile records from a folder (never deletes the records).
    public var removeRecords: (_ ids: Set<UUID>, _ folderID: UUID) -> Void

    /// Whether the host supports structure edits at all. Hosts normally pass
    /// the kind's `CollectionCapability.canOrganize`.
    public var canOrganize: Bool

    public init(
        canOrganize: Bool = true,
        createFolder: @escaping (String, UUID?) -> UUID? = { _, _ in nil },
        renameFolder: @escaping (UUID, String) -> Void = { _, _ in },
        reparentFolder: @escaping (UUID, UUID?) -> Void = { _, _ in },
        deleteFolder: @escaping (UUID) -> Void = { _ in },
        addRecords: @escaping (Set<UUID>, UUID) -> Void = { _, _ in },
        removeRecords: @escaping (Set<UUID>, UUID) -> Void = { _, _ in }
    ) {
        self.canOrganize = canOrganize
        self.createFolder = createFolder
        self.renameFolder = renameFolder
        self.reparentFolder = reparentFolder
        self.deleteFolder = deleteFolder
        self.addRecords = addRecords
        self.removeRecords = removeRecords
    }
}

// MARK: - Menus

/// The shared folder menu grammar. Both entries take the FLAT folder list and
/// render the tree themselves, so callers never hand-build nested menus.
public enum RecordFolderMenu {

    /// "Move to Folder ▸" — the iOS move gesture. Renders the folder tree as
    /// nested submenus; a folder with children is a `Menu` whose first item
    /// files into the folder itself, so every folder stays a legal target.
    @ViewBuilder
    @MainActor
    public static func moveTo(
        folders: [RecordFolder],
        targets: Set<UUID>,
        actions: RecordCollectionActions,
        currentFolderID: UUID? = nil,
        title: String = "Move to Folder"
    ) -> some View {
        if !folders.isEmpty, !targets.isEmpty {
            Menu(title) {
                ForEach(folders.children(of: nil)) { folder in
                    subtreeMenu(
                        folder: folder,
                        folders: folders,
                        targets: targets,
                        actions: actions)
                }
                if let currentFolderID {
                    Divider()
                    Button("Remove from Folder", role: .destructive) {
                        actions.removeRecords(targets, currentFolderID)
                    }
                }
            }
        }
    }

    /// The organise verbs for ONE folder row (rename / new subfolder / move /
    /// delete). Gated on `actions.canOrganize`; the host supplies the rename
    /// and create prompts because a modal is platform-shaped.
    @ViewBuilder
    @MainActor
    public static func organize(
        folder: RecordFolder,
        folders: [RecordFolder],
        actions: RecordCollectionActions,
        onRename: @escaping (RecordFolder) -> Void,
        onNewSubfolder: @escaping (RecordFolder) -> Void
    ) -> some View {
        if actions.canOrganize {
            Button {
                onRename(folder)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button {
                onNewSubfolder(folder)
            } label: {
                Label("New Subfolder…", systemImage: "folder.badge.plus")
            }
            // Reparent, touch-style: the kernel's cycle check is the backstop,
            // but a folder's own subtree is never offered in the first place.
            let forbidden = folders.subtreeIDs(of: folder.id)
            let candidates = folders.filter { !forbidden.contains($0.id) }
            if folder.parentID != nil || !candidates.isEmpty {
                Menu("Move Folder") {
                    if folder.parentID != nil {
                        Button("Top Level") { actions.reparentFolder(folder.id, nil) }
                        Divider()
                    }
                    ForEach(candidates.children(of: nil)) { candidate in
                        reparentSubtreeMenu(
                            candidate: candidate,
                            folders: candidates,
                            moving: folder,
                            actions: actions)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                actions.deleteFolder(folder.id)
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    // MARK: Recursive submenu helpers
    //
    // SwiftUI cannot recurse through `some View`, so each level returns
    // `AnyView`. Folder trees are shallow (a handful of levels), so the
    // erasure cost is irrelevant next to keeping ONE implementation.

    @MainActor
    private static func subtreeMenu(
        folder: RecordFolder,
        folders: [RecordFolder],
        targets: Set<UUID>,
        actions: RecordCollectionActions
    ) -> AnyView {
        let children = folders.children(of: folder.id)
        if children.isEmpty {
            return AnyView(
                Button {
                    actions.addRecords(targets, folder.id)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
            )
        }
        return AnyView(
            Menu {
                Button {
                    actions.addRecords(targets, folder.id)
                } label: {
                    Label("Into “\(folder.name)”", systemImage: "folder")
                }
                Divider()
                ForEach(children) { child in
                    subtreeMenu(
                        folder: child, folders: folders, targets: targets, actions: actions)
                }
            } label: {
                Label(folder.name, systemImage: "folder")
            }
        )
    }

    @MainActor
    private static func reparentSubtreeMenu(
        candidate: RecordFolder,
        folders: [RecordFolder],
        moving: RecordFolder,
        actions: RecordCollectionActions
    ) -> AnyView {
        let children = folders.children(of: candidate.id)
        if children.isEmpty {
            return AnyView(
                Button {
                    actions.reparentFolder(moving.id, candidate.id)
                } label: {
                    Label(candidate.name, systemImage: "folder")
                }
            )
        }
        return AnyView(
            Menu {
                Button {
                    actions.reparentFolder(moving.id, candidate.id)
                } label: {
                    Label("Into “\(candidate.name)”", systemImage: "folder")
                }
                Divider()
                ForEach(children) { child in
                    reparentSubtreeMenu(
                        candidate: child, folders: folders, moving: moving, actions: actions)
                }
            } label: {
                Label(candidate.name, systemImage: "folder")
            }
        )
    }
}
