//
//  ImprintiOSTests.swift
//  imprint-iOSTests
//
//  Created by Claude on 2026-01-27.
//

import XCTest
@testable import imprint_iOS

final class ImprintiOSTests: XCTestCase {

    func testDocumentCreation() throws {
        let document = ImprintDocument()
        XCTAssertFalse(document.id.uuidString.isEmpty)
        XCTAssertEqual(document.title, "Untitled")
    }

    func testDocumentMetadataRoundTrip() throws {
        let id = UUID()
        var document = ImprintDocument()
        document.title = "Test Document"
        document.authors = ["Author One", "Author Two"]

        XCTAssertEqual(document.title, "Test Document")
        XCTAssertEqual(document.authors.count, 2)
    }
}
