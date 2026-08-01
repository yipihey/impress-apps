//
//  TagVocabularyTests.swift
//  PublicationManagerCoreTests
//
//  A tag has TWO halves in this store: the envelope fact (`item_tags`) and the
//  DEFINITION row (`imbib/tag-definition`, which is what `listTags` returns and
//  therefore what the sidebar's Tags tree browses). Applying a tag wrote only
//  the first, so a tag the user put on a paper was invisible to every reader of
//  the vocabulary while being visible on the paper's own row — which is exactly
//  why it went unnoticed.
//
//  Found by the impress-iOS UI suite: `item_tags` held `reading/queue` and the
//  Tags section was empty.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class TagVocabularyTests: XCTestCase {

    func testApplyingATagAlsoDefinesItSoItCanBeBrowsed() throws {
        let adapter = RustStoreAdapter.shared
        let path = "tests/vocabulary-\(UUID().uuidString.prefix(8))"

        guard let library = adapter.createLibrary(name: "Tag vocabulary \(UUID().uuidString.prefix(6))")
        else {
            throw XCTSkip("no writable store in this environment")
        }
        let ids = adapter.importBibTeX(
            """
            @article{Vocabulary2026Test,
              author = {Tester, T.},
              title = {A paper that carries a tag},
              year = {2026}
            }
            """,
            libraryId: library.id)
        try XCTSkipIf(ids.isEmpty, "import produced nothing in this environment")

        adapter.addTag(ids: ids, tagPath: path)

        XCTAssertTrue(
            (adapter.getPublicationDetail(id: ids[0])?.tags.map(\.path) ?? []).contains(path),
            "the envelope half: the paper carries the tag")
        XCTAssertTrue(
            adapter.listTags().contains { $0.path == path },
            "the VOCABULARY half: a tag nothing has defined cannot be browsed, so the "
                + "sidebar's Tags tree would not show a tag the user just applied")
    }
}
