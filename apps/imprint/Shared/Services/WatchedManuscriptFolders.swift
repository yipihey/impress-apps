//
//  WatchedManuscriptFolders.swift
//  imprint
//
//  ADR-0023 W3 — imprint's whole watched-folder surface, as one file.
//
//  ── What is imprint's and what is not ───────────────────────────────────────
//
//  Everything about WATCHING is the chassis's and is reused, not forked:
//  `FolderWatchService` finds the files (W1), `SharedStore.watched*` records
//  and diffs them by hash (W0), `WatchedFolderIngestCoordinator` drives the
//  loop and sweeps what vanished (W2). What imprint supplies is exactly the
//  thing ADR-0023 D3 says differs by kind: **the per-file fan-out**, one
//  closure, plus the two tag hooks that make a folder's records a list.
//
//  For imprint the unit is `file` (D3), so the fan-out is the simplest one
//  there is: one discovered file becomes ONE manuscript row, and that row is a
//  reference (D4) — `ExternalManuscriptSource`, no copy, no write-back.
//
//  ── The two tags ────────────────────────────────────────────────────────────
//
//  The vocabulary is `WatchedFolderProvenanceTag`, W2's, unchanged:
//
//    watched/<folder name>          every manuscript the folder produced —
//                                   and therefore the folder row's list scope
//    watched/removed-from-source    a file that vanished (imprint's cousin of
//                                   imbib's dropped entry; the manuscript row
//                                   is KEPT, flagged, and un-flagged if the
//                                   file returns)
//
//  imprint reuses imbib's spelling deliberately. The tag is what a user sees;
//  a second word for the same situation in a second app would be a second
//  thing to learn for no gain, and `docs/chassis-capability-matrix.md` records
//  the tag namespace once.
//

import Foundation
import ImpressLogging
import OSLog
import PublicationManagerCore

/// imprint's watched-folder wiring: the hooks, the coordinator, the sweep.
@MainActor
public enum WatchedManuscriptFolders {

    /// The `kind_scope` every folder imprint watches is created with — and,
    /// by `FileDiscoveryFilter+RecordKind`'s identity rule, also the filter id
    /// and the persisted bookmark key. Read from the descriptor, never spelled.
    public static var kindScope: String { ManuscriptRecordKind.descriptor.id.rawValue }

    /// The one coordinator imprint runs.
    ///
    /// `nil` only if the manuscript kind ever stopped declaring a
    /// `FileDiscoveryCapability`, which the parity test would catch first.
    /// Asking by scope rather than using `.shared` is the point of W4's
    /// registry: `.shared` is imbib's publication coordinator, and a process
    /// that watched manuscripts through it would create `watched-folder` rows
    /// with the wrong `kind_scope` and discover `.bib` files.
    public static var coordinator: WatchedFolderIngestCoordinator? {
        // The missing sweep is installed HERE and not in `start()`, because on
        // macOS imprint never calls `start()`: the chassis sidebar starts every
        // file-unit coordinator its shell declares a section for
        // (`ImbibSidebarViewModel.startFileUnitWatchers`). Registering the
        // hooks and registering the sweep are the same moment — "imprint owns
        // the manuscript half of this kind scope" — so they belong on the same
        // line. Both are idempotent.
        installMissingSweep()
        return WatchedFolderIngestCoordinator.coordinator(forKindScope: kindScope, hooks: hooks)
    }

    /// The coordinator only if one is already running — what a SIDEBAR asks,
    /// so that rendering a section never starts a watcher.
    public static var runningCoordinator: WatchedFolderIngestCoordinator? {
        WatchedFolderIngestCoordinator.runningCoordinator(forKindScope: kindScope)
    }

    /// Begin watching every folder this launch remembers. Called once from the
    /// app's startup task, after the store is open.
    public static func start() async {
        await coordinator?.start()
    }

    /// Run `reconcileMissing()` after every pass of the chassis loop.
    ///
    /// The kernel's sweep (`finish_watched_scan`) marks the `watched-file` rows
    /// `missing`; the MANUSCRIPT rows are imprint's and nothing in the chassis
    /// knows they exist. `.watchedFoldersDidChange` is posted at the end of
    /// every event the coordinator handles — including `filesRemoved`, which is
    /// the only path that produces a `missing` row — so it is exactly the
    /// signal "the index moved; mirror it".
    ///
    /// Idempotent by construction: `markExternalManuscriptMissing` returns nil
    /// for a row already flagged, so the common case (nothing vanished) writes
    /// nothing at all.
    private static var missingSweepObserver: NSObjectProtocol?

    private static func installMissingSweep() {
        guard missingSweepObserver == nil else { return }
        missingSweepObserver = NotificationCenter.default.addObserver(
            forName: .watchedFoldersDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = reconcileMissing() }
        }
    }

    // MARK: - The fan-out (ADR-0023 D3)

    /// imprint's per-file ingest, as the chassis wants it.
    ///
    /// The contract of `produceRows` is "the store rows this FILE accounts
    /// for" — both the ones this pass created and the ones it refreshed —
    /// because an omitted id is reported to `record_produced_rows` as an id the
    /// source DROPPED. A file-unit kind accounts for exactly one row, so the
    /// only question each pass answers is which list it goes in.
    public static var hooks: WatchedFolderImportHooks {
        WatchedFolderImportHooks(
            produceRows: { path, _ in
                let adapter = ManuscriptStoreAdapter.shared
                let outcome = try adapter.upsertExternalManuscript(
                    path: path,
                    folderName: folderName(forPath: path),
                    watchedFolderID: nil,
                    watchedFileID: nil)
                // A file that had gone missing and came back un-flags itself —
                // the same reversibility rule W2 fixed for dropped entries. The
                // upsert above already restored `state: .present`.
                adapter.removeTag(
                    ids: [outcome.id],
                    tagPath: WatchedFolderProvenanceTag.removedFromSource,
                    undoManager: nil)
                return outcome.created ? ([outcome.id], []) : ([], [outcome.id])
            },
            // A manuscript is parented by its own kind's rules (a folder, or
            // nothing); there is no "library" to refuse for.
            requiresLibrary: false,
            addTag: { ids, path in
                guard !ids.isEmpty else { return }
                ManuscriptStoreAdapter.shared.addTag(ids: ids, tagPath: path, undoManager: nil)
            },
            removeTag: { ids, path in
                guard !ids.isEmpty else { return }
                ManuscriptStoreAdapter.shared.removeTag(ids: ids, tagPath: path, undoManager: nil)
            })
    }

    /// The watched folder a path is inside, by longest matching root.
    ///
    /// Needed because `produceRows` receives a path and not a folder: the
    /// closure is per FILE by design (the coordinator owns the folder loop).
    /// Longest-prefix rather than first-match so a folder watched inside
    /// another watched folder attributes to the nearer one.
    private static func folderName(forPath path: String) -> String? {
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        return runningCoordinator?.rows
            .compactMap { row -> (String, Int)? in
                guard let root = row.path, file.hasPrefix(root) else { return nil }
                return (row.displayName, root.count)
            }
            .max(by: { $0.1 < $1.1 })?.0
    }

    // MARK: - The missing sweep (ADR-0023 D4)

    /// Reconcile the manuscript rows with the `watched-file` rows the kernel
    /// swept, and flag what vanished.
    ///
    /// Two rows exist per external manuscript by design — a `watched-file` row
    /// (the index, W0's, which the kernel marks `missing`) and a `manuscript`
    /// row (imprint's). W0 owns the first; this owns the second, and the ONLY
    /// thing it does is set a flag. **Nothing is deleted, on either side.**
    @discardableResult
    public static func reconcileMissing() -> (flagged: Int, restored: Int) {
        guard let coordinator = runningCoordinator else { return (0, 0) }
        let adapter = ManuscriptStoreAdapter.shared
        var flagged = 0
        var restored = 0
        for row in coordinator.rows {
            for file in coordinator.files(in: row.id) {
                do {
                    if file.isMissing {
                        if let id = try adapter.markExternalManuscriptMissing(path: file.path) {
                            adapter.addTag(
                                ids: [id],
                                tagPath: WatchedFolderProvenanceTag.removedFromSource,
                                undoManager: nil)
                            flagged += 1
                        }
                    } else if let id = try adapter.markExternalManuscriptPresent(path: file.path) {
                        adapter.removeTag(
                            ids: [id],
                            tagPath: WatchedFolderProvenanceTag.removedFromSource,
                            undoManager: nil)
                        restored += 1
                    }
                } catch {
                    Logger.sharedStore.errorCapture(
                        "watched manuscripts: reconciling \(file.path) failed — "
                            + "\(error.localizedDescription)",
                        category: "watched-folders")
                }
            }
        }
        if flagged > 0 || restored > 0 {
            Logger.sharedStore.infoCapture(
                "watched manuscripts: \(flagged) flagged missing, \(restored) restored — "
                    + "nothing deleted",
                category: "watched-folders")
        }
        return (flagged, restored)
    }

    // MARK: - The folder's list

    /// The manuscripts one watched folder produced, as a list scope.
    ///
    /// W2's choice, reused: the provenance tag IS the scope, so there is no new
    /// query and no per-folder collection. (`WatchedFolderIngestCoordinator
    /// .publicationSource(for:)` is the publication-side twin of this line.)
    public static func storeScope(forFolder id: WatchedFolderID) -> ManuscriptStoreScope? {
        guard let name = runningCoordinator?.rows.first(where: { $0.id == id })?.displayName
        else { return nil }
        return .tag(WatchedFolderProvenanceTag.path(forFolderNamed: name))
    }
}

// MARK: - The no-write-back gate

/// The one predicate that keeps a store row from fighting the file (D4).
///
/// ── Why a gate at the SESSION and not at the save ───────────────────────────
///
/// `ManuscriptEditorSession`'s save is a 200 ms debounced compare-and-set into
/// the store, scheduled by the buffer's `didSet`. Its invariants are frozen and
/// its failure modes are known — most relevantly the one imbib's CLAUDE.md
/// records: a debounced save that fires after the row is gone RESURRECTS it.
/// The external-manuscript version of that bug would be worse in kind, because
/// the row it resurrects competes with a file the user is editing in their own
/// editor, and the store's copy is by definition older.
///
/// So the gate is placed where a session is CREATED, not where it saves: an
/// external manuscript never gets one, so there is no debounce to fire, no
/// buffer to go stale, and no conflict banner to reason about. A read-only
/// surface plus the two D4 affordances (open in place, import a copy) is what
/// the row offers instead. That is also the honest v1 the session supports —
/// `saveCAS` targets `RustStoreAdapter.setManuscriptBody` and has no
/// file-writing seam to hand a path to, and inventing one for W3 would mean
/// editing the frozen lifecycle rather than staying out of it.
@MainActor
public enum WatchedManuscriptGuard {

    /// Whether this manuscript may take a live editor session.
    ///
    /// False exactly when the file is authoritative. Consulted by every editor
    /// host: imprint macOS through `ManuscriptSectionView`'s resolution, and
    /// imprint-iOS in `IOSManuscriptEditorHost` (which has its own debounce and
    /// therefore its own copy of the risk).
    public static func allowsEditorSession(_ model: ManuscriptModel?) -> Bool {
        guard let model else { return true }
        return !model.isExternalReference
    }

    /// The same question by id, for hosts that hold one.
    public static func allowsEditorSession(id: UUID) -> Bool {
        allowsEditorSession(ManuscriptStoreAdapter.shared.manuscript(id: id))
    }
}
