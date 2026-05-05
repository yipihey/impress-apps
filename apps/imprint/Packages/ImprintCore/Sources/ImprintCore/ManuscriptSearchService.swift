//
//  ManuscriptSearchService.swift
//  ImprintCore
//
//  Cross-document full-text search over stored manuscript sections.
//  Builds an in-memory inverted index from `ImprintImpressStore` and
//  keeps it up to date by subscribing to the gateway's event stream.
//
//  Scope (Phase 1):
//  - Tokenization: lowercase, split on non-alphanumerics, drop tokens
//    shorter than 2 characters. Good enough for "halo bias" style
//    queries; real stemming is deferred.
//  - Ranking: simple term-frequency sum per matching section. Ties
//    broken by section title then recency. No BM25 yet.
//  - Rebuild strategy: full rebuild on `.structural`, delta-rebuild
//    for `.itemsMutated(kind:ids:)`.
//
//  This is a pure actor — it has no UI dependencies, so the HTTP
//  router, the MCP layer, and the SwiftUI search palette can all use
//  it.
//

import Foundation
import ImpressLogging
import ImpressStoreKit
import OSLog

private let searchLog = Logger(subsystem: "com.imprint.app", category: "manuscript-search")

/// One search result — a section whose text matches the query.
public struct ManuscriptSearchHit: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sectionID: UUID
    public let documentID: UUID?
    public let title: String
    public let sectionType: String?
    public let excerpt: String
    public let score: Double
    public let matchedTerms: [String]

    public init(
        sectionID: UUID,
        documentID: UUID?,
        title: String,
        sectionType: String?,
        excerpt: String,
        score: Double,
        matchedTerms: [String]
    ) {
        self.id = sectionID
        self.sectionID = sectionID
        self.documentID = documentID
        self.title = title
        self.sectionType = sectionType
        self.excerpt = excerpt
        self.score = score
        self.matchedTerms = matchedTerms
    }
}

/// Cross-document search service with an in-memory inverted index.
public actor ManuscriptSearchService {

    public static let shared = ManuscriptSearchService()

    // MARK: - Index state

    private struct IndexedSection: Sendable {
        let id: UUID
        let documentID: UUID?
        let title: String
        let sectionType: String?
        let createdAt: Date
        /// Lowercased body, kept so we can build excerpts without
        /// re-reading from the store. Truncated to 16 KiB to cap
        /// memory — longer bodies are indexed in full but the excerpt
        /// window uses this buffer.
        let excerptSource: String
        /// term -> frequency
        let termFrequencies: [String: Int]
    }

    private var sections: [UUID: IndexedSection] = [:]
    /// term -> set of section ids that contain it
    private var inverted: [String: Set<UUID>] = [:]
    private var isRunning = false
    private var isRebuilding = false
    private var pendingRebuild = false
    private var eventTask: Task<Void, Never>?

    public init() {}

    // MARK: - Lifecycle

    /// Start the event subscription. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let stream = ImprintImpressStore.shared.events.subscribe()
        eventTask = Task.detached(priority: .utility) { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .collectionMembershipChanged:
                    continue
                case .structural:
                    await self.triggerFullRebuild()
                case .itemsMutated(_, let ids):
                    await self.reindex(sectionIDs: ids)
                }
            }
        }
        triggerFullRebuild()
    }

    // MARK: - Public query API

    /// Search the index. Multi-term queries require every term to match
    /// the same section (AND semantics). Case-insensitive; tokens
    /// shorter than 2 characters are dropped to match the indexer.
    public func search(_ query: String, limit: Int = 50) -> [ManuscriptSearchHit] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [] }

        // Start with the smallest posting list and intersect.
        let postings = terms.map { inverted[$0] ?? [] }
        guard let smallest = postings.min(by: { $0.count < $1.count }) else { return [] }
        var candidates = smallest
        for posting in postings where posting.count != smallest.count {
            candidates.formIntersection(posting)
            if candidates.isEmpty { return [] }
        }

        // Score: sum of term frequencies; title matches boost.
        var hits: [ManuscriptSearchHit] = []
        hits.reserveCapacity(candidates.count)
        for id in candidates {
            guard let indexed = sections[id] else { continue }
            var score = 0.0
            for term in terms {
                let tf = Double(indexed.termFrequencies[term] ?? 0)
                score += tf
                // Title boost
                if indexed.title.lowercased().contains(term) {
                    score += 5
                }
            }
            let excerpt = Self.makeExcerpt(body: indexed.excerptSource, terms: terms)
            hits.append(ManuscriptSearchHit(
                sectionID: indexed.id,
                documentID: indexed.documentID,
                title: indexed.title,
                sectionType: indexed.sectionType,
                excerpt: excerpt,
                score: score,
                matchedTerms: terms
            ))
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title < rhs.title
        }
        return Array(hits.prefix(limit))
    }

    /// Debug: how many sections are in the index.
    public var indexedSectionCount: Int { sections.count }

    // MARK: - Rebuild orchestration

    private func triggerFullRebuild() {
        if isRebuilding {
            pendingRebuild = true
            return
        }
        isRebuilding = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.performFullRebuild()
        }
    }

    private func performFullRebuild() async {
        defer { Task { [weak self] in await self?.finishRebuild() } }

        #if canImport(ImpressRustCore)
        let raw = ImprintImpressStore.shared.listAllSections(limit: 10_000, offset: 0)
        // Rehydrate bodies one at a time; listAllSections skips rehydration.
        var sectionsByID: [UUID: IndexedSection] = [:]
        var inverted: [String: Set<UUID>] = [:]
        for stub in raw {
            // loadSection handles content-addressed bodies and is
            // instrumented, so we get timing coverage for free.
            guard let section = ImprintImpressStore.shared.loadSection(id: stub.id) else { continue }
            let indexed = Self.indexOne(section: section)
            sectionsByID[section.id] = indexed
            for term in indexed.termFrequencies.keys {
                inverted[term, default: []].insert(section.id)
            }
        }
        self.sections = sectionsByID
        self.inverted = inverted
        searchLog.infoCapture(
            "ManuscriptSearchService rebuilt index with \(sectionsByID.count) sections, \(inverted.count) unique terms",
            category: "manuscript-search"
        )
        #endif
    }

    private func reindex(sectionIDs: Set<UUID>) async {
        #if canImport(ImpressRustCore)
        for id in sectionIDs {
            // Remove from inverted index
            if let old = sections[id] {
                for term in old.termFrequencies.keys {
                    inverted[term]?.remove(id)
                    if inverted[term]?.isEmpty == true {
                        inverted.removeValue(forKey: term)
                    }
                }
                sections.removeValue(forKey: id)
            }
            // Re-load; if the section no longer exists, we've already removed it.
            guard let section = ImprintImpressStore.shared.loadSection(id: id) else { continue }
            let indexed = Self.indexOne(section: section)
            sections[id] = indexed
            for term in indexed.termFrequencies.keys {
                inverted[term, default: []].insert(id)
            }
        }
        #endif
    }

    private func finishRebuild() async {
        isRebuilding = false
        if pendingRebuild {
            pendingRebuild = false
            triggerFullRebuild()
        }
    }

    // MARK: - Indexing helpers

    private static func indexOne(section: ManuscriptSection) -> IndexedSection {
        let body = section.body ?? ""
        let titleTokens = tokenize(section.title)
        let bodyTokens = tokenize(body)
        var tf: [String: Int] = [:]
        for token in titleTokens { tf[token, default: 0] += 1 }
        for token in bodyTokens { tf[token, default: 0] += 1 }
        let excerptSource = String(body.prefix(16_384))
        return IndexedSection(
            id: section.id,
            documentID: section.documentID,
            title: section.title.isEmpty ? "Untitled section" : section.title,
            sectionType: section.sectionType,
            createdAt: section.createdAt,
            excerptSource: excerptSource,
            termFrequencies: tf
        )
    }

    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        current.reserveCapacity(16)
        for scalar in input.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                if current.count >= 2 { tokens.append(current.lowercased()) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty, current.count >= 2 {
            tokens.append(current.lowercased())
        }
        return tokens
    }

    /// Build a short excerpt around the first matching term, with
    /// ±60 characters of context. Falls back to the body prefix.
    private static func makeExcerpt(body: String, terms: [String]) -> String {
        let lower = body.lowercased()
        var matchStart: String.Index? = nil
        for term in terms {
            if let r = lower.range(of: term) {
                matchStart = r.lowerBound
                break
            }
        }
        guard let start = matchStart else {
            return String(body.prefix(140))
        }
        let windowStart = body.index(start, offsetBy: -60, limitedBy: body.startIndex) ?? body.startIndex
        let windowEnd = body.index(start, offsetBy: 100, limitedBy: body.endIndex) ?? body.endIndex
        var excerpt = String(body[windowStart..<windowEnd])
        if windowStart != body.startIndex { excerpt = "…" + excerpt }
        if windowEnd != body.endIndex { excerpt += "…" }
        return excerpt.replacingOccurrences(of: "\n", with: " ")
    }
}
