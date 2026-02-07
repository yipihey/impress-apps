import Foundation

/// Typed bridge for communicating with implore (data visualization) via its HTTP API.
public struct ImploreBridge: Sendable {

    /// List figures.
    public static func listFigures(limit: Int = 50) async throws -> [FigureInfo] {
        try await SiblingBridge.shared.get(
            "/api/figures",
            from: .implore,
            query: ["limit": String(limit)]
        )
    }

    /// Get a specific figure.
    public static func getFigure(id: String) async throws -> FigureInfo? {
        do {
            return try await SiblingBridge.shared.get("/api/figures/\(id)", from: .implore)
        } catch SiblingBridgeError.httpError(statusCode: 404) {
            return nil
        }
    }

    /// Export a figure in a specific format.
    public static func exportFigure(id: String, format: String = "png") async throws -> Data {
        try await SiblingBridge.shared.getRaw(
            "/api/figures/\(id)/export",
            from: .implore,
            query: ["format": format]
        )
    }

    /// Check if implore's HTTP API is available.
    public static func isAvailable() async -> Bool {
        await SiblingBridge.shared.isAvailable(.implore)
    }
}

// MARK: - Result Types

/// Basic figure information from implore.
public struct FigureInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let datasetName: String?
    public let format: String?
    public let createdAt: Date?
    public let modifiedAt: Date?
}
