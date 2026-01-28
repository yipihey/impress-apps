//
//  HTTPRouter.swift
//  ImpressAutomation
//
//  Protocol for app-specific request routing.
//

import Foundation

/// Protocol for application-specific HTTP request routing.
///
/// Apps implement this protocol to handle their specific endpoints
/// while using the shared `HTTPServer` infrastructure.
///
/// Example:
/// ```swift
/// public actor MyAppRouter: HTTPRouter {
///     public func route(_ request: HTTPRequest) async -> HTTPResponse {
///         switch (request.method, request.path) {
///         case ("GET", "/api/status"):
///             return .ok(["app": "MyApp"])
///         default:
///             return .notFound()
///         }
///     }
/// }
/// ```
public protocol HTTPRouter: Sendable {
    /// Route an incoming HTTP request and return a response.
    func route(_ request: HTTPRequest) async -> HTTPResponse
}
