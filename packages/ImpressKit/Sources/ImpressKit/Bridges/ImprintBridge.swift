import Foundation

/// Typed bridge for communicating with imprint (manuscript authoring) via its canonical verbs.
public struct ImprintBridge: Sendable {

    /// List manuscript metadata without loading document bodies.
    public static func listDocuments() async throws -> [DocumentInfo] {
        let records: [VerbDocumentSummary] = try await SiblingBridge.shared.callVerb(
            "imprint-manuscript-service_list-documents",
            on: .imprint
        )
        return records.map(DocumentInfo.init(record:))
    }

    /// Get a document's metadata and source from the two canonical reads.
    public static func getDocument(id: String) async throws -> DocumentContent? {
        let record: VerbDocumentSummary? = try await SiblingBridge.shared.callVerb(
            "imprint-manuscript-service_get-document",
            on: .imprint,
            arguments: ["id": id]
        )
        guard let record else { return nil }
        let source: String? = try await SiblingBridge.shared.callVerb(
            "imprint-app-service_get-content",
            on: .imprint,
            arguments: ["document_id": id]
        )
        guard let source else { throw SiblingBridgeError.invalidResponse }
        return DocumentContent(record: record, source: source)
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
            // imprint has no open editor for that manuscript. A refusal with a
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

struct VerbDocumentSummary: Decodable, Sendable {
    let id: String
    let title: String
    let format: String
    let authors: [String]
    let status: String
    let wordCount: Int
    let lastModified: String?
    let createdAt: String?
    let linkedImbibManuscriptId: String?
    let linkedImbibLibraryId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, format, authors, status
        case wordCount = "word_count"
        case lastModified = "last_modified"
        case createdAt = "created_at"
        case linkedImbibManuscriptId = "linked_imbib_manuscript_id"
        case linkedImbibLibraryId = "linked_imbib_library_id"
    }
}

extension DocumentInfo {
    init(record: VerbDocumentSummary) {
        self.init(
            id: record.id,
            title: record.title,
            wordCount: record.wordCount,
            lastModified: BridgeDate.parse(record.lastModified),
            format: record.format,
            authors: record.authors,
            status: record.status,
            createdAt: BridgeDate.parse(record.createdAt),
            linkedImbibManuscriptId: record.linkedImbibManuscriptId,
            linkedImbibLibraryId: record.linkedImbibLibraryId
        )
    }
}

// MARK: - Result Types

/// Basic document information from imprint.
public struct DocumentInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let wordCount: Int?
    public let lastModified: Date?
    public let format: String?
    public let authors: [String]?
    public let status: String?
    public let createdAt: Date?
    public let linkedImbibManuscriptId: String?
    public let linkedImbibLibraryId: String?

    init(
        id: String, title: String, wordCount: Int?, lastModified: Date?, format: String?,
        authors: [String]?, status: String?, createdAt: Date?,
        linkedImbibManuscriptId: String?, linkedImbibLibraryId: String?
    ) {
        self.id = id
        self.title = title
        self.wordCount = wordCount
        self.lastModified = lastModified
        self.format = format
        self.authors = authors
        self.status = status
        self.createdAt = createdAt
        self.linkedImbibManuscriptId = linkedImbibManuscriptId
        self.linkedImbibLibraryId = linkedImbibLibraryId
    }
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

/// Full document metadata and source assembled from imprint's detail/content reads.
public struct DocumentContent: Codable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    public let wordCount: Int?
    public let format: String?
    public let authors: [String]?
    public let status: String?
    public let lastModified: Date?
    public let createdAt: Date?
    public let linkedImbibManuscriptId: String?
    public let linkedImbibLibraryId: String?

    init(record: VerbDocumentSummary, source: String) {
        self.id = record.id
        self.title = record.title
        self.source = source
        self.wordCount = source.split(whereSeparator: \.isWhitespace).count
        self.format = record.format
        self.authors = record.authors
        self.status = record.status
        self.lastModified = BridgeDate.parse(record.lastModified)
        self.createdAt = BridgeDate.parse(record.createdAt)
        self.linkedImbibManuscriptId = record.linkedImbibManuscriptId
        self.linkedImbibLibraryId = record.linkedImbibLibraryId
    }
}

enum BridgeDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: value)
    }
}
