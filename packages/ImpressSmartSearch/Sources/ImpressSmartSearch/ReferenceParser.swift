//
//  ReferenceParser.swift
//  ImpressSmartSearch
//
//  Parse a single citation reference string into a structured `CitationInputLite`
//  ready for downstream resolution. Tries Apple Intelligence (`@Generable`)
//  first, then optionally falls back to a cloud LLM if the user enabled that.
//
//  ## Swift/Rust split
//
//  What stays here: the `FoundationModels` session and the cloud runner call.
//
//  What moved to Rust (`crates/impress-smart-search`, module `reference`): the
//  prompt, the cloud JSON decode, and — most importantly — `validate`, which
//  drops any DOI / arXiv id / bibcode whose shape is wrong. That check is
//  load-bearing: a hallucinated identifier resolves to the *wrong paper*
//  silently, which is worse than returning nothing. Pinned by
//  `test_fixtures/golden/reference_validate.json`.
//

import Foundation
import ImbibRustCore
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.impress.smartsearch", category: "refparse")

// MARK: - Generable schema (macOS 26+ on-device path)

#if canImport(FoundationModels)

@available(macOS 26, iOS 26, *)
@Generable
public struct ParsedCitation {
    @Guide(description: "Author surnames in citation order; last names only — drop initials, prefixes (van, de, von), and 'et al.'")
    public var authors: [String]

    @Guide(description: "Paper title with original capitalization preserved. Empty string if absent.")
    public var title: String

    @Guide(description: "Four-digit publication year in 1900–2100 range. 0 if not present in the input.", .range(0...2100))
    public var year: Int

    @Guide(description: "Journal name as it appears in the citation, e.g. 'ApJ', 'Nature', 'Phys. Rev. D'. Empty string if absent.")
    public var journal: String

    @Guide(description: "Volume number as a string (some journals use e.g. 'A123'). Empty string if absent.")
    public var volume: String

    @Guide(description: "Page number, range, or article identifier. Empty string if absent.")
    public var pages: String

    @Guide(description: "DOI in canonical 10.x/y format, only if present in input verbatim. Empty string otherwise — DO NOT invent.")
    public var doi: String

    @Guide(description: "arXiv identifier (e.g. 2301.04153 or astro-ph/0112088), only if present in input. Empty string otherwise.")
    public var arxiv: String

    @Guide(description: "ADS bibcode (19 chars, e.g. 1986ApJ...304...15B), only if present in input. Empty string otherwise.")
    public var bibcode: String

    @Guide(description: "Confidence the parse correctly captures the citation, 0.0 to 1.0", .range(0.0...1.0))
    public var confidence: Double
}

#endif

// MARK: - ReferenceParser

public actor ReferenceParser {

    public static let shared = ReferenceParser()

    /// Cloud LLM runner. Caller plugs this in (e.g. wrapping ImpressAI in imbib).
    /// Receives a system prompt and a user message; returns the model's text
    /// (which Rust then JSON-decodes), or nil on failure / disabled.
    public typealias CloudRunner = @Sendable (_ systemPrompt: String, _ userMessage: String) async -> String?

    private let cloudRunner: CloudRunner?

    public init(cloudRunner: CloudRunner? = nil) {
        self.cloudRunner = cloudRunner
    }

    /// Parse a single citation block. Returns `nil` if no parser is available
    /// (Apple Intelligence off, cloud fallback off) or parsing fails.
    public func parse(referenceBlock: String) async -> CitationInputLite? {
        guard let raw = await parseRaw(referenceBlock: referenceBlock) else {
            logger.warning("Reference parse failed for input of \(referenceBlock.count) chars")
            return nil
        }
        return Self.validate(raw, raw: Self.bounded(referenceBlock))
    }

    /// Lower-level entry point — returns the raw `ParsedReference` without
    /// converting to `CitationInputLite`, so callers and tests can inspect what
    /// the model emitted before validation drops invalid ids.
    public func parseRaw(referenceBlock: String) async -> ParsedReference? {
        let bounded = Self.bounded(referenceBlock)
        guard !bounded.isEmpty else { return nil }

        if let r = await parseOnDevice(bounded) { return r }
        if let runner = cloudRunner, let r = await parseCloud(bounded, runner: runner) { return r }
        return nil
    }

    private static func bounded(_ block: String) -> String {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 2000 ? String(trimmed.prefix(2000)) : trimmed
    }

    // MARK: - Apple Intelligence path (stays Swift — this is the platform)

    private func parseOnDevice(_ block: String) async -> ParsedReference? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let prompt = smartSearchReferencePrompt(block: block)
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(
                    to: Prompt(prompt),
                    generating: ParsedCitation.self
                )
                let p = response.content
                logger.info("On-device parse: authors=\(p.authors.count) year=\(p.year) journal=\(p.journal) confidence=\(String(format: "%.2f", p.confidence))")
                return ParsedReference(
                    authors: p.authors,
                    title: p.title,
                    year: p.year,
                    journal: p.journal,
                    volume: p.volume,
                    pages: p.pages,
                    doi: p.doi,
                    arxiv: p.arxiv,
                    bibcode: p.bibcode,
                    confidence: p.confidence
                )
            } catch {
                logger.warning("On-device parse failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - Cloud path (JSON-mode prompt)

    private func parseCloud(_ block: String, runner: CloudRunner) async -> ParsedReference? {
        let systemPrompt = """
        You are a bibliography parser. Convert a single citation reference string into a JSON \
        object with the schema below. Use empty strings for missing string fields and 0 for \
        missing year. Do NOT invent identifiers (DOI, arXiv, bibcode) — only emit them if they \
        appear verbatim in the input.

        Schema (return ONLY the JSON object — no markdown, no commentary):
        {
          "authors": [string, ...],   // last names in citation order; drop initials and "et al."
          "title": string,
          "year": number,             // 4-digit year, or 0
          "journal": string,
          "volume": string,
          "pages": string,
          "doi": string,
          "arxiv": string,
          "bibcode": string,
          "confidence": number        // 0.0 to 1.0
        }
        """
        let userMessage = "Parse this citation:\n\n\(block)"
        guard let text = await runner(systemPrompt, userMessage) else {
            return nil
        }
        // Fence-stripping + JSON decoding happen in Rust.
        guard let ffi = smartSearchDecodeReferenceJson(text: text) else {
            logger.warning("Cloud JSON decode failed; raw=\(text.prefix(200))")
            return nil
        }
        return Self.parsedReference(from: ffi)
    }

    // MARK: - Validation (Rust)

    /// Drop identifiers the model invented, and normalize empty strings to nil.
    public static func validate(_ p: ParsedReference, raw: String) -> CitationInputLite {
        let c = smartSearchValidateReference(
            parsed: SmartSearchParsedReference(
                authors: p.authors,
                title: p.title,
                year: Int32(clamping: p.year),
                journal: p.journal,
                volume: p.volume,
                pages: p.pages,
                doi: p.doi,
                arxiv: p.arxiv,
                bibcode: p.bibcode,
                confidence: p.confidence
            ),
            raw: raw
        )
        return CitationInputLite(
            authors: c.authors,
            title: c.title,
            year: c.year.map(Int.init),
            journal: c.journal,
            volume: c.volume,
            pages: c.pages,
            doi: c.doi,
            arxiv: c.arxiv,
            bibcode: c.bibcode,
            freeText: c.freeText
        )
    }

    private static func parsedReference(from ffi: SmartSearchParsedReference) -> ParsedReference {
        ParsedReference(
            authors: ffi.authors,
            title: ffi.title,
            year: Int(ffi.year),
            journal: ffi.journal,
            volume: ffi.volume,
            pages: ffi.pages,
            doi: ffi.doi,
            arxiv: ffi.arxiv,
            bibcode: ffi.bibcode,
            confidence: ffi.confidence
        )
    }
}
