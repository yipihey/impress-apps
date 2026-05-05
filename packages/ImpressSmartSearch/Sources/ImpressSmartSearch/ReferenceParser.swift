//
//  ReferenceParser.swift
//  ImpressSmartSearch
//
//  Parse a single citation reference string into a structured `CitationInputLite`
//  ready for downstream resolution. Tries Apple Intelligence (`@Generable`)
//  first, then optionally falls back to a cloud LLM via `AIMultiModelExecutor`
//  if the user has enabled that.
//

import Foundation
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
    /// (which the parser then JSON-decodes), or nil on failure / disabled.
    public typealias CloudRunner = @Sendable (_ systemPrompt: String, _ userMessage: String) async -> String?

    private let cloudRunner: CloudRunner?

    public init(cloudRunner: CloudRunner? = nil) {
        self.cloudRunner = cloudRunner
    }

    /// Parse a single citation block. Returns `nil` if no parser is available
    /// (Apple Intelligence off, cloud fallback off) or parsing fails.
    public func parse(referenceBlock: String) async -> CitationInputLite? {
        let trimmed = referenceBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let bounded = trimmed.count > 2000 ? String(trimmed.prefix(2000)) : trimmed

        if let result = await parseOnDevice(bounded) {
            return validate(result, raw: bounded)
        }
        if let runner = cloudRunner, let result = await parseCloud(bounded, runner: runner) {
            return validate(result, raw: bounded)
        }
        logger.warning("Reference parse failed for input of \(bounded.count) chars")
        return nil
    }

    /// Lower-level entry point used by the test harness — returns the raw
    /// `ParsedReference` without converting to `CitationInputLite`. Lets tests
    /// inspect what the LLM returned before validation drops invalid IDs.
    public func parseRaw(referenceBlock: String) async -> ParsedReference? {
        let trimmed = referenceBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bounded = trimmed.count > 2000 ? String(trimmed.prefix(2000)) : trimmed
        if let r = await parseOnDevice(bounded) { return r }
        if let runner = cloudRunner, let r = await parseCloud(bounded, runner: runner) { return r }
        return nil
    }

    // MARK: - Apple Intelligence path

    private func parseOnDevice(_ block: String) async -> ParsedReference? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let prompt = Self.makeReferencePrompt(block: block)
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
        return Self.decodeCloudJSON(text)
    }

    // MARK: - Validation

    private func validate(_ p: ParsedReference, raw: String) -> CitationInputLite {
        let doi = p.doi.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil ? p.doi : nil
        let arxivPattern = #"^(\d{4}\.\d{4,5}(v\d+)?|[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?)$"#
        let arxiv = p.arxiv.range(of: arxivPattern, options: .regularExpression) != nil ? p.arxiv : nil
        let bibcodeOK = p.bibcode.count == 19 &&
            p.bibcode.range(of: #"^\d{4}[A-Za-z&\.][A-Za-z&\.]{1,7}[\.\d][\.\d]+[A-Z]$"#,
                            options: .regularExpression) != nil
        let bibcode = bibcodeOK ? p.bibcode : nil

        let authors = p.authors.filter { !$0.isEmpty }
        let title = p.title.isEmpty ? nil : p.title
        let year: Int? = (1900...2100).contains(p.year) ? p.year : nil
        let journal = p.journal.isEmpty ? nil : p.journal
        let volume = p.volume.isEmpty ? nil : p.volume
        let pages = p.pages.isEmpty ? nil : p.pages

        return CitationInputLite(
            authors: authors,
            title: title,
            year: year,
            journal: journal,
            volume: volume,
            pages: pages,
            doi: doi,
            arxiv: arxiv,
            bibcode: bibcode,
            freeText: raw
        )
    }

    // MARK: - Prompt + JSON helpers

    fileprivate static func makeReferencePrompt(block: String) -> String {
        """
        Parse this scientific bibliography reference into structured fields. \
        It may be in any common style (APA, AMS, Nature, AAS, BibTeX-rendered, ADS). \
        Preserve the original title capitalization. Use empty string for missing string \
        fields and 0 for missing year. Do not invent DOI / arXiv / bibcode — only emit \
        them if they appear verbatim in the input.

        Reference:
        \(block)
        """
    }

    fileprivate static func decodeCloudJSON(_ text: String) -> ParsedReference? {
        let cleaned = stripCodeFences(text)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        do {
            let raw = try JSONDecoder().decode(CloudParsedCitation.self, from: data)
            return ParsedReference(
                authors: raw.authors ?? [],
                title: raw.title ?? "",
                year: raw.year ?? 0,
                journal: raw.journal ?? "",
                volume: raw.volume ?? "",
                pages: raw.pages ?? "",
                doi: raw.doi ?? "",
                arxiv: raw.arxiv ?? "",
                bibcode: raw.bibcode ?? "",
                confidence: raw.confidence ?? 0.5
            )
        } catch {
            logger.warning("Cloud JSON decode failed: \(error.localizedDescription); raw=\(cleaned.prefix(200))")
            return nil
        }
    }

    private static func stripCodeFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Cloud JSON shape

private struct CloudParsedCitation: Decodable {
    let authors: [String]?
    let title: String?
    let year: Int?
    let journal: String?
    let volume: String?
    let pages: String?
    let doi: String?
    let arxiv: String?
    let bibcode: String?
    let confidence: Double?
}
