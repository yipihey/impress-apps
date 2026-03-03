import Testing
import Foundation
@testable import ImpressAutomation

@Suite("HTTP Response Builder")
struct HTTPResponseBuilderTests {

    // MARK: - toData() format

    @Test("toData produces valid HTTP response format")
    func toDataFormat() {
        let response = HTTPResponse(status: 200, statusText: "OK", body: "hello".data(using: .utf8)!)
        let data = response.toData()
        let string = String(data: data, encoding: .utf8)!
        #expect(string.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(string.contains("\r\n\r\n"))
        #expect(string.hasSuffix("hello"))
    }

    @Test("Content-Length header matches body length")
    func contentLength() {
        let body = "test body"
        let response = HTTPResponse(status: 200, statusText: "OK", body: body.data(using: .utf8)!)
        let data = response.toData()
        let string = String(data: data, encoding: .utf8)!
        #expect(string.contains("Content-Length: \(body.count)"))
    }

    @Test("CORS headers are present")
    func corsHeaders() {
        let response = HTTPResponse(status: 200, statusText: "OK")
        let data = response.toData()
        let string = String(data: data, encoding: .utf8)!
        #expect(string.contains("Access-Control-Allow-Origin: *"))
        #expect(string.contains("Access-Control-Allow-Methods:"))
    }

    // MARK: - Factory methods

    @Test("ok() returns 200 with status ok in body")
    func okFactory() {
        let response = HTTPResponse.ok()
        #expect(response.status == 200)
        let bodyString = String(data: response.body, encoding: .utf8)!
        #expect(bodyString.contains("\"status\""))
        #expect(bodyString.contains("\"ok\""))
    }

    @Test("badRequest returns 400 with error message")
    func badRequestFactory() {
        let response = HTTPResponse.badRequest("missing param")
        #expect(response.status == 400)
        let bodyString = String(data: response.body, encoding: .utf8)!
        #expect(bodyString.contains("missing param"))
    }

    @Test("notFound returns 404")
    func notFoundFactory() {
        let response = HTTPResponse.notFound()
        #expect(response.status == 404)
    }

    @Test("notFound with custom message includes message")
    func notFoundCustomMessage() {
        let response = HTTPResponse.notFound("item not found")
        #expect(response.status == 404)
        let bodyString = String(data: response.body, encoding: .utf8)!
        #expect(bodyString.contains("item not found"))
    }

    @Test("serverError returns 500")
    func serverErrorFactory() {
        let response = HTTPResponse.serverError("internal failure")
        #expect(response.status == 500)
        let bodyString = String(data: response.body, encoding: .utf8)!
        #expect(bodyString.contains("internal failure"))
    }

    @Test("noContent returns 204 with empty body")
    func noContentFactory() {
        let response = HTTPResponse.noContent()
        #expect(response.status == 204)
        #expect(response.body.isEmpty)
    }

    @Test("text() returns plain text response")
    func textFactory() {
        let response = HTTPResponse.text("hello world")
        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "text/plain; charset=utf-8")
        #expect(String(data: response.body, encoding: .utf8) == "hello world")
    }

    @Test("json() returns JSON content type")
    func jsonFactory() {
        let response = HTTPResponse.json(["key": "value"])
        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "application/json; charset=utf-8")
        let bodyString = String(data: response.body, encoding: .utf8)!
        #expect(bodyString.contains("\"key\""))
        #expect(bodyString.contains("\"value\""))
    }

    @Test("jsonCodable() encodes Codable types")
    func jsonCodableFactory() throws {
        struct TestModel: Codable { let name: String; let count: Int }
        let model = TestModel(name: "test", count: 42)
        let response = HTTPResponse.jsonCodable(model)
        #expect(response.status == 200)
        let bodyString = String(data: response.body, encoding: .utf8)!
        #expect(bodyString.contains("\"name\""))
        #expect(bodyString.contains("\"test\""))
        #expect(bodyString.contains("42"))
    }

    @Test("forbidden returns 403")
    func forbiddenFactory() {
        let response = HTTPResponse.forbidden("not allowed")
        #expect(response.status == 403)
    }
}
