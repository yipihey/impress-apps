import Foundation

/// Typed bridge for communicating with imbib (bibliography manager).
///
/// Methods backed by generated service capabilities use `SiblingBridge`'s
/// authenticated loopback verb transport. Remaining legacy reads are being
/// migrated separately.
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
        try await searchExternal(query: query, source: source, limit: limit, using: .shared)
    }

    static func searchExternal(
        query: String,
        source: String?,
        limit: Int,
        using bridge: SiblingBridge
    ) async throws -> [ImbibExternalCandidate] {
        let papers: [ExternalPaperVerbResult] = try await bridge.callVerb(
            "imbib-app-service_search-sources",
            on: .imbib,
            arguments: ["query": query, "sources": source.map { $0 as Any } ?? NSNull(), "limit": limit]
        )
        return papers.map(\.candidate)
    }

    // MARK: - BibTeX export

    /// Export BibTeX for the given cite keys. Returns the concatenated
    /// `.bib` content string.
    public static func exportBibTeX(citeKeys: [String]) async throws -> String {
        guard !citeKeys.isEmpty else { return "" }
        return try await SiblingBridge.shared.callVerb(
            "imbib-library-service_export-bibtex",
            on: .imbib,
            arguments: ["ids": citeKeys]
        )
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
        try await addPapers(
            identifiers: identifiers,
            library: library,
            collection: collection,
            downloadPDFs: downloadPDFs,
            using: .shared
        )
    }

    static func addPapers(
        identifiers: [String],
        library: UUID?,
        collection: UUID?,
        downloadPDFs: Bool,
        using bridge: SiblingBridge
    ) async throws -> AddPapersResult {
        let wire: IdentifierImportVerbResult = try await bridge.callVerb(
            "imbib-library-service_import-identifiers",
            on: .imbib,
            arguments: [
                "identifiers": identifiers,
                "library_id": library.map { $0.uuidString as Any } ?? NSNull(),
                "collection_id": collection.map { $0.uuidString as Any } ?? NSNull(),
                "download_pdfs": downloadPDFs
            ]
        )
        return AddPapersResult(
            added: wire.added,
            rawAddedRecords: wire.rawAddedRecords,
            duplicates: wire.duplicates,
            failed: wire.failed.map { AddPapersResult.Failed(identifier: $0.key, error: $0.value) }
        )
    }

    // MARK: - Structured citation resolve

    /// Resolve a structured citation (typed input) via imbib's search stack.
    ///
    /// Delegates to imbib's generated app-service capability with the
    /// structured `citation` field set. Imbib handles LaTeX decoding, identifier extraction, local
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
        try await resolveCitation(input, library: library, downloadPDFs: downloadPDFs, using: .shared)
    }

    static func resolveCitation(
        _ input: ImbibCitationInput,
        library: UUID?,
        downloadPDFs: Bool,
        using bridge: SiblingBridge
    ) async throws -> ImbibResolveResponse {
        let citation = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        return try await bridge.callVerb(
            "imbib-app-service_resolve-citation",
            on: .imbib,
            arguments: [
                "query": NSNull(),
                "bibtex": NSNull(),
                "citation": citation,
                "library_id": library.map { $0.uuidString as Any } ?? NSNull(),
                "download_pdfs": downloadPDFs
            ]
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
        let created: CreatedLibraryID? = try await SiblingBridge.shared.callVerb(
            "imbib-library-service_create-library",
            on: .imbib,
            arguments: ["name": name]
        )
        guard let id = created.flatMap({ UUID(uuidString: $0.id) }) else {
            throw SiblingBridgeError.invalidResponse
        }
        return id
    }
}

private struct CreatedLibraryID: Decodable, Sendable {
    let id: String
}

// MARK: - Public result types

/// A paper from the imbib library — search hit, detail lookup, and add-papers
/// result all share this shape (the server uses one `paperToDict` helper).
///
/// `authors` arrives as a `[String]` (one "Family, Given" per author) or as an
/// already-joined string, and is normalized to imbib's own author text,
/// "Family, Given; Family, Given". Joined on ", ", the boundary between two
/// authors would be indistinguishable from the comma inside each name.
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
        // `authors` may be a String or a [String]; see the type's doc comment.
        if let single = try? c.decode(String.self, forKey: .authors) {
            self.authors = single
        } else if let many = try? c.decode([String].self, forKey: .authors) {
            self.authors = many.joined(separator: "; ")
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
///   - `authors`: a single joined string (what the library search returns), OR
///     an array of strings (what the generated external search returns).
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

/// Result of imbib's identifier-import capability.
public struct AddPapersResult: Codable, Sendable {
    public let added: [ImbibPaper]
    /// Complete result dictionaries returned by imbib, including fields that
    /// the stable `ImbibPaper` convenience model does not currently expose.
    public let rawAddedRecords: [ImbibRawJSON]
    public let duplicates: [String]
    public let failed: [Failed]

    public struct Failed: Codable, Sendable, Hashable {
        public let identifier: String?
        public let error: String?
    }

    public var addedCount: Int { added.count }
    public var duplicateCount: Int { duplicates.count }
    public var failedCount: Int { failed.count }

    init(added: [ImbibPaper], rawAddedRecords: [ImbibRawJSON], duplicates: [String], failed: [Failed]) {
        self.added = added
        self.rawAddedRecords = rawAddedRecords
        self.duplicates = duplicates
        self.failed = failed
    }

    private enum CodingKeys: String, CodingKey { case added, duplicates, failed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.added = try c.decodeIfPresent([ImbibPaper].self, forKey: .added) ?? []
        self.rawAddedRecords = try c.decodeIfPresent([ImbibRawJSON].self, forKey: .added) ?? []
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
        if rawAddedRecords.isEmpty {
            try c.encode(added.map { try ImbibRawJSON.paper($0) }, forKey: .added)
        } else {
            try c.encode(rawAddedRecords, forKey: .added)
        }
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
    /// Complete server dictionaries. The typed fields above remain convenient
    /// for existing UI callers; these preserve route-specific metadata.
    public let rawPaper: ImbibRawJSON?
    public let rawCandidates: [ImbibRawJSON]?
    public let reason: String?

    public init(
        status: String? = "ok",
        via: String,
        paper: ImbibPaper? = nil,
        candidates: [ImbibRankedCandidate]? = nil,
        rawPaper: ImbibRawJSON? = nil,
        rawCandidates: [ImbibRawJSON]? = nil,
        reason: String? = nil
    ) {
        self.status = status
        self.via = via
        self.paper = paper
        self.candidates = candidates
        self.rawPaper = rawPaper
        self.rawCandidates = rawCandidates
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        via = try container.decode(String.self, forKey: .via)
        rawPaper = try container.decodeIfPresent(ImbibRawJSON.self, forKey: .paper)
        rawCandidates = try container.decodeIfPresent([ImbibRawJSON].self, forKey: .candidates)
        paper = try container.decodeIfPresent(ImbibPaper.self, forKey: .paper)
        candidates = try container.decodeIfPresent([ImbibRankedCandidate].self, forKey: .candidates)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey { case status, via, paper, candidates, reason }
}

/// JSON value used where generated service results intentionally preserve an
/// open dictionary. This keeps newer server fields available without forcing
/// every caller to understand their shape.
public enum ImbibRawJSON: Codable, Sendable, Hashable {
    case object([String: ImbibRawJSON])
    case array([ImbibRawJSON])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicKey.self) {
            var object: [String: ImbibRawJSON] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(ImbibRawJSON.self, forKey: key)
            }
            self = .object(object)
        } else if var container = try? decoder.unkeyedContainer() {
            var values: [ImbibRawJSON] = []
            while !container.isAtEnd { values.append(try container.decode(ImbibRawJSON.self)) }
            self = .array(values)
        } else {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int64.self) { self = .integer(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else { self = .string(try container.decode(String.self)) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicKey(stringValue: key)!)
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .string(let value): var container = encoder.singleValueContainer(); try container.encode(value)
        case .integer(let value): var container = encoder.singleValueContainer(); try container.encode(value)
        case .number(let value): var container = encoder.singleValueContainer(); try container.encode(value)
        case .bool(let value): var container = encoder.singleValueContainer(); try container.encode(value)
        case .null: var container = encoder.singleValueContainer(); try container.encodeNil()
        }
    }

    fileprivate static func paper(_ paper: ImbibPaper) throws -> ImbibRawJSON {
        try JSONDecoder().decode(ImbibRawJSON.self, from: JSONEncoder().encode(paper))
    }
}

private struct DynamicKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

// MARK: - Response envelopes (internal)

private struct SearchEnvelope: Decodable, Sendable {
    let papers: [ImbibPaper]
}

private struct PaperEnvelope: Decodable, Sendable {
    let paper: ImbibPaper
}

private struct ExternalPaperVerbResult: Decodable, Sendable {
    let title: String
    let identifier: String?
    let authors: [String]
    let year: Int?
    let venue: String?
    let doi: String?
    let arxivID: String?
    let bibcode: String?
    let abstractText: String?
    let source: String?

    private enum CodingKeys: String, CodingKey {
        case title, identifier, authors, year, venue, doi, bibcode, source
        case arxivID = "arxiv_id"
        case abstractText = "abstract_text"
    }

    var candidate: ImbibExternalCandidate {
        ImbibExternalCandidate(
            title: title,
            authors: authors.joined(separator: ", "),
            venue: venue,
            abstract: abstractText,
            year: year,
            sourceID: source ?? "",
            identifier: identifier ?? "",
            doi: doi,
            arxivID: arxivID,
            bibcode: bibcode
        )
    }
}

private struct IdentifierImportVerbResult: Decodable, Sendable {
    let added: [ImbibPaper]
    let rawAddedRecords: [ImbibRawJSON]
    let duplicates: [String]
    let failed: [String: String]

    private enum CodingKeys: String, CodingKey { case added, duplicates, failed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawAddedRecords = try container.decodeIfPresent([ImbibRawJSON].self, forKey: .added) ?? []
        added = try container.decodeIfPresent([ImbibPaper].self, forKey: .added) ?? []
        duplicates = try container.decodeIfPresent([String].self, forKey: .duplicates) ?? []
        failed = try container.decodeIfPresent([String: String].self, forKey: .failed) ?? [:]
    }
}

private struct LibrariesEnvelope: Decodable, Sendable {
    let libraries: [ImbibLibrary]
}

private struct CollectionsEnvelope: Decodable, Sendable {
    let collections: [ImbibCollection]
}
