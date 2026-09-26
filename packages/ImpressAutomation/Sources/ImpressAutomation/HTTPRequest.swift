//
//  HTTPRequest.swift
//  ImpressAutomation
//
//  Shared HTTP request parser for impress apps.
//

import Foundation

/// Simple HTTP request parser.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let queryParams: [String: String]
    public let headers: [String: String]
    public let body: String?
    /// The local port the request arrived on — the port the server is BOUND
    /// to, which is the one the caller dialled. Set by `HTTPServer`; nil for
    /// a request built by hand or parsed from text. A route that reports
    /// "where am I" (`/api/status`) reads this rather than a setting, which
    /// can say something else: the port table's default, or a port edited
    /// in Settings since the server started.
    public var localPort: UInt16?

    public init(
        method: String,
        path: String,
        queryParams: [String: String] = [:],
        headers: [String: String] = [:],
        body: String? = nil,
        localPort: UInt16? = nil
    ) {
        self.method = method
        self.path = path
        self.queryParams = queryParams
        self.headers = headers
        self.body = body
        self.localPort = localPort
    }

    /// Parse an HTTP request string.
    public static func parse(_ string: String) -> HTTPRequest? {
        let lines = string.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse request line
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }

        let method = requestLine[0]
        let fullPath = requestLine[1]

        // Parse path and query parameters
        let pathComponents = fullPath.components(separatedBy: "?")
        let path = pathComponents[0]

        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            let queryString = pathComponents[1]
            for param in queryString.components(separatedBy: "&") {
                let parts = param.components(separatedBy: "=")
                if parts.count == 2 {
                    let key = parts[0].removingPercentEncoding ?? parts[0]
                    let value = parts[1].removingPercentEncoding ?? parts[1]
                    queryParams[key] = value
                }
            }
        }

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStartIndex: Int?

        for (index, line) in lines.dropFirst().enumerated() {
            if line.isEmpty {
                bodyStartIndex = index + 2  // +1 for dropFirst, +1 for empty line
                break
            }
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                headers[headerParts[0].lowercased()] = headerParts.dropFirst().joined(separator: ": ")
            }
        }

        // Parse body — treat an empty body as absent (nil), matching the
        // `body: String?` contract that downstream routers rely on.
        var body: String?
        if let startIndex = bodyStartIndex, startIndex < lines.count {
            let joined = lines[startIndex...].joined(separator: "\r\n")
            body = joined.isEmpty ? nil : joined
        }

        return HTTPRequest(
            method: method,
            path: path,
            queryParams: queryParams,
            headers: headers,
            body: body
        )
    }
}
