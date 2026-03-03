import Testing
@testable import ImpressAutomation

@Suite("HTTP Request Parser")
struct HTTPRequestParserTests {

    @Test("Simple GET request")
    func simpleGet() {
        let request = HTTPRequest.parse("GET /api/status HTTP/1.1\r\n\r\n")
        #expect(request != nil)
        #expect(request?.method == "GET")
        #expect(request?.path == "/api/status")
        #expect(request?.queryParams.isEmpty == true)
    }

    @Test("GET with query parameters")
    func getWithQueryParams() {
        let request = HTTPRequest.parse("GET /api/logs?limit=20&level=info HTTP/1.1\r\n\r\n")
        #expect(request?.path == "/api/logs")
        #expect(request?.queryParams["limit"] == "20")
        #expect(request?.queryParams["level"] == "info")
    }

    @Test("POST with body")
    func postWithBody() {
        let raw = "POST /api/command HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"action\":\"test\"}"
        let request = HTTPRequest.parse(raw)
        #expect(request?.method == "POST")
        #expect(request?.path == "/api/command")
        #expect(request?.body == "{\"action\":\"test\"}")
    }

    @Test("Multiple headers parsed correctly")
    func multipleHeaders() {
        let raw = "GET /api/status HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer token123\r\n\r\n"
        let request = HTTPRequest.parse(raw)
        #expect(request?.headers["content-type"] == "application/json")
        #expect(request?.headers["authorization"] == "Bearer token123")
    }

    @Test("URL-encoded query parameters are decoded")
    func urlEncodedParams() {
        let request = HTTPRequest.parse("GET /api/search?q=hello%20world HTTP/1.1\r\n\r\n")
        #expect(request?.queryParams["q"] == "hello world")
    }

    @Test("Empty string returns nil")
    func emptyString() {
        #expect(HTTPRequest.parse("") == nil)
    }

    @Test("Malformed request line returns nil")
    func malformedRequestLine() {
        #expect(HTTPRequest.parse("INVALID\r\n\r\n") == nil)
    }

    @Test("Path without query params has empty queryParams")
    func pathWithoutQuery() {
        let request = HTTPRequest.parse("GET /api/status HTTP/1.1\r\n\r\n")
        #expect(request?.queryParams.isEmpty == true)
    }

    @Test("Header with colon in value is preserved")
    func headerColonInValue() {
        let raw = "GET / HTTP/1.1\r\nX-Custom: value: with: colons\r\n\r\n"
        let request = HTTPRequest.parse(raw)
        #expect(request?.headers["x-custom"] == "value: with: colons")
    }

    @Test("DELETE method parsed correctly")
    func deleteMethod() {
        let request = HTTPRequest.parse("DELETE /api/items/123 HTTP/1.1\r\n\r\n")
        #expect(request?.method == "DELETE")
        #expect(request?.path == "/api/items/123")
    }

    @Test("Request without body has nil body")
    func noBody() {
        let request = HTTPRequest.parse("GET /api/status HTTP/1.1\r\n\r\n")
        #expect(request?.body == nil)
    }

    @Test("Multiple query parameters with same structure")
    func multipleQueryParams() {
        let request = HTTPRequest.parse("GET /api/logs?level=info,warning,error&limit=50&offset=10 HTTP/1.1\r\n\r\n")
        #expect(request?.queryParams["level"] == "info,warning,error")
        #expect(request?.queryParams["limit"] == "50")
        #expect(request?.queryParams["offset"] == "10")
    }
}
