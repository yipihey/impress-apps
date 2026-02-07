import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Typed cross-app communication via HTTP APIs.
///
/// SiblingBridge wraps the HTTP automation endpoints that each Impress app already
/// exposes. It provides structured request/response communication — unlike Darwin
/// notifications (signal-only) or URL schemes (launch-only, no response).
///
/// Usage:
/// ```swift
/// let papers: [PaperSearchResult] = try await SiblingBridge.shared.get(
///     "/api/search", from: .imbib, query: ["query": "Einstein"]
/// )
/// ```
public actor SiblingBridge {
    public static let shared = SiblingBridge()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Generic HTTP Methods

    /// Make a GET request to a sibling app's HTTP API.
    public func get<T: Decodable & Sendable>(
        _ path: String,
        from app: SiblingApp,
        query: [String: String] = []
    ) async throws -> T {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(app.httpPort)
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw SiblingBridgeError.invalidURL(path)
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try decoder.decode(T.self, from: data)
    }

    /// Make a GET request returning raw Data.
    public func getRaw(
        _ path: String,
        from app: SiblingApp,
        query: [String: String] = []
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(app.httpPort)
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw SiblingBridgeError.invalidURL(path)
        }
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return data
    }

    /// Make a POST request to a sibling app's HTTP API.
    public func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        to app: SiblingApp,
        body: Body
    ) async throws -> T {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(app.httpPort)
        components.path = path
        guard let url = components.url else {
            throw SiblingBridgeError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(T.self, from: data)
    }

    /// Make a POST request returning raw Data.
    public func postRaw<Body: Encodable & Sendable>(
        _ path: String,
        to app: SiblingApp,
        body: Body
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(app.httpPort)
        components.path = path
        guard let url = components.url else {
            throw SiblingBridgeError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }

    // MARK: - Availability

    /// Check if a sibling app's HTTP API is responding.
    public func isAvailable(_ app: SiblingApp) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(app.httpPort)/api/status")!
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Launch a sibling app via URL scheme if it's not responding.
    public func ensureRunning(_ app: SiblingApp) async {
        guard !(await isAvailable(app)) else { return }
        #if os(macOS)
        if let url = URL(string: "\(app.urlScheme)://") {
            await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
        #endif
    }

    // MARK: - Helpers

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SiblingBridgeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SiblingBridgeError.httpError(statusCode: http.statusCode)
        }
    }
}

// MARK: - Error

/// Errors from SiblingBridge HTTP communication.
public enum SiblingBridgeError: LocalizedError, Sendable {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int)
    case appNotAvailable(SiblingApp)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let path): "Invalid URL path: \(path)"
        case .invalidResponse: "Invalid HTTP response"
        case .httpError(let code): "HTTP error \(code)"
        case .appNotAvailable(let app): "\(app.displayName) is not responding"
        }
    }
}
