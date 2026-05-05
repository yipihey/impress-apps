//
//  IntentClassifier.swift
//  ImpressSmartSearch
//
//  Deterministic, no-LLM classification of Cmd+S search input. Decides which
//  downstream path to take:
//
//    .identifier  → bare DOI / arXiv / bibcode / PMID
//    .fielded     → ADS-syntax query (passthrough)
//    .reference   → pasted citation string(s)
//    .freeText    → anything else
//
//  Designed for hot-path use (every keystroke). All decisions are regex-driven.
//

import Foundation

public enum IntentClassifier {

    /// Classify a user input string. Empty input → `.freeText("")`.
    public static func classify(_ input: String) -> SearchIntent {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .freeText(query: "") }

        // 1. URL — single line, http(s) scheme. Three short-circuits before
        //    we fall through to "fetch and extract":
        //     a. doi.org / arxiv abstract / pubmed / ADS abstract / publisher
        //        landing page → `.identifier`
        //     b. ADS search URL with `q=` parameter → `.fielded` (passthrough
        //        the query — the page itself is JS-rendered and unscrapable)
        //     c. Otherwise → `.url` and let the extractor fetch the HTML.
        if !trimmed.contains("\n"), let url = urlMatch(trimmed) {
            if let id = identifierFromURL(url) {
                return .identifier(id)
            }
            if let query = searchQueryFromURL(url) {
                return .fielded(query: query)
            }
            return .url(url)
        }

        // 2. Identifier — full-string match, single line only.
        if !trimmed.contains("\n"), let id = identifierMatch(trimmed) {
            return .identifier(id)
        }

        // 3. Fielded — ADS qualifier syntax wins over reference heuristics.
        if hasFieldQualifiers(trimmed) {
            return .fielded(query: trimmed)
        }

        // 4. Reference — multi-block paste or single-string heuristic match.
        let blocks = splitReferenceBlocks(trimmed)
        if blocks.count >= 2 {
            return .reference(blocks: blocks)
        }
        if looksLikeReference(trimmed) {
            return .reference(blocks: [trimmed])
        }

        // 5. Free-text fallthrough.
        return .freeText(query: trimmed)
    }

    // MARK: - URL detection

    /// Match a single bare http(s) URL.
    public static func urlMatch(_ input: String) -> URL? {
        guard input.range(of: #"^https?://"#, options: .regularExpression) != nil,
              let url = URL(string: input),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    /// Some URLs are direct identifier links — `https://doi.org/10.x/y`,
    /// `https://arxiv.org/abs/2301.04153`, `https://pubmed.ncbi.nlm.nih.gov/12345678`,
    /// `https://ui.adsabs.harvard.edu/abs/2002Sci...295...93A`, plus most
    /// publisher landing pages whose URL embeds the DOI in the path
    /// (Wiley, Science.org, Springer, Cell, Taylor & Francis, AGU, ACS, …).
    /// Recognize these so the caller routes them to the cheap identifier
    /// path instead of fetching the HTML and scraping the bibliography.
    public static func identifierFromURL(_ url: URL) -> PaperIdentifierLite? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path

        // doi.org / dx.doi.org → DOI is the path (drop leading /)
        if host == "doi.org" || host == "dx.doi.org" {
            let doi = String(path.drop(while: { $0 == "/" }))
            if doi.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil {
                return .doi(doi)
            }
        }

        // arxiv.org/abs/<id>  or  arxiv.org/pdf/<id>(.pdf)
        if host.hasSuffix("arxiv.org") {
            let segments = path.split(separator: "/").map(String.init)
            if segments.count >= 2, segments[0] == "abs" || segments[0] == "pdf" {
                var id = segments.dropFirst().joined(separator: "/")
                // Strip trailing .pdf and version suffix-stripping is OK to keep.
                if id.hasSuffix(".pdf") { id = String(id.dropLast(4)) }
                if id.range(of: #"^(\d{4}\.\d{4,5}(v\d+)?|[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?)$"#,
                            options: .regularExpression) != nil {
                    return .arxiv(id)
                }
            }
        }

        // pubmed.ncbi.nlm.nih.gov/<digits>
        if host.hasSuffix("pubmed.ncbi.nlm.nih.gov") || host.hasSuffix("ncbi.nlm.nih.gov") {
            let segments = path.split(separator: "/").map(String.init)
            for seg in segments where seg.range(of: #"^\d{5,9}$"#, options: .regularExpression) != nil {
                return .pmid(seg)
            }
        }

        // nature.com/articles/<slug> — Nature publications encode their DOI
        // suffix as the URL slug (DOI prefix is always 10.1038). Without this
        // short-circuit the page-fetch path would scrape the article's
        // bibliography, returning the article DOI buried among ~30 references.
        if host.hasSuffix("nature.com") {
            let segments = path.split(separator: "/").map(String.init)
            if segments.count >= 2, segments[0] == "articles" {
                let slug = segments[1]
                // Nature article slugs look like `s41586-024-07930-y`,
                // `nature01080`, `s41467-...`, etc. Accept anything non-empty
                // that isn't itself an unresolvable token.
                if !slug.isEmpty, slug.range(of: #"^[a-z0-9._\-]+$"#, options: .regularExpression) != nil {
                    return .doi("10.1038/\(slug)")
                }
            }
        }

        // ui.adsabs.harvard.edu/abs/<bibcode>
        if host.hasSuffix("adsabs.harvard.edu") {
            let segments = path.split(separator: "/").map(String.init)
            if let absIdx = segments.firstIndex(of: "abs"), absIdx + 1 < segments.count {
                let candidate = segments[absIdx + 1]
                // The bibcode in URLs is typically URL-encoded; decode.
                let decoded = candidate.removingPercentEncoding ?? candidate
                if decoded.count == 19,
                   decoded.range(of: #"^\d{4}[A-Za-z&\.][A-Za-z&\.]{1,7}[\.\d][\.\d]+[A-Z]$"#,
                                 options: .regularExpression) != nil {
                    return .bibcode(decoded)
                }
            }
        }

        // Generic publisher pattern: any URL whose path contains a DOI prefix
        // `10.NNNN/...` is most likely the article's landing page. Common forms:
        //   /doi/10.x/y                    (Science.org, ACS, AIP, T&F, …)
        //   /doi/full/10.x/y               (Wiley, AGU)
        //   /doi/abs/10.x/y                (Wiley)
        //   /doi/pdf/10.x/y, /doi/epdf/…   (Wiley, Cell)
        //   /doi/reader/10.x/y             (Wiley)
        //   /doi/fulltext/10.x/y           (Cell)
        //   /article/10.x/y                (Springer)
        //   /chapter/10.x/y                (Springer)
        //   /article/abs/10.x/y            (some Cambridge / OUP)
        //
        // Match `10.{4-9 digits}/<rest-up-to-?#>` anywhere in the path. We
        // stop at `?`, `#`, end-of-path. The DOI itself is allowed to contain
        // `/`, `(`, `)`, `.`, `-`, etc.
        if let doi = doiInPath(path) {
            return .doi(doi)
        }

        return nil
    }

    /// Extract a search query embedded in a URL — currently only handles
    /// ADS search URLs (`ui.adsabs.harvard.edu/search/...?q=...` or with
    /// the query as a path-style fragment). Returns the decoded `q=` value
    /// suitable for handing to `.fielded(query:)`, or nil if the URL isn't
    /// an ADS search or has no `q=` parameter.
    public static func searchQueryFromURL(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host.hasSuffix("adsabs.harvard.edu") else { return nil }

        // ADS search URLs come in two flavours:
        //   /search?q=...           (proper query string)
        //   /search/<k=v&k=v&...>   (slash-style — params live in the path)
        // In either case we need the `q=` parameter SPECIFICALLY, not the
        // `q=` substring inside `fq=...` (Solr filter) or `aq=...`.

        let path = url.path
        guard path.hasPrefix("/search") else { return nil }

        // 1. Standard query component: ?q=...
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let q = components.queryItems?.first(where: { $0.name == "q" })?.value,
           !q.isEmpty {
            return q
        }

        // 2. ADS-style: split the path tail on `&` and find the segment
        //    whose key is exactly `q` (not `fq`, `aq`, etc.).
        let tail: String
        if path.hasPrefix("/search/") {
            tail = String(path.dropFirst("/search/".count))
        } else {
            return nil
        }
        for segment in tail.split(separator: "&") {
            let pair = segment.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == "q" else { continue }
            let value = String(pair[1])
            let decoded = value.removingPercentEncoding ?? value
            return decoded.isEmpty ? nil : decoded
        }
        return nil
    }

    /// Extract a DOI from a URL path component. Returns the canonical DOI
    /// string (no leading slash, no trailing punctuation) or nil if the path
    /// doesn't contain a `10.x/y` prefix.
    static func doiInPath(_ path: String) -> String? {
        // Find first occurrence of `10.NNNN/` and take everything from there
        // to the end of the path (stopping at `?` and `#` is implicit since
        // URL.path doesn't include those).
        guard let regex = try? NSRegularExpression(
            pattern: #"10\.\d{4,9}/[^\s?#]+"#,
            options: []
        ) else { return nil }
        let nsRange = NSRange(path.startIndex..., in: path)
        guard let m = regex.firstMatch(in: path, range: nsRange),
              let r = Range(m.range, in: path) else { return nil }
        var doi = String(path[r])
        // Strip trailing punctuation that's likely URL/path noise rather
        // than part of the DOI (matches `trimTrailingPunct` in URLContentExtractor).
        while let last = doi.last, ".,;:)\"'/]".contains(last) {
            doi.removeLast()
        }
        // Sanity: a real DOI is at least a few chars after the slash.
        let parts = doi.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return doi
    }

    // MARK: - Identifier detection

    /// Match a single bare identifier. Returns nil if the input is anything
    /// other than a clean identifier (rejects identifiers buried in prose).
    public static func identifierMatch(_ input: String) -> PaperIdentifierLite? {
        let lower = input.lowercased()
        let stripped: String
        if lower.hasPrefix("doi:") { stripped = String(input.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        else if lower.hasPrefix("arxiv:") { stripped = String(input.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        else if lower.hasPrefix("pmid:") { stripped = String(input.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        else if lower.hasPrefix("bibcode:") { stripped = String(input.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        else { stripped = input }

        // DOI: 10.NNNN/anything (no spaces)
        if let m = stripped.wholeMatch(of: #/^10\.\d{4,9}\/\S+$/#) {
            return .doi(String(m.0))
        }
        // arXiv new format: YYMM.NNNNN with optional version
        if stripped.wholeMatch(of: #/^\d{4}\.\d{4,5}(v\d+)?$/#) != nil {
            return .arxiv(stripped)
        }
        // arXiv old format: archive[.subclass]/YYMMNNN with optional version
        if stripped.wholeMatch(of: #/^[a-z\-]+(\.[A-Z]{2})?\/\d{7}(v\d+)?$/#) != nil {
            return .arxiv(stripped)
        }
        // Bibcode: exactly 19 chars, year prefix, ends with author letter.
        if stripped.count == 19, stripped.wholeMatch(of: #/^\d{4}[A-Za-z&\.][A-Za-z&\.]{1,7}[\.\d][\.\d]+[A-Z]$/#) != nil {
            return .bibcode(stripped)
        }
        // PMID: only when prefixed (a bare 7-digit number is too ambiguous).
        if lower.hasPrefix("pmid:"),
           stripped.wholeMatch(of: #/^\d{5,9}$/#) != nil {
            return .pmid(stripped)
        }
        return nil
    }

    // MARK: - Fielded query detection

    public static let adsFieldQualifiers: Set<String> = [
        "author", "first_author", "title", "abs", "abstract",
        "year", "bibcode", "doi", "arxiv", "orcid",
        "aff", "affiliation", "full", "object", "body",
        "keyword", "property", "doctype", "collection", "bibstem",
        "arxiv_class", "identifier", "citations", "references",
        "similar", "trending", "reviews", "useful",
        "author_count", "citation_count", "read_count", "database",
        "au", "ti", "ab"
    ]

    public static func hasFieldQualifiers(_ text: String) -> Bool {
        for field in adsFieldQualifiers {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: field)):"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        // ADS function operators
        let funcPattern = #"\b(citations|references|similar|trending|reviews|useful)\("#
        if text.range(of: funcPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    // MARK: - Reference detection

    private static let journalTokens: Set<String> = [
        "ApJ", "ApJL", "ApJS", "MNRAS", "A&A", "AAS",
        "Nature", "Science", "PNAS",
        "PRL", "PRD", "PRA", "PRB", "PRC", "PRE", "PRX",
        "JCAP", "JHEP", "JHEPL",
        "PhysRev", "Phys.Rev.", "PhysLett", "PhysLet",
        "Astrophys.", "Astron.", "AstroLett",
        "Icarus", "Geophys", "JGR"
    ]

    /// True when ≥2 reference signals fire on a single-line input, or any one
    /// signal fires on multi-line input.
    public static func looksLikeReference(_ text: String) -> Bool {
        var score = 0
        if text.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil {
            score += 1
        }
        let volPagePatterns = [
            #"\b\d{1,4},\s*\d{1,4}\b"#,
            #"(?i)\bvol\.?\s*\d+\b"#,
            #"(?i)\bpp?\.\s*\d+"#
        ]
        for pat in volPagePatterns {
            if text.range(of: pat, options: .regularExpression) != nil {
                score += 1
                break
            }
        }
        for token in journalTokens {
            if text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: token))\\b",
                          options: .regularExpression) != nil {
                score += 1
                break
            }
        }
        if text.range(of: #"(?i)\bet\s+al\.?"#, options: .regularExpression) != nil {
            score += 1
        }
        if text.range(of: #"\b[A-Z][a-z]+,\s*[A-Z][a-z]*\.?"#, options: .regularExpression) != nil {
            score += 1
        }
        let bibitemPattern = #"(?m)^\s*(\\bibitem|\[\d{1,3}\]|\(\d{1,3}\)|\d{1,3}\.\s+[A-Z])"#
        if text.range(of: bibitemPattern, options: .regularExpression) != nil {
            score += 1
        }
        let isMultiLine = text.contains("\n")
        if isMultiLine { return score >= 1 }
        return score >= 2
    }

    // MARK: - Reference block splitting

    public static func splitReferenceBlocks(_ text: String) -> [String] {
        // Strategy 1: \bibitem
        if text.range(of: #"\\bibitem"#, options: .regularExpression) != nil {
            let blocks = splitByLinePrefix(text) { line in
                line.hasPrefix(#"\bibitem"#)
            }
            if blocks.count >= 2 { return blocks }
        }
        // Strategy 2: numbered markers at line start
        let blocks = splitByLinePrefix(text) { line in
            line.range(
                of: #"^[\[\(]?\d{1,3}[\]\.\)]\s+"#,
                options: .regularExpression
            ) != nil
        }
        if blocks.count >= 2 { return blocks }
        // Strategy 3: blank-line-separated
        let blankSplit = blankLineSplit(text)
        if blankSplit.count >= 2 {
            return blankSplit
        }
        return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    private static func splitByLinePrefix(
        _ text: String,
        isStart: (String) -> Bool
    ) -> [String] {
        var blocks: [String] = []
        var current = ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmedLeading = String(line).drop(while: \.isWhitespace)
            let starts = isStart(String(trimmedLeading))
            if starts {
                let finalized = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalized.isEmpty { blocks.append(finalized) }
                current = String(line)
            } else if !current.isEmpty {
                current += "\n" + String(line)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { blocks.append(tail) }
        return blocks
    }

    private static func blankLineSplit(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy(\.isWhitespace) {
                if !current.isEmpty {
                    let block = current.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !block.isEmpty { blocks.append(block) }
                    current = []
                }
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty {
            let block = current.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { blocks.append(block) }
        }
        return blocks
    }
}
