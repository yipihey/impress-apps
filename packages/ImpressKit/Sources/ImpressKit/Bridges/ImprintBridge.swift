import Foundation

/// Typed bridge for communicating with imprint (manuscript authoring) via its HTTP API.
public struct ImprintBridge: Sendable {

    /// List open documents.
    public static func listDocuments() async throws -> [DocumentInfo] {
        try await SiblingBridge.shared.get("/api/documents", from: .imprint)
    }

    /// Get a specific document's content.
    public static func getDocument(id: String) async throws -> DocumentContent? {
        do {
            return try await SiblingBridge.shared.get(
                "/api/documents/\(id)",
                from: .imprint
            )
        } catch SiblingBridgeError.httpError(statusCode: 404) {
            return nil
        }
    }

    /// Check if imprint's HTTP API is available.
    public static func isAvailable() async -> Bool {
        await SiblingBridge.shared.isAvailable(.imprint)
    }
}

// MARK: - Result Types

/// Basic document information from imprint.
public struct DocumentInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let wordCount: Int?
    public let lastModified: Date?
}

/// Full document content from imprint.
public struct DocumentContent: Codable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    public let wordCount: Int?
}
