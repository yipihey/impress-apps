//
//  URLContentExtractor.swift
//  ImpressSmartSearch
//
//  Fetch a web page and extract any paper identifiers it contains. The output
//  is a list of `PaperIdentifierLite` that the caller can run through its
//  identifier-resolution pipeline (which already calls SciX/ADS).
//
//  v1: regex-driven extraction. Pulls DOIs, arXiv IDs (new and old format),
//  ADS bibcodes, and PMIDs out of the HTML body. Most academic pages
//  (publisher landing, ADS, arXiv, ResearchGate, conference proceedings)
//  embed these prominently in the markup, so this catches the common cases
//  without an LLM.
//
//  v2 (deferred): LLM-based reference extraction for pages that have citation
//  lists in prose form without identifiers.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.impress.smartsearch", category: "urlext")

public actor URLContentExtractor {

    public static let shared = URLContentExtractor()

    private let session: URLSession
    private let maxBytes: Int
    private let timeout: TimeInterval

    public init(
        session: URLSession = .shared,
        maxBytes: Int = 4_000_000,            // 4 MB cap on page size
        timeout: TimeInterval = 12            // 12 s network timeout
    ) {
        self.session = session
        self.maxBytes = maxBytes
        self.timeout = timeout
    }

    /// Fetch a URL and extract any paper identifiers found in the HTML.
    /// Returns an empty `identifiers` list with a non-nil `reason` if the
    /// fetch failed or the page contains nothing recognisable.
    ///
    /// On HTTP 404, retries once with one round of `%25XX → %XX` decoding —
    /// handles URLs that have been doubly percent-encoded by some upstream
    /// (a common copy-paste-from-logs artifact).
    public func extract(from url: URL) async -> URLExtractionResult {
        let (result, status) = await fetchAndExtract(url: url)
        if status == 404, let alt = Self.unwindDoubleEncoding(url), alt != url {
            logger.info("Retrying \(url.absoluteString) with double-encoding unwound: \(alt.absoluteString)")
            let (retry, _) = await fetchAndExtract(url: alt)
            // Prefer the retry's identifiers; fall back to the original result for diagnostics.
            return retry.identifiers.isEmpty ? result : retry
        }
        return result
    }

    /// Single-shot fetch + extract. Returns the result and the HTTP status
    /// code (or nil for non-HTTP errors / network failures).
    private func fetchAndExtract(url: URL) async -> (URLExtractionResult, Int?) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            if let s = status, !(200..<400).contains(s) {
                logger.warning("URL fetch \(url.absoluteString) returned HTTP \(s)")
                return (URLExtractionResult(
                    url: url,
                    pageTitle: nil,
                    identifiers: [],
                    reason: "HTTP \(s) from \(url.host ?? "server")"
                ), status)
            }

            let bounded: Data = data.count > maxBytes ? data.prefix(maxBytes) : data
            let html = String(data: bounded, encoding: .utf8)
                ?? String(data: bounded, encoding: .isoLatin1)
                ?? ""
            let title = Self.extractTitle(from: html)
            let identifiers = Self.extractIdentifiers(from: html)
            logger.info("URL extract \(url.absoluteString): title='\(title ?? "?")', \(identifiers.count) identifier(s)")

            if identifiers.isEmpty {
                return (URLExtractionResult(
                    url: url,
                    pageTitle: title,
                    identifiers: [],
                    reason: "No DOI, arXiv id, bibcode, or PMID found on the page."
                ), status)
            }
            return (URLExtractionResult(url: url, pageTitle: title, identifiers: identifiers), status)
        } catch {
            logger.warning("URL fetch \(url.absoluteString) failed: \(error.localizedDescription)")
            return (URLExtractionResult(
                url: url,
                pageTitle: nil,
                identifiers: [],
                reason: "Couldn't fetch the page: \(error.localizedDescription)"
            ), nil)
        }
    }

    /// Surgically unwind one round of `%25XX → %XX` percent-encoding in the URL
    /// path / query. Wikipedia (and similar) encode an apostrophe as `%27`; if
    /// the URL has been doubly encoded, the apostrophe shows up as `%2527`
    /// which the server interprets as a literal `%27` substring in the slug.
    /// Returns nil if the URL contains no `%25` sequences or rebuilding fails.
    static func unwindDoubleEncoding(_ url: URL) -> URL? {
        let abs = url.absoluteString
        guard abs.range(of: #"%25[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil else {
            return nil
        }
        let unwound = abs.replacingOccurrences(
            of: #"%25([0-9A-Fa-f]{2})"#,
            with: "%$1",
            options: .regularExpression
        )
        return URL(string: unwound)
    }

    // MARK: - HTML scraping

    static func extractTitle(from html: String) -> String? {
        let nsRange = NSRange(html.startIndex..., in: html)
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>([\s\S]*?)</title>"#,
                                                   options: .caseInsensitive),
              let m = regex.firstMatch(in: html, range: nsRange),
              let r = Range(m.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[r])
        return decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract identifiers in priority order: DOI, arXiv (new/old), bibcode,
    /// PMID. Deduped while preserving first-seen order.
    static func extractIdentifiers(from html: String) -> [PaperIdentifierLite] {
        var found: [PaperIdentifierLite] = []
        var seen: Set<String> = []
        func add(_ id: PaperIdentifierLite) {
            let key = "\(id.typeName):\(id.value.lowercased())"
            if seen.insert(key).inserted { found.append(id) }
        }

        // DOI: 10.NNNN/anything-not-whitespace-or-html-delimiter.
        // We deliberately stop at HTML/URL boundary characters: " < > ( ) { }
        // [ ] \ space, AND the ampersand `&` — real DOIs never contain `&`,
        // but `&amp;` and `&format=...` query trailers are everywhere in HTML.
        let doiPattern = #"\b10\.\d{4,9}/[^\s"<>()\\{}\[\]&]+"#
        for raw in matches(in: html, pattern: doiPattern) {
            let cleaned = trimTrailingPunct(raw)
            if cleaned.count >= 8 { add(.doi(cleaned)) }
        }

        // arXiv new format: arXiv:YYMM.NNNNN(vN)? or bare YYMM.NNNNN preceded by arXiv markers.
        // Two passes — explicit "arXiv:" prefix first, then bare ids in URL contexts.
        let arxivPrefixed = #"(?i)\barxiv[:\s/]+(\d{4}\.\d{4,5})(?:v\d+)?"#
        for cap in capturedMatches(in: html, pattern: arxivPrefixed, captureGroup: 1) {
            add(.arxiv(cap))
        }
        // Bare new format (be conservative — only allow when surrounded by URL/text boundaries).
        let arxivBare = #"\b(\d{4}\.\d{4,5})\b"#
        for cap in capturedMatches(in: html, pattern: arxivBare, captureGroup: 1) {
            // Skip year-only-looking bare numbers; YYMM.NNNNN is min 9 chars
            if cap.count >= 9 { add(.arxiv(cap)) }
        }
        // arXiv old format: archive[.subclass]/YYMMNNN. Restrict to the known
        // arxiv archive whitelist — otherwise unrelated `slug/1234567` patterns
        // (e.g. `gnd/4226307` for German National Library IDs) get mis-classified.
        let arxivOld = #"\b([a-z\-]{2,12}(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?\b"#
        for cap in capturedMatches(in: html, pattern: arxivOld, captureGroup: 1) {
            let archive = cap.split(separator: "/").first.map(String.init)?
                .split(separator: ".").first.map(String.init) ?? ""
            if Self.arxivOldArchives.contains(archive) {
                add(.arxiv(cap))
            }
        }

        // ADS bibcode: 19 chars, year prefix.
        let bibcode = #"\b(\d{4}[A-Za-z&\.][A-Za-z&\.]{1,7}[\.\d][\.\d]+[A-Z])\b"#
        for cap in capturedMatches(in: html, pattern: bibcode, captureGroup: 1) {
            if cap.count == 19 { add(.bibcode(cap)) }
        }

        // PMID: pubmed-style URLs and explicit PMID labels.
        let pmidLabel = #"(?i)\bpmid[:\s]+(\d{5,9})\b"#
        for cap in capturedMatches(in: html, pattern: pmidLabel, captureGroup: 1) {
            add(.pmid(cap))
        }
        let pubmedURL = #"pubmed\.ncbi\.nlm\.nih\.gov/(\d{5,9})"#
        for cap in capturedMatches(in: html, pattern: pubmedURL, captureGroup: 1) {
            add(.pmid(cap))
        }

        return found
    }

    /// arXiv pre-2007 archive identifiers. Drawn from
    /// https://info.arxiv.org/help/arxiv_identifier.html (legacy archives).
    /// Used to filter out non-arxiv `slug/N{7}` patterns (GND, OCLC, etc.).
    static let arxivOldArchives: Set<String> = [
        "math", "astro-ph", "hep-th", "hep-ph", "hep-ex", "hep-lat", "gr-qc",
        "nucl-th", "nucl-ex", "cond-mat", "quant-ph", "q-alg", "alg-geom",
        "dg-ga", "funct-an", "q-bio", "cs", "nlin", "physics", "chao-dyn",
        "solv-int", "comp-gas", "adap-org", "atom-ph", "plasm-ph", "supr-con",
        "mtrl-th", "cmp-lg", "acc-phys", "patt-sol", "ao-sci", "bayes-an",
        "chem-ph"
    ]

    // MARK: - Regex helpers

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func capturedMatches(in text: String, pattern: String, captureGroup: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { m -> String? in
            guard m.numberOfRanges > captureGroup,
                  let r = Range(m.range(at: captureGroup), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func trimTrailingPunct(_ s: String) -> String {
        var t = s
        while let last = t.last, ".,;:)\"']".contains(last) {
            t.removeLast()
        }
        return t
    }

    // MARK: - HTML entity decoding (just the common ones)

    private static let htmlEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">",
        "&quot;": "\"", "&apos;": "'", "&#39;": "'",
        "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
        "&hellip;": "…", "&copy;": "©"
    ]

    static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        for (k, v) in htmlEntities {
            out = out.replacingOccurrences(of: k, with: v)
        }
        // Numeric entities &#N; and &#xHH;
        if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#, options: []) {
            let nsRange = NSRange(out.startIndex..., in: out)
            let matches = regex.matches(in: out, range: nsRange).reversed()
            for m in matches {
                guard let full = Range(m.range, in: out),
                      let inner = Range(m.range(at: 1), in: out) else { continue }
                let raw = String(out[inner])
                let scalar: Unicode.Scalar?
                if raw.lowercased().hasPrefix("x"), let n = UInt32(raw.dropFirst(), radix: 16) {
                    scalar = Unicode.Scalar(n)
                } else if let n = UInt32(raw) {
                    scalar = Unicode.Scalar(n)
                } else {
                    scalar = nil
                }
                if let scalar { out.replaceSubrange(full, with: String(Character(scalar))) }
            }
        }
        return out
    }
}
