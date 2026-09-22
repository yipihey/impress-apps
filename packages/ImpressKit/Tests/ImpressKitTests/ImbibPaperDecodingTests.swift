import XCTest
@testable import ImpressKit

/// imbib sends a paper's `authors` as one "Family, Given" per author. Joined
/// back on ", " the boundary between two authors is indistinguishable from the
/// comma inside each name, so the bridge restores imbib's own author text.
final class ImbibPaperDecodingTests: XCTestCase {

    private func decode(authors: String) throws -> ImbibPaper {
        let json = #"{"id": "25656963-7BB6-4F28-A247-E983A444FAC3", "citeKey": "AminJainKarurMocz2022", "title": "t", "authors": "#
            + authors + "}"
        return try JSONDecoder().decode(ImbibPaper.self, from: Data(json.utf8))
    }

    func testAuthorArrayJoinsBackIntoImbibsAuthorText() throws {
        let paper = try decode(authors: #"["Amin, Mustafa A.", "Jain, Mudit", "Karur, Rohith", "Mocz, Philip"]"#)
        XCTAssertEqual(paper.authors, "Amin, Mustafa A.; Jain, Mudit; Karur, Rohith; Mocz, Philip")
    }

    func testJoinedAuthorStringPassesThroughUnchanged() throws {
        let paper = try decode(authors: #""Amin, Mustafa A.; Jain, Mudit""#)
        XCTAssertEqual(paper.authors, "Amin, Mustafa A.; Jain, Mudit")
    }
}
