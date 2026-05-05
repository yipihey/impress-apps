//
//  FreeTextQueryRewriter.swift
//  ImpressSmartSearch
//
//  Convert free-form natural-language search input into a valid ADS Lucene
//  query string. Apple Intelligence first, optional cloud fallback, degenerate
//  regex fallback.
//

import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.impress.smartsearch", category: "qrewrite")

// MARK: - Generable schema (macOS 26+ on-device path)
//
// We ask the model to extract STRUCTURED fields (authors, journal, topic
// words, year range, refereed flag) rather than to write a query string. The
// query string is then built deterministically from these fields, which
// avoids the model emitting malformed ADS syntax.

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
    /// (which the rewriter then JSON-decodes), or nil on failure / disabled.
    public typealias CloudRunner = @Sendable (_ systemPrompt: String, _ userMessage: String) async -> String?

    private let cloudRunner: CloudRunner?

    public init(cloudRunner: CloudRunner? = nil) {
        self.cloudRunner = cloudRunner
    }

    // MARK: - Public

    /// Rewrite free-text search input into an ADS query. Always returns a
    /// result — the degenerate fallback path produces a usable query even
    /// when no LLM is available.
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
        return degenerateRewrite(bounded)
    }

    // MARK: - Apple Intelligence path

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
                let parts = response.content
                let query = Self.buildQuery(from: parts, originalInput: input)
                logger.info("On-device rewrite: parts={authors=\(parts.authors), bibstem=\(parts.bibstem), topicWords=\(parts.topicWords), year=\(parts.yearFrom)-\(parts.yearTo), refereed=\(parts.refereedOnly)} → '\(query)'")
                return QueryRewriteResult(
                    query: query,
                    interpretation: parts.interpretation,
                    confidence: parts.confidence,
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

    /// Build a deterministic ADS Lucene query from extracted structured parts.
    /// Always produces well-formed syntax — no semicolons, proper quoting, etc.
    /// Applies post-processing safety filters to catch common LLM mistakes.
    static func buildQuery(from parts: ADSQueryParts, originalInput: String = "") -> String {
        var clauses: [String] = []
        let inputLower = originalInput.lowercased()

        // Filter authors. Three rules:
        //   1. Reject blacklisted instrument/telescope/survey names.
        //   2. Reject lowercase names (real surnames are capitalized in citations).
        //   3. Reject names that don't actually appear in the input (catches LLM
        //      hallucinations like "SDSS DR17 spectroscopy" → author:"Smith").
        let nonAuthors = filterAuthors(parts.authors, inputLower: inputLower)

        // Sanity check — if we have ≥4 "authors" and zero topicWords, the LLM
        // probably mis-classified topic words as authors. Demote to topics.
        let demoted = nonAuthors.filtered.count >= 4 && parts.topicWords.isEmpty
        let authors = demoted ? [] : nonAuthors.filtered
        let extraTopics = (demoted ? nonAuthors.filtered : []) + nonAuthors.rejected

        for surname in authors {
            clauses.append("author:\"\(surname)\"")
        }

        // Bibstem — only if non-empty and looks like a real abbreviation.
        let bibstem = parts.bibstem.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bibstem.isEmpty,
           bibstem.count <= 12,
           bibstem.allSatisfy({ $0.isLetter || $0 == "&" || $0 == "." }) {
            clauses.append("bibstem:\(bibstem)")
        }

        // Topic words — combine LLM topicWords with demoted authors. Filter
        // out anything we already used as an author (avoids `author:"Smith"`
        // AND `abs:(... Smith ...)`). Dedup at both whole-string and per-word
        // level (avoids "galaxy rotation curves galaxy rotation curves").
        let authorSet = Set(authors.map { $0.lowercased() })
        var rawTopics: [String] = parts.topicWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        rawTopics.append(contentsOf: extraTopics)
        var seenWords = Set<String>()
        var topicTokens: [String] = []
        for phrase in rawTopics {
            for word in phrase.split(whereSeparator: { $0.isWhitespace }) {
                let key = word.lowercased()
                if authorSet.contains(key) { continue }
                if !seenWords.insert(key).inserted { continue }
                topicTokens.append(String(word))
            }
        }
        if !topicTokens.isEmpty {
            let topicPhrase = topicTokens.joined(separator: " ")
            clauses.append("abs:(\(topicPhrase))")
        }

        // Year range. Pre-extract decade ("1970s") from the original input —
        // the LLM is unreliable on decade interpretation.
        let thisYear = Calendar.current.component(.year, from: Date())
        if let (decadeFrom, decadeTo) = extractDecade(originalInput) {
            clauses.append("year:\(decadeFrom)-\(decadeTo)")
        } else if parts.yearFrom > 0 {
            let from = parts.yearFrom
            let to: Int = {
                if parts.yearTo >= from { return parts.yearTo }
                return thisYear
            }()
            if from == to {
                clauses.append("year:\(from)")
            } else {
                clauses.append("year:\(from)-\(to)")
            }
        }

        // Refereed flag — only when explicitly requested.
        if parts.refereedOnly {
            clauses.append("property:refereed")
        }

        return clauses.joined(separator: " ")
    }

    /// Names that are NEVER human authors — instruments, telescopes, satellites,
    /// surveys, common nouns. The LLM often mis-classifies these as authors.
    private static let nonAuthorNames: Set<String> = [
        // Telescopes / observatories
        "JWST", "HST", "Hubble", "Webb", "Chandra", "Fermi", "Spitzer", "Herschel",
        "Kepler", "TESS", "ALMA", "VLA", "VLBA", "LIGO", "Virgo", "KAGRA",
        "Planck", "WMAP", "COBE", "GAIA", "Gaia", "ROSAT", "XMM", "INTEGRAL",
        "Swift", "NICER", "Euclid", "Roman", "PLATO", "ARIEL", "WFIRST",
        // Surveys / datasets
        "SDSS", "DESI", "DES", "LSST", "Pan-STARRS", "PanSTARRS", "ZTF", "ATLAS",
        "BOSS", "eBOSS", "MaNGA", "APOGEE", "GALAH", "RAVE", "2MASS", "WISE",
        "GALEX", "Vera", "Rubin", "DR16", "DR17", "DR18", "DR19", "DR20",
        // Generic words sometimes mis-flagged
        "Galaxy", "Galaxies", "Star", "Stars", "Curves", "Curve", "Rotation",
        "Energy", "Matter", "Radiation", "Waves", "Wave", "Field", "Fields",
        "Cosmology", "Inflation", "Universe", "Cosmic", "Astronomy",
    ]

    private struct AuthorFilterResult {
        let filtered: [String]   // accepted as authors
        let rejected: [String]   // names rejected — re-injected as topics
    }

    private static func filterAuthors(_ raw: [String], inputLower: String) -> AuthorFilterResult {
        var ok: [String] = []
        var bad: [String] = []
        for r in raw {
            let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            guard trimmed.contains(where: { $0.isLetter }) else { continue }
            // Reject blacklisted instrument/telescope/survey names.
            if nonAuthorNames.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
                bad.append(trimmed)
                continue
            }
            // Reject pure-lowercase names — citations capitalize surnames.
            if trimmed.first?.isUppercase == false {
                bad.append(trimmed)
                continue
            }
            // Reject hallucinations — surname must actually appear in input
            // (case-insensitive substring match).
            if !inputLower.isEmpty, !inputLower.contains(trimmed.lowercased()) {
                bad.append(trimmed)
                continue
            }
            ok.append(trimmed)
        }
        return AuthorFilterResult(filtered: ok, rejected: bad)
    }

    /// Detect decade pattern ("1970s", "1980s", etc.) in the original input.
    /// Returns inclusive (from, to) year range — "1970s" → (1970, 1979).
    private static func extractDecade(_ input: String) -> (Int, Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(19|20)(\d)0s\b"#) else { return nil }
        let nsRange = NSRange(input.startIndex..., in: input)
        guard let m = regex.firstMatch(in: input, range: nsRange),
              let centRange = Range(m.range(at: 1), in: input),
              let decadeRange = Range(m.range(at: 2), in: input),
              let cent = Int(input[centRange]),
              let dec = Int(input[decadeRange]) else { return nil }
        let from = cent * 100 + dec * 10
        return (from, from + 9)
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
        return Self.decodeCloudJSON(text)
    }

    // MARK: - Degenerate fallback

    /// Last-resort rewrite when no LLM is available. Extracts year/decade
    /// tokens with regex and wraps the residual words in `abs:(...)`.
    /// Reuses the regex extractors that lived in `SmartQueryTranslator`.
    private func degenerateRewrite(_ input: String) -> QueryRewriteResult {
        let thisYear = Calendar.current.component(.year, from: Date())
        let words = input.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var queryParts: [String] = []
        var topicWords: [String] = []
        var refereed = false
        var i = 0

        while i < words.count {
            let word = words[i]
            let lower = word.lowercased()

            // Decade: "1970s"
            if let m = word.firstMatch(of: #/^(\d{4})s$/#),
               let start = Int(String(m.output.1)),
               (1900...2090).contains(start) {
                queryParts.append("year:\(start - 2)-\(start + 12)")
                i += 1
                continue
            }
            // Hyphenated year range: "2020-2024"
            let hyphenParts = word.split(separator: "-")
            if hyphenParts.count == 2,
               let from = Int(hyphenParts[0]), (1900...2100).contains(from),
               let to = Int(hyphenParts[1]), (1900...2100).contains(to) {
                queryParts.append("year:\(from)-\(to)")
                i += 1
                continue
            }
            // Standalone year
            if let year = Int(word), (1900...2100).contains(year) {
                queryParts.append("year:\(year)")
                i += 1
                continue
            }
            // "since YYYY" / "after YYYY"
            if (lower == "since" || lower == "after"),
               i + 1 < words.count,
               let y = Int(words[i + 1]), (1900...2100).contains(y) {
                queryParts.append("year:\(y)-\(thisYear)")
                i += 2
                continue
            }
            // "recent" / "latest"
            if lower == "recent" || lower == "latest" {
                queryParts.append("year:\(thisYear - 4)-\(thisYear)")
                i += 1
                continue
            }
            // "last N years"
            if lower == "last", i + 2 < words.count, words[i + 2].lowercased() == "years",
               let n = Int(words[i + 1]), n > 0, n < 100 {
                queryParts.append("year:\(thisYear - n)-\(thisYear)")
                i += 3
                continue
            }
            // Refereed flag
            if lower == "refereed" || lower == "peer-reviewed" {
                refereed = true
                i += 1
                continue
            }
            // "by Author"
            if lower == "by", i + 1 < words.count {
                let next = words[i + 1]
                queryParts.append("author:\"\(next.capitalized)\"")
                i += 2
                continue
            }
            topicWords.append(word)
            i += 1
        }

        if !topicWords.isEmpty {
            let phrase = topicWords.joined(separator: " ")
            queryParts.append("abs:(\(phrase))")
        }
        if refereed {
            queryParts.append("property:refereed")
        }

        let query = queryParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let interpretation: String = {
            if queryParts.isEmpty { return "Free-text search (no parser available)" }
            return "Local pattern match (no AI available)"
        }()
        return QueryRewriteResult(
            query: query.isEmpty ? input : query,
            interpretation: interpretation,
            confidence: 0.4,
            source: .degenerate
        )
    }

    // MARK: - Prompt + JSON helpers

    fileprivate static func makeRewritePrompt(input: String) -> String {
        let yr = Calendar.current.component(.year, from: Date())
        return """
        Today is \(todayString()).
        Extract structured search fields from this scientific publication search request.

        Identify each piece separately:
          - authors: surnames of HUMAN researchers (last names, capitalized). Most requests have 0–3 authors. NEVER include: instruments (JWST, ALMA, LIGO, Hubble, Webb, Chandra, Fermi), satellites, surveys (SDSS, DESI, BOSS), telescopes, programs, common nouns, topic words.
          - bibstem: ADS journal abbreviation if a journal is named (Sci=Science, Nat=Nature, ApJ, ApJL, ApJS, MNRAS, A&A, PRL, PRD, PNAS, JCAP, JHEP) — empty otherwise.
          - topicWords: subject keywords. Instruments, surveys, methods, and physics terms ALL go here. Drop generic words ('paper', 'about', 'on', 'recent').
          - yearFrom / yearTo: year bounds if mentioned. "since 2020" → from=2020, to=0. "2018-2024" → from=2018, to=2024. "1970s" → from=1970, to=1979. "recent" → from=\(yr - 4), to=\(yr). "this year" → from=\(yr), to=\(yr). No year mentioned → both 0.
          - refereedOnly: true ONLY if the user EXPLICITLY requested refereed / peer-reviewed papers.

        CRITICAL: when in doubt about authors vs. topics, prefer topics. A query with 4+ "authors" is almost certainly wrong.

        Examples:
          Input: "abel norman first stars science"
          → authors=["Abel", "Norman"]  bibstem="Sci"  topicWords=["first stars"]
            yearFrom=0  yearTo=0  refereedOnly=false

          Input: "Riess dark energy since 2020 refereed"
          → authors=["Riess"]  bibstem=""  topicWords=["dark energy"]
            yearFrom=2020  yearTo=0  refereedOnly=true

          Input: "BBKS power spectrum"
          → authors=[]  bibstem=""  topicWords=["BBKS", "power spectrum"]
            yearFrom=0  yearTo=0  refereedOnly=false

          Input: "recent JWST galaxy formation"
          → authors=[]  bibstem=""  topicWords=["JWST", "galaxy formation"]
            yearFrom=\(yr - 4)  yearTo=\(yr)  refereedOnly=false
            (JWST is a telescope, NOT an author!)

          Input: "JWST galaxy formation high redshift"
          → authors=[]  bibstem=""  topicWords=["JWST", "galaxy formation", "high redshift"]
            yearFrom=0  yearTo=0  refereedOnly=false

          Input: "Bardeen ApJ 1986"
          → authors=["Bardeen"]  bibstem="ApJ"  topicWords=[]
            yearFrom=1986  yearTo=1986  refereedOnly=false

          Input: "galaxy rotation curves 1970s"
          → authors=[]  bibstem=""  topicWords=["galaxy rotation curves"]
            yearFrom=1970  yearTo=1979  refereedOnly=false
            (ALL of "galaxy", "rotation", "curves" are topic words, NOT authors!)

          Input: "SDSS DR17 spectroscopy"
          → authors=[]  bibstem=""  topicWords=["SDSS", "DR17", "spectroscopy"]
            yearFrom=0  yearTo=0  refereedOnly=false

          Input: "Smith and Jones 2020"
          → authors=["Smith", "Jones"]  bibstem=""  topicWords=[]
            yearFrom=2020  yearTo=2020  refereedOnly=false

        Request: \(input)
        """
    }

    fileprivate static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    fileprivate static func decodeCloudJSON(_ text: String) -> QueryRewriteResult? {
        let cleaned = stripCodeFences(text)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        do {
            let raw = try JSONDecoder().decode(CloudQueryPlan.self, from: data)
            return QueryRewriteResult(
                query: cleanQuery(raw.query ?? ""),
                interpretation: raw.interpretation ?? "ADS query",
                confidence: raw.confidence ?? 0.5,
                source: .cloud
            )
        } catch {
            logger.warning("Cloud JSON decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Post-process LLM-emitted query to fix common syntax mistakes:
    ///   - separators: replace `;` and stray commas-between-clauses with a space
    ///   - convert `title:"X Y Z"` → `title:(X Y Z)` for multi-word topic fields
    ///     (these fields are word-match in ADS; quoted = exact phrase, which the
    ///      LLM almost always emits incorrectly)
    ///   - excess whitespace → single spaces
    ///   - defer to ADSQueryNormalizer for unquoted authors / lowercase booleans
    fileprivate static func cleanQuery(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Separator fixes — Apple Intelligence sometimes uses `;` or `,` between
        // ADS clauses. ADS expects whitespace (or AND/OR/NOT).
        s = s.replacingOccurrences(of: ";", with: " ")
        s = collapseCommasOutsideQuotes(s)
        // Convert quoted multi-word topic values to parenthesised word lists.
        s = unquoteTopicFields(s)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        return ADSQueryNormalizer.normalize(s).correctedQuery
    }

    /// Topic fields where ADS expects a word list in `(...)`, not a quoted
    /// exact phrase: `title:"X Y" → title:(X Y)`. Single-word values stay
    /// quoted (they're harmless either way). `author:"Last, F"` is preserved
    /// because that field expects the quoted comma form.
    private static let topicFields: [String] = ["title", "abs", "abstract", "body", "full", "object", "keyword"]

    private static func unquoteTopicFields(_ input: String) -> String {
        var output = input
        for field in topicFields {
            // Match field:"value" — value may contain anything but quotes.
            let pattern = "\\b\(field):\"([^\"]+)\""
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsRange = NSRange(output.startIndex..., in: output)
            // Iterate matches in reverse so replacement offsets stay valid.
            let matches = regex.matches(in: output, range: nsRange).reversed()
            for m in matches {
                guard let valueRange = Range(m.range(at: 1), in: output),
                      let fullRange = Range(m.range(at: 0), in: output) else { continue }
                let value = String(output[valueRange])
                // Only rewrite when the value has multiple whitespace-separated words.
                let words = value.split(whereSeparator: { $0.isWhitespace })
                if words.count >= 2 {
                    output.replaceSubrange(fullRange, with: "\(field):(\(value))")
                }
            }
        }
        return output
    }

    /// Replace commas that appear OUTSIDE of double-quoted strings with spaces.
    /// Preserves `author:"Last, F"` while fixing `title:foo, abs:bar`.
    private static func collapseCommasOutsideQuotes(_ s: String) -> String {
        var out = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" {
                inQuote.toggle()
                out.append(ch)
            } else if ch == "," && !inQuote {
                out.append(" ")
            } else {
                out.append(ch)
            }
        }
        return out
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

private struct CloudQueryPlan: Decodable {
    let query: String?
    let interpretation: String?
    let confidence: Double?
}
