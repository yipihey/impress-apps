import Foundation

/// Typed bridge for communicating with imbib (bibliography manager) via its HTTP API.
///
/// All methods use `SiblingBridge.shared` to send HTTP requests to imbib's
/// automation server on `localhost:23120` (see `/api/status` for health).
///
/// Response bodies are wrapped in `{status, ...}` envelopes on the server side;
/// this bridge unwraps them so callers see plain result types.
public struct ImbibBridge: Sendable {

    // MARK: - Availability

    /// Probe imbib's HTTP automation server. Returns true when `/api/status`
    /// responds with 200.
    public static func isAvailable() async -> Bool {
        await SiblingBridge.shared.isAvailable(.imbib)
    }

    // MARK: - Library search

    /// Search the imbib library for papers matching a query.
    ///
    /// The server endpoint is `GET /api/search?q=&limit=`. Empty `query` is
    /// treated as "list everything matching the other filters".
    public static func searchLibrary(query: String, limit: Int = 20) async throws -> [ImbibPaper] {
        let env: SearchEnvelope = try await SiblingBridge.shared.get(
            "/api/search",
            from: .imbib,
            query: ["q": query, "limit": String(limit)]
        )
        return env.papers
    }

    /// Get a single paper by cite key. Returns `nil` if not found.
    public static func getPaper(citeKey: String) async throws -> ImbibPaper? {
        let encoded = citeKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? citeKey
        do {
            let env: PaperEnvelope = try await SiblingBridge.shared.get(
                "/api/papers/\(encoded)",
                from: .imbib
            )
            return env.paper
        } catch SiblingBridgeError.httpError(statusCode: 404) {
            return nil
        }
    }

    // MARK: - External search

    /// Search external sources (ADS, arXiv, Crossref, PubMed, OpenAlex, …) for papers
    /// not already in the library. `source` restricts to a single provider when non-nil.
    public static func searchExternal(query: String, source: String? = nil, limit: Int = 20) async throws -> [ImbibExternalCandidate] {
        var q = ["q": query, "limit": String(limit)]
        if let source { q["source"] = source }
        let env: ExternalSearchEnvelope = try await SiblingBridge.shared.get(
            "/api/search/external",
            from: .imbib,
            query: q
        )
        return env.results
    }

    // MARK: - BibTeX export

    /// Export BibTeX for the given cite keys. Returns the concatenated
    /// `.bib` content string.
    public static func exportBibTeX(citeKeys: [String]) async throws -> String {
        guard !citeKeys.isEmpty else { return "" }
        let env: ExportEnvelope = try await SiblingBridge.shared.get(
            "/api/export",
            from: .imbib,
            query: ["keys": citeKeys.joined(separator: ","), "format": "bibtex"]
        )
        return env.content
    }

    // MARK: - Add to library

    /// Add papers to imbib by identifier (DOI, arXiv ID, ADS bibcode, PMID).
    ///
    /// Identifiers the server recognizes are auto-detected by
    /// `PaperIdentifier.fromString` (see `AutomationTypes.swift`). Passing a
    /// bare cite key like "smith2024" will not trigger an external fetch — use
    /// a DOI/arXiv/bibcode for papers not yet in the library.
    public static func addPapers(
        identifiers: [String],
        library: UUID? = nil,
        collection: UUID? = nil,
        downloadPDFs: Bool = false
    ) async throws -> AddPapersResult {
        let body = AddPapersRequest(
            identifiers: identifiers,
            library: library?.uuidString,
            collection: collection?.uuidString,
            downloadPDFs: downloadPDFs
        )
        return try await SiblingBridge.shared.post("/api/papers/add", to: .imbib, body: body)
    }

    // MARK: - Structured citation resolve

    /// Resolve a structured citation (typed input) via imbib's search stack.
    ///
    /// Delegates to `POST /api/papers/resolve` with the `citation` JSON field
    /// set. Imbib handles LaTeX decoding, identifier extraction, local
    /// lookup, identifier-based import, and a ranked ADS-first / all-sources
    /// fallback search — the caller just hands over structured fields and
    /// receives either a single paper or a ranked candidate list.
    ///
    /// See `ImbibCitationInput`, `ImbibResolveResponse` for shapes.
    public static func resolveCitation(
        _ input: ImbibCitationInput,
        library: UUID? = nil,
        downloadPDFs: Bool = false
    ) async throws -> ImbibResolveResponse {
        let body = ResolveRequest(
            citation: input,
            library: library?.uuidString,
            downloadPDFs: downloadPDFs
        )
        return try await SiblingBridge.shared.post(
            "/api/papers/resolve",
            to: .imbib,
            body: body
        )
    }

    // MARK: - Library & collection listing

    /// List all libraries. `isInbox`-flagged libraries are included — filter client-side
    /// if you want to hide them from a picker.
    public static func listLibraries() async throws -> [ImbibLibrary] {
        let env: LibrariesEnvelope = try await SiblingBridge.shared.get(
            "/api/libraries",
            from: .imbib
        )
        return env.libraries
    }

    /// List all collections. Smart-collections are included; filter client-side if needed.
    public static func listCollections() async throws -> [ImbibCollection] {
        let env: CollectionsEnvelope = try await SiblingBridge.shared.get(
            "/api/collections",
            from: .imbib
        )
        return env.collections
    }

    /// Create a new library and return its id.
    public static func createLibrary(name: String) async throws -> UUID {
        let body = CreateLibraryRequest(name: name)
        let env: CreateLibraryResponse = try await SiblingBridge.shared.post(
            "/api/libraries",
            to: .imbib,
            body: body
        )
        guard let id = UUID(uuidString: env.library.id) else {
            throw SiblingBridgeError.invalidResponse
        }
        return id
    }
}

// MARK: - Public result types

/// A paper from the imbib library — search hit, detail lookup, and add-papers
/// result all share this shape (the server uses one `paperToDict` helper).
///
/// Server-side shape inconsistency: `/api/search` returns `authors` as a
/// joined string, while `/api/papers/add` returns it as `[String]`. The
/// decoder tolerates both and normalizes to a `String` (comma-joined).
public struct ImbibPaper: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let citeKey: String
    public let title: String
    public let authors: String
    public let year: Int?
    public let venue: String?
    public let abstract: String?
    public let doi: String?
    public let arxivID: String?
    public let bibcode: String?
    public let pmid: String?
    public let bibtex: String?
    public let hasPDF: Bool?
    public let isRead: Bool?
    public let isStarred: Bool?
    public let tags: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, citeKey, title, authors, year, venue, abstract
        case doi, arxivID, bibcode, pmid, bibtex
        case hasPDF, isRead, isStarred, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? ""
        self.citeKey = (try? c.decode(String.self, forKey: .citeKey)) ?? ""
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        // `authors` may be a String (from /api/search) or [String] (from
        // /api/papers/add). Normalize to a comma-joined string.
        if let single = try? c.decode(String.self, forKey: .authors) {
            self.authors = single
        } else if let many = try? c.decode([String].self, forKey: .authors) {
            self.authors = many.joined(separator: ", ")
        } else {
            self.authors = ""
        }
        self.year = try c.decodeIfPresent(Int.self, forKey: .year)
        self.venue = try c.decodeIfPresent(String.self, forKey: .venue)
        self.abstract = try c.decodeIfPresent(String.self, forKey: .abstract)
        self.doi = try c.decodeIfPresent(String.self, forKey: .doi)
        self.arxivID = try c.decodeIfPresent(String.self, forKey: .arxivID)
        self.bibcode = try c.decodeIfPresent(String.self, forKey: .bibcode)
        self.pmid = try c.decodeIfPresent(String.self, forKey: .pmid)
        self.bibtex = try c.decodeIfPresent(String.self, forKey: .bibtex)
        self.hasPDF = try c.decodeIfPresent(Bool.self, forKey: .hasPDF)
        self.isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead)
        self.isStarred = try c.decodeIfPresent(Bool.self, forKey: .isStarred)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(citeKey, forKey: .citeKey)
        try c.encode(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(venue, forKey: .venue)
        try c.encodeIfPresent(abstract, forKey: .abstract)
        try c.encodeIfPresent(doi, forKey: .doi)
        try c.encodeIfPresent(arxivID, forKey: .arxivID)
        try c.encodeIfPresent(bibcode, forKey: .bibcode)
        try c.encodeIfPresent(pmid, forKey: .pmid)
        try c.encodeIfPresent(bibtex, forKey: .bibtex)
        try c.encodeIfPresent(hasPDF, forKey: .hasPDF)
        try c.encodeIfPresent(isRead, forKey: .isRead)
        try c.encodeIfPresent(isStarred, forKey: .isStarred)
        try c.encodeIfPresent(tags, forKey: .tags)
    }

    /// Testing / synthetic-data initializer.
    public init(
        id: String,
        citeKey: String,
        title: String,
        authors: String,
        year: Int? = nil,
        venue: String? = nil,
        abstract: String? = nil,
        doi: String? = nil,
        arxivID: String? = nil,
        bibcode: String? = nil,
        pmid: String? = nil,
        bibtex: String? = nil,
        hasPDF: Bool? = nil,
        isRead: Bool? = nil,
        isStarred: Bool? = nil,
        tags: [String]? = nil
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.abstract = abstract
        self.doi = doi
        self.arxivID = arxivID
        self.bibcode = bibcode
        self.pmid = pmid
        self.bibtex = bibtex
        self.hasPDF = hasPDF
        self.isRead = isRead
        self.isStarred = isStarred
        self.tags = tags
    }
}

/// A candidate paper from external search (ADS / arXiv / Crossref / …) that is
/// not yet in the imbib library. Feed `identifier` to `addPapers` to import it.
///
/// The decoder tolerates two server response shapes:
///   - `authors`: a single joined string (what `/api/search` returns for
///     library hits), OR an array of strings (what `/api/search/external`
///     returns for ADS / Crossref / OpenAlex results).
///   - `identifier`: optional, since some sources don't produce a clean
///     `bestIdentifier` (e.g. a hit with no DOI/arXiv/bibcode). Falls back
///     to the sourceID + title when absent.
public struct ImbibExternalCandidate: Codable, Sendable, Identifiable, Hashable {
    public let title: String
    public let authors: String
    public let venue: String?
    public let abstract: String?
    public let year: Int?
    public let sourceID: String
    /// Best identifier the source could produce (DOI preferred, then arXiv,
    /// then bibcode). Empty string when the source didn't produce one —
    /// caller should treat that case as "can't import directly".
    public let identifier: String
    public let doi: String?
    public let arxivID: String?
    public let bibcode: String?

    public var id: String { identifier.isEmpty ? "\(sourceID):\(title)" : identifier }

    private enum CodingKeys: String, CodingKey {
        case title, authors, venue, abstract, year, sourceID, identifier, doi, arxivID, bibcode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        // authors may be a String or [String]
        if let single = try? c.decode(String.self, forKey: .authors) {
            self.authors = single
        } else if let many = try? c.decode([String].self, forKey: .authors) {
            self.authors = many.joined(separator: ", ")
        } else {
            self.authors = ""
        }
        self.venue = try c.decodeIfPresent(String.self, forKey: .venue)
        self.abstract = try c.decodeIfPresent(String.self, forKey: .abstract)
        self.year = try c.decodeIfPresent(Int.self, forKey: .year)
        self.sourceID = (try? c.decode(String.self, forKey: .sourceID)) ?? ""
        self.identifier = (try? c.decode(String.self, forKey: .identifier)) ?? ""
        self.doi = try c.decodeIfPresent(String.self, forKey: .doi)
        self.arxivID = try c.decodeIfPresent(String.self, forKey: .arxivID)
        self.bibcode = try c.decodeIfPresent(String.self, forKey: .bibcode)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(venue, forKey: .venue)
        try c.encodeIfPresent(abstract, forKey: .abstract)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(identifier, forKey: .identifier)
        try c.encodeIfPresent(doi, forKey: .doi)
        try c.encodeIfPresent(arxivID, forKey: .arxivID)
        try c.encodeIfPresent(bibcode, forKey: .bibcode)
    }

    /// Testing / synthetic-data initializer.
    public init(
        title: String, authors: String, venue: String? = nil, abstract: String? = nil,
        year: Int? = nil, sourceID: String = "", identifier: String = "",
        doi: String? = nil, arxivID: String? = nil, bibcode: String? = nil
    ) {
        self.title = title; self.authors = authors; self.venue = venue; self.abstract = abstract
        self.year = year; self.sourceID = sourceID; self.identifier = identifier
        self.doi = doi; self.arxivID = arxivID; self.bibcode = bibcode
    }
}

/// A library in imbib.
public struct ImbibLibrary: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let paperCount: Int?
    public let collectionCount: Int?
    public let isDefault: Bool?
    public let isInbox: Bool?
    public let isShared: Bool?
}

/// A collection in imbib.
public struct ImbibCollection: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let paperCount: Int?
    public let isSmartCollection: Bool?
    public let libraryID: String?
    public let libraryName: String?
}

/// Result of a `POST /api/papers/add` call.
public struct AddPapersResult: Codable, Sendable {
    public let added: [ImbibPaper]
    public let duplicates: [String]
    public let failed: [Failed]

    public struct Failed: Codable, Sendable, Hashable {
        public let identifier: String?
        public let error: String?
    }

    public var addedCount: Int { added.count }
    public var duplicateCount: Int { duplicates.count }
    public var failedCount: Int { failed.count }

    private enum CodingKeys: String, CodingKey { case added, duplicates, failed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.added = try c.decodeIfPresent([ImbibPaper].self, forKey: .added) ?? []
        // `duplicates` may be a bare [String] of cite keys or [dict]; tolerate both.
        if let s = try? c.decodeIfPresent([String].self, forKey: .duplicates) {
            self.duplicates = s
        } else if let rows = try? c.decodeIfPresent([[String: String]].self, forKey: .duplicates) {
            self.duplicates = rows.compactMap { $0["citeKey"] ?? $0["identifier"] }
        } else {
            self.duplicates = []
        }
        // `failed` is typically [{identifier, error}] but may be [String] on older builds.
        if let rows = try? c.decodeIfPresent([Failed].self, forKey: .failed) {
            self.failed = rows
        } else if let s = try? c.decodeIfPresent([String].self, forKey: .failed) {
            self.failed = s.map { Failed(identifier: $0, error: nil) }
        } else {
            self.failed = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(added, forKey: .added)
        try c.encode(duplicates, forKey: .duplicates)
        try c.encode(failed, forKey: .failed)
    }
}

// MARK: - Structured citation resolve

/// Structured input for `ImbibBridge.resolveCitation`. Mirrors imbib's
/// `CitationInput` shape — leave fields unsanitized (the server decodes
/// LaTeX accents, quotes author names for ADS, etc.).
public struct ImbibCitationInput: Codable, Sendable, Hashable {
    public var authors: [String]
    public var title: String?
    public var year: Int?
    public var journal: String?
    public var volume: String?
    public var pages: String?
    public var doi: String?
    public var arxiv: String?
    public var bibcode: String?
    public var rawBibtex: String?
    public var freeText: String?
    /// `"astronomy"`, `"physics"`, `"arxiv"`, or `"all"`.
    public var preferredDatabase: String?

    public init(
        authors: [String] = [],
        title: String? = nil,
        year: Int? = nil,
        journal: String? = nil,
        volume: String? = nil,
        pages: String? = nil,
        doi: String? = nil,
        arxiv: String? = nil,
        bibcode: String? = nil,
        rawBibtex: String? = nil,
        freeText: String? = nil,
        preferredDatabase: String? = nil
    ) {
        self.authors = authors
        self.title = title
        self.year = year
        self.journal = journal
        self.volume = volume
        self.pages = pages
        self.doi = doi
        self.arxiv = arxiv
        self.bibcode = bibcode
        self.rawBibtex = rawBibtex
        self.freeText = freeText
        self.preferredDatabase = preferredDatabase
    }

    /// True when any of the three identifier fields (DOI / arXiv id /
    /// ADS bibcode) is set and non-empty.
    public var hasIdentifier: Bool {
        !(doi ?? "").isEmpty || !(arxiv ?? "").isEmpty || !(bibcode ?? "").isEmpty
    }
}

/// A ranked external candidate returned by structured citation resolution.
/// Like `ImbibExternalCandidate` but carries a confidence score.
public struct ImbibRankedCandidate: Codable, Sendable, Identifiable, Hashable {
    public let title: String
    public let authors: String
    public let venue: String?
    public let abstract: String?
    public let year: Int?
    public let sourceID: String
    public let identifier: String
    public let doi: String?
    public let arxivID: String?
    public let bibcode: String?
    /// 0.0–1.0. Higher = better match to the input query.
    public let confidence: Double

    public var id: String { identifier.isEmpty ? "\(sourceID):\(title)" : identifier }

    /// Convert to an `ImbibExternalCandidate` for callers that already
    /// render unranked candidates (e.g. the existing picker UI).
    public var asExternalCandidate: ImbibExternalCandidate {
        ImbibExternalCandidate(
            title: title,
            authors: authors,
            venue: venue,
            abstract: abstract,
            year: year,
            sourceID: sourceID,
            identifier: identifier,
            doi: doi,
            arxivID: arxivID,
            bibcode: bibcode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title, authors, venue, abstract, year, sourceID, identifier, doi, arxivID, bibcode, confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        if let single = try? c.decode(String.self, forKey: .authors) {
            self.authors = single
        } else if let many = try? c.decode([String].self, forKey: .authors) {
            self.authors = many.joined(separator: ", ")
        } else {
            self.authors = ""
        }
        self.venue = try c.decodeIfPresent(String.self, forKey: .venue)
        self.abstract = try c.decodeIfPresent(String.self, forKey: .abstract)
        self.year = try c.decodeIfPresent(Int.self, forKey: .year)
        self.sourceID = (try? c.decode(String.self, forKey: .sourceID)) ?? ""
        self.identifier = (try? c.decode(String.self, forKey: .identifier)) ?? ""
        self.doi = try c.decodeIfPresent(String.self, forKey: .doi)
        self.arxivID = try c.decodeIfPresent(String.self, forKey: .arxivID)
        self.bibcode = try c.decodeIfPresent(String.self, forKey: .bibcode)
        self.confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(venue, forKey: .venue)
        try c.encodeIfPresent(abstract, forKey: .abstract)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(identifier, forKey: .identifier)
        try c.encodeIfPresent(doi, forKey: .doi)
        try c.encodeIfPresent(arxivID, forKey: .arxivID)
        try c.encodeIfPresent(bibcode, forKey: .bibcode)
        try c.encode(confidence, forKey: .confidence)
    }
}

/// Response from `ImbibBridge.resolveCitation`. Exactly one of `paper` or
/// `candidates` is typically set. `via` names the cascade branch taken,
/// useful for logging: `local-identifier`, `local-text`,
/// `imported-identifier`, `ads-high-confidence`, `ads-candidates`,
/// `all-sources-fallback`, `duplicate`, `not-found`.
public struct ImbibResolveResponse: Decodable, Sendable {
    public let status: String?
    public let via: String
    public let paper: ImbibPaper?
    public let candidates: [ImbibRankedCandidate]?
    public let reason: String?

    public init(
        status: String? = "ok",
        via: String,
        paper: ImbibPaper? = nil,
        candidates: [ImbibRankedCandidate]? = nil,
        reason: String? = nil
    ) {
        self.status = status
        self.via = via
        self.paper = paper
        self.candidates = candidates
        self.reason = reason
    }
}

// MARK: - Request bodies

private struct ResolveRequest: Encodable, Sendable {
    let citation: ImbibCitationInput
    let library: String?
    let downloadPDFs: Bool

    private enum CodingKeys: String, CodingKey {
        case citation, library
        case downloadPDFs = "download_pdfs"
    }
}

private struct AddPapersRequest: Encodable, Sendable {
    let identifiers: [String]
    let library: String?
    let collection: String?
    let downloadPDFs: Bool
}

private struct CreateLibraryRequest: Encodable, Sendable {
    let name: String
}

// MARK: - Response envelopes (internal)

private struct SearchEnvelope: Decodable, Sendable {
    let papers: [ImbibPaper]
}

private struct PaperEnvelope: Decodable, Sendable {
    let paper: ImbibPaper
}

private struct ExternalSearchEnvelope: Decodable, Sendable {
    let results: [ImbibExternalCandidate]
}

private struct ExportEnvelope: Decodable, Sendable {
    let content: String
}

private struct LibrariesEnvelope: Decodable, Sendable {
    let libraries: [ImbibLibrary]
}

private struct CollectionsEnvelope: Decodable, Sendable {
    let collections: [ImbibCollection]
}

private struct CreateLibraryResponse: Decodable, Sendable {
    let library: ImbibLibrary
}
