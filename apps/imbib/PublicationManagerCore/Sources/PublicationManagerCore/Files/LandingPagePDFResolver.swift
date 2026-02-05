//
//  LandingPagePDFResolver.swift
//  PublicationManagerCore
//
//  Resolves PDF URLs by following DOI landing pages and extracting PDF links from HTML.
//

import Foundation
import OSLog

// MARK: - Landing Page PDF Resolver

/// Service for resolving PDF URLs from publisher landing pages.
///
/// When OpenAlex only provides a landing page URL (not a direct PDF link), this service:
/// 1. Follows redirects from DOI URLs to the publisher landing page
/// 2. Fetches and parses the HTML to find PDF links
/// 3. Validates discovered URLs
/// 4. Caches results to avoid repeated requests
///
/// ## Resolution Strategies (in order)
///
/// 1. Meta tag: `<meta name="citation_pdf_url">`
/// 2. Link tag: `<link rel="alternate" type="application/pdf">`
/// 3. Publisher-specific patterns via `PublisherHTMLParsers`
/// 4. Heuristic scan: links containing `/pdf`, `.pdf`, "Download PDF"
public actor LandingPagePDFResolver {

    // MARK: - Singleton

    public static let shared = LandingPagePDFResolver()

    // MARK: - Types

    /// Result of landing page resolution.
    public struct ResolutionResult: Sendable {
        public let pdfURL: URL?
        public let status: ResolutionStatus
        public let publisherHost: String?
        public let timestamp: Date

        public init(
            pdfURL: URL? = nil,
            status: ResolutionStatus,
            publisherHost: String? = nil,
            timestamp: Date = Date()
        ) {
            self.pdfURL = pdfURL
            self.status = status
            self.publisherHost = publisherHost
            self.timestamp = timestamp
        }
    }

    /// Status of landing page resolution.
    public enum ResolutionStatus: Sendable, Equatable {
        case found                         // PDF URL found
        case requiresAuthentication        // Need login/proxy
        case captchaBlocked                // CAPTCHA detected
        case rateLimited                   // Too many requests
        case notFound                      // No PDF link found on page
        case fetchFailed(String)           // Network or parsing error
    }

    // MARK: - Properties

    private let session: URLSession
    private let parsers: PublisherHTMLParsers
    private let cache: NSCache<NSString, CachedResolution>
    private let cacheTTL: TimeInterval
    private let negativeCacheTTL: TimeInterval

    /// Default cache TTL: 24 hours
    public static let defaultCacheTTL: TimeInterval = 24 * 60 * 60
    /// Negative cache TTL: 1 hour (retry failures sooner)
    public static let defaultNegativeCacheTTL: TimeInterval = 60 * 60

    // MARK: - Initialization

    public init(
        parsers: PublisherHTMLParsers? = nil,
        cacheTTL: TimeInterval = LandingPagePDFResolver.defaultCacheTTL,
        negativeCacheTTL: TimeInterval = LandingPagePDFResolver.defaultNegativeCacheTTL,
        cacheCountLimit: Int = 1000
    ) {
        self.parsers = parsers ?? PublisherHTMLParsers()
        self.cacheTTL = cacheTTL
        self.negativeCacheTTL = negativeCacheTTL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        self.session = URLSession(configuration: config)

        self.cache = NSCache<NSString, CachedResolution>()
        cache.countLimit = cacheCountLimit
    }

    // MARK: - Resolution

    /// Resolve PDF URL from a landing page URL.
    ///
    /// - Parameters:
    ///   - landingPageURL: The DOI or landing page URL
    ///   - useProxy: Whether to prepend proxy URL
    ///   - proxyPrefix: The library proxy URL prefix
    /// - Returns: Resolution result with PDF URL if found
    public func resolve(
        landingPageURL: URL,
        useProxy: Bool = false,
        proxyPrefix: String? = nil
    ) async -> ResolutionResult {
        let cacheKey = cacheKeyFor(url: landingPageURL, useProxy: useProxy)

        // Check cache
        if let cached = getCachedResult(for: cacheKey) {
            Logger.files.debug("[LandingPagePDFResolver] Cache hit for \(landingPageURL.absoluteString)")
            return cached
        }

        // Apply proxy if needed
        let fetchURL: URL
        if useProxy, let prefix = proxyPrefix, !prefix.isEmpty {
            fetchURL = URL(string: prefix + landingPageURL.absoluteString) ?? landingPageURL
        } else {
            fetchURL = landingPageURL
        }

        Logger.files.info("[LandingPagePDFResolver] Fetching: \(fetchURL.absoluteString)")

        // Fetch the landing page
        let result = await fetchAndParse(url: fetchURL, originalURL: landingPageURL)

        // Cache the result
        cacheResult(result, for: cacheKey)

        return result
    }

    /// Resolve PDF URL from a DOI.
    ///
    /// Constructs the DOI URL and resolves from the landing page.
    public func resolve(
        doi: String,
        useProxy: Bool = false,
        proxyPrefix: String? = nil
    ) async -> ResolutionResult {
        let cleanDOI = cleanDOI(doi)
        guard let doiURL = URL(string: "https://doi.org/\(cleanDOI)") else {
            return ResolutionResult(status: .fetchFailed("Invalid DOI"))
        }
        return await resolve(landingPageURL: doiURL, useProxy: useProxy, proxyPrefix: proxyPrefix)
    }

    // MARK: - Fetching and Parsing

    private func fetchAndParse(url: URL, originalURL: URL) async -> ResolutionResult {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return ResolutionResult(
                    status: .fetchFailed("Invalid response"),
                    publisherHost: url.host
                )
            }

            // Check for blocking responses
            if let blockingStatus = checkBlockingResponse(httpResponse, url: url) {
                return blockingStatus
            }

            // Get final URL after redirects
            let finalURL = httpResponse.url ?? url
            let publisherHost = finalURL.host

            // Parse HTML
            guard let html = String(data: data, encoding: .utf8) else {
                return ResolutionResult(
                    status: .fetchFailed("Could not decode HTML"),
                    publisherHost: publisherHost
                )
            }

            // Check for blocking content in HTML
            if let htmlBlockingStatus = checkBlockingContent(html: html, publisherHost: publisherHost) {
                return htmlBlockingStatus
            }

            // Try to extract PDF URL
            if let pdfURL = await extractPDFURL(from: html, baseURL: finalURL) {
                Logger.files.info("[LandingPagePDFResolver] Found PDF: \(pdfURL.absoluteString)")
                return ResolutionResult(
                    pdfURL: pdfURL,
                    status: .found,
                    publisherHost: publisherHost
                )
            }

            Logger.files.info("[LandingPagePDFResolver] No PDF found on \(finalURL.absoluteString)")
            return ResolutionResult(
                status: .notFound,
                publisherHost: publisherHost
            )

        } catch let error as URLError {
            if error.code == .userAuthenticationRequired {
                return ResolutionResult(
                    status: .requiresAuthentication,
                    publisherHost: url.host
                )
            }
            Logger.files.warning("[LandingPagePDFResolver] Fetch error: \(error.localizedDescription)")
            return ResolutionResult(
                status: .fetchFailed(error.localizedDescription),
                publisherHost: url.host
            )
        } catch {
            Logger.files.warning("[LandingPagePDFResolver] Unexpected error: \(error.localizedDescription)")
            return ResolutionResult(
                status: .fetchFailed(error.localizedDescription),
                publisherHost: url.host
            )
        }
    }

    private func checkBlockingResponse(_ response: HTTPURLResponse, url: URL) -> ResolutionResult? {
        switch response.statusCode {
        case 200...299:
            return nil  // Success, continue parsing

        case 401, 403:
            // Check if it's a CAPTCHA redirect
            if let location = response.value(forHTTPHeaderField: "Location"),
               isCaptchaURL(location) {
                return ResolutionResult(
                    status: .captchaBlocked,
                    publisherHost: url.host
                )
            }
            return ResolutionResult(
                status: .requiresAuthentication,
                publisherHost: url.host
            )

        case 429:
            return ResolutionResult(
                status: .rateLimited,
                publisherHost: url.host
            )

        default:
            return ResolutionResult(
                status: .fetchFailed("HTTP \(response.statusCode)"),
                publisherHost: url.host
            )
        }
    }

    private func checkBlockingContent(html: String, publisherHost: String?) -> ResolutionResult? {
        let lowercased = html.lowercased()

        // CAPTCHA detection
        let captchaPatterns = [
            "captcha", "recaptcha", "hcaptcha", "cf-challenge",
            "cloudflare", "please verify", "are you a robot",
            "security check", "ddos protection"
        ]
        if captchaPatterns.contains(where: { lowercased.contains($0) }) {
            // Additional check: ensure it's actually a CAPTCHA page, not just mentioning it
            if lowercased.contains("challenge-form") || lowercased.contains("cf-browser-verification") ||
               lowercased.contains("g-recaptcha") || lowercased.contains("h-captcha") {
                return ResolutionResult(
                    status: .captchaBlocked,
                    publisherHost: publisherHost
                )
            }
        }

        // Paywall/authentication detection
        let paywallPatterns = [
            "sign in to access", "login required", "subscription required",
            "purchase this article", "buy this article", "rent this article",
            "access denied", "institutional access"
        ]
        if paywallPatterns.contains(where: { lowercased.contains($0) }) {
            return ResolutionResult(
                status: .requiresAuthentication,
                publisherHost: publisherHost
            )
        }

        return nil
    }

    // MARK: - PDF URL Extraction

    private func extractPDFURL(from html: String, baseURL: URL) async -> URL? {
        let host = baseURL.host?.lowercased() ?? ""

        // 1. Try publisher-specific parser first (most reliable)
        if let pdfURL = parsers.parse(html: html, baseURL: baseURL, publisherHost: host) {
            return pdfURL
        }

        // 2. Try standard meta tag
        if let pdfURL = extractFromMetaTag(html: html, baseURL: baseURL) {
            return pdfURL
        }

        // 3. Try link tag
        if let pdfURL = extractFromLinkTag(html: html, baseURL: baseURL) {
            return pdfURL
        }

        // 4. Heuristic scan for PDF links
        if let pdfURL = extractFromHeuristics(html: html, baseURL: baseURL) {
            return pdfURL
        }

        return nil
    }

    /// Extract PDF URL from `<meta name="citation_pdf_url">` tag.
    private func extractFromMetaTag(html: String, baseURL: URL) -> URL? {
        // Pattern: <meta name="citation_pdf_url" content="...">
        let pattern = #"<meta\s+name\s*=\s*["']citation_pdf_url["']\s+content\s*=\s*["']([^"']+)["']"#
        let altPattern = #"<meta\s+content\s*=\s*["']([^"']+)["']\s+name\s*=\s*["']citation_pdf_url["']"#

        if let url = extractURL(from: html, pattern: pattern, baseURL: baseURL) {
            return url
        }
        return extractURL(from: html, pattern: altPattern, baseURL: baseURL)
    }

    /// Extract PDF URL from `<link rel="alternate" type="application/pdf">` tag.
    private func extractFromLinkTag(html: String, baseURL: URL) -> URL? {
        let pattern = #"<link[^>]+rel\s*=\s*["']alternate["'][^>]+type\s*=\s*["']application/pdf["'][^>]+href\s*=\s*["']([^"']+)["']"#
        let altPattern = #"<link[^>]+href\s*=\s*["']([^"']+)["'][^>]+type\s*=\s*["']application/pdf["']"#

        if let url = extractURL(from: html, pattern: pattern, baseURL: baseURL) {
            return url
        }
        return extractURL(from: html, pattern: altPattern, baseURL: baseURL)
    }

    /// Heuristic extraction of PDF links from HTML.
    private func extractFromHeuristics(html: String, baseURL: URL) -> URL? {
        // Look for links with PDF-related patterns
        let linkPattern = #"<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>"#

        guard let regex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        var candidates: [(url: URL, score: Int)] = []

        for match in matches {
            guard let urlRange = Range(match.range(at: 1), in: html) else { continue }
            let urlString = String(html[urlRange])

            guard let url = resolveURL(urlString, baseURL: baseURL) else { continue }

            var score = 0
            let lowerURL = urlString.lowercased()
            let lowerHost = url.host?.lowercased() ?? ""

            // Score PDF-related patterns
            if lowerURL.hasSuffix(".pdf") { score += 10 }
            if lowerURL.contains("/pdf/") { score += 8 }
            if lowerURL.contains("/pdf") && !lowerURL.contains("/pdfjs") { score += 5 }
            if lowerURL.contains("download") && lowerURL.contains("pdf") { score += 7 }
            if lowerURL.contains("fulltext") { score += 4 }
            if lowerURL.contains("epdf") { score += 6 }

            // Penalize non-PDF patterns
            if lowerURL.contains("supplementary") { score -= 5 }
            if lowerURL.contains("appendix") { score -= 3 }
            if lowerURL.contains("figure") { score -= 5 }
            if lowerURL.contains("image") { score -= 5 }
            if lowerURL.contains("table") { score -= 3 }

            // Prefer same host
            if lowerHost == baseURL.host?.lowercased() { score += 2 }

            if score > 0 {
                candidates.append((url, score))
            }
        }

        // Return highest-scoring candidate
        return candidates.sorted { $0.score > $1.score }.first?.url
    }

    // MARK: - URL Helpers

    private func extractURL(from html: String, pattern: String, baseURL: URL) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let urlRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        let urlString = String(html[urlRange])
        return resolveURL(urlString, baseURL: baseURL)
    }

    private func resolveURL(_ urlString: String, baseURL: URL) -> URL? {
        // Decode HTML entities
        let decoded = urlString
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")

        // Try as absolute URL first
        if let url = URL(string: decoded), url.scheme != nil {
            return url
        }

        // Resolve as relative URL
        return URL(string: decoded, relativeTo: baseURL)?.absoluteURL
    }

    private func cleanDOI(_ doi: String) -> String {
        var cleaned = doi
        if cleaned.lowercased().hasPrefix("https://doi.org/") {
            cleaned = String(cleaned.dropFirst(16))
        } else if cleaned.lowercased().hasPrefix("http://doi.org/") {
            cleaned = String(cleaned.dropFirst(15))
        } else if cleaned.lowercased().hasPrefix("doi:") {
            cleaned = String(cleaned.dropFirst(4))
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private func isCaptchaURL(_ urlString: String) -> Bool {
        let patterns = ["captcha", "recaptcha", "hcaptcha", "cloudflare", "challenge"]
        let lowercased = urlString.lowercased()
        return patterns.contains { lowercased.contains($0) }
    }

    // MARK: - Caching

    private func cacheKeyFor(url: URL, useProxy: Bool) -> String {
        "\(url.absoluteString):\(useProxy)"
    }

    private func getCachedResult(for key: String) -> ResolutionResult? {
        guard let cached = cache.object(forKey: key as NSString) else {
            return nil
        }

        // Use different TTL for positive vs negative results
        let ttl = cached.result.pdfURL != nil ? cacheTTL : negativeCacheTTL

        if Date().timeIntervalSince(cached.result.timestamp) > ttl {
            cache.removeObject(forKey: key as NSString)
            return nil
        }

        return cached.result
    }

    private func cacheResult(_ result: ResolutionResult, for key: String) {
        cache.setObject(CachedResolution(result: result), forKey: key as NSString)
    }

    /// Clear the cache.
    public func clearCache() {
        cache.removeAllObjects()
        Logger.files.info("[LandingPagePDFResolver] Cache cleared")
    }
}

// MARK: - Cache Wrapper

/// Cache wrapper for NSCache (must be a class).
private final class CachedResolution: NSObject {
    let result: LandingPagePDFResolver.ResolutionResult

    init(result: LandingPagePDFResolver.ResolutionResult) {
        self.result = result
    }
}
