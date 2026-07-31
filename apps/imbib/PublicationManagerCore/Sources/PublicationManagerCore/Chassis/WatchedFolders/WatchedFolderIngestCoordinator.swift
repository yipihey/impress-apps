// Chassis WIRING file — CROSS-PLATFORM (macOS + iOS). The ADR-0023 W2 loop.
//
//  WatchedFolderIngestCoordinator.swift
//  PublicationManagerCore
//
//  ── The whole feature, as one pipeline ──────────────────────────────────────
//
//      FolderWatchService (W1, Swift)   "these paths are here now"
//            │  FolderWatchEvent
//            ▼
//      SharedStore.watchedImportDiscovered (W0, Rust)   the D4 diff
//            │  created / changed / restored     (unchanged writes NOTHING)
//            ▼
//      imbib's REAL importer                     BibTeX text → publications,
//            │  (imported, existing)             deduped by identifier
//            ▼
//      SharedStore.watchedRecordProduced (W0, Rust)     provenance + removed_ids
//            │
//            ▼
//      finishScan                                the missing-file sweep
//
//  Every stage is somebody else's; this file is only the wiring, and that is
//  the point — ADR-0023 D5's "platform policy in Swift, logic in Rust" leaves a
//  coordinator with no logic of its own to get wrong.
//
//  ── The three product decisions this file makes ─────────────────────────────
//
//  **1. What "the importer" means.** The same call a manual drag makes:
//  `import_bibtex_into(bibtex, library, collection: nil)` — one blob per file,
//  whole-library identifier dedup, one pass. A watched `.bib` and a dragged
//  `.bib` produce the same rows because they run the same verb. The one thing
//  read differently is the RESULT: the manual path keeps the created ids and
//  drops the deduped ones; this path needs both (see `importBibTeXOutcome`).
//
//  **2. What happens to an entry the source dropped** (`removed_ids`). It is
//  TAGGED, never deleted:
//
//      watched/removed-from-source
//
//  Rationale, since ADR-0023 explicitly leaves this to the app. The store's
//  answer is already fixed — nothing is deleted, D4 says so twice — so the only
//  question is where a human sees it. A tag is the least machinery that is
//  actually honest: it renders on the row (`TagLine`), in the detail pane
//  (`PublicationFlagAndTagsSection`), it is removable by the user with the
//  gesture they already know, and `PublicationSource.tag(_:)` makes the whole
//  set a list one construction site away. It survives relaunch because it is a
//  store row, not view state. And critically, it is REVERSIBLE by the system
//  too: if the entry comes back — the user hit undo in their editor, or the
//  file was mid-save — the next pass removes the tag again, which no
//  "review queue" placement would do without inventing a resolution verb.
//
//  What was rejected: deleting (D4 forbids it), a `status` change (imbib's
//  statuses are the reading workflow — "unread/reading/read" — and overloading
//  one would corrupt a user's actual reading state), and the review queue
//  (its rows are things awaiting a DECISION with an accept/reject pair, and
//  there is no accept verb here: the paper is fine, only its source moved on).
//
//  **3. Where the papers a folder produced can be seen.** The same tag
//  mechanism, per folder: every publication a watched folder imports carries
//
//      watched/<folder display name>
//
//  so selecting the folder row shows `PublicationSource.tag(...)` — an existing,
//  fully Rust-backed scope, with no new `PublicationSource` case, no new query,
//  and no per-folder collection cluttering the Libraries tree. It also answers
//  "where did this paper come from" on the row itself, without opening anything.
//  Display names are uniquified when a folder is added (`uniqueDisplayName`)
//  precisely because this tag is an identity: two folders both called "papers"
//  sharing one tag would merge two lists into a lie.
//

import Foundation
import ImpressKit
import OSLog

// MARK: - Change notification

public extension Notification.Name {

    /// A watched folder's rows changed — state, counts, or membership.
    ///
    /// `@Observable` reaches SwiftUI on its own; this exists for the ONE
    /// consumer it does not reach, macOS's `NSOutlineView` sidebar, which
    /// reloads on `ImbibSidebarViewModel.dataVersion`. The store-backed half of
    /// a change already arrives there through `RustStoreAdapter.dataVersion`;
    /// the watcher-only half (a folder degrading to `fallback`, a gather
    /// finishing, a badge clearing) touches no store row and would otherwise
    /// never redraw.
    static let watchedFoldersDidChange = Notification.Name("watchedFoldersDidChange")
}

// MARK: - The provenance tag vocabulary

/// The `watched/` tag namespace, in one place.
///
/// A tag path is user-visible text AND a scope key, so it gets a type rather
/// than string literals at call sites — the same rule `WatchedFolderRoute`
/// follows for sidebar keys, for the same reason.
public enum WatchedFolderProvenanceTag {

    /// The namespace every tag this feature writes lives under.
    public static let namespace = "watched"

    /// The tag every publication a watched folder produced carries.
    public static func path(forFolderNamed name: String) -> String {
        // A tag path is slash-separated, so a slash in a folder name would mint
        // a spurious hierarchy level. Folder display names are last path
        // components and cannot contain one — this is belt and braces for a
        // caller that passes something else.
        let leaf = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(namespace)/\(leaf.isEmpty ? "folder" : leaf)"
    }

    /// The tag an entry gets when its source file stops containing it.
    ///
    /// **Nothing is deleted.** This is a flag for a human to look at, and it is
    /// removed again automatically if the entry reappears.
    public static let removedFromSource = "\(namespace)/removed-from-source"

    /// Names a folder may not take, because they would collide with a tag this
    /// vocabulary already means something by.
    public static let reservedFolderNames: Set<String> = ["removed-from-source"]
}

// MARK: - Injection

/// The three things the coordinator needs from imbib, as closures.
///
/// A struct of closures rather than a protocol: the live value is three lines
/// over `RustStoreAdapter.shared`, and a test wants to substitute exactly one
/// of them (usually none — the headless test runs the REAL importer against an
/// in-memory store, which is the only way the dedup claim gets proven).
/// `FolderWatchEngineFactory` is the same shape one layer down.
@MainActor
public struct WatchedFolderImportHooks {

    /// Import one file's worth of BibTeX. Returns the ids the file accounts
    /// for: `imported` are new rows, `existing` deduped onto papers already in
    /// the library — and BOTH are produced by this file.
    public var importBibTeX: (String, UUID) -> (imported: [UUID], existing: [UUID])

    /// The library watched folders import into. `nil` refuses the import
    /// rather than inventing a parent id.
    public var defaultLibraryID: () -> UUID?

    public var addTag: ([UUID], String) -> Void
    public var removeTag: ([UUID], String) -> Void

    public init(
        importBibTeX: @escaping (String, UUID) -> (imported: [UUID], existing: [UUID]),
        defaultLibraryID: @escaping () -> UUID?,
        addTag: @escaping ([UUID], String) -> Void,
        removeTag: @escaping ([UUID], String) -> Void
    ) {
        self.importBibTeX = importBibTeX
        self.defaultLibraryID = defaultLibraryID
        self.addTag = addTag
        self.removeTag = removeTag
    }

    /// imbib's real import path.
    public static var live: WatchedFolderImportHooks {
        WatchedFolderImportHooks(
            importBibTeX: { bibtex, library in
                RustStoreAdapter.shared.importBibTeXOutcome(bibtex, libraryId: library)
            },
            defaultLibraryID: { RustStoreAdapter.shared.getDefaultLibrary()?.id },
            addTag: { ids, path in
                guard !ids.isEmpty else { return }
                RustStoreAdapter.shared.addTag(ids: ids, tagPath: path)
            },
            removeTag: { ids, path in
                guard !ids.isEmpty else { return }
                RustStoreAdapter.shared.removeTag(ids: ids, tagPath: path)
            })
    }
}

// MARK: - Coordinator

/// Drives W1's watcher into W0's store verbs and imbib's importer.
@MainActor
@Observable
public final class WatchedFolderIngestCoordinator {

    /// The app's one coordinator.
    ///
    /// A singleton for the same reason `RustStoreAdapter.shared` is one: there
    /// is exactly ONE set of watched folders per launch, two `FolderWatchService`
    /// instances over the same bookmarks would run two engines per directory,
    /// and both sidebars (macOS's outline, iOS's `RecordSidebarView`) plus the
    /// detail pane's provenance row need to read the same rows.
    public static let shared = WatchedFolderIngestCoordinator(
        watcher: FolderWatchService(startupGate: WatchedFolderIngestCoordinator.startupGate))

    /// The 90-second background-service embargo — except where there is no
    /// settling production UI to protect.
    ///
    /// `FolderWatchStartupGate`'s own doc comment names this: the default is
    /// "assume there is a UI" because a beachball is worse than a late scan,
    /// and `.immediate` is for "a headless host, a CLI, or a test". A UI test
    /// is the third of those — it runs against an in-memory store, and making
    /// every watched-folder assertion wait out 90 seconds would not be caution,
    /// it would be a suite nobody runs.
    private static var startupGate: FolderWatchStartupGate {
        UITestingEnvironment.isUITesting || ImpressRuntime.isUnitTestProcess
            ? .immediate
            : FolderWatchStartupGate()
    }

    /// imbib's `kind_scope` — the publication kind, whose declaration is also
    /// what the filters are derived from.
    public static let kindScope = RecordKindID.publication.rawValue

    // MARK: Dependencies

    public let watcher: FolderWatchService
    private let store: WatchedFolderStoreAdapter
    private let hooks: WatchedFolderImportHooks

    // MARK: Published state

    /// The sidebar's source. A straight proxy of the watcher's rows so a host
    /// observes ONE object; the watcher stays a chassis primitive with no
    /// knowledge of the store.
    public var rows: [WatchedFolderRowState] { watcher.rows }

    /// The last error each folder's ingest hit, for the row's detail line.
    /// Cleared by a successful pass.
    public private(set) var ingestErrors: [WatchedFolderID: String] = [:]

    /// Publications the most recent pass produced, per folder — the number the
    /// row can honestly claim it put in the library, as distinct from the file
    /// count the watcher reports.
    public private(set) var producedCounts: [WatchedFolderID: Int] = [:]

    /// Ids tagged `watched/removed-from-source` by the most recent pass, per
    /// folder. Surfaced so a host can say "3 entries are no longer in the
    /// source" without re-querying.
    public private(set) var removedFromSource: [WatchedFolderID: [UUID]] = [:]

    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    /// Store-side folder id (kernel-derived, from path+scope) per watcher id.
    @ObservationIgnored private var storeFolderIDs: [WatchedFolderID: String] = [:]
    /// Display name per watcher id — the provenance tag's leaf.
    @ObservationIgnored private var folderNames: [WatchedFolderID: String] = [:]
    /// Running per-scan totals `finishScan` cannot compute for itself.
    @ObservationIgnored private var pendingNew: [WatchedFolderID: Int] = [:]
    @ObservationIgnored private var pendingChanged: [WatchedFolderID: Int] = [:]

    public init(
        watcher: FolderWatchService = FolderWatchService(),
        store: WatchedFolderStoreAdapter = .shared,
        hooks: WatchedFolderImportHooks = .live
    ) {
        self.watcher = watcher
        self.store = store
        self.hooks = hooks
    }

    deinit { pumpTask?.cancel() }

    // MARK: Lifecycle

    /// Rebuild this launch's folders and begin watching.
    ///
    /// The 90-second startup embargo is the WATCHER's (`FolderWatchStartupGate`,
    /// awaited once inside `startAll`), not this file's: registration and
    /// bookmark resolution are cheap reads that must happen at launch so the
    /// sidebar has rows, while the first GATHER — the part that writes — is
    /// what the embargo protects the settling UI from.
    public func start() async {
        // A UI test that did not ASK for a watched folder must not inherit one.
        //
        // Bookmarks are persistent by design (D6 — a folder survives a launch),
        // and under UI testing they land in one shared suite
        // (`com.imbib.app.uitesting`) that outlives the process. So the run
        // that seeds a folder leaves it behind for every later run, where it
        // shows up as an extra Libraries row and pushes the sections a lazy
        // `List` has materialised — which is exactly how it first announced
        // itself: two unrelated sidebar tests failing to find `search`.
        if UITestingEnvironment.isUITesting, !UITestingEnvironment.shouldSeedWatchedFolder {
            await WatchedFolderBookmarkStore.shared.removeAll()
        }
        startPump()
        await restore()
        await watcher.startAll()
    }

    /// Subscribe to the watcher BEFORE anything can publish.
    ///
    /// Idempotent, and called from `addFolder` as well as `start`: the engine a
    /// freshly added folder starts publishes its gather immediately, and
    /// `FolderWatchService.events()` registers a continuation at call time — so
    /// a host that adds a folder before starting the coordinator would lose
    /// exactly the first, largest batch, silently.
    private func startPump() {
        guard pumpTask == nil else { return }
        let stream = watcher.events()
        pumpTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        watcher.stopAll()
    }

    /// Re-register every persisted folder, and reconcile the store rows with
    /// them.
    ///
    /// Filters are re-DERIVED from the record-kind declarations rather than
    /// read back from the bookmark — a folder watched before the publication
    /// kind gained an extension gains it here, with no migration (see
    /// `FileDiscoveryFilter+RecordKind`).
    private func restore() async {
        let restored = await watcher.restorePersistedFolders(
            filtersByID: FileDiscoveryFilter.builtinFiltersByID)
        for row in restored {
            folderNames[row.id] = row.displayName
            guard let path = row.path else { continue }
            do {
                let outcome = try store.addFolder(
                    path: path,
                    kindScope: Self.kindScope,
                    displayName: row.displayName,
                    bookmarkBase64: nil,
                    recursive: true)
                storeFolderIDs[row.id] = outcome.folder.id
            } catch {
                note(error, for: row.id)
            }
        }
    }

    // MARK: Adding and removing folders

    /// The "Add Watched Folder…" verb, from the URL a picker produced.
    ///
    /// Order matters and is the one the bookmark store's header insists on:
    /// mint and persist the bookmark FIRST (`persistAndAdd`), because that is
    /// the operation that can fail for sandbox reasons, and only then write the
    /// store row. A store row for a folder the app cannot open is a row that
    /// renders forever with nothing behind it.
    @discardableResult
    public func addFolder(at url: URL) async throws -> WatchedFolderRowState {
        guard let filter = FileDiscoveryFilter.publications else {
            throw FolderWatchFailure.noFilters
        }
        startPump()

        // Idempotent by PATH, matching the store verb one layer down (whose id
        // is derived from `(path, kind_scope)` for the same reason). Choosing
        // the same directory twice in the panel is a re-grant, not a second
        // folder — and without this it minted a second bookmark, a second
        // engine over the same tree, and a duplicate sidebar row whose display
        // name and therefore whose provenance TAG collided with the first's.
        let standardized = url.standardizedFileURL
        if let existing = watcher.rows.first(where: { $0.path == standardized.path }) {
            Logger.files.infoCapture(
                "watched folder: \(standardized.path) is already watched, reusing its row",
                category: "watched-folders")
            await watcher.start(existing.id)
            return existing
        }
        let name = uniqueDisplayName(for: standardized)
        let registration = try await watcher.persistAndAdd(
            url: url, filters: [filter], displayName: name)
        folderNames[registration.id] = registration.displayName

        let outcome = try store.addFolder(
            path: url.standardizedFileURL.path,
            kindScope: Self.kindScope,
            displayName: registration.displayName,
            bookmarkBase64: nil,
            recursive: true)
        storeFolderIDs[registration.id] = outcome.folder.id

        await watcher.start(registration.id)
        NotificationCenter.default.post(name: .watchedFoldersDidChange, object: nil)
        return watcher.row(for: registration.id)
            ?? WatchedFolderRowState(
                id: registration.id, displayName: registration.displayName,
                path: url.path, state: .scanOnDemand)
    }

    /// Stop watching. Removes the bookmark and the store's folder row; keeps
    /// every publication the folder imported, and keeps their provenance tag —
    /// un-watching is not a retraction.
    public func removeFolder(_ id: WatchedFolderID) async {
        if let storeID = storeFolderIDs[id] {
            do {
                try store.removeFolder(id: storeID, deleteFileRows: false)
            } catch {
                note(error, for: id)
            }
        }
        await watcher.remove(id)
        storeFolderIDs.removeValue(forKey: id)
        folderNames.removeValue(forKey: id)
        ingestErrors.removeValue(forKey: id)
        producedCounts.removeValue(forKey: id)
        removedFromSource.removeValue(forKey: id)
        NotificationCenter.default.post(name: .watchedFoldersDidChange, object: nil)
    }

    /// The row's Refresh verb.
    public func refresh(_ id: WatchedFolderID) async {
        ingestErrors.removeValue(forKey: id)
        await watcher.refresh(id)
    }

    public func markSeen(_ id: WatchedFolderID) { watcher.markSeen(id) }

    /// The publications one folder produced, as a list scope.
    ///
    /// See the file header: the provenance tag IS the scope, so this needs no
    /// new `PublicationSource` case and no new query.
    public func publicationSource(for id: WatchedFolderID) -> PublicationSource? {
        guard let name = folderNames[id] ?? watcher.row(for: id)?.displayName else { return nil }
        return .tag(WatchedFolderProvenanceTag.path(forFolderNamed: name))
    }

    /// A display name no other watched folder is using.
    ///
    /// Not cosmetic: the name is the provenance tag's leaf, and therefore the
    /// identity of "the papers this folder produced".
    private func uniqueDisplayName(for url: URL) -> String {
        let base = url.standardizedFileURL.lastPathComponent
        var taken = Set(watcher.rows.map(\.displayName))
        taken.formUnion(WatchedFolderProvenanceTag.reservedFolderNames)
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: The loop

    private func handle(_ event: FolderWatchEvent) async {
        defer { NotificationCenter.default.post(name: .watchedFoldersDidChange, object: nil) }
        switch event {
        case .gatheredBatch(let id, let files, _, let isFinal):
            await ingest(files.map(\.url.path), for: id)
            if isFinal { await closeScan(id) }

        case .filesAdded(let id, let files):
            await ingest(files.map(\.url.path), for: id)
            await closeScan(id)

        case .filesChanged(let id, let files):
            // The same sink as `.filesAdded`: `import_discovered` decides
            // whether anything actually moved, by hash. This is the path an
            // edited `.bib` takes — the live half of the feature.
            await ingest(files.map(\.url.path), for: id)
            await closeScan(id)

        case .filesRemoved(let id, _):
            // The paths are already gone; the sweep is what turns that into
            // `missing` rows, and it is the ONLY thing allowed to. Discovery is
            // never told about an absence, on purpose (a batch is not a set).
            await closeScan(id)

        case .stateChanged(let id, let state):
            declare(state, for: id)

        case .failed(let id, let failure):
            note(failure, for: id)
            declare(failure.resultingState, for: id)
        }
    }

    /// One batch of discovered paths: record them, then run the importer on the
    /// ones whose content actually moved.
    private func ingest(_ paths: [String], for id: WatchedFolderID) async {
        guard !paths.isEmpty, let storeID = storeFolderIDs[id] else { return }

        let report: WatchedDiscoveryReport
        do {
            report = try store.importDiscovered(folderID: storeID, paths: paths)
        } catch {
            note(error, for: id)
            return
        }

        pendingNew[id, default: 0] += report.created
        pendingChanged[id, default: 0] += report.changed + report.restored

        for skipped in report.skipped {
            Logger.files.warningCapture(
                "watched folder \(id.storageKey): skipped \(skipped.path) — \(skipped.reason)",
                category: "watched-folders")
        }

        let owed = report.needingImport
        guard !owed.isEmpty else {
            // The zero-write path. Nothing changed on disk, so nothing is
            // parsed, nothing is imported and no store mutation fires.
            Logger.files.infoCapture(
                "watched folder \(id.storageKey): \(report.unchanged) file(s) unchanged, "
                    + "nothing to import",
                category: "watched-folders")
            return
        }

        guard let library = hooks.defaultLibraryID() else {
            note(WatchedIngestError.noLibrary, for: id)
            return
        }

        var produced = 0
        var orphaned: [UUID] = []
        for file in owed {
            do {
                let outcome = try await importOne(file, into: library, folder: id)
                produced += outcome.produced
                orphaned.append(contentsOf: outcome.orphaned)
            } catch {
                note(error, for: id)
            }
        }
        producedCounts[id] = produced
        removedFromSource[id] = orphaned
        if !orphaned.isEmpty {
            Logger.files.warningCapture(
                "watched folder \(id.storageKey): \(orphaned.count) entr(ies) are no longer in "
                    + "their source file — tagged \(WatchedFolderProvenanceTag.removedFromSource), "
                    + "nothing deleted",
                category: "watched-folders")
        }
    }

    /// One file, all the way through: read → import → attribute → tag.
    private func importOne(
        _ file: WatchedDiscoveryReport.Outcome, into library: UUID, folder id: WatchedFolderID
    ) async throws -> (produced: Int, orphaned: [UUID]) {
        // 1. The file, as BibTeX. (.ris is converted; .bib passes through.)
        let bibtex = try BibliographyFileText.bibtex(atPath: file.path)

        // 2. imbib's REAL importer, with its whole-library identifier dedup.
        let (imported, existing) = hooks.importBibTeX(bibtex, library)
        let accounted = imported + existing

        // 3. Attribution. `replace: true` is what makes a dropped entry
        //    visible; `accounted` — not just `imported` — is what stops a
        //    deduped entry from LOOKING dropped.
        let attribution = try store.recordProduced(
            fileID: file.fileID, publicationIDs: accounted, replace: true)

        // 4. Provenance: the tag that is both "where this came from" and the
        //    folder row's list scope.
        let name = folderNames[id] ?? watcher.row(for: id)?.displayName ?? "folder"
        hooks.addTag(accounted, WatchedFolderProvenanceTag.path(forFolderNamed: name))

        // 5. The removed disposition — flag, never delete. And un-flag anything
        //    that has come back, so the tag never accumulates stale claims.
        hooks.addTag(attribution.removedIDs, WatchedFolderProvenanceTag.removedFromSource)
        hooks.removeTag(accounted, WatchedFolderProvenanceTag.removedFromSource)

        Logger.files.infoCapture(
            "watched folder \(id.storageKey): \((file.path as NSString).lastPathComponent) "
                + "\(file.action) → \(imported.count) new, \(existing.count) already present, "
                + "\(attribution.removedIDs.count) no longer in source",
            category: "watched-folders")
        return (accounted.count, attribution.removedIDs)
    }

    /// The sweep. Finds what vanished and writes the folder's stats.
    private func closeScan(_ id: WatchedFolderID) async {
        guard let storeID = storeFolderIDs[id] else { return }
        let new = pendingNew.removeValue(forKey: id) ?? 0
        let changed = pendingChanged.removeValue(forKey: id) ?? 0
        do {
            let scan = try store.finishScan(
                folderID: storeID, newCount: new, changedCount: changed)
            if scan.markedMissing > 0 {
                Logger.files.warningCapture(
                    "watched folder \(id.storageKey): \(scan.markedMissing) file(s) are gone "
                        + "from disk — rows kept and flagged missing, nothing deleted",
                    category: "watched-folders")
            }
        } catch {
            // The documented failure here is "the root is unreachable", and the
            // store has already declared the volume unavailable. Surfacing it
            // is right; retrying is not.
            note(error, for: id)
        }
    }

    /// Mirror the watcher's live state into the store row's D6 declaration, so
    /// a CLI or an agent reading `list_watched_folders` sees what the sidebar
    /// sees rather than a stale `indexed`.
    private func declare(_ state: WatchedFolderState, for id: WatchedFolderID) {
        guard let storeID = storeFolderIDs[id] else { return }
        let declared: String
        switch state {
        case .live: declared = "indexed"
        case .fallback: declared = "unindexed"
        case .scanOnDemand: declared = "scan-on-demand"
        case .inaccessible: declared = "unavailable"
        }
        do {
            try store.updateFolder(id: storeID, volumeState: declared)
        } catch {
            note(error, for: id)
        }
    }

    private func note(_ error: Error, for id: WatchedFolderID) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        ingestErrors[id] = message
        Logger.files.errorCapture(
            "watched folder \(id.storageKey): \(message)", category: "watched-folders")
    }
}

/// Why one folder's ingest could not run.
public enum WatchedIngestError: Error, LocalizedError, Equatable {

    /// The store has no library to import into. Refusing is the only honest
    /// option — writing to an invented parent id is the `AlreadyExists` storm
    /// `LibraryViewModel.libraryForWriting` exists to prevent.
    case noLibrary

    public var errorDescription: String? {
        switch self {
        case .noLibrary:
            return "There is no library to import into. Create one, or set a default library."
        }
    }
}
