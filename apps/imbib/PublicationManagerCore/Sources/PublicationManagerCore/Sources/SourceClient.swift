//
//  SourceClient.swift
//  PublicationManagerCore
//
//  The GUI's one client of the online databases (source convention S6,
//  koine docs/plan-source-convention.md): every search, fetch, export and
//  related-works walk is a Rust verb — `imbib-sources-service_search-sources`,
//  `bib-source-service_{fetch, related, export}`,
//  `imbib-sources-service_source-status` — called through the app's verb FFI.
//  Nothing here decides anything about a source: it hands the verb its
//  arguments and reads the `bibliographic-work@1.0.0` rows back into the
//  `SearchResult` / `PaperStub` the views already render.
//
//  The Swift `SourcePlugin` tree this replaces (seven adapters, their
//  parsers, `SourceClient`'s credential filtering) is gone: the adapters
//  are koine's `source-*` crates, their secrets are pushed into Rust memory
//  by `SourceSecrets.push`, and the same verbs answer the MCP server, the
//  CLI and the daemons with the app closed.
//

import Foundation
import ImbibVerbsFFI
import OSLog

// MARK: - Verb call

/// What one verb call answered: the pipeline's `ok`, the body as JSON, and
/// the refusal's code and message when it refused.
public struct VerbReply: Sendable {
    public let ok: Bool
    public let bodyJSON: String
    public let code: String?
    public let message: String?

    public init(ok: Bool, bodyJSON: String, code: String? = nil, message: String? = nil) {
        self.ok = ok
        self.bodyJSON = bodyJSON
        self.code = code
        self.message = message
    }

    /// The body parsed, or `nil` when it is not JSON.
    public var body: Any? {
        try? JSONSerialization.jsonObject(with: Data(bodyJSON.utf8), options: [.fragmentsAllowed])
    }
}

// MARK: - Source client

/// The verb-backed client. An actor so callers keep the `await` shape the
/// `SourceClient` actor had; it holds no state but the caller.
public actor SourceClient {

    /// One verb call as the person: `(verb name, args as JSON) → reply`.
    public typealias Call = @Sendable (_ verb: String, _ argsJSON: String) async -> VerbReply

    private let call: Call

    /// - Parameter call: how a verb is reached. The default is the app's
    ///   in-process verb FFI (`dispatchVerbAsync`, the same dispatcher the
    ///   HTTP `/api/verb/<name>` surface uses); a test passes a stub.
    public init(call: Call? = nil) {
        self.call = call ?? Self.dispatchThroughFFI
    }

    /// The in-process dispatcher. The store must have been initialized
    /// (`ImbibNativeVerbs.install`), which the app does at launch; before
    /// that every call is refused `store-unavailable`.
    public static let dispatchThroughFFI: Call = { name, argsJSON in
        let caller = "{\"kind\":\"person\",\"name\":\"imbib-gui\",\"trace_id\":\"\(UUID().uuidString)\"}"
        let result = await dispatchVerbAsync(name: name, argsJson: argsJSON, callerJson: caller)
        let object = (try? JSONSerialization.jsonObject(
            with: Data(result.bodyJson.utf8), options: [.fragmentsAllowed])) as? [String: Any]
        let refused = !(200..<300).contains(Int(result.status)) || (object?["ok"] as? Bool == false)
        if refused {
            return VerbReply(
                ok: false,
                bodyJSON: result.bodyJson,
                code: object?["code"] as? String ?? "verb-failed",
                message: object?["message"] as? String ?? "\(name) refused"
            )
        }
        return VerbReply(ok: true, bodyJSON: result.bodyJson)
    }

    // MARK: - Calling

    private func invoke(_ verb: String, _ args: [String: Any]) async throws -> Any {
        let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        let reply = await call(verb, String(decoding: data, as: UTF8.self))
        guard reply.ok else {
            let code = reply.code ?? "verb-failed"
            let message = reply.message ?? "\(verb) refused"
            Logger.sources.warningCapture("\(verb) refused: \(code): \(message)", category: "sources")
            throw Self.error(code: code, message: message)
        }
        return reply.body ?? NSNull()
    }

    /// A refusal as the `SourceError` the callers already handle.
    static func error(code: String, message: String) -> SourceError {
        switch code {
        case "secret-missing", "unauthorized", "forbidden":
            let source = message.split(separator: " ").first.map(String.init) ?? "source"
            return .authenticationRequired(source)
        case "not-found":
            return .notFound(message)
        case "invalid-argument":
            return .invalidRequest(message)
        case "rate-limited":
            return .rateLimited(retryAfter: nil)
        case "store-unavailable":
            return .invalidResponse(message)
        default:
            return .parseError(message)
        }
    }

    // MARK: - Search

    /// One federated search (`imbib-sources-service_search-sources`): words,
    /// an identifier, an ADS-native string, or an arXiv API string (the
    /// verb translates it clause by clause). `options.sourceIDs` scopes it;
    /// nil asks every source whose explain record covers the query.
    public func search(
        query: String,
        options: SearchOptions = .default
    ) async throws -> [SearchResult] {
        var args: [String: Any] = [
            "query": query,
            "limit": max(1, min(options.maxResults, 100)),
        ]
        if let ids = options.sourceIDs, !ids.isEmpty {
            args["sources"] = ids.joined(separator: ",")
        }
        if let sort = options.sortOrder.verbSort {
            args["sort"] = sort
        }
        let sources = options.sourceIDs?.joined(separator: ",") ?? "all"
        Logger.sources.infoCapture(
            "search-sources requested: sources=\(sources) limit=\(options.maxResults) query=\(query.prefix(120))",
            category: "sources"
        )
        let body = try await invoke("imbib-sources-service_search-sources", args)
        let rows = (body as? [[String: Any]]) ?? []
        let results = rows.compactMap(Self.searchResult(fromExternalPaper:))
        Logger.sources.infoCapture(
            "search-sources answered: \(results.count) row(s) from [\(Set(results.map(\.sourceID)).sorted().joined(separator: ", "))]",
            category: "sources"
        )
        return results
    }

    /// Search one source.
    public func search(
        query: String,
        sourceID: String,
        maxResults: Int = 50
    ) async throws -> [SearchResult] {
        try await search(query: query, options: SearchOptions(maxResults: maxResults, sourceIDs: [sourceID]))
    }

    // MARK: - Fetch

    /// One record by a canonical identifier (`doi:…`, `arXiv:…`, `bibcode:…`,
    /// `pmid:…`, a bare DOI) through `bib-source-service_fetch`, merged
    /// across the sources that claim it; `sources` narrows them. `nil` when
    /// no source has it.
    public func fetchWork(id: String, sources: [String]? = nil) async throws -> SearchResult? {
        var args: [String: Any] = ["id": id]
        if let sources, !sources.isEmpty { args["sources"] = sources }
        Logger.sources.infoCapture("fetch requested: id=\(id) sources=\(sources?.joined(separator: ",") ?? "any")", category: "sources")
        do {
            let body = try await invoke("bib-source-service_fetch", args)
            guard let answer = body as? [String: Any], let work = answer["work"] as? [String: Any] else {
                return nil
            }
            let result = Self.searchResult(fromWork: work)
            Logger.sources.infoCapture("fetch answered: \(id) from \(result?.sourceID ?? "?")", category: "sources")
            return result
        } catch SourceError.notFound {
            Logger.sources.infoCapture("fetch answered: \(id) not found", category: "sources")
            return nil
        }
    }

    /// The locations of one record (`fetch`): where each version of the work
    /// can be had — landing `url`, `pdf`, `version`, `license`, `oa_status`.
    /// Empty when no source has the id.
    public func fetchLocations(id: String, sources: [String]? = nil) async throws -> [WorkLocation] {
        var args: [String: Any] = ["id": id]
        if let sources, !sources.isEmpty { args["sources"] = sources }
        do {
            let body = try await invoke("bib-source-service_fetch", args)
            let work = (body as? [String: Any])?["work"] as? [String: Any]
            let locations = (work?["locations"] as? [[String: Any]] ?? []).compactMap(WorkLocation.init(dictionary:))
            Logger.sources.infoCapture("fetch \(id): \(locations.count) location(s), \(locations.filter { $0.pdf != nil }.count) with a PDF", category: "sources")
            return locations
        } catch SourceError.notFound {
            return []
        }
    }

    // MARK: - BibTeX

    /// The source's own BibTeX for a search result (`bib-source-service_export
    /// bibtex`), asked by the identifier its source claims first.
    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        var ids: [String] = []
        func push(_ kind: String, _ value: String?) {
            if let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty { ids.append("\(kind):\(v)") }
        }
        switch result.sourceID {
        case "ads", "scix":
            push("bibcode", result.bibcode); push("doi", result.doi); push("arxiv", result.arxivID)
        case "arxiv":
            push("arxiv", result.arxivID); push("doi", result.doi)
        default:
            push("doi", result.doi); push("arxiv", result.arxivID); push("bibcode", result.bibcode); push("pmid", result.pmid)
        }
        guard !ids.isEmpty else {
            throw SourceError.notFound("No identifier to export for \(result.title.prefix(60))")
        }
        var last: Error = SourceError.notFound("No source exported BibTeX for \(ids.joined(separator: ", "))")
        for id in ids {
            do {
                return try await fetchBibTeX(id: id)
            } catch {
                last = error
            }
        }
        throw last
    }

    /// The source's own BibTeX for one canonical identifier.
    public func fetchBibTeX(id: String) async throws -> BibTeXEntry {
        let body = try await invoke("bib-source-service_export", ["ids": [id], "format": "bibtex"])
        guard let answer = body as? [String: Any],
              let text = answer["text"] as? String,
              (answer["count"] as? Int ?? 0) > 0,
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@") else {
            let diagnostics = ((body as? [String: Any])?["diagnostics"] as? [[String: Any]] ?? [])
                .map { "\($0["source"] ?? "?") \($0["status"] ?? "?") \($0["detail"] ?? "")" }
                .joined(separator: "; ")
            Logger.sources.infoCapture("export \(id): no BibTeX (\(diagnostics))", category: "sources")
            throw SourceError.notFound("No BibTeX for \(id)")
        }
        let entries = try BibTeXParserFactory.createParser().parseEntries(text)
        guard let entry = entries.first else {
            throw SourceError.parseError("No entry in the BibTeX for \(id)")
        }
        Logger.sources.infoCapture("export \(id): BibTeX \(entry.citeKey)", category: "sources")
        return entry
    }

    // MARK: - Related works

    /// Works related to an identifier by `relation` (`cites`: its
    /// references; `cited_by`: what cites it; `similar`; `coreads`), through
    /// `bib-source-service_related`, from the sources that claim the id.
    public func related(
        id: String,
        relation: RelatedRelation,
        limit: Int = 200
    ) async throws -> [PaperStub] {
        let args: [String: Any] = ["id": id, "relation": relation.rawValue, "limit": max(1, min(limit, 100))]
        Logger.sources.infoCapture("related requested: \(relation.rawValue) of \(id)", category: "sources")
        let body = try await invoke("bib-source-service_related", args)
        let answer = body as? [String: Any]
        let rows = answer?["rows"] as? [[String: Any]] ?? []
        for d in answer?["diagnostics"] as? [[String: Any]] ?? [] {
            Logger.sources.infoCapture("related \(relation.rawValue) of \(id): \(d["source"] ?? "?") \(d["status"] ?? "?") \(d["detail"] ?? "")", category: "sources")
        }
        let stubs = rows.compactMap(Self.paperStub(fromWork:))
        Logger.sources.infoCapture("related answered: \(stubs.count) \(relation.rawValue) of \(id)", category: "sources")
        return stubs
    }

    // MARK: - Import

    /// File a search result into a library with its provenance
    /// (`imbib-library-service_import-work`, source convention S-D5): the
    /// record the result carries is handed back; `source_id`, `ids_json` and
    /// `provenance_json` land on the row. `fetchBibTeX` asks the source for
    /// its own BibTeX (one export call); a feed filing many rows passes
    /// false and the BibTeX is synthesized from the record, marked as such.
    /// A result that carries no record (one built by hand) cannot be
    /// imported this way and is refused `invalid-argument`.
    public func importWork(
        _ result: SearchResult,
        library: UUID?,
        collection: UUID? = nil,
        fetchBibTeX: Bool
    ) async throws -> WorkImportOutcome {
        guard let workJSON = result.workJSON,
              let work = (try? JSONSerialization.jsonObject(with: Data(workJSON.utf8))) as? [String: Any] else {
            throw SourceError.invalidRequest("\(result.title.prefix(60)): no bibliographic-work record to import")
        }
        var args: [String: Any] = ["work": work, "fetch_bibtex": fetchBibTeX]
        if let library { args["library"] = library.uuidString.lowercased() }
        if let collection { args["collection"] = collection.uuidString.lowercased() }
        Logger.sources.infoCapture(
            "import-work requested: \(result.sourceID) \(result.primaryIdentifier ?? result.id) library=\(library?.uuidString.lowercased() ?? "default") fetch_bibtex=\(fetchBibTeX)",
            category: "sources"
        )
        let body = try await invoke("imbib-library-service_import-work", args)
        let outcome = WorkImportOutcome(dictionary: body as? [String: Any] ?? [:])
        Logger.sources.infoCapture(
            "import-work answered: imported=\(outcome.importedID?.uuidString.lowercased() ?? "-") existing=\(outcome.existingID?.uuidString.lowercased() ?? "-") dismissed=\(outcome.dismissed)",
            category: "sources"
        )
        if outcome.importedID != nil {
            // The verb wrote through its own store handle: tell the GUI's
            // adapter so the list re-reads (display half of the trace).
            await MainActor.run { RustStoreAdapter.shared.notifyMutationFromBackground() }
        }
        return outcome
    }

    // MARK: - Sources and credentials

    /// Every registered source, with what it needs
    /// (`imbib-sources-service_source-status`).
    public func sourceStatus() async -> [SourceStatusRecord] {
        do {
            let body = try await invoke("imbib-sources-service_source-status", [:])
            return (body as? [[String: Any]] ?? []).compactMap(SourceStatusRecord.init(dictionary:))
        } catch {
            Logger.sources.errorCapture("source-status failed: \(error.localizedDescription)", category: "sources")
            return []
        }
    }

    /// The registered sources as the search form lists them, by name.
    public var availableSources: [SourceMetadata] {
        get async {
            await sourceStatus().map(\.metadata).sorted { $0.name < $1.name }
        }
    }

    /// Whether a source can be asked: its required secrets are present.
    public func hasValidCredentials(for sourceID: String) async -> Bool {
        await sourceStatus().first(where: { $0.id == sourceID })?.status.isUsable ?? false
    }

    /// The Settings > Sources rows.
    public func credentialStatus() async -> [SourceCredentialInfo] {
        await sourceStatus().map(\.credentialInfo).sorted { $0.sourceName < $1.sourceName }
    }

    // MARK: - Rows → the views' shapes

    /// One `imbib-sources-service_search-sources` row.
    static func searchResult(fromExternalPaper row: [String: Any]) -> SearchResult? {
        guard let title = row["title"] as? String else { return nil }
        let ids = row["ids"] as? [String: String] ?? [:]
        let source = (row["source"] as? String) ?? (row["provenance"] as? [String: Any])?["source"] as? String ?? "unknown"
        let doi = (row["doi"] as? String) ?? ids["doi"]
        let arxiv = (row["arxiv_id"] as? String) ?? ids["arxiv"]
        let bibcode = (row["bibcode"] as? String) ?? ids["bibcode"]
        let locations = row["locations"] as? [[String: Any]] ?? []
        let sourceRecordID = (row["provenance"] as? [String: Any])?["source_id"] as? String
        return SearchResult(
            id: sourceRecordID ?? (row["identifier"] as? String) ?? doi ?? arxiv ?? bibcode ?? title,
            sourceID: source,
            title: title,
            authors: row["authors"] as? [String] ?? [],
            year: (row["year"] as? Int) ?? (row["year"] as? NSNumber)?.intValue,
            venue: row["venue"] as? String,
            abstract: row["abstract_text"] as? String,
            doi: doi,
            arxivID: arxiv,
            pmid: ids["pmid"],
            bibcode: bibcode,
            semanticScholarID: ids["s2"] ?? ids["semantic_scholar"],
            openAlexID: ids["openalex"],
            citationCount: (row["cited_by"] as? Int) ?? (row["cited_by"] as? NSNumber)?.intValue,
            workJSON: (row["work"] as? [String: Any]).flatMap(json(of:)),
            pdfLinks: pdfLinks(fromLocations: locations, source: source, doi: doi, arxivID: arxiv),
            webURL: webURL(fromLocations: locations, source: source, doi: doi, arxivID: arxiv, bibcode: bibcode)
        )
    }

    /// One `bibliographic-work@1.0.0` record (`fetch`, `related` rows).
    static func searchResult(fromWork work: [String: Any]) -> SearchResult? {
        guard let title = work["title"] as? String else { return nil }
        let ids = work["ids"] as? [String: String] ?? [:]
        let provenance = work["provenance"] as? [String: Any]
        let source = provenance?["source"] as? String
            ?? (work["locations"] as? [[String: Any]])?.first(where: { $0["primary"] as? Bool == true })?["source"] as? String
            ?? "unknown"
        let doi = (work["DOI"] as? String) ?? ids["doi"]
        let arxiv = ids["arxiv"]
        let bibcode = ids["bibcode"]
        let locations = work["locations"] as? [[String: Any]] ?? []
        return SearchResult(
            id: provenance?["source_id"] as? String ?? doi ?? arxiv ?? bibcode ?? title,
            sourceID: source,
            title: title,
            authors: authors(fromWork: work),
            year: year(fromWork: work),
            venue: work["container-title"] as? String,
            abstract: work["abstract"] as? String,
            doi: doi,
            arxivID: arxiv,
            pmid: ids["pmid"],
            bibcode: bibcode,
            semanticScholarID: ids["s2"] ?? ids["semantic_scholar"],
            openAlexID: ids["openalex"],
            citationCount: ((work["metrics"] as? [String: Any])?["cited_by"] as? [String: Any])?["value"] as? Int,
            workJSON: json(of: work),
            pdfLinks: pdfLinks(fromLocations: locations, source: source, doi: doi, arxivID: arxiv),
            webURL: (work["URL"] as? String).flatMap(URL.init(string:))
                ?? webURL(fromLocations: locations, source: source, doi: doi, arxivID: arxiv, bibcode: bibcode)
        )
    }

    /// One related-works row as the citation explorer's stub.
    static func paperStub(fromWork work: [String: Any]) -> PaperStub? {
        guard let title = work["title"] as? String else { return nil }
        let ids = work["ids"] as? [String: String] ?? [:]
        let provenance = work["provenance"] as? [String: Any]
        let doi = (work["DOI"] as? String) ?? ids["doi"]
        let citedBy = ((work["metrics"] as? [String: Any])?["cited_by"] as? [String: Any])?["value"] as? Int
        let oa = (work["locations"] as? [[String: Any]] ?? []).contains { ($0["oa_status"] as? String).map { $0 != "closed" } ?? false }
        return PaperStub(
            id: ids["bibcode"] ?? provenance?["source_id"] as? String ?? doi ?? ids["arxiv"] ?? title,
            title: title,
            authors: authors(fromWork: work),
            year: year(fromWork: work),
            venue: work["container-title"] as? String,
            doi: doi,
            arxivID: ids["arxiv"],
            citationCount: citedBy,
            referenceCount: nil,
            isOpenAccess: oa ? true : nil,
            abstract: work["abstract"] as? String
        )
    }

    static func json(of object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func authors(fromWork work: [String: Any]) -> [String] {
        (work["author"] as? [[String: Any]] ?? []).compactMap { a in
            let family = (a["family"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let given = (a["given"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            switch (family.isEmpty, given.isEmpty) {
            case (false, false): return "\(family), \(given)"
            case (false, true): return family
            case (true, false): return given
            case (true, true): return nil
            }
        }
    }

    static func year(fromWork work: [String: Any]) -> Int? {
        let issued = work["issued"] as? [String: Any]
        let parts = (issued?["date-parts"] ?? issued?["date_parts"]) as? [[Any]]
        return (parts?.first?.first as? Int) ?? (parts?.first?.first as? NSNumber)?.intValue
    }

    /// The PDF links the record's locations carry; the arXiv and DOI
    /// fallbacks the old ADS conversion built when a source listed none.
    static func pdfLinks(fromLocations locations: [[String: Any]], source: String, doi: String?, arxivID: String?) -> [PDFLink] {
        var links: [PDFLink] = []
        for location in locations {
            guard let pdf = location["pdf"] as? String, let url = URL(string: pdf) else { continue }
            let locSource = location["source"] as? String ?? source
            let version = location["version"] as? String
            let type: PDFLinkType = (locSource == "arxiv" || version == "submitted") ? .preprint : .publisher
            links.append(PDFLink(url: url, type: type, sourceID: locSource))
        }
        if links.isEmpty {
            if let arxivID, !arxivID.isEmpty, let url = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf") {
                links.append(PDFLink(url: url, type: .preprint, sourceID: source))
            }
            if let doi, !doi.isEmpty, let url = URL(string: "https://doi.org/\(doi)") {
                links.append(PDFLink(url: url, type: .publisher, sourceID: source))
            }
        }
        return links
    }

    static func webURL(fromLocations locations: [[String: Any]], source: String, doi: String?, arxivID: String?, bibcode: String?) -> URL? {
        if let primary = locations.first(where: { $0["primary"] as? Bool == true }) ?? locations.first,
           let url = primary["url"] as? String, let parsed = URL(string: url) {
            return parsed
        }
        if let bibcode, !bibcode.isEmpty {
            return URL(string: source == "scix" ? "https://scixplorer.org/abs/\(bibcode)" : "https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }
        if let arxivID, !arxivID.isEmpty { return URL(string: "https://arxiv.org/abs/\(arxivID)") }
        if let doi, !doi.isEmpty { return URL(string: "https://doi.org/\(doi)") }
        return nil
    }
}

// MARK: - Import outcome

/// What `imbib-library-service_import-work` did.
public struct WorkImportOutcome: Sendable, Equatable {
    /// The new row, when one was created.
    public let importedID: UUID?
    /// The row that already carried one of the work's identifiers.
    public let existingID: UUID?
    /// True when the work matched a dismissed paper and nothing was written.
    public let dismissed: Bool
    /// True when the row (new or existing) was filed into the collection asked for.
    public let addedToCollection: Bool

    init(dictionary d: [String: Any]) {
        importedID = (d["imported_id"] as? String).flatMap(UUID.init(uuidString:))
        existingID = (d["existing_id"] as? String).flatMap(UUID.init(uuidString:))
        dismissed = d["dismissed"] as? Bool ?? false
        addedToCollection = d["added_to_collection"] as? Bool ?? false
    }

    public init(importedID: UUID?, existingID: UUID?, dismissed: Bool = false, addedToCollection: Bool = false) {
        self.importedID = importedID
        self.existingID = existingID
        self.dismissed = dismissed
        self.addedToCollection = addedToCollection
    }
}

// MARK: - Work location

/// One `bibliographic-work@1.0.0` location.
public struct WorkLocation: Sendable, Equatable {
    public let source: String
    public let sourceID: String
    /// `submitted`, `accepted` or `published`.
    public let version: String
    public let url: URL?
    public let pdf: URL?
    public let license: String?
    public let oaStatus: String?
    public let primary: Bool

    init?(dictionary d: [String: Any]) {
        guard let source = d["source"] as? String else { return nil }
        self.source = source
        self.sourceID = d["source_id"] as? String ?? ""
        self.version = d["version"] as? String ?? "published"
        self.url = (d["url"] as? String).flatMap(URL.init(string:))
        self.pdf = (d["pdf"] as? String).flatMap(URL.init(string:))
        self.license = d["license"] as? String
        self.oaStatus = d["oa_status"] as? String
        self.primary = d["primary"] as? Bool ?? false
    }

    /// Open access by the source's own status (`closed` is the one no).
    public var isOpenAccess: Bool {
        guard let oaStatus else { return pdf != nil }
        return oaStatus != "closed"
    }
}

// MARK: - Related relation

/// The relations `bib-source-service_related` walks.
public enum RelatedRelation: String, Sendable, CaseIterable {
    /// The works this one cites (its references).
    case cites
    /// The works that cite this one.
    case citedBy = "cited_by"
    /// Works the source judges similar.
    case similar
    /// Works read together with this one (ADS's co-reads).
    case coreads
}

// MARK: - Source status

/// One `imbib-sources-service_source-status` row.
public struct SourceStatusRecord: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    /// `api-key`, `api-key-optional`, `email-optional` or `none`.
    public let requirement: String
    /// `valid`, `missing`, `optional-valid`, `optional-missing`, `not-required`.
    public let status: CredentialStatus
    public let secrets: [String]
    public let secretsPresent: [String]
    public let wantsContact: Bool
    public let contactSet: Bool
    public let registrationURL: URL?
    public let operations: [String]

    init?(dictionary d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.requirement = d["requirement"] as? String ?? "none"
        self.status = Self.status(d["status"] as? String ?? "not-required")
        self.secrets = d["secrets"] as? [String] ?? []
        self.secretsPresent = d["secrets_present"] as? [String] ?? []
        self.wantsContact = d["wants_contact"] as? Bool ?? false
        self.contactSet = d["contact_set"] as? Bool ?? false
        self.registrationURL = (d["registration_url"] as? String).flatMap(URL.init(string:))
        self.operations = d["operations"] as? [String] ?? []
    }

    static func status(_ text: String) -> CredentialStatus {
        switch text {
        case "valid": return .valid
        case "missing": return .missing
        case "optional-valid": return .optionalValid
        case "optional-missing": return .optionalMissing
        default: return .notRequired
        }
    }

    public var credentialRequirement: CredentialRequirement {
        switch requirement {
        case "api-key": return .apiKey
        case "api-key-optional": return .apiKeyOptional
        case "email-optional": return .emailOptional
        default: return .none
        }
    }

    public var metadata: SourceMetadata {
        SourceMetadata(
            id: id,
            name: name,
            description: "",
            credentialRequirement: credentialRequirement,
            registrationURL: registrationURL,
            iconName: SourceMetadata.iconName(for: id)
        )
    }

    public var credentialInfo: SourceCredentialInfo {
        SourceCredentialInfo(
            sourceID: id,
            sourceName: name,
            requirement: credentialRequirement,
            status: status,
            registrationURL: registrationURL
        )
    }
}

// MARK: - Source metadata (the views' display facts)

/// What the views show for a source: its id, name and what it needs. The
/// facts come from the explain record through `source-status`; the icon is
/// the one display choice made here.
public struct SourceMetadata: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let credentialRequirement: CredentialRequirement
    public let registrationURL: URL?
    public let iconName: String

    public init(
        id: String,
        name: String,
        description: String = "",
        credentialRequirement: CredentialRequirement = .none,
        registrationURL: URL? = nil,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.credentialRequirement = credentialRequirement
        self.registrationURL = registrationURL
        self.iconName = iconName ?? Self.iconName(for: id)
    }

    /// SF Symbol per source id.
    public static func iconName(for sourceID: String) -> String {
        switch sourceID {
        case "arxiv": return "doc.text"
        case "ads": return "sparkles"
        case "scix": return "globe.americas"
        case "crossref": return "link"
        case "pubmed": return "heart.text.square"
        case "wos": return "building.columns"
        case "openalex": return "book.pages"
        default: return "doc.text.magnifyingglass"
        }
    }

    /// The display name for a source id when no record is at hand.
    public static func displayName(for sourceID: String) -> String {
        switch sourceID {
        case "arxiv": return "arXiv"
        case "ads": return "NASA ADS"
        case "scix": return "NASA SciX"
        case "crossref": return "Crossref"
        case "pubmed": return "PubMed"
        case "wos": return "Web of Science"
        case "openalex": return "OpenAlex"
        default: return sourceID
        }
    }
}

// MARK: - Credential Requirement

/// What credentials a source requires.
public enum CredentialRequirement: Sendable, Equatable {
    case none
    case apiKey
    case email
    case apiKeyAndEmail
    case apiKeyOptional
    case emailOptional

    public var requiresCredentials: Bool {
        switch self {
        case .none, .apiKeyOptional, .emailOptional:
            return false
        case .apiKey, .email, .apiKeyAndEmail:
            return true
        }
    }

    public var displayDescription: String {
        switch self {
        case .none: return "No credentials required"
        case .apiKey: return "API key required"
        case .email: return "Email required"
        case .apiKeyAndEmail: return "API key and email required"
        case .apiKeyOptional: return "API key optional (recommended)"
        case .emailOptional: return "Email optional (recommended)"
        }
    }
}

// MARK: - Search Sort Order

/// Sort order for search results.
public enum SearchSortOrder: String, Sendable, CaseIterable {
    case relevance
    case dateDescending
    case dateAscending
    case citationCount

    public var displayName: String {
        switch self {
        case .relevance: return "Relevance"
        case .dateDescending: return "Newest First"
        case .dateAscending: return "Oldest First"
        case .citationCount: return "Citation Count"
        }
    }

    /// The verb's `sort`: nil keeps each source's own order (the arXiv
    /// `cat:` feeds default to `year` on the Rust side).
    var verbSort: String? {
        switch self {
        case .relevance: return nil
        case .dateDescending, .dateAscending: return "year"
        case .citationCount: return "cited_by"
        }
    }
}

// MARK: - Search Options

/// Options for a search.
public struct SearchOptions: Sendable {
    public let maxResults: Int
    public let sortOrder: SearchSortOrder
    /// Specific sources to search (nil = every source that covers the query).
    public let sourceIDs: [String]?

    public init(
        maxResults: Int = 300,
        sortOrder: SearchSortOrder = .relevance,
        sourceIDs: [String]? = nil
    ) {
        self.maxResults = maxResults
        self.sortOrder = sortOrder
        self.sourceIDs = sourceIDs
    }

    public static let `default` = SearchOptions()
}
