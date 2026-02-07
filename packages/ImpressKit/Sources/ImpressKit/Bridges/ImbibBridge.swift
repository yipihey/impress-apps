import Foundation

/// Typed bridge for communicating with imbib (bibliography manager) via its HTTP API.
///
/// All methods use `SiblingBridge.shared` to send HTTP requests to imbib's
/// automation server (default port 23120).
public struct ImbibBridge: Sendable {

    /// Search the imbib library for papers matching a query.
    public static func searchLibrary(query: String, limit: Int = 20) async throws -> [PaperSearchResult] {
        try await SiblingBridge.shared.get(
            "/api/search",
            from: .imbib,
            query: ["query": query, "limit": String(limit)]
        )
    }

    /// Get details for a specific paper by cite key.
    public static func getPaper(citeKey: String) async throws -> PaperDetail? {
        do {
            return try await SiblingBridge.shared.get(
                "/api/publications/\(citeKey)",
                from: .imbib
            )
        } catch SiblingBridgeError.httpError(statusCode: 404) {
            return nil
        }
    }

    /// Export BibTeX for the given cite keys.
    public static func exportBibTeX(citeKeys: [String]) async throws -> String {
        let keysParam = citeKeys.joined(separator: ",")
        let data = try await SiblingBridge.shared.getRaw(
            "/api/export/bibtex",
            from: .imbib,
            query: ["keys": keysParam]
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Add papers to imbib by identifier (DOI, arXiv ID, etc.).
    public static func addPapers(identifiers: [String], library: String? = nil) async throws -> AddPapersResult {
        var body = AddPapersRequest(identifiers: identifiers, library: library)
        _ = body // suppress warning
        return try await SiblingBridge.shared.post(
            "/api/papers/add",
            to: .imbib,
            body: body
        )
    }

    /// Check if imbib's HTTP API is available.
    public static func isAvailable() async -> Bool {
        await SiblingBridge.shared.isAvailable(.imbib)
    }
}

// MARK: - Result Types

/// A paper returned from imbib search.
public struct PaperSearchResult: Codable, Sendable, Identifiable {
    public let id: String
    public let citeKey: String
    public let title: String
    public let authors: String?
    public let year: Int?
    public let doi: String?
    public let abstract: String?

    public init(id: String, citeKey: String, title: String, authors: String? = nil,
                year: Int? = nil, doi: String? = nil, abstract: String? = nil) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.doi = doi
        self.abstract = abstract
    }
}

/// Detailed paper information from imbib.
public struct PaperDetail: Codable, Sendable {
    public let id: String
    public let citeKey: String
    public let title: String
    public let authors: String?
    public let year: Int?
    public let doi: String?
    public let abstract: String?
    public let rawBibTeX: String?
    public let pdfPath: String?
}

/// Request body for adding papers.
public struct AddPapersRequest: Codable, Sendable {
    public let identifiers: [String]
    public let library: String?

    public init(identifiers: [String], library: String? = nil) {
        self.identifiers = identifiers
        self.library = library
    }
}

/// Result of adding papers to imbib.
public struct AddPapersResult: Codable, Sendable {
    public let added: Int
    public let skipped: Int
    public let errors: [String]?
}
