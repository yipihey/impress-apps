//
//  ImprintIOSApp.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI
import ImprintCore
import ImpressTheme
import PublicationManagerCore

// MARK: - imprint iOS App

@main
struct ImprintIOSApp: App {

    // MARK: - Properties

    /// State for handling incoming URLs
    @State private var pendingURL: URL?

    // The appearance preference the (Stage 6) settings screen writes is applied
    // by `ImpressTheme.withAppearance()` on the scene root below (ADR-0022 X2).
    //
    // It used to be a local `@AppStorage("appearanceMode")` plus a
    // string→ColorScheme switch, written here because macOS's `AppearanceModifier`
    // lived in `Shared/ImprintApp.swift` behind `#if os(macOS)` and iOS could not
    // reach it. The shared modifier is un-gated, so both platforms now apply the
    // preference through one implementation instead of two that agreed by luck.
    // Same key, same three values, same result.

    init() {
        // Citation seam. WITHOUT THIS, `ManuscriptCompileController`
        // .assembleBibliography finds no `citationSearch` and returns nil, so
        // the virtual `bibliography.bib` is never written — every real
        // manuscript with `@citeKey` references fails to compile on iOS while
        // compiling fine on macOS. macOS installs its own provider from
        // `macOS/ManuscriptEditorInstall.swift`, and imbib-iOS installs this
        // very service; imprint-iOS installed nothing, because imprint's
        // startup wiring lives in files the iOS target does not compile
        // (`Shared/ImprintApp.swift` is `#if os(macOS)` end to end).
        //
        // The same seam backs the citation picker's search.
        ManuscriptEditorEnvironment.shared.citationSearch = ImbibCitationSearchService.shared

        Self.seedUITestDataIfNeeded()
    }

    // MARK: - UI test fixtures

    /// Seed a manuscript that cites a paper, and the paper it cites.
    ///
    /// `--ui-testing` puts BOTH adapters on in-memory stores, so a UI test that
    /// merely launches the app finds an empty library and every citation lookup
    /// misses — `LibraryShellUITests` skips half its assertions for exactly this
    /// reason. Seeding here (the pattern imbib-iOS already uses in
    /// `imbibApp.seedUITestDataIfNeeded`) makes a citation test hermetic instead
    /// of dependent on whatever is on the developer's simulator.
    ///
    /// Both stores must be seeded: `ImbibCitationSearchService` (which resolves
    /// cite keys) reads `RustStoreAdapter`'s handle, while the manuscript list
    /// and the citation picker read `ManuscriptStoreAdapter`'s — under
    /// `--ui-testing` those are two separate in-memory databases.
    @MainActor
    static func seedUITestDataIfNeeded() {
        // The SEED flag alone is enough, and that is deliberate (C1). It used to
        // require `--ui-testing` too, which pinned the fixture to the in-memory
        // lane — but two of the things this fixture now has to reach are only
        // ever on disk: `ImprintStoreAdapter` (throughline + citation-usage
        // rows, whose reader has no in-memory redirect) and the app-group store
        // imbib-iOS reads when it shows "Cited in N manuscript sections" for a
        // paper THIS app's manuscript cites. Passing both flags still means what
        // it always meant (hermetic, in-memory publications and manuscripts);
        // passing the seed flag alone writes the simulator's real app-group
        // store, which is exactly the shape impart-iOS's seed already has and
        // the only way a cross-APP fixture can exist at all.
        guard UITestingEnvironment.shouldSeedTestData else { return }

        let library = RustStoreAdapter.shared.listLibraries().first
            ?? RustStoreAdapter.shared.createLibrary(name: "Test Library")
        var seededPaperID: UUID?
        if let library {
            RustStoreAdapter.shared.setLibraryDefault(id: library.id)
            // Rust owns BibTeX parsing; never hand-build publication rows.
            seededPaperID = RustStoreAdapter.shared
                .importBibTeX(Self.seedBibTeX, libraryId: library.id).first
        }

        let adapter = ManuscriptStoreAdapter.shared

        // Idempotent. Under `--ui-testing` the manuscript store is in-memory and
        // starts empty every launch, but the seed flag ALONE writes the real
        // app-group store (see the guard above) — and re-seeding there on every
        // launch would pile up fixture manuscripts.
        let existing = adapter.allManuscripts(limit: 0)
        let manuscriptID = existing.first { $0.title == Self.fixtureTitle }?.id
            ?? (try? adapter.createManuscript(
                title: Self.fixtureTitle,
                format: .typst,
                body: Self.seedManuscriptBody,
                authors: ["Test Author"]))

        if let manuscriptID {
            seedThroughline(documentID: manuscriptID, title: Self.fixtureTitle)
            seedCitationUsage(documentID: manuscriptID, paperID: seededPaperID)
        }

        seedCollectionTreeAndDismissedManuscript(adapter: adapter, existing: existing)

        // TAGS. `RecordTriageActions.availableTagPaths` offers the paths
        // already in use, so an untagged store shows no Tags submenu at all —
        // the seed has to put some there or the submenu is untestable and its
        // absence is indistinguishable from the bug it used to have (a hard
        // `{ [] }` provider). Two paths, one nested, because the submenu
        // renders full paths and nesting is the case worth seeing.
        let tagged = adapter.allManuscripts(limit: 0).map(\.id)
        if !tagged.isEmpty {
            for path in Self.seedTagPaths {
                adapter.addTag(ids: tagged, tagPath: path)
            }
        }
    }

    /// Tag paths for the seeded store — see `seedUITestDataIfNeeded`.
    private static let seedTagPaths = ["methods/simulations", "reading/priority"]

    /// The fixture manuscript's title. Named once: three UI suites open it by
    /// this string.
    static let fixtureTitle = "Citation Long Press Fixture"

    // MARK: Collection tree + a dismissed manuscript (C1)

    /// The folder tree and the dismissed manuscript `LibraryShellUITests`
    /// asserts by NAME.
    ///
    /// That suite launches with no arguments on purpose — it is the one that
    /// runs against whatever is really on the device — and its collection-tree
    /// case therefore only passed on a machine whose personal store happened to
    /// contain a "Papers" folder with a "Reionization 2026" child and a
    /// dismissed "Early Draft…". On any other simulator it failed for an
    /// environmental reason while two of its cases skipped themselves
    /// ("no manuscripts in the shared store"). Seeding the tree makes those
    /// assertions provable rather than lucky: one launch with `--uitesting-seed`
    /// puts the documented fixture in the on-disk store the un-argumented suite
    /// then reads.
    @MainActor
    private static func seedCollectionTreeAndDismissedManuscript(
        adapter: ManuscriptStoreAdapter, existing: [ManuscriptModel]
    ) {
        let folders = adapter.listCollections()
        let papersID = folders.first { $0.name == "Papers" }?.id
            ?? (try? adapter.createCollection(name: "Papers"))
        if let papersID,
           !folders.contains(where: { $0.name == "Reionization 2026" }) {
            _ = try? adapter.createCollection(name: "Reionization 2026", parentID: papersID)
        }

        // The manuscript that must be visible ONLY in the Dismissed scope.
        let dismissedTitle = "Early Draft of the Reionization Review"
        guard !existing.contains(where: { $0.title == dismissedTitle }) else { return }
        if let id = try? adapter.createManuscript(
            title: dismissedTitle, format: .typst,
            body: "= Reionization\n\nAn early draft.", authors: ["Test Author"]) {
            // Through the triage verb, not by writing the status string: the
            // dismissed value is the DESCRIPTOR's and this file must not learn
            // a second copy of it.
            _ = adapter.dismiss(ids: [id])
        }
    }

    // MARK: Throughline fixture (C1)

    /// Seed a throughline for the fixture manuscript, ANCHORED and baselined,
    /// so the ported pane opens on real state instead of its create affordance.
    ///
    /// Two things about this are deliberate and worth knowing before changing it:
    ///
    ///  * **It writes through `ImprintStoreAdapter` directly, not through
    ///    `ThroughlineCoordinator.mirror`.** The coordinator disables ALL store
    ///    mirroring under `--ui-testing` (`mirroringDisabled`), because
    ///    `ManuscriptStoreAdapter` is in-memory there while `ImprintStoreAdapter`
    ///    always opens the on-disk workspace — so a mirror would write the real
    ///    store. The pane hydrates FROM `ImprintStoreAdapter.loadThroughline`
    ///    (`IOSManuscriptEditorHost`), which is that same on-disk lane, so the
    ///    fixture has to be written there or the pane cannot see it. On a
    ///    simulator that lane is the simulator's own app-group container; this is
    ///    a UI-test-only path, gated by the launch arguments above.
    ///  * **The anchor is set through the coordinator** (`setAnchor`), never by
    ///    hand-writing an anchor map. `setAnchor` baselines the ledger with the
    ///    section body's SHA-256, which is what makes the badge read `synced`;
    ///    a hand-built map would either duplicate the hashing rule or seed a
    ///    misleading `manuscript-ahead`.
    @MainActor
    private static func seedThroughline(documentID: UUID, title: String) {
        var doc = ImprintDocument(format: .typst)
        doc.id = documentID
        doc.title = title
        doc.source = Self.seedManuscriptBody

        // Scaffold (the same source create() writes), then the fixture's own
        // second beat so the pane shows a LIST rather than one paragraph.
        ThroughlineCoordinator.create(in: &doc)
        doc.throughlineSource = Self.seedThroughlineSource

        // Anchor the first beat to the manuscript's only section and baseline it.
        if let sectionKey = ThroughlineCoordinator.extractSections(of: doc).first?.key {
            ThroughlineCoordinator.setAnchor(
                in: &doc, label: "tl-overview", sectionKeys: [sectionKey])
        }

        let paragraphs = ThroughlineText.extractParagraphs(doc.throughlineSource ?? "")
        ImprintStoreAdapter.shared.storeThroughline(
            itemID: ThroughlineIdentity.itemID(documentID: documentID).uuidString,
            documentID: documentID.uuidString,
            title: title,
            source: doc.throughlineSource ?? "",
            anchorMapJSON: doc.throughlineAnchorsJSON ?? "",
            paragraphCount: paragraphs.count
        )
    }

    /// The fixture narrative: two labelled beats, one of which gets anchored.
    private static let seedThroughlineSource = """
    = Citation Long Press Fixture

    Special relativity follows from two postulates and nothing else. <tl-overview>

    The Lorentz transformation is a consequence, not an assumption. <tl-derivation>

    """

    // MARK: Cited-in fixture (C1)

    /// Record that the fixture manuscript CITES the seeded paper, through the
    /// real writer (`ImprintStoreAdapter.upsertCitationUsage`, bare
    /// `citation-usage` schema ref) rather than a second definition of the row.
    ///
    /// This is what makes imbib's `CitedInManuscriptsSection` renderable on a
    /// simulator: the section reads `CitationUsageReader`, whose rows only ever
    /// come from imprint. imprint's runtime writer is `CitationUsageTracker`,
    /// which scans stored manuscript SECTIONS on store events — a chain a
    /// launched-and-screenshotted app cannot be relied on to complete, and one
    /// that resolves `paper_id` through a resolver only the macOS target
    /// installs. Seeding the record itself keeps the fixture honest about what
    /// it is proving: the SECTION renders a real row, not that the tracker ran.
    @MainActor
    private static func seedCitationUsage(documentID: UUID, paperID: UUID?) {
        guard let paperID else { return }
        // A stable section id: the fixture's one heading, addressed the way
        // `ThroughlineIdentity` addresses sections, so re-seeding upserts the
        // same row instead of accumulating duplicates.
        let sectionID = ThroughlineIdentity.sectionItemID(
            documentID: documentID, sectionKey: "special-relativity")
        ImprintStoreAdapter.shared.upsertCitationUsage(
            sectionID: sectionID.uuidString,
            documentID: documentID.uuidString,
            citeKey: "Einstein1905",
            paperID: paperID.uuidString,
            firstCitedAt: Date(),
            lastSeenAt: Date()
        )
    }

    /// One resolvable key (`Einstein1905`) — long-pressing it must show the
    /// paper — and one that is deliberately absent (`Missing2099`), so the
    /// unresolved-citation copy is testable too.
    private static let seedBibTeX = """
    @article{Einstein1905,
      author = {Albert Einstein},
      title = {Zur Elektrodynamik bewegter Körper},
      journal = {Annalen der Physik},
      volume = {322},
      pages = {891--921},
      year = {1905},
      doi = {10.1002/andp.19053221004},
      abstract = {That light is always propagated in empty space with a definite
      velocity c which is independent of the state of motion of the emitting body.}
    }
    """

    /// The citations lead each line on purpose: a UI test long-presses at a
    /// point offset from the text view's origin, and a token at a predictable
    /// column is the difference between testing the gesture and testing the
    /// text layout engine.
    private static let seedManuscriptBody = """
    @Einstein1905 introduces the two postulates of special relativity.

    @Missing2099 is a cite key that is deliberately absent from the library.

    = Special Relativity
    """

    // MARK: - Body

    var body: some Scene {
        // Store-backed manuscripts app (GUI-meld Phase 8): a manuscript
        // library fronts the editor rather than the system document browser,
        // so imprint-iOS reads/writes the same unified store as imbib and
        // macOS imprint. URL handling + outline-snapshot upkeep live inside
        // the library view.
        WindowGroup {
            // `WindowGroup` does not populate `\.undoManager` on iOS the way
            // `DocumentGroup` did — see IOSUndoSupport.swift. This restores
            // both the environment value and the responder-chain manager that
            // shake-to-undo needs.
            IOSManuscriptLibraryView()
                .undoEnabled()
                .withAppearance()
        }
    }
}

// MARK: - Configuration

extension ImprintIOSApp {
    /// Configure app-wide keyboard shortcuts
    /// Note: Keyboard shortcuts are handled by SwiftUI's .keyboardShortcut() modifier
    static func configureKeyboardShortcuts() {
        // No additional configuration needed - shortcuts are declarative in SwiftUI
    }
}
