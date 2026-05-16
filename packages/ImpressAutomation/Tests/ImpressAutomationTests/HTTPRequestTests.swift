//
//  HTTPRequestTests.swift
//  ImpressAutomation
//

import XCTest
@testable import ImpressAutomation

final class HTTPRequestTests: XCTestCase {

    func testParseSimpleGet() {
        let raw = "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let request = HTTPRequest.parse(raw)

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/api/status")
        XCTAssertTrue(request?.queryParams.isEmpty ?? false)
        XCTAssertEqual(request?.headers["host"], "localhost")
        XCTAssertTrue(request?.body?.isEmpty ?? true)
    }

    func testParseGetWithQueryParams() {
        let raw = "GET /api/search?q=quantum&limit=10 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let request = HTTPRequest.parse(raw)

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.path, "/api/search")
        XCTAssertEqual(request?.queryParams["q"], "quantum")
        XCTAssertEqual(request?.queryParams["limit"], "10")
    }

    func testParseGetWithEncodedQueryParams() {
        let raw = "GET /api/search?q=hello%20world HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let request = HTTPRequest.parse(raw)

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.queryParams["q"], "hello world")
    }

    func testParsePostWithBody() {
        let raw = "POST /api/import HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\r\n{\"bibtex\": \"@article{}\"}"
        let request = HTTPRequest.parse(raw)

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/api/import")
        XCTAssertEqual(request?.headers["content-type"], "application/json")
        XCTAssertEqual(request?.body, "{\"bibtex\": \"@article{}\"}")
    }

    func testParseInvalidRequest() {
        let raw = "INVALID"
        let request = HTTPRequest.parse(raw)
        XCTAssertNil(request)
    }

    func testParseEmptyString() {
        let raw = ""
        let request = HTTPRequest.parse(raw)
        XCTAssertNil(request)
    }
}
