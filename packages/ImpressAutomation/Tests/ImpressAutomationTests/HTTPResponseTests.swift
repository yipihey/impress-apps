//
//  HTTPResponseTests.swift
//  ImpressAutomation
//

import XCTest
@testable import ImpressAutomation

final class HTTPResponseTests: XCTestCase {

    func testOkResponse() {
        let response = HTTPResponse.ok(["foo": "bar"])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.statusText, "OK")

        let bodyString = String(data: response.body, encoding: .utf8)
        XCTAssertNotNil(bodyString)
        XCTAssertTrue(bodyString?.contains("\"status\" : \"ok\"") ?? false)
        XCTAssertTrue(bodyString?.contains("\"foo\" : \"bar\"") ?? false)
    }

    func testBadRequestResponse() {
        let response = HTTPResponse.badRequest("Missing parameter")
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(response.statusText, "Bad Request")

        let bodyString = String(data: response.body, encoding: .utf8)
        XCTAssertTrue(bodyString?.contains("Missing parameter") ?? false)
    }

    func testNotFoundResponse() {
        let response = HTTPResponse.notFound()
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(response.statusText, "Not Found")
    }

    func testServerErrorResponse() {
        let response = HTTPResponse.serverError("Database error")
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(response.statusText, "Internal Server Error")
    }

    func testTextResponse() {
        let response = HTTPResponse.text("Hello, World!")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "Hello, World!")
    }

    func testToDataIncludesCorsHeaders() {
        let response = HTTPResponse.ok()
        let data = response.toData()
        let string = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(string.contains("Access-Control-Allow-Origin: *"))
        XCTAssertTrue(string.contains("Access-Control-Allow-Methods: GET, POST, OPTIONS"))
    }

    func testJsonCodableWithDateStrategy() {
        struct TestData: Encodable {
            let date: Date
        }

        let testDate = Date(timeIntervalSince1970: 0)
        let response = HTTPResponse.jsonCodable(
            TestData(date: testDate),
            dateEncodingStrategy: .iso8601
        )

        let bodyString = String(data: response.body, encoding: .utf8)
        XCTAssertTrue(bodyString?.contains("1970-01-01") ?? false)
    }

    func testNoContentResponse() {
        let response = HTTPResponse.noContent()
        XCTAssertEqual(response.status, 204)
        XCTAssertEqual(response.statusText, "No Content")
        XCTAssertTrue(response.body.isEmpty)
    }
}
