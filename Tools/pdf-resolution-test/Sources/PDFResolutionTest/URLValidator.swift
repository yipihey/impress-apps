//
//  URLValidator.swift
//  PDFResolutionTest
//
//  Validates URLs to determine if they point to actual PDF files.
//

import Foundation

// MARK: - URL Validator

/// Validates URLs to check if they point to valid PDF files.
public actor URLValidator {

    private let session: URLSession
    private let timeout: TimeInterval

    /// PDF magic bytes: %PDF
    private static let pdfMagicBytes: [UInt8] = [0x25, 0x50, 0x44, 0x46]

    public init(session: URLSession? = nil, timeout: TimeInterval = 30) {
        self.timeout = timeout

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "Accept": "application/pdf,*/*"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// Validate a URL to check if it points to a valid PDF.
    ///
    /// Validation pipeline:
    /// 1. HEAD request (fast, most servers support)
    /// 2. If HEAD blocked: GET with Range header (first 1KB)
    /// 3. Check Content-Type header
    /// 4. Check magic bytes (%PDF)
    /// 5. Detect CAPTCHA patterns in redirects/HTML
    public func validate(url: URL) async -> URLValidationResult {
        // First try HEAD request
        let headResult = await validateWithHEAD(url: url)

        switch headResult {
        case .validPDF:
            return headResult
        case .htmlContent, .networkError:
            // HEAD might be blocked or return wrong content type, try Range GET
            return await validateWithRangeGET(url: url)
        default:
            return headResult
        }
    }

    /// Validate URL with optional proxy, racing both paths.
    ///
    /// Returns results from both direct and proxied requests.
    public func validateWithProxyRace(
        url: URL,
        proxyURL: String
    ) async -> (direct: URLValidationResult, proxied: URLValidationResult) {
        async let directResult = validate(url: url)
        async let proxiedResult = validateProxied(url: url, proxyURL: proxyURL)

        return await (directResult, proxiedResult)
    }

    // MARK: - HEAD Validation

    private func validateWithHEAD(url: URL) async -> URLValidationResult {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError(url: url, error: URLError(.badServerResponse))
            }

            return analyzeResponse(httpResponse, url: url, data: nil)
        } catch {
            return .networkError(url: url, error: error)
        }
    }

    // MARK: - Range GET Validation

    private func validateWithRangeGET(url: URL) async -> URLValidationResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError(url: url, error: URLError(.badServerResponse))
            }

            return analyzeResponse(httpResponse, url: url, data: data)
        } catch {
            return .networkError(url: url, error: error)
        }
    }

    // MARK: - Proxied Validation

    private func validateProxied(url: URL, proxyURL: String) async -> URLValidationResult {
        // Construct proxied URL
        let proxiedURLString = proxyURL + url.absoluteString
        guard let proxiedURL = URL(string: proxiedURLString) else {
            return .networkError(url: url, error: URLError(.badURL))
        }

        return await validate(url: proxiedURL)
    }

    // MARK: - Response Analysis

    private func analyzeResponse(
        _ response: HTTPURLResponse,
        url: URL,
        data: Data?
    ) -> URLValidationResult {
        let statusCode = response.statusCode
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let contentLength = response.expectedContentLength

        // Check status code first
        switch statusCode {
        case 200, 206:
            break // Continue analysis
        case 401, 403:
            return detectAuthType(response: response, url: url)
        case 404:
            return .notFound(url: url)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            return .rateLimited(url: url, retryAfter: retryAfter)
        case 301, 302, 303, 307, 308:
            // Check redirect location for CAPTCHA patterns
            if let location = response.value(forHTTPHeaderField: "Location") {
                if CaptchaDetector.isCaptchaURL(location) {
                    let domain = URL(string: location)?.host ?? url.host ?? "unknown"
                    return .captchaRequired(url: url, domain: domain)
                }
            }
            // Follow redirect would happen automatically with URLSession
            return .networkError(url: url, error: URLError(.httpTooManyRedirects))
        default:
            return .networkError(url: url, error: URLError(.badServerResponse))
        }

        // Check Content-Type
        if contentType.contains("application/pdf") {
            return .validPDF(url: url, contentLength: contentLength > 0 ? contentLength : nil)
        }

        if contentType.contains("text/html") {
            // Check for CAPTCHA or paywall in HTML
            if let data = data {
                return analyzeHTMLContent(data, url: url)
            }
            return .htmlContent(url: url, title: nil)
        }

        // Check magic bytes if we have data
        if let data = data, isPDFData(data) {
            return .validPDF(url: url, contentLength: contentLength > 0 ? contentLength : nil)
        }

        // Unknown content type but no data to verify
        if data == nil {
            // Might be PDF, need to download to verify
            return .htmlContent(url: url, title: nil)
        }

        return .htmlContent(url: url, title: nil)
    }

    // MARK: - PDF Detection

    private func isPDFData(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(4))
        return bytes == Self.pdfMagicBytes
    }

    // MARK: - Auth Detection

    private func detectAuthType(response: HTTPURLResponse, url: URL) -> URLValidationResult {
        let wwwAuth = response.value(forHTTPHeaderField: "WWW-Authenticate")?.lowercased() ?? ""

        if wwwAuth.contains("basic") {
            return .requiresAuthentication(url: url, authType: .basicAuth)
        }
        if wwwAuth.contains("bearer") || wwwAuth.contains("oauth") {
            return .requiresAuthentication(url: url, authType: .oauth)
        }

        // Check for Shibboleth patterns in URL
        let urlString = url.absoluteString.lowercased()
        if urlString.contains("shibboleth") || urlString.contains("saml") {
            return .requiresAuthentication(url: url, authType: .shibboleth)
        }

        // Check for proxy patterns
        if urlString.contains("idm.oclc.org") || urlString.contains("ezproxy") {
            return .requiresAuthentication(url: url, authType: .proxy)
        }

        return .requiresAuthentication(url: url, authType: .unknown)
    }

    // MARK: - HTML Analysis

    private func analyzeHTMLContent(_ data: Data, url: URL) -> URLValidationResult {
        guard let html = String(data: data, encoding: .utf8) else {
            return .htmlContent(url: url, title: nil)
        }

        let lowercaseHTML = html.lowercased()

        // Check for CAPTCHA
        if CaptchaDetector.containsCaptcha(html: lowercaseHTML) {
            let domain = url.host ?? "unknown"
            return .captchaRequired(url: url, domain: domain)
        }

        // Check for paywall indicators
        if let publisher = detectPaywall(html: lowercaseHTML, url: url) {
            return .paywall(url: url, publisher: publisher)
        }

        // Extract title
        let title = extractHTMLTitle(html)

        return .htmlContent(url: url, title: title)
    }

    private func detectPaywall(html: String, url: URL) -> String? {
        let paywallPatterns = [
            ("sciencedirect.com", ["purchase pdf", "get access", "subscribe"]),
            ("springer.com", ["buy article", "access options", "institutional access"]),
            ("wiley.com", ["purchase article", "institutional login"]),
            ("nature.com", ["subscribe", "access options"]),
            ("science.org", ["purchase", "institutional access"]),
            ("iop.org", ["purchase article", "institutional login"]),
            ("oup.com", ["purchase", "get access"]),
        ]

        let host = url.host?.lowercased() ?? ""

        for (domain, keywords) in paywallPatterns {
            if host.contains(domain) {
                for keyword in keywords {
                    if html.contains(keyword) {
                        return domain.components(separatedBy: ".").first?.capitalized ?? domain
                    }
                }
            }
        }

        return nil
    }

    private func extractHTMLTitle(_ html: String) -> String? {
        // Simple regex to extract title
        let pattern = "<title[^>]*>([^<]+)</title>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - CAPTCHA Detector

/// Detects CAPTCHA challenges in URLs and HTML content.
public struct CaptchaDetector {

    /// Known CAPTCHA URL patterns
    private static let captchaURLPatterns = [
        "captcha",
        "recaptcha",
        "hcaptcha",
        "challenge",
        "cloudflare",
        "bot-check",
        "verify",
        "security-check",
    ]

    /// Known CAPTCHA HTML patterns
    private static let captchaHTMLPatterns = [
        "g-recaptcha",
        "h-captcha",
        "cf-turnstile",
        "captcha",
        "challenge-form",
        "please verify you are human",
        "checking your browser",
        "just a moment",
        "enable javascript and cookies",
        "access denied",
        "bot detected",
    ]

    /// Check if URL indicates a CAPTCHA challenge
    public static func isCaptchaURL(_ urlString: String) -> Bool {
        let lowercased = urlString.lowercased()
        return captchaURLPatterns.contains { lowercased.contains($0) }
    }

    /// Check if HTML content contains CAPTCHA challenge
    public static func containsCaptcha(html: String) -> Bool {
        return captchaHTMLPatterns.contains { html.contains($0) }
    }
}
