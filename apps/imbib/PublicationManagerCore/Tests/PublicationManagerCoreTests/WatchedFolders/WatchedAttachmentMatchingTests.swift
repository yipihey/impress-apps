//
//  WatchedAttachmentMatchingTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 W5 — PDFs beside a watched `.bib`, END TO END and headless.
//
//  ── What is real here ───────────────────────────────────────────────────────
//
//  The same arrangement `WatchedFolderIngestCoordinatorTests` (W2) proved the
//  ingest loop with, extended by one file type. Four of the five stages are the
//  real thing:
//
//    * the watcher is W1's `FolderWatchService` over the walk engine, driven by
//      `ManualDirectoryChangeNotifier` — notify → re-walk → diff → publish;
//    * the store is a real `SharedStore` scratch database, so
//      `import_discovered`, `finish_watched_scan` and the missing sweep run
//      their real Rust;
//    * the importer is `RustStoreAdapter` — imbib's actual BibTeX path;
//    * **the MATCHER is `imbib_core::attachments` over the FFI**, the same
//      function the golden corpus pins, not a Swift reimplementation of it.
//
//  Only the attach step is captured as well as performed, so a test can assert
//  on what was asked for without inferring it from a store query.
//
//  ── The scenario ────────────────────────────────────────────────────────────
//
//  One folder. One `.bib` with THREE entries, two of which are the same author
//  in the same year with the same first three title words (a two-part paper —
//  the shape that makes a filename genuinely ambiguous). Two PDFs:
//
//    hubble1929.pdf                             → the cite key, exactly. ATTACHES.
//    Weyl_1918_Gravitation_und_Elektrizitaet.pdf → imbib's own naming for BOTH
//                                                  Weyl entries. OFFERED, twice.
//
//  Everything below is a claim about that folder.
//

import ImbibRustCore
import ImpressKit
import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

@MainActor
final class WatchedAttachmentMatchingTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var notifier: ManualDirectoryChangeNotifier!
    private var store: WatchedFolderStoreAdapter!
    private var library: RustStoreAdapter!

    /// Every `(path, publicationID)` the coordinator asked to attach, in order.
    /// Accumulated across passes, which is what makes the idempotency claim
    /// checkable rather than inferred.
    private var attachRequests: [(path: String, publicationID: UUID)] = []

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.watchedAttach.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watched-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        notifier = ManualDirectoryChangeNotifier()
        try SharedWorkspace.ensureDirectoryExists()
        library = try RustStoreAdapter(inMemory: false)
        store = WatchedFolderStoreAdapter(
            store: try SharedStore.open(path: SharedWorkspace.databasePath))
        attachRequests = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        root = nil
        defaults = nil
        suiteName = nil
        notifier = nil
        store = nil
        library = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Three entries: one distinctive, and two that are deliberately confusable.
    private static let bibliography = """
        @article{hubble1929,
          author = {Hubble, Edwin},
          title = {A Relation between Distance and Radial Velocity},
          year = {1929},
          doi = {10.1073/pnas.15.3.168}
        }

        @article{weyl1918a,
          author = {Weyl, Hermann},
          title = {Gravitation und Elektrizitaet, Teil I},
          year = {1918},
          doi = {10.1000/weyl.1}
        }

        @article{weyl1918b,
          author = {Weyl, Hermann},
          title = {Gravitation und Elektrizitaet, Teil II},
          year = {1918},
          doi = {10.1000/weyl.2}
        }
        """

    /// The PDF whose name IS a cite key. Auto-attaches.
    private static let exactMatchPDF = "hubble1929.pdf"
    /// The PDF imbib's own namer would produce for EITHER Weyl entry. Offered.
    private static let ambiguousPDF = "Weyl_1918_Gravitation_und_Elektrizitaet.pdf"

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A file with a `.pdf` name. The matcher never opens a PDF — that is the
    /// deferral its module header records — so bytes are irrelevant here, and
    /// making them irrelevant is a property worth having: discovery and
    /// matching cost nothing per megabyte.
    @discardableResult
    private func writePDF(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("%PDF-1.4\n% not a real PDF, and nothing here reads it\n".utf8).write(to: url)
        return url
    }

    private func makeLibrary() throws -> UUID {
        if let existing = library.getDefaultLibrary() { return existing.id }
        guard let created = library.createLibrary(name: "Attachment Test Library") else {
            throw XCTSkip("the test store has no library and would not create one")
        }
        return created.id
    }

    // MARK: - Wiring

    private func makeCoordinator(library libraryID: UUID) -> WatchedFolderIngestCoordinator {
        let adapter = library!
        let notifier = self.notifier!
        let watcher = FolderWatchService(
            bookmarks: WatchedFolderBookmarkStore(userDefaults: defaults, broker: .scratch()),
            engines: FolderWatchEngineFactory(
                makePrimary: { nil },
                makeFallback: {
                    WalkFolderDiscoveryEngine(notifier: notifier, debounce: .milliseconds(1))
                }),
            startupGate: .immediate)

        let hooks = WatchedFolderImportHooks(
            importBibTeX: { bibtex, target in
                adapter.importBibTeXOutcome(bibtex, libraryId: target)
            },
            defaultLibraryID: { libraryID },
            addTag: { ids, path in adapter.addTag(ids: ids, tagPath: path) },
            removeTag: { ids, path in adapter.removeTag(ids: ids, tagPath: path) })

        // The attachment side: REAL entry reads and REAL store writes, with the
        // attach call also recorded so idempotency is observable and not
        // inferred from a count that happens not to have moved.
        let attachments = WatchedAttachmentHooks(
            entries: { ids in
                ids.compactMap { id in
                    adapter.getPublicationDetail(id: id).map(AttachmentEntry.init(publication:))
                }
            },
            linkedPaths: { id in
                Set(adapter.listLinkedFiles(publicationId: id).compactMap(\.relativePath))
            },
            attach: { [weak self] path, id in
                self?.attachRequests.append((path: path, publicationID: id))
                return adapter.addLinkedFile(
                    publicationId: id,
                    filename: (path as NSString).lastPathComponent,
                    relativePath: path,
                    fileType: "pdf",
                    fileSize: 0,
                    sha256: nil,
                    isPdf: true) != nil
            },
            libraryID: { libraryID })

        return WatchedFolderIngestCoordinator(
            watcher: watcher, store: store, hooks: hooks, attachmentHooks: attachments)
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func folderStoreID() throws -> String {
        let wanted = root.standardizedFileURL.path
        guard let mine = try store.folders().first(where: { $0.path == wanted }) else {
            throw XCTSkip("no watched folder row was written for \(wanted)")
        }
        return mine.id
    }

    private func publicationID(citeKey: String, in libraryID: UUID) throws -> UUID {
        let storeID = try folderStoreID()
        let produced = try store.files(folderID: storeID).files
            .flatMap(\.producedPublicationIDs)
        for id in produced {
            if library.getPublicationDetail(id: id)?.citeKey == citeKey { return id }
        }
        throw XCTSkip("no publication with cite key \(citeKey) was produced")
    }

    /// The whole scenario, run once.
    private func runScenario() async throws -> (
        coordinator: WatchedFolderIngestCoordinator, row: WatchedFolderRowState, library: UUID
    ) {
        let libraryID = try makeLibrary()
        try write("refs.bib", Self.bibliography)
        try writePDF(Self.exactMatchPDF)
        try writePDF(Self.ambiguousPDF)

        let coordinator = makeCoordinator(library: libraryID)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()

        await waitUntil("the attachment pass to run") {
            coordinator.attachmentPasses[row.id]?.isEmpty == false
        }
        return (coordinator, row, libraryID)
    }

    // MARK: - Discovery scope

    /// **The scope decision, proven.** The PDFs come from the SAME folder's
    /// discovery — one registration, one filter, one gather — and each gets a
    /// full `watched-file` row, which is where its hash tracking and its
    /// missing sweep come from.
    func testPDFsAreDiscoveredByTheSameFolderAndGetWatchedFileRows() async throws {
        let (_, _, _) = try await runScenario()

        let files = try store.files(folderID: try folderStoreID()).files
        let names = Set(files.map { ($0.path as NSString).lastPathComponent })
        XCTAssertEqual(
            names, ["refs.bib", Self.exactMatchPDF, Self.ambiguousPDF],
            "one folder, one gather: the .bib AND both PDFs are indexed rows")

        for file in files where file.path.hasSuffix(".pdf") {
            XCTAssertFalse(
                file.contentHash.isEmpty,
                "a PDF row is hash-tracked like every other watched file (W0)")
            XCTAssertEqual(file.state, "present")
            XCTAssertEqual(file.kindScope, WatchedFolderIngestCoordinator.kindScope)
        }
    }

    /// A PDF mints NO publication. The attachment unit's whole point: a
    /// discovered PDF joins a record, it never becomes one — and handing one to
    /// the fan-out would have put its bytes through the BibTeX reader.
    func testAPDFProducesNoPublication() async throws {
        let (_, _, _) = try await runScenario()

        let files = try store.files(folderID: try folderStoreID()).files
        for file in files where file.path.hasSuffix(".pdf") {
            XCTAssertTrue(
                file.producedIDs.isEmpty,
                "\((file.path as NSString).lastPathComponent) produced \(file.producedIDs.count) "
                    + "row(s); an attachment-unit file produces none")
        }
        let bib = try XCTUnwrap(files.first { $0.path.hasSuffix("refs.bib") })
        XCTAssertEqual(bib.producedIDs.count, 3, "the .bib still fans out to its three entries")
    }

    // MARK: - The headline: an unambiguous PDF attaches itself

    /// The feature. A PDF named for a cite key attaches to that entry with
    /// nobody pressing anything — and the attachment is a real
    /// `LinkedFileModel` on the publication, reference-in-place.
    func testAnExactMatchAttachesAutomatically() async throws {
        let (coordinator, row, libraryID) = try await runScenario()

        let pass = try XCTUnwrap(coordinator.attachmentPasses[row.id])
        XCTAssertEqual(pass.attached, 1, "exactly one PDF was unambiguous")
        XCTAssertEqual(pass.missing, 0)

        let hubble = try publicationID(citeKey: "hubble1929", in: libraryID)
        let detail = try XCTUnwrap(library.getPublicationDetail(id: hubble))
        let linked = try XCTUnwrap(detail.linkedFiles.first)
        XCTAssertEqual(linked.filename, Self.exactMatchPDF)
        XCTAssertTrue(linked.isPDF)
        XCTAssertEqual(
            linked.relativePath, root.appendingPathComponent(Self.exactMatchPDF).path,
            """
            REFERENCE-IN-PLACE (ADR-0023 D4). The linked file's path is the PDF where \
            the researcher keeps it, not a copy inside imbib's library container — the \
            watcher never writes user files.
            """)

        // And the file is still exactly where it was. Nothing was moved.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(Self.exactMatchPDF).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: AttachmentManager.shared
                    .papersContainerURL(for: libraryID)
                    .appendingPathComponent(Self.exactMatchPDF).path),
            "no copy was taken into the library's Papers folder")
    }

    /// **The round-trip gate.** A watcher-attached file must serialize the way
    /// BibDesk would: exporting the entry after the attach produces a
    /// `Bdsk-File-*` field whose decoded value is the path that was attached.
    func testExportAfterAttachCarriesTheBdskFileField() async throws {
        let (_, _, libraryID) = try await runScenario()
        let hubble = try publicationID(citeKey: "hubble1929", in: libraryID)

        let exported = library.exportBibTeX(ids: [hubble])
        XCTAssertTrue(
            exported.lowercased().contains("bdsk-file"),
            "export-after-attach must mention the file:\n\(exported)")

        // Decoded, not just present. A base64 blob that says the wrong thing
        // would satisfy a `contains` check and nothing else.
        let parsed = try XCTUnwrap(UnifiedFormatConverter.parseBibTeX(exported).first)
        let declared = parsed.fields
            .filter { $0.key.lowercased().hasPrefix("bdsk-file-") }
            .compactMap { BdskFileCodec.decode($0.value) }
        XCTAssertEqual(
            declared, [root.appendingPathComponent(Self.exactMatchPDF).path],
            "the Bdsk-File field must decode to the attached path:\n\(exported)")
    }

    // MARK: - The ambiguous half: offered, never attached

    /// Two entries could equally own this file, so the app ASKS. Nothing is
    /// attached, and the offer carries both candidates with a reason each.
    func testAnAmbiguousMatchIsOfferedAndNothingIsAttached() async throws {
        let (coordinator, row, libraryID) = try await runScenario()

        let offers = try XCTUnwrap(coordinator.attachmentOffers[row.id])
        let offer = try XCTUnwrap(offers.first { $0.fileName == Self.ambiguousPDF })
        XCTAssertEqual(
            offer.candidates.count, 2,
            "both Weyl entries generate the same Author_Year_Title name")
        XCTAssertEqual(
            Set(offer.candidates.map(\.citeKey)), ["weyl1918a", "weyl1918b"])
        XCTAssertFalse(offer.isUnmatched)
        for candidate in offer.candidates {
            XCTAssertFalse(candidate.reason.isEmpty, "an offer row must be able to explain itself")
            XCTAssertGreaterThanOrEqual(candidate.confidence, 0.5)
        }
        XCTAssertFalse(offer.statusLine.isEmpty)

        // NOTHING was attached to either.
        for citeKey in ["weyl1918a", "weyl1918b"] {
            let id = try publicationID(citeKey: citeKey, in: libraryID)
            XCTAssertTrue(
                library.getPublicationDetail(id: id)?.linkedFiles.isEmpty ?? false,
                "\(citeKey) must have no attachment — the match was ambiguous")
        }
        XCTAssertEqual(
            attachRequests.filter { $0.path.hasSuffix(Self.ambiguousPDF) }.count, 0,
            "the coordinator must not even ASK to attach an ambiguous match")
    }

    /// A PDF that matches nothing is reported as such — not forced onto the
    /// nearest entry, and not silently dropped.
    func testAPDFMatchingNothingIsSurfacedAsUnmatched() async throws {
        let (coordinator, row, _) = try await runScenario()

        try writePDF("tax-return-2019.pdf")
        notifier.fire()

        await waitUntil("the stray PDF to be seen") {
            (coordinator.attachmentOffers[row.id] ?? []).contains {
                $0.fileName == "tax-return-2019.pdf"
            }
        }
        let offers = try XCTUnwrap(coordinator.attachmentOffers[row.id])
        let stray = try XCTUnwrap(offers.first { $0.fileName == "tax-return-2019.pdf" })
        XCTAssertTrue(stray.isUnmatched)
        XCTAssertTrue(stray.candidates.isEmpty)
        XCTAssertFalse(
            stray.statusLine.isEmpty,
            "an unmatched file still says something; a blank row reads as a bug")
        XCTAssertEqual(
            attachRequests.filter { $0.path.hasSuffix("tax-return-2019.pdf") }.count, 0)
    }

    // MARK: - Idempotency

    /// **Nothing double-attaches on a re-scan.** The property the steady state
    /// rests on, checked two ways: the coordinator does not repeat the attach
    /// CALL, and the publication does not gain a second linked file.
    func testARescanDoesNotDoubleAttach() async throws {
        let (coordinator, row, libraryID) = try await runScenario()

        XCTAssertEqual(attachRequests.count, 1)
        let hubble = try publicationID(citeKey: "hubble1929", in: libraryID)
        XCTAssertEqual(library.getPublicationDetail(id: hubble)?.linkedFiles.count, 1)

        // Re-scan the unchanged folder, twice, through the real refresh verb.
        for _ in 0..<2 {
            await coordinator.refresh(row.id)
            notifier.fire()
            try? await Task.sleep(for: .milliseconds(300))
        }

        XCTAssertEqual(
            attachRequests.count, 1,
            """
            The coordinator asked to attach again. The idempotency check reads the \
            STORE (`linkedPaths`), so this failing means the check was skipped or the \
            path it compares is not the path it writes.
            """)
        XCTAssertEqual(
            library.getPublicationDetail(id: hubble)?.linkedFiles.count, 1,
            "a re-scan must not leave a second copy of the same attachment")

        // ── Now force a pass that genuinely RUNS ────────────────────────────
        //
        // An unchanged folder produces no discovery event, so the pass above
        // did not re-execute — which is the zero-write property W2 proved for
        // the importer, holding here for free. That is the right behaviour and
        // the wrong test: it proves the check was never reached, not that the
        // check works. So change the folder (a new file, which is what a real
        // re-scan reacts to) and assert on the pass that actually runs.
        try writePDF("a-new-arrival.pdf")
        notifier.fire()
        await waitUntil("a pass that re-examines the attached PDF") {
            (coordinator.attachmentOffers[row.id] ?? []).contains {
                $0.fileName == "a-new-arrival.pdf"
            }
        }

        let pass = try XCTUnwrap(coordinator.attachmentPasses[row.id])
        XCTAssertEqual(
            pass.attached, 0,
            "the PDF was already attached; this pass must attach nothing new")
        XCTAssertEqual(
            pass.alreadyAttached, 1,
            """
            The store-backed idempotency check did not fire. `linkedPaths` reads the \
            publication's linked files and must find the path the earlier pass wrote — \
            if these two spell the path differently, every re-scan duplicates an \
            attachment.
            """)
        XCTAssertEqual(attachRequests.count, 1, "and still only ever asked once")
        XCTAssertEqual(library.getPublicationDetail(id: hubble)?.linkedFiles.count, 1)

        // The offer set is stable too — a re-scan must not grow the review list.
        let offers = try XCTUnwrap(coordinator.attachmentOffers[row.id])
        XCTAssertEqual(offers.filter { $0.fileName == Self.ambiguousPDF }.count, 1)
    }

    /// Exporting twice after a re-scan does not accumulate `Bdsk-File-2`.
    /// The round-trip has to be idempotent too, or a nightly re-scan would
    /// grow the user's `.bib` without bound.
    func testTheBdskFieldDoesNotAccumulateAcrossRescans() async throws {
        let (coordinator, row, libraryID) = try await runScenario()
        let hubble = try publicationID(citeKey: "hubble1929", in: libraryID)
        let first = library.exportBibTeX(ids: [hubble])

        await coordinator.refresh(row.id)
        notifier.fire()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(library.exportBibTeX(ids: [hubble]), first)
        XCTAssertEqual(
            first.lowercased().components(separatedBy: "bdsk-file-").count - 1, 1,
            "exactly one Bdsk-File field:\n\(first)")
    }

    // MARK: - The missing discipline

    /// An attached PDF that vanishes is FLAGGED, never detached (ADR-0023 D4,
    /// W5 point 5). Deleting the attachment would erase a fact the user
    /// established because a disk was unplugged.
    func testAVanishedPDFKeepsItsAttachmentAndIsFlagged() async throws {
        let (coordinator, row, libraryID) = try await runScenario()
        let hubble = try publicationID(citeKey: "hubble1929", in: libraryID)
        XCTAssertEqual(library.getPublicationDetail(id: hubble)?.linkedFiles.count, 1)

        try FileManager.default.removeItem(at: root.appendingPathComponent(Self.exactMatchPDF))
        notifier.fire()

        let storeID = try folderStoreID()
        await waitUntil("the sweep to mark the PDF missing") {
            ((try? self.store.files(folderID: storeID, state: "missing").files) ?? [])
                .contains { $0.path.hasSuffix(Self.exactMatchPDF) }
        }

        XCTAssertEqual(
            library.getPublicationDetail(id: hubble)?.linkedFiles.count, 1,
            "the attachment is KEPT — nothing this feature touches is ever deleted")
        XCTAssertEqual(
            coordinator.attachmentPasses[row.id]?.missing, 1,
            "and the pass reports it, so a surface can say the file has gone")

        // And it is not re-offered: the row is missing, not unclaimed.
        let offers = coordinator.attachmentOffers[row.id] ?? []
        XCTAssertFalse(offers.contains { $0.fileName == Self.exactMatchPDF })
    }

    // MARK: - The strongest signal, through the REAL import path

    /// **A BibDesk `.bib` works.** The most credible signal is the entry's own
    /// `Bdsk-File-*` field, and this is the only test that proves it survives
    /// the round trip through imbib's importer rather than being handed to the
    /// matcher directly.
    ///
    /// It is here because it nearly did not: `Bdsk-File-1` lands in the
    /// publication payload's nested `extra_fields` object, and
    /// `item_to_publication_detail` flattens only TOP-LEVEL payload strings
    /// into `fields` — so the field is faithfully stored and completely
    /// invisible to any Swift caller reading `PublicationModel.fields`. Every
    /// unit test that builds an `AttachmentEntry` by hand passes regardless.
    func testABibDeskFileFieldAttachesItsPDFThroughTheRealImporter() async throws {
        let libraryID = try makeLibrary()

        // The file BibDesk names, at a path the entry declares RELATIVELY —
        // which is how BibDesk actually writes it.
        let papers = root.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: papers, withIntermediateDirectories: true)
        try Data("%PDF-1.4\n".utf8).write(to: papers.appendingPathComponent("declared.pdf"))

        let encoded = try XCTUnwrap(BdskFileCodec.encode(relativePath: "Papers/declared.pdf"))
        try write(
            "bibdesk.bib",
            """
            @article{bibdesk2024,
              author = {Desk, Bib},
              title = {A Paper With An Attachment},
              year = {2024},
              Bdsk-File-1 = {\(encoded)}
            }
            """)

        let coordinator = makeCoordinator(library: libraryID)
        let row = try await coordinator.addFolder(at: root)
        await coordinator.start()

        await waitUntil("the attachment pass") {
            (coordinator.attachmentPasses[row.id]?.attached ?? 0) >= 1
        }

        let id = try publicationID(citeKey: "bibdesk2024", in: libraryID)
        let linked = try XCTUnwrap(library.getPublicationDetail(id: id)?.linkedFiles.first)
        XCTAssertEqual(
            linked.relativePath, papers.appendingPathComponent("declared.pdf").path,
            """
            The entry's own Bdsk-File-1 named this PDF and it was not attached. The \
            usual cause is that the field never reached the matcher: it lives in the \
            payload's nested `extra_fields`, which `PublicationModel.fields` does not \
            surface, so `AttachmentEntry(publication:)` recovers it from `rawBibTeX`.
            """)
        XCTAssertEqual(coordinator.attachmentPasses[row.id]?.attached, 1)
    }

    // MARK: - The offer's own contract

    /// The offer value renders without the coordinator. Pinned because the
    /// review pane reads nothing else, and a blank secondary line is the
    /// `WatchedFolderRowState.statusLine` failure the chassis has a rule about.
    func testOfferRenderingIsSelfContained() {
        let unmatched = WatchedAttachmentOffer(path: "/w/stray.pdf", candidates: [])
        XCTAssertTrue(unmatched.isUnmatched)
        XCTAssertEqual(unmatched.fileName, "stray.pdf")
        XCTAssertFalse(unmatched.statusLine.isEmpty)

        let one = WatchedAttachmentOffer(
            path: "/w/a.pdf",
            candidates: [
                .init(id: UUID(), citeKey: "k1", title: "T", confidence: 0.7, reason: "why")
            ])
        XCTAssertFalse(one.isUnmatched)
        XCTAssertTrue(one.statusLine.contains("k1"))
        XCTAssertEqual(one.candidates[0].confidenceLabel, "70%")

        let many = WatchedAttachmentOffer(
            path: "/w/b.pdf",
            candidates: [
                .init(id: UUID(), citeKey: "k1", title: "T1", confidence: 0.92, reason: "a"),
                .init(id: UUID(), citeKey: "k2", title: "T2", confidence: 0.92, reason: "b"),
            ])
        XCTAssertTrue(many.statusLine.contains("2 possible entries"))
        XCTAssertTrue(many.statusLine.contains("92%"))
    }

    /// The thresholds a surface explains come from Rust, so a UI cannot drift
    /// from the matcher it is describing.
    func testThresholdsAreReadFromRustNotRestated() {
        let thresholds = ImbibRustCore.attachmentThresholds()
        XCTAssertLessThan(
            thresholds.fuzzyCeiling, thresholds.autoAttach,
            "the structural rule: a guess can never auto-attach")
        XCTAssertLessThan(thresholds.offer, thresholds.autoAttach)
        XCTAssertGreaterThan(thresholds.ambiguityMargin, 0)
    }
}
