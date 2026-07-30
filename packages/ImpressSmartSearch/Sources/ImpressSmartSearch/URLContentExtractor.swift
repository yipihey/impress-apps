//
//  URLContentExtractor.swift
//  ImpressSmartSearch
//
//  Fetch a web page and extract any paper identifiers it contains. The output
//  is a list of `PaperIdentifierLite` that the caller runs through its existing
//  identifier-resolution pipeline (which already calls SciX/ADS).
//
//  ## Swift/Rust split
//
//  What stays here: the fetch. `URLSession` carries the system proxy
//  configuration, App Transport Security, the sandbox's network entitlement,
//  the shared cookie/cache stores and the redirect policy — reimplementing that
//  on `reqwest` would mean reimplementing platform policy, not logic, and would
//  need an async FFI boundary to do it. So the HTTP round-trip, the status-code
//  handling, the byte cap and the UTF-8/Latin-1 decode ladder stay Swift.
//
//  What moved to Rust (`crates/impress-smart-search`, module `url_extract`):
//  everything downstream of "here are some bytes" — the `<title>` read, the
//  DOI/arXiv/bibcode/PMID patterns, the arXiv legacy-archive whitelist that
//  keeps `gnd/4226307` from being mistaken for a paper, HTML entity decoding,
//  and the `%25XX` double-encoding unwind. That is the half that decides what
//  the user gets. Pinned by `test_fixtures/golden/url_extract.json`.
//

import Foundation
import ImbibRustCore
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

            // Everything from here is Rust.
            let extraction = smartSearchExtractPageIdentifiers(html: html)
            let title = extraction.pageTitle
            let identifiers = extraction.identifiers.compactMap(Self.identifier(from:))
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

    /// Unwind one round of `%25XX → %XX` in the URL. Returns nil if the URL
    /// contains no `%25` sequences or rebuilding fails.
    static func unwindDoubleEncoding(_ url: URL) -> URL? {
        guard let unwound = smartSearchUnwindDoubleEncoding(url: url.absoluteString) else {
            return nil
        }
        return URL(string: unwound)
    }

    private static func identifier(from ffi: SmartSearchIdentifier) -> PaperIdentifierLite? {
        switch ffi.kind {
        case "doi": return .doi(ffi.value)
        case "arxiv": return .arxiv(ffi.value)
        case "bibcode": return .bibcode(ffi.value)
        case "pmid": return .pmid(ffi.value)
        default: return nil
        }
    }
}
