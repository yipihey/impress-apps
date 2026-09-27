import XCTest
@testable import imprint

final class LegacyPersistenceIsolationTests: XCTestCase {
    func testSharedLegacyStoreIsInMemoryInTestHost() {
        let descriptions = ImprintPersistenceController.shared.container.persistentStoreDescriptions
        XCTAssertFalse(descriptions.isEmpty)
        XCTAssertTrue(descriptions.allSatisfy { $0.url?.path == "/dev/null" })
    }
}
