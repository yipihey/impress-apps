//
//  MockURLProtocol.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import Foundation

/// Mock URL protocol for intercepting and mocking network requests.
public final class MockURLProtocol: URLProtocol {

    // MARK: - Static Configuration

    /// Map of URL patterns to mock responses
    public static var mockResponses: [String: MockResponse] = [:]

    /// Request handler for dynamic responses
    public static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    /// All requests that were made (for verification)
    public static var requestHistory: [URLRequest] = []

    /// Simulated network delay in seconds
    public static var networkDelay: TimeInterval = 0

    // MARK: - Mock Response

    public struct MockResponse {
        public let data: Data?
        public let statusCode: Int
        public let headers: [String: String]
        public let error: Error?

        public init(
            data: Data?,
            statusCode: Int = 200,
            headers: [String: String] = [:],
            error: Error? = nil
        ) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
            self.error = error
        }

        /// Create a JSON response
        public static func json(_ data: Data, statusCode: Int = 200) -> MockResponse {
            MockResponse(
                data: data,
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"]
            )
        }

        /// Create an XML response
        public static func xml(_ data: Data, statusCode: Int = 200) -> MockResponse {
            MockResponse(
                data: data,
                statusCode: statusCode,
                headers: ["Content-Type": "application/xml"]
            )
        }

        /// Create a plain text response
        public static func text(_ string: String, statusCode: Int = 200) -> MockResponse {
            MockResponse(
                data: string.data(using: .utf8),
                statusCode: statusCode,
                headers: ["Content-Type": "text/plain"]
            )
        }

        /// Create an error response
        public static func error(_ error: Error) -> MockResponse {
            MockResponse(data: nil, statusCode: 0, error: error)
        }

        /// Create a 404 Not Found response
        public static var notFound: MockResponse {
            MockResponse(data: nil, statusCode: 404)
        }

        /// Create a 401 Unauthorized response
        public static var unauthorized: MockResponse {
            MockResponse(data: nil, statusCode: 401)
        }

        /// Create a 429 Rate Limited response
        public static func rateLimited(retryAfter: Int = 60) -> MockResponse {
            MockResponse(
                data: nil,
                statusCode: 429,
                headers: ["Retry-After": String(retryAfter)]
            )
        }

        /// Create a 500 Server Error response
        public static var serverError: MockResponse {
            MockResponse(data: nil, statusCode: 500)
        }
    }

    // MARK: - URLProtocol Methods

    public override class func canInit(with request: URLRequest) -> Bool {
        // Handle all requests
        true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        // Record the request
        MockURLProtocol.requestHistory.append(request)

        // Simulate network delay if configured
        if MockURLProtocol.networkDelay > 0 {
            Thread.sleep(forTimeInterval: MockURLProtocol.networkDelay)
        }

        do {
            // Try request handler first
            if let handler = MockURLProtocol.requestHandler {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data = data {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            // Fall back to URL pattern matching
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let mockResponse = findMockResponse(for: url)

            if let error = mockResponse?.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }

            let statusCode = mockResponse?.statusCode ?? 404
            let headers = mockResponse?.headers ?? [:]

            guard let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                throw URLError(.unknown)
            }

            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

            if let data = mockResponse?.data {
                client?.urlProtocol(self, didLoad: data)
            }

            client?.urlProtocolDidFinishLoading(self)

        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    public override func stopLoading() {
        // Nothing to clean up
    }

    // MARK: - Private Helpers

    private func findMockResponse(for url: URL) -> MockResponse? {
        let urlString = url.absoluteString

        // Exact match
        if let response = MockURLProtocol.mockResponses[urlString] {
            return response
        }

        // Pattern matching (simple prefix/contains matching)
        for (pattern, response) in MockURLProtocol.mockResponses {
            if pattern.hasPrefix("*") {
                let suffix = String(pattern.dropFirst())
                if urlString.contains(suffix) {
                    return response
                }
            } else if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                if urlString.hasPrefix(prefix) {
                    return response
                }
            } else if urlString.contains(pattern) {
                return response
            }
        }

        return nil
    }

    // MARK: - Test Helpers

    /// Reset all mock state
    public static func reset() {
        mockResponses.removeAll()
        requestHandler = nil
        requestHistory.removeAll()
        networkDelay = 0
    }

    /// Register a mock response for a URL pattern
    public static func register(
        pattern: String,
        response: MockResponse
    ) {
        mockResponses[pattern] = response
    }

    /// Register JSON response from fixture file
    public static func registerJSONFixture(
        pattern: String,
        filename: String,
        bundle: Bundle = Bundle(for: MockURLProtocol.self)
    ) throws {
        guard let url = bundle.url(forResource: filename, withExtension: "json") else {
            throw NSError(domain: "MockURLProtocol", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture not found: \(filename).json"
            ])
        }
        let data = try Data(contentsOf: url)
        mockResponses[pattern] = .json(data)
    }

    /// Register XML response from fixture file
    public static func registerXMLFixture(
        pattern: String,
        filename: String,
        bundle: Bundle = Bundle(for: MockURLProtocol.self)
    ) throws {
        guard let url = bundle.url(forResource: filename, withExtension: "xml") else {
            throw NSError(domain: "MockURLProtocol", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture not found: \(filename).xml"
            ])
        }
        let data = try Data(contentsOf: url)
        mockResponses[pattern] = .xml(data)
    }

    /// Create a URLSession configured to use this mock protocol
    public static func mockURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Get the last request that was made
    public static var lastRequest: URLRequest? {
        requestHistory.last
    }

    /// Get requests matching a URL pattern
    public static func requests(matching pattern: String) -> [URLRequest] {
        requestHistory.filter { request in
            guard let url = request.url else { return false }
            return url.absoluteString.contains(pattern)
        }
    }
}

// MARK: - Convenience Extensions

extension MockURLProtocol.MockResponse {
    /// Create from a JSON-encodable object
    public static func json<T: Encodable>(_ object: T, statusCode: Int = 200) throws -> MockURLProtocol.MockResponse {
        let data = try JSONEncoder().encode(object)
        return .json(data, statusCode: statusCode)
    }

    /// Create from a dictionary
    public static func json(_ dictionary: [String: Any], statusCode: Int = 200) throws -> MockURLProtocol.MockResponse {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return .json(data, statusCode: statusCode)
    }
}
