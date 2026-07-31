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

/// The things the coordinator needs from its HOST APP, as closures.
///
/// A struct of closures rather than a protocol: the live value is three lines
/// over `RustStoreAdapter.shared`, and a test wants to substitute exactly one
/// of them (usually none — the headless test runs the REAL importer against an
/// in-memory store, which is the only way the dedup claim gets proven).
/// `FolderWatchEngineFactory` is the same shape one layer down.
///
/// ── The per-kind fan-out (ADR-0023 W4) ──────────────────────────────────────
///
/// W2 hard-wired one verb here (`importBibTeX`) because one kind existed. D3
/// says the ingest UNIT differs by kind, so what varies between apps is exactly
/// one closure: **one discovered file → the store rows it accounts for**.
/// Everything around it — recording the discovery, deciding by hash whether the
/// fan-out is owed, attributing the produced rows, sweeping what vanished — is
/// kind-agnostic and stays in the coordinator.
///
/// `produceRows` is that closure. imbib's reads the file as BibTeX and runs the
/// real importer (`entries` unit); a `file`-unit kind whose v1 mints nothing
/// returns `([], [])` and the watched-FILE row IS the record. The BibTeX
/// initializer below is kept verbatim so imbib's call sites and its six
/// end-to-end tests are untouched by the generalization.
@MainActor
public struct WatchedFolderImportHooks {

    /// One discovered file → the store rows it accounts for.
    ///
    /// `imported` are rows this pass created; `existing` are rows the file's
    /// content deduped onto. **Both** are produced by this file — an omitted id
    /// is reported to `record_produced_rows` as an id the source DROPPED, which
    /// is the claim that must not be made by accident (see `importOne` step 3).
    ///
    /// `libraryID` is nil for kinds that ingest without one; a hook that needs
    /// a library declares `requiresLibrary` and is never called with nil.
    public var produceRows: (
        _ path: String, _ libraryID: UUID?
    ) throws -> (imported: [UUID], existing: [UUID])

    /// The library watched folders import into. `nil` refuses the import
    /// rather than inventing a parent id — when `requiresLibrary`.
    public var defaultLibraryID: () -> UUID?

    /// Whether a nil library must refuse the pass.
    ///
    /// True for entry-unit kinds (imbib: an entry has to land IN something).
    /// False for file-unit kinds, whose row is the file itself and whose store
    /// rows, if any, are parented by their own kind's rules.
    public var requiresLibrary: Bool

    public var addTag: ([UUID], String) -> Void
    public var removeTag: ([UUID], String) -> Void

    /// The general initializer: any kind, its own fan-out.
    public init(
        produceRows: @escaping (
            _ path: String, _ libraryID: UUID?
        ) throws -> (imported: [UUID], existing: [UUID]),
        defaultLibraryID: @escaping () -> UUID? = { nil },
        requiresLibrary: Bool = false,
        addTag: @escaping ([UUID], String) -> Void = { _, _ in },
        removeTag: @escaping ([UUID], String) -> Void = { _, _ in }
    ) {
        self.produceRows = produceRows
        self.defaultLibraryID = defaultLibraryID
        self.requiresLibrary = requiresLibrary
        self.addTag = addTag
        self.removeTag = removeTag
    }

    /// The ENTRY-unit initializer (imbib): the file is read as bibliography
    /// text and handed to the app's importer whole, one blob per file, so the
    /// identifier dedup runs once per file rather than once per entry — which
    /// is what the manual drag does too.
    public init(
        importBibTeX: @escaping (String, UUID) -> (imported: [UUID], existing: [UUID]),
        defaultLibraryID: @escaping () -> UUID?,
        addTag: @escaping ([UUID], String) -> Void,
        removeTag: @escaping ([UUID], String) -> Void
    ) {
        self.init(
            produceRows: { path, libraryID in
                // `requiresLibrary` is true, so the coordinator has already
                // refused the pass if this is nil. Throwing rather than
                // force-unwrapping keeps a direct caller honest.
                guard let libraryID else { throw WatchedIngestError.noLibrary }
                return importBibTeX(try BibliographyFileText.bibtex(atPath: path), libraryID)
            },
            defaultLibraryID: defaultLibraryID,
            requiresLibrary: true,
            addTag: addTag,
            removeTag: removeTag)
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

    /// The fan-out that mints nothing (ADR-0023 W4, impart + implore v1).
    ///
    /// The file is discovered, hashed, given its `watched-file` row, re-hashed
    /// on every later pass and swept when it vanishes — and NO record of the
    /// app's own kind is created. This is not a stub: for a `file`-unit kind
    /// (D3) the file IS the record, and D4 already says the store row is an
    /// index entry rather than a copy. What it withholds is the SECOND
    /// fan-out — mbox → messages, `.vsz` → figure — which each app's W4 row in
    /// ADR-0023 decides on its own terms.
    public static var recordingOnly: WatchedFolderImportHooks {
        WatchedFolderImportHooks(produceRows: { _, _ in ([], []) })
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

    // MARK: The per-kind registry (ADR-0023 W4)

    /// The coordinators this process is running, one per `kind_scope`.
    ///
    /// `shared` stays imbib's, so every W2 call site is unchanged; a host that
    /// watches a DIFFERENT kind's folders asks for that kind's coordinator by
    /// scope. One per scope and not one per app, for the reason `shared`'s own
    /// comment gives: two `FolderWatchService` instances over the same bookmarks
    /// would run two engines per directory. Scopes are disjoint by construction
    /// — a watched folder's store id is derived from `(path, kind_scope)` — so
    /// two coordinators never contend for one row.
    @ObservationIgnored private static var registry: [String: WatchedFolderIngestCoordinator] = [
        WatchedFolderIngestCoordinator.kindScope: .shared
    ]

    /// The coordinator for one record kind, created on first ask.
    ///
    /// `hooks` is only consulted when the coordinator does not exist yet: the
    /// SECOND caller for a scope gets the one that is already running, which is
    /// the whole point of a registry. `nil` for a kind that declares no
    /// `FileDiscoveryCapability` — refusing is honest, since a coordinator with
    /// no filter can only ever produce an empty folder.
    public static func coordinator(
        forKindScope kindScope: String,
        hooks: @autoclosure () -> WatchedFolderImportHooks = .recordingOnly
    ) -> WatchedFolderIngestCoordinator? {
        if let existing = registry[kindScope] { return existing }
        guard BuiltinRecordKinds.fileDiscovery(forKindScope: kindScope) != nil else { return nil }
        let made = WatchedFolderIngestCoordinator(
            kindScope: kindScope,
            watcher: FolderWatchService(startupGate: Self.startupGate),
            hooks: hooks())
        registry[kindScope] = made
        return made
    }

    /// The coordinator already running for a scope, without creating one.
    ///
    /// What a SIDEBAR asks: a section that renders rows must not be the thing
    /// that starts a watcher, or the rows appear before the host has decided it
    /// wants them.
    public static func runningCoordinator(
        forKindScope kindScope: String
    ) -> WatchedFolderIngestCoordinator? {
        registry[kindScope]
    }

    /// Test seam: forget every registered coordinator except imbib's.
    static func resetRegistryForTesting() {
        registry = [WatchedFolderIngestCoordinator.kindScope: .shared]
    }

    // MARK: The nonisolated snapshot

    /// One watched folder's provenance tag path, resolvable **without the main
    /// actor**.
    ///
    /// This exists for `RecordRouteScope.init?(routeScope:)` — the protocol
    /// requirement that turns a sidebar selection into a kind's list scope, and
    /// which is nonisolated. A watched folder's route carries the folder's ID,
    /// but its list scope is the provenance TAG, whose leaf is the folder's
    /// display name; only the coordinator knows that mapping (the name is an
    /// identity, uniquified at add time). The coordinator is `@MainActor`, so a
    /// nonisolated caller cannot read `rows` at all.
    ///
    /// The honest fix is to PUBLISH the mapping rather than to hop (the
    /// initializer is synchronous), block (it runs during a view body), or
    /// `assumeIsolated` (it is called from wherever a route is decoded, and an
    /// assumption that is wrong once traps). `WatchedFolderRowState` is
    /// `Sendable` by construction — W1 made the row a snapshot value precisely
    /// so it could cross boundaries — and the published map is a tiny
    /// `[WatchedFolderID: String]` behind a lock, the same shape
    /// `RecordViewerRegistry` uses for the same reason.
    ///
    /// `nil` when no coordinator for that kind is running, or the folder is not
    /// one of its — which renders the "viewer unavailable" state rather than an
    /// empty list that reads as "this folder found nothing".
    public nonisolated static func provenanceTagPath(
        ofFolder id: WatchedFolderID, kindScope: String
    ) -> String? {
        publishedNamesLock.lock()
        defer { publishedNamesLock.unlock() }
        return publishedNames[kindScope]?[id]
            .map(WatchedFolderProvenanceTag.path(forFolderNamed:))
    }

    /// Display names by folder id, per kind scope. Written only by
    /// `publishNames()` below, on every change the sidebar is told about.
    private nonisolated static let publishedNamesLock = NSLock()
    nonisolated(unsafe) private static var publishedNames: [String: [WatchedFolderID: String]] = [:]

    /// Republish this coordinator's id → name map for nonisolated readers.
    /// Called from exactly the places that post `.watchedFoldersDidChange`, so
    /// the snapshot and the redraw can never disagree.
    private func publishNames() {
        var names = folderNames
        for row in watcher.rows where names[row.id] == nil {
            names[row.id] = row.displayName
        }
        let scope = kindScope
        Self.publishedNamesLock.lock()
        Self.publishedNames[scope] = names
        Self.publishedNamesLock.unlock()
    }

    // MARK: Dependencies

    /// The record kind this coordinator watches for — the store's `kind_scope`
    /// and the `FileDiscoveryFilter.id` in one, exactly as
    /// `FileDiscoveryFilter+RecordKind`'s header requires.
    public let kindScope: String

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

    /// PDFs this folder discovered that were NOT attached automatically —
    /// ambiguous candidates and unclaimed files (ADR-0023 W5).
    ///
    /// The review surface's whole content. `public private(set)` and
    /// `@Observable`, so the pane redraws when a scan finishes without asking
    /// anything.
    public internal(set) var attachmentOffers: [WatchedFolderID: [WatchedAttachmentOffer]] = [:]

    /// What the most recent attachment pass did, per folder. For the row's
    /// detail line, for logs, and for the tests that pin idempotency.
    public internal(set) var attachmentPasses: [WatchedFolderID: WatchedAttachmentPass] = [:]

    /// The attachment side of the wiring (ADR-0023 W5), or `nil` for a
    /// coordinator whose kind has no attachment unit.
    ///
    /// Separate from `hooks` because it is imbib's alone: no other watched kind
    /// declares `attachmentTypes`, so folding these four closures into the
    /// per-kind `WatchedFolderImportHooks` would have put three apps' worth of
    /// `nil` into a struct they all construct.
    @ObservationIgnored let attachmentHooks: WatchedAttachmentHooks?

    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    /// Store-side folder id (kernel-derived, from path+scope) per watcher id.
    @ObservationIgnored private var storeFolderIDs: [WatchedFolderID: String] = [:]
    /// Display name per watcher id — the provenance tag's leaf.
    @ObservationIgnored private var folderNames: [WatchedFolderID: String] = [:]
    /// Running per-scan totals `finishScan` cannot compute for itself.
    @ObservationIgnored private var pendingNew: [WatchedFolderID: Int] = [:]
    @ObservationIgnored private var pendingChanged: [WatchedFolderID: Int] = [:]

    public init(
        kindScope: String = WatchedFolderIngestCoordinator.kindScope,
        watcher: FolderWatchService = FolderWatchService(),
        store: WatchedFolderStoreAdapter = .shared,
        hooks: WatchedFolderImportHooks = .live,
        attachmentHooks: WatchedAttachmentHooks? = .live
    ) {
        self.kindScope = kindScope
        self.watcher = watcher
        self.store = store
        self.hooks = hooks
        // A kind that declares no attachment types gets none, whatever the
        // caller passed: the pass would find no candidates anyway, and refusing
        // here keeps `coordinator(forKindScope:)` from handing imbib's wiring
        // to impart's coordinator.
        let declaresAttachments =
            !(BuiltinRecordKinds.fileDiscovery(forKindScope: kindScope)?
                .attachmentExtensions.isEmpty ?? true)
        self.attachmentHooks = declaresAttachments ? attachmentHooks : nil
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
        publishNames()
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
        // W4: a process can run more than one coordinator (one per record kind)
        // and the bookmark store is ONE suite shared by all of them, so each
        // adopts only the bookmarks its own kind asked for. Without the
        // narrowing, impart's coordinator would claim imbib's `.bib` folder and
        // write it into the store a SECOND time under `kind_scope: message`.
        let restored = await watcher.restorePersistedFolders(
            filtersByID: FileDiscoveryFilter.builtinFiltersByID,
            limitedToFilterIDs: [kindScope])
        for row in restored {
            folderNames[row.id] = row.displayName
            guard let path = row.path else { continue }
            do {
                let outcome = try store.addFolder(
                    path: path,
                    kindScope: kindScope,
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
        // Derived from THIS coordinator's kind, never spelled: the filter id,
        // the persisted bookmark key and the store's `kind_scope` are the same
        // string by construction (FileDiscoveryFilter+RecordKind's "Identity").
        guard let filter = FileDiscoveryFilter.forKindScope(kindScope) else {
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
            publishNames()
            return existing
        }
        let name = uniqueDisplayName(for: standardized)
        let registration = try await watcher.persistAndAdd(
            url: url, filters: [filter], displayName: name)
        folderNames[registration.id] = registration.displayName

        let outcome = try store.addFolder(
            path: url.standardizedFileURL.path,
            kindScope: kindScope,
            displayName: registration.displayName,
            bookmarkBase64: nil,
            recursive: true)
        storeFolderIDs[registration.id] = outcome.folder.id

        await watcher.start(registration.id)
        publishNames()
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
        publishNames()
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

    /// The store id of one watcher row's folder, once it has one.
    ///
    /// The two ids are deliberately different things: the watcher's is a launch
    /// identity minted with the bookmark, the store's is derived by the kernel
    /// from `(path, kind_scope)`. A surface that needs the folder's FILES needs
    /// the second, and this is the only place the mapping lives.
    public func storeFolderID(for id: WatchedFolderID) -> String? { storeFolderIDs[id] }

    /// The files one folder has discovered, newest page first (ADR-0023 W4).
    ///
    /// The `file`-unit answer to `publicationSource(for:)`: where an entry-unit
    /// kind's folder resolves to a list of the RECORDS it produced, a file-unit
    /// kind's folder resolves to the FILES themselves, because for that unit
    /// the file is the record (D3) and the row is an index entry (D4).
    public func files(in id: WatchedFolderID, includingMissing: Bool = true) -> [WatchedFileRecord] {
        guard let storeID = storeFolderIDs[id] else { return [] }
        do {
            let page = try store.files(folderID: storeID, state: includingMissing ? nil : "present")
            return page.files
        } catch {
            note(error, for: id)
            return []
        }
    }

    /// One page of a folder's `watched-file` rows (ADR-0023 W5).
    ///
    /// `files(in:)` takes the store's DEFAULT page, which is right for a list a
    /// human scrolls and wrong for a matcher that must see every candidate —
    /// this is the seam `allFiles(in:)` pages through. It lives here rather
    /// than in the W5 extension only because `store` is private to this file.
    func attachmentFilesPage(
        folderID: String, limit: Int, offset: Int
    ) throws -> (files: [WatchedFileRecord], total: Int) {
        try store.files(folderID: folderID, state: nil, limit: limit, offset: offset)
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
        defer {
            publishNames()
            NotificationCenter.default.post(name: .watchedFoldersDidChange, object: nil)
        }
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

        // ADR-0023 W5: attachment-unit files are recorded (the `watched-file`
        // row above already happened — that is where the hash tracking and the
        // missing sweep come from) but they are NOT handed to the fan-out. A
        // PDF produces no publication; it JOINS one, at the end of the scan,
        // once every entry exists. Handing one to `produceRows` would put a
        // PDF's bytes through the BibTeX reader.
        let capability = BuiltinRecordKinds.fileDiscovery(forKindScope: kindScope)
        let owed = report.needingImport.filter {
            capability?.ingestUnit(forFileName: $0.path) != .attachment
        }
        guard !owed.isEmpty else {
            // The zero-write path. Nothing changed on disk, so nothing is
            // parsed, nothing is imported and no store mutation fires.
            Logger.files.infoCapture(
                "watched folder \(id.storageKey): \(report.unchanged) file(s) unchanged, "
                    + "nothing to import",
                category: "watched-folders")
            return
        }

        let library = hooks.defaultLibraryID()
        if hooks.requiresLibrary, library == nil {
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

    /// One file, all the way through: fan out → attribute → tag.
    private func importOne(
        _ file: WatchedDiscoveryReport.Outcome, into library: UUID?, folder id: WatchedFolderID
    ) async throws -> (produced: Int, orphaned: [UUID]) {
        // 1+2. The per-kind fan-out (D3). imbib reads the file as BibTeX and
        //      runs its REAL importer with the whole-library identifier dedup;
        //      a file-unit kind that mints nothing returns no ids and the steps
        //      below all no-op, leaving the watched-FILE row as the record.
        let (imported, existing) = try hooks.produceRows(file.path, library)
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

        // ADR-0023 W5, LAST and once per scan. The question "does this PDF
        // belong to exactly one entry?" is about the folder as a whole, so it
        // cannot be answered while entries are still arriving — and the
        // ambiguity margin, which is the thing standing between the user and a
        // silently wrong attachment, is only meaningful once every rival exists.
        // It runs after the sweep, so a vanished PDF is already `missing` and
        // the pass can report it rather than trying to attach it.
        let pass = matchAttachments(in: id)
        attachmentPasses[id] = pass
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
