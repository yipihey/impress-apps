import XCTest
@testable import ImpressKit

/// Pins the service ports that are mirrored by Rust defaults, so a change on
/// one side cannot drift silently.
final class SiblingServicesTests: XCTestCase {
    func testOMLXPortMatchesTheRustCatalogueDefault() {
        // `impress_ai::catalogue::OMLX_DEFAULT_URL` is `http://127.0.0.1:8000`.
        XCTAssertEqual(SiblingApp.Services.omlxPort, 8000)
    }

    func testImpressAIServerPortIsTheDocumentedDefault() {
        XCTAssertEqual(SiblingApp.Services.impressAIPort, 8787)
    }
}
