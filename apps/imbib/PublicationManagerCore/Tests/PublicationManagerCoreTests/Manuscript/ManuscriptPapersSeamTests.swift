//
//  ManuscriptPapersSeamTests.swift
//  PublicationManagerCoreTests
//
//  The seam that replaced imprint's Papers panel: imbib's papers window asks,
//  the manuscript's editor writes. These pin the parts that live in Swift —
//  the citation TEXT per format, the registry that answers "did it land?", the
//  cite-key scan the sync is given, and the URL the editor opens imbib with.
//  (The collection itself is Rust's: see `manuscript_reading_list`'s
//  `sync_folds_cited_papers_into_the_collection_and_is_idempotent`.)
//

#if os(macOS)
import XCTest
@testable import PublicationManagerCore

@MainActor
final class ManuscriptPapersSeamTests: XCTestCase {

    private let manuscript = UUID()
    private let other = UUID()

    override func tearDown() {
        ManuscriptCitationInserter.shared.unregister(manuscriptID: manuscript)
        ManuscriptCitationInserter.shared.unregister(manuscriptID: other)
        super.tearDown()
    }

    // MARK: - Citation text

    func testCitationTextFollowsTheDocumentsSyntax() {
        let one = ["smith2024"]
        let two = ["smith2024", "jones2020"]
        XCTAssertEqual(ManuscriptCitationInserter.citationText(for: one, format: .typst), "@smith2024")
        XCTAssertEqual(
            ManuscriptCitationInserter.citationText(for: two, format: .typst),
            "@smith2024 @jones2020")
        XCTAssertEqual(
            ManuscriptCitationInserter.citationText(for: two, format: .latex),
            "\\cite{smith2024,jones2020}")
        XCTAssertEqual(
            ManuscriptCitationInserter.citationText(for: two, format: .markdown),
            "[@smith2024; @jones2020]")
        XCTAssertEqual(
            ManuscriptCitationInserter.citationText(for: one, format: .markdown), "@smith2024")
        XCTAssertEqual(ManuscriptCitationInserter.citationText(for: [], format: .typst), "")
    }

    // MARK: - The registry

    /// Register a fake editor; returns what it was asked to insert.
    private func registerFakeEditor(
        _ id: UUID,
        format: DocumentFormat = .typst,
        outcome: @escaping ([String]) -> CitationInsertOutcome = { keys in
            .inserted(keys.joined(separator: " "))
        }
    ) -> (keys: () -> [[String]], paletteOpened: () -> Int) {
        final class Box {
            var asked: [[String]] = []
            var palette = 0
        }
        let box = Box()
        ManuscriptCitationInserter.shared.register(
            manuscriptID: id,
            format: { format },
            insert: { keys in
                box.asked.append(keys)
                return outcome(keys)
            },
            openPalette: {
                box.palette += 1
                return true
            })
        return ({ box.asked }, { box.palette })
    }

    func testAnInsertReachesTheEditorRegisteredForThatManuscript() {
        let editor = registerFakeEditor(manuscript)
        let outcome = ManuscriptCitationInserter.shared.insert(
            ["smith2024", " jones2020 "], into: manuscript)
        XCTAssertTrue(outcome.didInsert, outcome.message)
        XCTAssertEqual(editor.keys(), [["smith2024", "jones2020"]], "trimmed, in order")
        XCTAssertEqual(ManuscriptCitationInserter.shared.format(of: manuscript), .typst)
    }

    func testWithNoEditorTheCallerIsTold() {
        let outcome = ManuscriptCitationInserter.shared.insert(["smith2024"], into: manuscript)
        XCTAssertEqual(outcome, .noEditor)
        XCTAssertFalse(outcome.didInsert)
        XCTAssertTrue(outcome.message.contains("no open editor"), outcome.message)
        XCTAssertFalse(ManuscriptCitationInserter.shared.canInsert(into: manuscript))
    }

    func testAClosedEditorStopsBeingACitationTarget() {
        _ = registerFakeEditor(manuscript)
        XCTAssertTrue(ManuscriptCitationInserter.shared.canInsert(into: manuscript))
        ManuscriptCitationInserter.shared.unregister(manuscriptID: manuscript)
        XCTAssertEqual(
            ManuscriptCitationInserter.shared.insert(["smith2024"], into: manuscript), .noEditor)
        XCTAssertNil(ManuscriptCitationInserter.shared.focusedManuscriptID)
    }

    func testAnUntargetedInsertGoesToTheMostRecentlyFocusedEditor() {
        let first = registerFakeEditor(manuscript)
        let second = registerFakeEditor(other, format: .latex)
        // Registering focuses; then the author clicks back into the first.
        ManuscriptCitationInserter.shared.noteFocused(manuscript)
        XCTAssertEqual(ManuscriptCitationInserter.shared.focusedManuscriptID, manuscript)

        ManuscriptCitationInserter.shared.insert(["smith2024"])
        XCTAssertEqual(first.keys(), [["smith2024"]])
        XCTAssertTrue(second.keys().isEmpty)
    }

    func testBlankKeysAndARefusalAreDistinctFromSuccess() {
        _ = registerFakeEditor(manuscript, outcome: { _ in .refused("read-only here") })
        XCTAssertEqual(
            ManuscriptCitationInserter.shared.insert(["  ", ""], into: manuscript),
            .nothingToInsert)
        let refused = ManuscriptCitationInserter.shared.insert(["smith2024"], into: manuscript)
        XCTAssertEqual(refused, .refused("read-only here"))
        XCTAssertEqual(refused.message, "read-only here")
    }

    func testThePaletteCanBeRaisedFromOutsideTheEditor() {
        let editor = registerFakeEditor(manuscript)
        XCTAssertTrue(ManuscriptCitationInserter.shared.openPalette(for: manuscript))
        XCTAssertEqual(editor.paletteOpened(), 1)
        ManuscriptCitationInserter.shared.unregister(manuscriptID: manuscript)
        XCTAssertFalse(
            ManuscriptCitationInserter.shared.openPalette(for: manuscript),
            "no editor, no palette — and the menu item must not claim otherwise")
    }

    // MARK: - Where the citation lands in the text

    /// A citation must stand apart from the text on BOTH sides. Only the
    /// leading side was handled at first, and a Typst `@key` runs until a
    /// non-word character — so citing into a document whose caret sat at the
    /// start produced `@a@b` and `@key= Heading`: one mangled label, reported
    /// by Typst as "label `<a@b@…>` does not exist", naming a key nobody typed.
    private func spaced(_ citation: String, into text: String, at location: Int,
                        format: DocumentFormat = .typst) -> String {
        TypstEditorRepresentable.Coordinator.spaced(
            citation, insertedInto: text as NSString, at: location, format: format)
    }

    func testACitationNeverRunsIntoTheTextAfterIt() {
        // Before a heading, which is what an untouched caret at 0 hits.
        XCTAssertEqual(spaced("@a", into: "= Title\n", at: 0), "@a ")
        // Before another citation.
        XCTAssertEqual(spaced("@a", into: "@b rest", at: 0), "@a ")
        // Mid-sentence after a word, with a space already following.
        XCTAssertEqual(spaced("@a", into: "halos and more", at: 5), " @a")
        // …and with no space following.
        XCTAssertEqual(spaced("@a", into: "halosand more", at: 5), " @a ")
    }

    func testSpacingIsAddedOnlyWhereItIsNeeded() {
        // Existing whitespace on both sides: nothing added.
        XCTAssertEqual(spaced("@a", into: "halos  more", at: 6), "@a")
        // A word before, whitespace after.
        XCTAssertEqual(spaced("@a", into: "halos more", at: 5), " @a")
        // Punctuation that naturally follows a citation stays tight.
        XCTAssertEqual(spaced("@a", into: "halos.", at: 5), " @a")
        XCTAssertEqual(spaced("@a", into: "(halos)", at: 6), " @a")
        // An opening bracket before needs no space.
        XCTAssertEqual(spaced("@a", into: "(x", at: 1), "@a ")
        // End of document: nothing follows, nothing to separate from.
        XCTAssertEqual(spaced("@a", into: "halos ", at: 6), "@a")
        // LaTeX braces close the citation, but the text after still needs air.
        XCTAssertEqual(
            spaced("\\cite{a}", into: "halos and", at: 5, format: .latex), " \\cite{a}")
        XCTAssertEqual(
            spaced("\\cite{a}", into: "halosand", at: 5, format: .latex), " \\cite{a} ")
    }

    // MARK: - What the sync is given

    func testCiteKeysAreTheBufferFirstThenTheProjectFiles() {
        let keys = ManuscriptCiteKeyScanner.citeKeys(
            buffer: "Intro @b and @a, again @b.",
            format: .typst,
            otherFiles: [(text: "\\cite{c} and \\cite{a}", format: .latex)])
        XCTAssertEqual(keys, ["b", "a", "c"], "distinct, in reading order")
        XCTAssertEqual(ManuscriptCiteKeyScanner.format(forPath: "chapters/intro.typ"), .typst)
        XCTAssertEqual(ManuscriptCiteKeyScanner.format(forPath: "main.tex"), .latex)
        XCTAssertNil(ManuscriptCiteKeyScanner.format(forPath: "refs.bib"))
    }

    // MARK: - Opening imbib

    func testThePapersURLNamesTheManuscriptAndItsSyntax() throws {
        let id = UUID()
        let url = try XCTUnwrap(
            ManuscriptPapersCommand.papersURL(
                manuscriptID: id, title: "Wave Dark Matter", format: .latex))
        XCTAssertEqual(url.scheme, "imbib")
        XCTAssertEqual(url.host, "manuscript")
        XCTAssertEqual(url.path, "/\(id.uuidString.lowercased())/papers")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "format" })?.value, "latex")
        XCTAssertEqual(query.first(where: { $0.name == "title" })?.value, "Wave Dark Matter")

        // imbib parses exactly what imprint builds — the two halves of this
        // seam were written apart and must not drift.
        let command = try URLCommandParser().parse(url)
        guard case .manuscriptPapers(let parsed, let title, let format) = command else {
            return XCTFail("expected .manuscriptPapers, got \(command)")
        }
        XCTAssertEqual(parsed, id)
        XCTAssertEqual(title, "Wave Dark Matter")
        XCTAssertEqual(format, "latex")
    }

    // MARK: - The order papers are shown in

    /// "Recently Used" is an ordinary imbib sort — every list and collection
    /// offers it (the menu is `LibrarySortOrder.allCases`), and it is the
    /// order the papers window opens on. The SQL half is pinned by
    /// `recency_sort_orders_a_collection_and_a_library` in imbib-core.
    func testRecentlyUsedIsASortEveryListOffers() {
        XCTAssertTrue(LibrarySortOrder.allCases.contains(.recentActivity))
        XCTAssertEqual(LibrarySortOrder.recentActivity.sortKey, "last_activity",
                       "the key the Rust query maps to payload.last_activity_at")
        XCTAssertEqual(LibrarySortOrder.recentActivity.displayName, "Recently Used")
        XCTAssertFalse(LibrarySortOrder.recentActivity.defaultAscending,
                       "most recent first, and untouched papers last")
        XCTAssertFalse(LibrarySortOrder.recentActivity.usesRecommendation)
    }

    func testTheWindowIsTitledForTheManuscriptWhenOneAsked() {
        let collection = UUID()
        let forManuscript = ManuscriptPapersRequest(
            collectionID: collection, collectionName: "Draft — papers",
            manuscriptID: UUID(), manuscriptTitle: "Draft")
        XCTAssertEqual(forManuscript.windowTitle, "Draft — Papers")

        let bare = ManuscriptPapersRequest(collectionID: collection, collectionName: "Cosmology")
        XCTAssertEqual(bare.windowTitle, "Cosmology", "no manuscript, no citation verbs")
        XCTAssertNil(bare.manuscriptID)
    }
}
#endif
