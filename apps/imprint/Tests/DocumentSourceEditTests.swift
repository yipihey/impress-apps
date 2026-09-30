import XCTest
@testable import imprint

final class DocumentSourceEditTests: XCTestCase {
    func testInsertDeleteAndFirstReplaceUseDocumentOrder() {
        let inserted = DocumentSourceEdit.replaceUTF16("abcd", location: 2, length: 0, with: "XY")
        XCTAssertEqual(inserted, "abXYcd")
        let deleted = DocumentSourceEdit.replaceUTF16("abXYcd", location: 2, length: 2, with: "")
        XCTAssertEqual(deleted, "abcd")
        XCTAssertNil(DocumentSourceEdit.replaceUTF16("abcd", location: 8, length: 0, with: "Z"))

        XCTAssertEqual(
            DocumentSourceEdit.replace("aa", search: "a", replacement: "b", all: false),
            .success("ba"))
        XCTAssertEqual(
            DocumentSourceEdit.replace("aa", search: "a", replacement: "b", all: true),
            .success("bb"))
        XCTAssertEqual(
            DocumentSourceEdit.replace("aa", search: "z", replacement: "b", all: false),
            .failure(DocumentEditFailure(message: "search text not found")))
    }

    func testBibliographyUpsertReplacesOneKeyAndRemoveDropsIt() {
        let first = DocumentSourceEdit.upsertBibliography(
            "", citeKey: "Ada2020", bibtex: "@article{Ada2020, title={One}}")
        let both = DocumentSourceEdit.upsertBibliography(
            first, citeKey: "Bea2021", bibtex: "@article{Bea2021, title={Two}}")
        let replaced = DocumentSourceEdit.upsertBibliography(
            both, citeKey: "Ada2020", bibtex: "@article{Ada2020, title={Revised}}")
        XCTAssertTrue(replaced.contains("title={Revised}"))
        XCTAssertFalse(replaced.contains("title={One}"))
        XCTAssertTrue(replaced.contains("Bea2021"))
        let removed = DocumentSourceEdit.removeBibliography(replaced, citeKey: "Bea2021")
        XCTAssertFalse(removed.contains("Bea2021"))
        XCTAssertTrue(removed.contains("Ada2020"))
    }
}
