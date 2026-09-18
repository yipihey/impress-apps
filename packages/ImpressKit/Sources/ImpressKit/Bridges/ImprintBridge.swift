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

    /// Ask imprint to insert citations into a manuscript's open editor, at the
    /// caret, in that document's own syntax.
    ///
    /// Answers whether the citation actually landed: imprint returns 409 with
    /// a reason when it has no editor open for that manuscript, which is the
    /// difference the old fire-and-forget notification could not report.
    @discardableResult
    public static func insertCitation(
        citeKeys: [String],
        into manuscriptID: UUID
    ) async throws -> CitationInsertResponse {
        let path = "/api/documents/\(manuscriptID.uuidString.lowercased())/insert-citation"
        do {
            let data = try await SiblingBridge.shared.postRaw(
                path,
                to: .imprint,
                body: ["citeKey": citeKeys.joined(separator: ","), "citeKeys": citeKeys]
                    as [String: Any]
            )
            return try JSONDecoder().decode(CitationInsertResponse.self, from: data)
        } catch SiblingBridgeError.httpError(let statusCode) where statusCode == 409 {
            // imprint has no editor open for that manuscript. A refusal with a
            // reason, not a transport failure.
            return CitationInsertResponse(
                inserted: false,
                message: "imprint has no open editor for that manuscript")
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

/// What imprint did with an insert-citation request.
public struct CitationInsertResponse: Codable, Sendable {
    public let inserted: Bool
    public let message: String?

    public init(inserted: Bool, message: String?) {
        self.inserted = inserted
        self.message = message
    }
}

/// Full document content from imprint.
public struct DocumentContent: Codable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    public let wordCount: Int?
}
