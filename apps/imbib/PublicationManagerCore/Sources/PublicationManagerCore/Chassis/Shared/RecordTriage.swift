// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
// The action bag, the row state and BOTH SwiftUI builders (swipe + menu) are
// portable: `swipeActions`, `Menu`, `Button`, `Divider` and `Label` are all
// plain SwiftUI, and the store-backed defaults go through `RustStoreAdapter`,
// which was never gated. The one AppKit dependency — the modal "New Tag…"
// prompt (NSAlert + NSTextField) — was SPLIT out into
// `RecordTriageNewTagPrompt.swift` rather than half-gating this file.
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
    /// Rename a single record (payload `title`). Store-backed defaults write
    /// the field with undo; hosts with file-backed titles may override.
    public var onRename: (UUID, String) -> Void = { _, _ in }
    /// Remove from the current container scope (folder/collection), when the
    /// surface is scoped to one.
    public var onRemoveFromScope: (Set<UUID>) -> Void = { _ in }

    /// Tag paths the Tags submenu offers. `nil` = "ask the imbib store", which
    /// is what every macOS host wants and what this always did.
    ///
    /// It became injectable when imprint-iOS adopted the shared menu: that
    /// host talks to `ManuscriptStoreAdapter`, and reaching through
    /// `RustStoreAdapter.shared` from it would boot a SECOND store facade
    /// (imbib's) inside imprint just to populate a submenu. A host on another
    /// adapter supplies its own list — or an empty one, which hides the
    /// submenu rather than showing a lying empty menu.
    public var availableTagPaths: (() -> [String])?

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
        a.onRename = { id, title in
            RustStoreAdapter.shared.updateField(id: id, field: "title", value: title)
            Logger.library.infoCapture(
                "renamed \(descriptor.displayName.lowercased()) \(id) → '\(title)'",
                category: "triage")
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

    /// Store-backed defaults WITH UNDO, for a host on the shared impress store.
    ///
    /// `storeBacked(descriptor:)` above needs no undo argument because it never
    /// registers any: every `RustStoreAdapter` verb it calls returns an
    /// `UndoInfo` from imbib-core's operation log and hands it to
    /// `UndoCoordinator` itself. The `SharedStore` FFI has no operation log —
    /// `SharedStore.setStarred` returns `Void` — so a host on THAT surface needs
    /// closure-based undo with per-item prior-value capture, which is what
    /// `RecordTriageStoreKernel` provides.
    ///
    /// That missing argument is the whole reason imprint carried a hand-rolled
    /// twin of the store half of triage. It passes the `UndoManager` its platform
    /// supplies (the window's on macOS, `SceneUndoManager.shared.manager` on iOS,
    /// a fresh one in tests) and its OWN adapter's kernel, so no second store
    /// facade is booted inside it.
    ///
    /// - Parameters:
    ///   - kernel: the host's kernel. Defaults to one on the shared impress
    ///     store with imbib's mutation fan-out — right for a PMC-internal caller,
    ///     wrong for a sibling app, which passes its own.
    ///   - availableTagPaths: defaults to the kernel's own
    ///     `tagPathsInUse()` (what is USED on this kind), so the Tags submenu is
    ///     populated without reaching into imbib's tag-definition rows.
    ///   - onDelete is deliberately NOT set: deletion carries a confirmation and
    ///     any editor-session teardown, which are the host's business.
    @MainActor
    public static func storeBacked(
        descriptor: RecordKindDescriptor,
        undoManager: UndoManager?,
        kernel: RecordTriageStoreKernel? = nil,
        availableTagPaths: (() -> [String])? = nil
    ) -> RecordTriageActions {
        let kernel = kernel ?? RecordTriageStoreKernel(
            descriptor: descriptor, scope: CollectionStoreAdapter.shared.scope)
        let undo = StoreUndoScope.manager(undoManager)
        var a = RecordTriageActions()
        a.onToggleStar = { ids, starred in
            kernel.setStarred(ids: Array(ids), starred: starred, undo: undo)
        }
        a.onSetFlag = { ids, color in
            kernel.setFlag(ids: Array(ids), color: color?.rawValue, undo: undo)
        }
        a.onAddTag = { ids, path in
            kernel.addTag(ids: Array(ids), tagPath: path, undo: undo)
        }
        a.onRemoveTag = { ids, path in
            kernel.removeTag(ids: Array(ids), tagPath: path, undo: undo)
        }
        // Status-based verbs follow the descriptor: a kind that declares `.none`
        // gets a no-op rather than a silent wrong write.
        a.onDismiss = { ids in _ = kernel.dismiss(ids: Array(ids), undo: undo) }
        a.onRestore = { ids in _ = kernel.restore(ids: Array(ids), undo: undo) }
        a.onArchive = { ids in _ = kernel.archive(ids: Array(ids), undo: undo) }
        a.onRename = { id, title in kernel.rename(id: id, to: title, undo: undo) }
        a.availableTagPaths = availableTagPaths ?? { kernel.tagPathsInUse() }
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
            // The submenu hides ITSELF when the host has neither tags to
            // offer nor a prompt to make one — the check has to live in a
            // `body` (main-actor) rather than in this nonisolated builder.
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

    /// Tag paths for this host: the injected list when there is one, imbib's
    /// store otherwise (the historical behaviour).
    @MainActor
    static func tagPaths(actions: RecordTriageActions) -> [String] {
        if let provider = actions.availableTagPaths { return provider() }
        return RustStoreAdapter.shared.listTags().map(\.path)
    }

    var body: some View {
        let allTags = Self.tagPaths(actions: actions)
        if isAvailable(tagPaths: allTags) {
            Menu("Tags") {
            ForEach(allTags, id: \.self) { path in
                Button {
                    if rowTagPaths.contains(path) {
                        actions.onRemoveTag(targets, path)
                    } else {
                        actions.onAddTag(targets, path)
                    }
                } label: {
                    if rowTagPaths.contains(path) {
                        Label(path, systemImage: "checkmark")
                    } else {
                        Text(path)
                    }
                }
            }
            // The affordance is present only where a modal prompt exists.
            // On macOS that is `NSAlert` (unchanged); iOS hosts create tags
            // from their own sheet, so showing a dead button here would be
            // worse than not showing one.
            if RecordTriageNewTagPrompt.isAvailable {
                if !allTags.isEmpty { Divider() }
                Button("New Tag…") { promptForNewTag() }
            }
            }
        }
    }

    /// A Tags submenu with neither tags nor a way to make one is a dead menu
    /// item — hosts that can offer neither simply don't get the submenu.
    private func isAvailable(tagPaths: [String]) -> Bool {
        RecordTriageNewTagPrompt.isAvailable || !tagPaths.isEmpty
    }

    private func promptForNewTag() {
        guard let path = RecordTriageNewTagPrompt.run() else { return }
        actions.onAddTag(targets, path)
    }
}
