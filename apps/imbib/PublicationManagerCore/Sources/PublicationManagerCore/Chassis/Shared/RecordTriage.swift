#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  RecordTriage.swift
//  PublicationManagerCore
//
//  Stage 1 (ADR-0021): ONE triage action surface + ONE swipe/menu grammar for
//  every record list, parameterized by the kind's TriageCapabilities. The
//  store side is already schema-agnostic (set_flag / add_tag / set_starred /
//  status updateField), so a single store-backed default serves all kinds;
//  hosts override only kind-specific verbs (create, open, delete — delete
//  stays host-owned because of confirmation + editor-session discard).
//

import SwiftUI
import ImpressFTUI
import ImpressKeyboard
import OSLog

// MARK: - Actions

/// The triage verbs a record list surfaces. All selection-shaped verbs take
/// `Set<UUID>` (Mail semantics: acting on a selected row acts on the whole
/// selection).
public struct RecordTriageActions {
    public var onToggleStar: (Set<UUID>, Bool) -> Void = { _, _ in }
    public var onSetFlag: (Set<UUID>, FlagColor?) -> Void = { _, _ in }
    public var onAddTag: (Set<UUID>, String) -> Void = { _, _ in }
    public var onRemoveTag: (Set<UUID>, String) -> Void = { _, _ in }
    public var onDismiss: (Set<UUID>) -> Void = { _ in }
    public var onRestore: (Set<UUID>) -> Void = { _ in }
    public var onArchive: (Set<UUID>) -> Void = { _ in }
    /// Host-owned: confirmation + any session teardown happen in the host.
    public var onDelete: (Set<UUID>) -> Void = { _ in }
    public var onOpen: (UUID) -> Void = { _ in }
    public var onCreate: (CreationAffordance) -> Void = { _ in }
    public var onDuplicate: (UUID) -> Void = { _ in }
    /// Remove from the current container scope (folder/collection), when the
    /// surface is scoped to one.
    public var onRemoveFromScope: (Set<UUID>) -> Void = { _ in }

    public init() {}

    /// Store-backed defaults for everything the generic Rust ops cover.
    /// Status-based dismiss/restore/archive follow the descriptor's
    /// `TriageCapabilities`; kinds with other semantics (publications'
    /// library-move) override those closures host-side.
    @MainActor
    public static func storeBacked(descriptor: RecordKindDescriptor) -> RecordTriageActions {
        var a = RecordTriageActions()
        let triage = descriptor.triage
        a.onToggleStar = { ids, starred in
            RustStoreAdapter.shared.setStarred(ids: Array(ids), starred: starred)
        }
        a.onSetFlag = { ids, color in
            RustStoreAdapter.shared.setFlag(ids: Array(ids), color: color?.rawValue)
        }
        a.onAddTag = { ids, path in
            RustStoreAdapter.shared.addTag(ids: Array(ids), tagPath: path)
        }
        a.onRemoveTag = { ids, path in
            RustStoreAdapter.shared.removeTag(ids: Array(ids), tagPath: path)
        }
        if case .statusChange(let dismissed, let restoreTo) = triage.dismissal {
            a.onDismiss = { ids in
                for id in ids {
                    RustStoreAdapter.shared.updateField(id: id, field: "status", value: dismissed)
                }
                Logger.library.infoCapture(
                    "dismissed \(ids.count) \(descriptor.displayName.lowercased())(s)",
                    category: "triage")
            }
            a.onRestore = { ids in
                for id in ids {
                    RustStoreAdapter.shared.updateField(id: id, field: "status", value: restoreTo)
                }
                Logger.library.infoCapture(
                    "restored \(ids.count) \(descriptor.displayName.lowercased())(s)",
                    category: "triage")
            }
        }
        if let archiveStatus = triage.archiveStatus {
            a.onArchive = { ids in
                for id in ids {
                    RustStoreAdapter.shared.updateField(
                        id: id, field: "status", value: archiveStatus)
                }
                Logger.library.infoCapture(
                    "archived \(ids.count) \(descriptor.displayName.lowercased())(s)",
                    category: "triage")
            }
        }
        return a
    }
}

/// The per-row state the shared builders need to phrase the grammar.
public struct TriageRowState {
    public let isStarred: Bool
    /// Whether the row currently sits in the Dismissed state/scope.
    public let isDismissed: Bool
    /// Whether the row is already archived.
    public let isArchived: Bool

    public init(isStarred: Bool, isDismissed: Bool, isArchived: Bool = false) {
        self.isStarred = isStarred
        self.isDismissed = isDismissed
        self.isArchived = isArchived
    }
}

// MARK: - Swipe grammar

/// The suite-wide swipe grammar: leading = star (full swipe); trailing =
/// dismiss + archive — except in Dismissed, where delete becomes primary and
/// restore replaces dismiss.
public enum TriageSwipe {
    @ViewBuilder
    public static func trailing(
        triage: TriageCapabilities,
        row: TriageRowState,
        targets: Set<UUID>,
        actions: RecordTriageActions
    ) -> some View {
        if row.isDismissed {
            if triage.deletion != .none {
                Button(role: .destructive) {
                    actions.onDelete(targets)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if triage.dismissal != .none {
                Button {
                    actions.onRestore(targets)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.blue)
            }
        } else {
            if triage.dismissal != .none {
                Button {
                    actions.onDismiss(targets)
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle")
                }
                .tint(.orange)
            }
            if triage.archiveStatus != nil, !row.isArchived {
                Button {
                    actions.onArchive(targets)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.gray)
            }
        }
    }

    @ViewBuilder
    public static func leading(
        triage: TriageCapabilities,
        row: TriageRowState,
        targets: Set<UUID>,
        actions: RecordTriageActions
    ) -> some View {
        if triage.canStar {
            Button {
                actions.onToggleStar(targets, !row.isStarred)
            } label: {
                Label(
                    row.isStarred ? "Unstar" : "Star",
                    systemImage: row.isStarred ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
    }
}

// MARK: - Menu grammar

/// The triage segment of a record row's context menu (star/dismiss/archive,
/// Flag submenu, Tags submenu, delete-with-ellipsis last). Kind-specific
/// items (Open/Duplicate/collections/enrichment) are appended by the caller.
public enum TriageMenu {
    @ViewBuilder
    public static func items(
        triage: TriageCapabilities,
        row: TriageRowState,
        rowTagPaths: Set<String>,
        targets: Set<UUID>,
        actions: RecordTriageActions
    ) -> some View {
        if triage.canStar {
            Button(row.isStarred ? "Unstar" : "Star") {
                actions.onToggleStar(targets, !row.isStarred)
            }
        }
        if row.isDismissed {
            if triage.dismissal != .none {
                Button("Restore") { actions.onRestore(targets) }
            }
        } else {
            if triage.dismissal != .none {
                Button("Dismiss") { actions.onDismiss(targets) }
            }
            if triage.archiveStatus != nil, !row.isArchived {
                Button("Archive") { actions.onArchive(targets) }
            }
        }
        Divider()
        if triage.canFlag {
            Menu("Flag") {
                ForEach(FlagColor.allCases) { color in
                    Button(color.displayName) { actions.onSetFlag(targets, color) }
                }
                Button("Clear Flag") { actions.onSetFlag(targets, nil) }
            }
        }
        if triage.canTag {
            TriageTagMenu(rowTagPaths: rowTagPaths, targets: targets, actions: actions)
        }
        if triage.deletion != .none {
            Divider()
            Button(
                targets.count > 1 ? "Delete \(targets.count) Items…" : "Delete…",
                role: .destructive
            ) {
                actions.onDelete(targets)
            }
        }
    }
}

/// Tags submenu with checkmarks + "New Tag…" prompt — shared verbatim across
/// kinds (tags are store-generic).
struct TriageTagMenu: View {
    let rowTagPaths: Set<String>
    let targets: Set<UUID>
    let actions: RecordTriageActions

    var body: some View {
        Menu("Tags") {
            let allTags = RustStoreAdapter.shared.listTags()
            ForEach(allTags, id: \.path) { tag in
                Button {
                    if rowTagPaths.contains(tag.path) {
                        actions.onRemoveTag(targets, tag.path)
                    } else {
                        actions.onAddTag(targets, tag.path)
                    }
                } label: {
                    if rowTagPaths.contains(tag.path) {
                        Label(tag.path, systemImage: "checkmark")
                    } else {
                        Text(tag.path)
                    }
                }
            }
            if !allTags.isEmpty { Divider() }
            Button("New Tag…") { promptForNewTag() }
        }
    }

    private func promptForNewTag() {
        let alert = NSAlert()
        alert.messageText = "New Tag"
        alert.informativeText = "Tag path (use / for hierarchy, e.g. projects/reionization)."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        actions.onAddTag(targets, path)
    }
}
#endif
