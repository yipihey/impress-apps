//
//  FreeTextQueryRewriter.swift
//  ImpressSmartSearch
//
//  Convert free-form natural-language search input into a valid ADS Lucene
//  query. Apple Intelligence first, optional cloud fallback, deterministic
//  regex fallback last.
//
//  ## Swift/Rust split
//
//  What stays here: the `FoundationModels` session (the `@Generable` schema
//  below and the `respond(to:generating:)` call) and the caller-supplied cloud
//  runner. Those are the platform.
//
//  What moved to Rust (`crates/impress-smart-search`, module `rewriter`):
//  every transformation applied to the model's output, plus the prompt itself
//  and the whole no-model fallback. That is where search quality is decided —
//  the author blacklist, the hallucinated-surname check, the bare-year filter,
//  the `;`→space repair, the `title:"x y"` → `title:(x y)` rewrite. Pinned by
//  `test_fixtures/golden/rewriter_*.json` and `prompts.json`.
//

import Foundation
import ImbibRustCore
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.impress.smartsearch", category: "qrewrite")

// MARK: - Generable schema (macOS 26+ on-device path)
//
// We ask the model to extract STRUCTURED fields (authors, journal, topic
// words, year range, refereed flag) rather than to write a query string. The
// query string is then built deterministically in Rust from these fields,
// which avoids the model emitting malformed ADS syntax.

#if canImport(FoundationModels)

@available(macOS 26, iOS 26, *)
@Generable
public struct ADSQueryParts {
    @Guide(description: "Author surnames mentioned in the request. Just last names, capitalized. Empty array if none. NEVER include topic words like 'first', 'stars', 'dark', 'energy' here.")
    public var authors: [String]

    @Guide(description: "ADS bibstem (journal abbreviation) if a journal name is mentioned: 'Sci' for Science, 'Nat' for Nature, 'ApJ' for Astrophysical Journal, 'MNRAS', 'A&A', 'PRL', 'PRD', 'PNAS', 'JCAP', 'JHEP'. Empty string if no journal is mentioned.")
    public var bibstem: String

    @Guide(description: "Topic keywords from the request — concrete subject terms (e.g. 'first stars', 'dark energy', 'galaxy formation', 'JWST'). Drop generic words like 'paper', 'about', 'on'. Empty array if no topic.")
    public var topicWords: [String]

    @Guide(description: "Earliest publication year if the user specified one (e.g. 'since 2020' → 2020, '2018-2024' → 2018). 0 if no year was specified.", .range(0...2100))
    public var yearFrom: Int

    @Guide(description: "Latest publication year if the user specified a range. If yearFrom > 0 but no upper bound was given (e.g. 'since 2020'), set this to 0 — the caller will fill in the current year.", .range(0...2100))
    public var yearTo: Int

    @Guide(description: "True if the user EXPLICITLY asked for refereed, peer-reviewed, or published papers. False otherwise.")
    public var refereedOnly: Bool

    @Guide(description: "One short sentence describing the search in plain English.")
    public var interpretation: String

    @Guide(description: "Confidence the extraction captures the user's intent, 0.0 to 1.0", .range(0.0...1.0))
    public var confidence: Double
}

#endif

// MARK: - FreeTextQueryRewriter
// QueryRewriteResult is defined in SmartSearchTypes.swift.

/// Actor that rewrites free-text input into an ADS query.
public actor FreeTextQueryRewriter {

    public static let shared = FreeTextQueryRewriter()

    /// Cloud LLM runner. Caller plugs this in (e.g. wrapping ImpressAI in imbib).
    /// Receives a system prompt and a user message; returns the model's text
    /// (which Rust then JSON-decodes), or nil on failure / disabled.
    public typealias CloudRunner = @Sendable (_ systemPrompt: String, _ userMessage: String) async -> String?

    private let cloudRunner: CloudRunner?

    public init(cloudRunner: CloudRunner? = nil) {
        self.cloudRunner = cloudRunner
    }

    // MARK: - Public

    /// Rewrite free-text search input into an ADS query. Always returns a
    /// result — the deterministic fallback produces a usable query even when no
    /// model is available.
    public func rewrite(_ input: String) async -> QueryRewriteResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return QueryRewriteResult(
                query: "",
                interpretation: "Empty query",
                confidence: 0,
                source: .degenerate
            )
        }
        let bounded = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed

        if let result = await rewriteOnDevice(bounded), !result.query.isEmpty {
            return result
        }
        if let runner = cloudRunner,
           let result = await rewriteCloud(bounded, runner: runner),
           !result.query.isEmpty {
            return result
        }
        return Self.degenerateRewrite(bounded)
    }

    // MARK: - Apple Intelligence path (stays Swift — this is the platform)

    private func rewriteOnDevice(_ input: String) async -> QueryRewriteResult? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let prompt = Self.makeRewritePrompt(input: input)
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(
                    to: Prompt(prompt),
                    generating: ADSQueryParts.self
                )
                let g = response.content
                // The deterministic assembly — including every safety filter —
                // happens in Rust.
                let query = smartSearchBuildAdsQuery(
                    parts: SmartSearchQueryParts(
                        authors: g.authors,
                        bibstem: g.bibstem,
                        topicWords: g.topicWords,
                        yearFrom: Int32(clamping: g.yearFrom),
                        yearTo: Int32(clamping: g.yearTo),
                        refereedOnly: g.refereedOnly
                    ),
                    originalInput: input,
                    thisYear: Self.currentYear
                )
                logger.info("On-device rewrite: parts={authors=\(g.authors), bibstem=\(g.bibstem), topicWords=\(g.topicWords), year=\(g.yearFrom)-\(g.yearTo), refereed=\(g.refereedOnly)} → '\(query)'")
                return QueryRewriteResult(
                    query: query,
                    interpretation: g.interpretation,
                    confidence: g.confidence,
                    source: .appleIntelligence
                )
            } catch {
                logger.warning("On-device rewrite failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - Cloud path

    private func rewriteCloud(_ input: String, runner: CloudRunner) async -> QueryRewriteResult? {
        let systemPrompt = """
        You are a query rewriter for the NASA Astrophysics Data System (ADS). \
        Convert a natural-language search request into an ADS Lucene query.

        ADS query syntax:
          author:"Last, F"        single author — one author per clause; never put two surnames in one quoted string
          first_author:"Last, F"  the first author specifically
          title:(words)           words in the title; use parentheses, not quotes, for multi-word topics
          abs:(words)             words in the abstract
          year:YYYY  or  year:YYYY-YYYY
          bibstem:Sci             venue/journal abbreviation (e.g. Sci, ApJ, Nature, MNRAS, A&A, PNAS, PRL)
          property:refereed       peer-reviewed only

        Separate clauses with a single SPACE. Never use ';' or ',' between clauses
        (commas only inside "Last, F"). ADS treats space as AND already.

        Rules:
          1. Multiple author surnames → one author:"Surname" clause per name, all space-joined.
          2. Recognize common journal names (Science, Nature, ApJ, MNRAS, A&A, PRL, PNAS) and emit bibstem:.
          3. Topic words go inside title:(...) or abs:(...); when uncertain, use abs:(...).
          4. Don't add property:refereed unless the user explicitly asked for refereed/peer-reviewed.
          5. Don't invent specific authors, years, or titles that weren't in the input.
          6. Today is \(Self.todayString()) — resolve "recent", "this year", "last N years" against that.

        Return ONLY a JSON object with this schema (no markdown fences, no commentary):
        {
          "query": string,           // the ADS query
          "interpretation": string,  // one short sentence in plain English
          "confidence": number       // 0.0 to 1.0
        }
        """
        guard let text = await runner(systemPrompt, input) else {
            return nil
        }
        // Fence-stripping, JSON decoding, and query repair all happen in Rust.
        guard let r = smartSearchDecodeRewriteJson(text: text) else {
            logger.warning("Cloud JSON decode failed")
            return nil
        }
        return QueryRewriteResult(
            query: r.query,
            interpretation: r.interpretation,
            confidence: r.confidence,
            source: .cloud
        )
    }

    // MARK: - Deterministic fallback (Rust)

    /// Last-resort rewrite when no model is available.
    public static func degenerateRewrite(_ input: String) -> QueryRewriteResult {
        let r = smartSearchDegenerateRewrite(input: input, thisYear: currentYear)
        return QueryRewriteResult(
            query: r.query,
            interpretation: r.interpretation,
            confidence: r.confidence,
            source: .degenerate
        )
    }

    // MARK: - Prompt (Rust)

    static func makeRewritePrompt(input: String) -> String {
        smartSearchRewritePrompt(input: input, thisYear: currentYear, today: todayString())
    }

    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// The one place the clock is read. Rust takes the year as a parameter so
    /// its year-relative branches are testable; this is the caller that
    /// supplies the real value.
    static var currentYear: Int32 {
        Int32(clamping: Calendar.current.component(.year, from: Date()))
    }
}
