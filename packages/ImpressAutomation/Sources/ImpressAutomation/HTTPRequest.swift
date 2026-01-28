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

    public init(
        method: String,
        path: String,
        queryParams: [String: String] = [:],
        headers: [String: String] = [:],
        body: String? = nil
    ) {
        self.method = method
        self.path = path
        self.queryParams = queryParams
        self.headers = headers
        self.body = body
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

        // Parse body
        var body: String?
        if let startIndex = bodyStartIndex, startIndex < lines.count {
            body = lines[startIndex...].joined(separator: "\r\n")
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
