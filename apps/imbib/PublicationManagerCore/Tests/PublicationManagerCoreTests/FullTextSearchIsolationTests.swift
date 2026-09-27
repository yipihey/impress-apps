import Foundation
import ImpressKit
import XCTest
@testable import PublicationManagerCore

final class FullTextSearchIsolationTests: XCTestCase {
    func testIndexUsesTheTestContainer() throws {
        let location = try XCTUnwrap(FullTextSearchService.indexDirectory).standardizedFileURL
        let root = SharedContainer.rootDirectory.standardizedFileURL
        XCTAssertEqual(location.path, root.appendingPathComponent("Application Support/imbib/search_index").path)
        XCTAssertTrue(root.lastPathComponent.hasPrefix("impress-unit-tests-"))
    }
}
