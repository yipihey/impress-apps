//
//  HTTPResponse.swift
//  ImpressAutomation
//
//  Shared HTTP response builder for impress apps.
//

import Foundation

/// Simple HTTP response builder.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let statusText: String
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, statusText: String, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    /// Convert to HTTP response data.
    public func toData() -> Data {
        var responseString = "HTTP/1.1 \(status) \(statusText)\r\n"

        // Add default headers
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"

        // Add CORS headers for browser/tool requests
        allHeaders["Access-Control-Allow-Origin"] = "*"
        allHeaders["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        allHeaders["Access-Control-Allow-Headers"] = "Content-Type, Authorization"

        for (key, value) in allHeaders {
            responseString += "\(key): \(value)\r\n"
        }
        responseString += "\r\n"

        var responseData = responseString.data(using: .utf8) ?? Data()
        responseData.append(body)
        return responseData
    }

    // MARK: - Factory Methods

    /// Create a JSON response.
    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                status: status,
                statusText: statusText(for: status),
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        } catch {
            return serverError("JSON serialization failed: \(error.localizedDescription)")
        }
    }

    /// Create a JSON response from Codable with optional date encoding strategy.
    public static func jsonCodable<T: Encodable>(
        _ object: T,
        status: Int = 200,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate
    ) -> HTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = dateEncodingStrategy
            let data = try encoder.encode(object)
            return HTTPResponse(
                status: status,
                statusText: statusText(for: status),
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        } catch {
            return serverError("JSON encoding failed: \(error.localizedDescription)")
        }
    }

    /// Create a plain text response.
    public static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            statusText: statusText(for: status),
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: string.data(using: .utf8) ?? Data()
        )
    }

    /// Create a 200 OK response.
    public static func ok(_ body: [String: Any] = [:]) -> HTTPResponse {
        var response = body
        response["status"] = "ok"
        return json(response)
    }

    /// Create a 204 No Content response.
    public static func noContent() -> HTTPResponse {
        HTTPResponse(status: 204, statusText: statusText(for: 204))
    }

    /// Create a 400 Bad Request response.
    public static func badRequest(_ message: String) -> HTTPResponse {
        json(["status": "error", "error": message], status: 400)
    }

    /// Create a 403 Forbidden response.
    public static func forbidden(_ message: String) -> HTTPResponse {
        json(["status": "error", "error": message], status: 403)
    }

    /// Create a 404 Not Found response.
    public static func notFound(_ message: String = "Not found") -> HTTPResponse {
        json(["status": "error", "error": message], status: 404)
    }

    /// Create a 500 Server Error response.
    public static func serverError(_ message: String) -> HTTPResponse {
        json(["status": "error", "error": message], status: 500)
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
