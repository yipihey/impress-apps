//
//  SmartSearchEngine.swift
//  ImpressSmartSearch
//
//  Headless coordinator. Composes IntentClassifier + ReferenceParser +
//  FreeTextQueryRewriter into a single async entry point. Does NOT perform
//  source fan-out or local lookup — those are caller responsibilities (in
//  imbib, those go to AutomationService and SourceManager).
//

import Foundation

public actor SmartSearchEngine {

    private let referenceParser: ReferenceParser
    private let queryRewriter: FreeTextQueryRewriter
    private let urlExtractor: URLContentExtractor

    /// Initialize the engine. `cloudRunner` is optional — without it, the
    /// engine uses Apple Intelligence on-device (when available) and falls
    /// back to the deterministic regex rewriter for free-text. Plug in a
    /// cloud runner (e.g. wrapping ImpressAI) to enable a third tier.
    public init(
        cloudRunner: ReferenceParser.CloudRunner? = nil,
        urlExtractor: URLContentExtractor = .shared
    ) {
        self.referenceParser = ReferenceParser(cloudRunner: cloudRunner)
        self.queryRewriter = FreeTextQueryRewriter(cloudRunner: cloudRunner)
        self.urlExtractor = urlExtractor
    }

    // MARK: - Direct entry points

    /// Deterministic intent classification. Cheap; no LLM. Use this on every
    /// keystroke to drive UI labels.
    public nonisolated func classify(_ input: String) -> SearchIntent {
        IntentClassifier.classify(input)
    }

    /// Parse a single citation block. May invoke Apple Intelligence and/or
    /// the cloud fallback (per init). Returns nil if neither is available.
    public func parseReference(_ block: String) async -> CitationInputLite? {
        await referenceParser.parse(referenceBlock: block)
    }

    /// Lower-level reference parse — returns the raw `ParsedReference` so
    /// callers (and tests) can inspect what the LLM emitted before validation.
    public func parseReferenceRaw(_ block: String) async -> ParsedReference? {
        await referenceParser.parseRaw(referenceBlock: block)
    }

    /// Rewrite free-form input into an ADS query. Always returns a result —
    /// degenerate regex fallback runs when no LLM is available.
    public func rewriteFreeText(_ input: String) async -> QueryRewriteResult {
        await queryRewriter.rewrite(input)
    }

    /// Fetch a URL and extract any paper identifiers found in the page.
    public func extractFromURL(_ url: URL) async -> URLExtractionResult {
        await urlExtractor.extract(from: url)
    }

    // MARK: - Composed pipeline

    /// One-shot pipeline: classify the input, run the appropriate LLM step,
    /// return a `ResolveOutcome`. Caller composes downstream behavior on top.
    public func resolve(_ input: String) async -> ResolveOutcome {
        let intent = classify(input)
        switch intent {
        case .identifier(let id):
            return .identifier(id)
        case .fielded(let q):
            return .fielded(query: q)
        case .reference(let blocks):
            if blocks.count == 1 {
                guard let parsed = await parseReferenceRaw(blocks[0]) else {
                    // Parser unavailable — fall through to free-text rewrite.
                    let rw = await rewriteFreeText(blocks[0])
                    return .freeTextQuery(rw)
                }
                return .citation(parsed)
            }
            var out: [ParsedReference?] = []
            for block in blocks {
                out.append(await parseReferenceRaw(block))
            }
            return .citations(out)
        case .freeText(let q):
            let rw = await rewriteFreeText(q)
            return .freeTextQuery(rw)
        case .url(let u):
            let extraction = await extractFromURL(u)
            return .urlExtraction(extraction)
        }
    }
}
