//
//  PDFURLResolverV2.swift
//  PublicationManagerCore
//
//  Enhanced PDF URL resolver with validation and multi-source support.
//

import Foundation
import OSLog

// MARK: - PDF URL Resolver V2

/// Enhanced PDF URL resolver with:
/// - URL validation before download
/// - OpenAlex OA location caching
/// - Publisher registry for URL construction
/// - Parallel proxy testing
/// - Rich access status reporting
///
/// ## Resolution Order
///
/// 1. arXiv (if preprint priority or arXiv-only paper)
/// 2. OpenAlex OA locations (cached)
/// 3. Publisher rules + validation
/// 4. arXiv fallback
/// 5. Browser fallback with clear status
///
/// ## Usage
///
/// ```swift
/// let status = await PDFURLResolverV2.resolve(for: publication)
/// switch status {
/// case .available(let source):
///     // Download PDF from source.url
/// case .captchaBlocked(let publisher, let browserURL):
///     // Show message and offer to open browser
/// }
/// ```
public actor PDFURLResolverV2 {

    // MARK: - Singleton

    public static let shared = PDFURLResolverV2()

    // MARK: - Properties

    private let openAlexService: OpenAlexPDFService
    private let publisherRegistry: PublisherRegistry
    private let validator: URLValidatorService

    // MARK: - Initialization

    public init(
        openAlexService: OpenAlexPDFService? = nil,
        publisherRegistry: PublisherRegistry? = nil
    ) {
        self.openAlexService = openAlexService ?? OpenAlexPDFService.shared
        self.publisherRegistry = publisherRegistry ?? PublisherRegistry.shared
        self.validator = URLValidatorService()
    }

    // MARK: - Resolution

    /// Resolve PDF access status for a publication.
    ///
    /// This is the main entry point for PDF resolution. It returns rich status
    /// information that can be used by the UI to show appropriate messages and actions.
    ///
    /// - Parameters:
    ///   - publication: The publication to resolve PDF for
    ///   - settings: PDF settings (priority, proxy configuration)
    /// - Returns: PDF access status with URL or fallback information
    public func resolve(
        for publication: CDPublication,
        settings: PDFSettings
    ) async -> PDFAccessStatus {
        Logger.files.infoCapture(
            "[PDFURLResolverV2] Resolving for: '\(publication.citeKey)'",
            category: "pdf"
        )

        // 1. Check for arXiv (always accessible, no validation needed)
        if settings.sourcePriority == .preprint || isArXivOnlyPaper(publication) {
            if let arxivURL = arxivPDFURL(for: publication) {
                Logger.files.infoCapture("[PDFURLResolverV2] Using arXiv: \(arxivURL.absoluteString)", category: "pdf")
                return .available(source: ResolvedPDFSource(type: .arxiv, url: arxivURL, name: "arXiv"))
            }
        }

        // 2. Try OpenAlex OA locations (cached, pre-validated by OpenAlex)
        if let doi = publication.doi, !doi.isEmpty {
            if let oaLocation = await openAlexService.fetchBestOALocation(doi: doi) {
                Logger.files.infoCapture(
                    "[PDFURLResolverV2] Using OpenAlex OA: \(oaLocation.pdfURL.absoluteString)",
                    category: "pdf"
                )
                return .available(source: ResolvedPDFSource(
                    type: .openAlex,
                    url: oaLocation.pdfURL,
                    name: oaLocation.sourceName ?? "Open Access"
                ))
            }
        }

        // 3. Try publisher rules with validation
        if let doi = publication.doi, !doi.isEmpty, !isArXivDOI(doi) {
            let publisherStatus = await resolvePublisherPDF(doi: doi, settings: settings)
            if publisherStatus.isAccessible {
                return publisherStatus
            }

            // If publisher returned a blocking status (CAPTCHA, paywall), return it
            if publisherStatus.requiresUserAction {
                return publisherStatus
            }
        }

        // 4. arXiv fallback (if publisher priority was set but failed)
        if settings.sourcePriority == .publisher {
            if let arxivURL = arxivPDFURL(for: publication) {
                Logger.files.infoCapture(
                    "[PDFURLResolverV2] Falling back to arXiv: \(arxivURL.absoluteString)",
                    category: "pdf"
                )
                return .available(source: ResolvedPDFSource(type: .arxiv, url: arxivURL, name: "arXiv"))
            }
        }

        // 5. ADS scan fallback
        if let adsScanURL = adsScanURL(for: publication) {
            Logger.files.infoCapture("[PDFURLResolverV2] Using ADS scan: \(adsScanURL.absoluteString)", category: "pdf")
            return .available(source: ResolvedPDFSource(type: .adsScan, url: adsScanURL, name: "ADS Scan"))
        }

        // 6. No PDF found
        Logger.files.infoCapture("[PDFURLResolverV2] No PDF available", category: "pdf")
        return .unavailable(reason: .noPDFFound)
    }

    /// Convenience method that uses current settings.
    public func resolve(for publication: CDPublication) async -> PDFAccessStatus {
        let settings = await PDFSettingsStore.shared.settings
        return await resolve(for: publication, settings: settings)
    }

    // MARK: - Publisher Resolution

    private func resolvePublisherPDF(doi: String, settings: PDFSettings) async -> PDFAccessStatus {
        // Get publisher rule
        let rule = await publisherRegistry.rule(forDOI: doi)
        let publisherName = rule?.name ?? "Publisher"

        // Check if we should prefer OpenAlex (already tried above, so skip)
        if rule?.preferOpenAlex == true {
            // Construct browser URL for fallback
            if let browserURL = URL(string: "https://doi.org/\(doi)") {
                let proxiedURL = settings.proxyEnabled && rule?.requiresProxy == true
                    ? applyProxy(to: browserURL, settings: settings)
                    : browserURL

                // High CAPTCHA risk publishers go straight to browser fallback
                if rule?.captchaRisk == .high {
                    return .captchaBlocked(publisher: publisherName, browserURL: proxiedURL)
                }
            }
            return .unavailable(reason: .noPDFFound)
        }

        // Construct PDF URL from rule
        guard let pdfURL = rule?.constructPDFURL(doi: doi) ?? constructFallbackPDFURL(doi: doi) else {
            return .unavailable(reason: .noPDFFound)
        }

        // Validate the URL
        let needsProxy = rule?.requiresProxy ?? true

        if needsProxy && settings.proxyEnabled {
            // Try with proxy
            let proxiedURL = applyProxy(to: pdfURL, settings: settings)
            let result = await validator.validate(url: proxiedURL)

            switch result {
            case .validPDF:
                return .requiresProxy(source: ResolvedPDFSource(type: .publisher, url: proxiedURL, name: publisherName))

            case .captchaRequired(_, let domain):
                let browserURL = URL(string: "https://doi.org/\(doi)")!
                let proxiedBrowserURL = applyProxy(to: browserURL, settings: settings)
                return .captchaBlocked(publisher: domain, browserURL: proxiedBrowserURL)

            case .paywall:
                let browserURL = URL(string: "https://doi.org/\(doi)")!
                let proxiedBrowserURL = applyProxy(to: browserURL, settings: settings)
                return .paywalled(publisher: publisherName, browserURL: proxiedBrowserURL)

            case .requiresAuthentication:
                // Proxy might not be working, return browser fallback
                let browserURL = URL(string: "https://doi.org/\(doi)")!
                let proxiedBrowserURL = applyProxy(to: browserURL, settings: settings)
                return .paywalled(publisher: publisherName, browserURL: proxiedBrowserURL)

            default:
                break
            }
        }

        // Try direct access (for open access publishers or when proxy not configured)
        let directResult = await validator.validate(url: pdfURL)

        switch directResult {
        case .validPDF:
            return .available(source: ResolvedPDFSource(type: .publisher, url: pdfURL, name: publisherName))

        case .captchaRequired(_, let domain):
            let browserURL = URL(string: "https://doi.org/\(doi)")!
            return .captchaBlocked(publisher: domain, browserURL: browserURL)

        case .paywall:
            let browserURL = URL(string: "https://doi.org/\(doi)")!
            return .paywalled(publisher: publisherName, browserURL: browserURL)

        case .requiresAuthentication:
            if settings.proxyEnabled {
                let browserURL = URL(string: "https://doi.org/\(doi)")!
                let proxiedBrowserURL = applyProxy(to: browserURL, settings: settings)
                return .paywalled(publisher: publisherName, browserURL: proxiedBrowserURL)
            }
            return .unavailable(reason: .allSourcesFailed)

        default:
            return .unavailable(reason: .allSourcesFailed)
        }
    }

    // MARK: - URL Helpers

    private func arxivPDFURL(for publication: CDPublication) -> URL? {
        // Try arxivID field first
        if let arxivID = publication.arxivID, !arxivID.isEmpty {
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
        }

        // Try extracting from arXiv DOI
        if let doi = publication.doi, let arxivID = extractArXivIDFromDOI(doi) {
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
        }

        // Check pdfLinks for arXiv
        if let arxivLink = publication.pdfLinks.first(where: {
            $0.url.host?.contains("arxiv.org") == true && $0.type == .preprint
        }) {
            return arxivLink.url
        }

        return nil
    }

    private func adsScanURL(for publication: CDPublication) -> URL? {
        publication.pdfLinks.first(where: { $0.type == .adsScan })?.url
    }

    private func isArXivOnlyPaper(_ publication: CDPublication) -> Bool {
        // Paper has arXiv but no publisher DOI
        guard publication.arxivID != nil else { return false }

        if let doi = publication.doi {
            // If DOI is an arXiv DOI, this is arXiv-only
            return isArXivDOI(doi)
        }

        // No DOI at all means arXiv-only
        return true
    }

    private func isArXivDOI(_ doi: String) -> Bool {
        doi.lowercased().hasPrefix("10.48550/arxiv.")
    }

    private func extractArXivIDFromDOI(_ doi: String) -> String? {
        let prefix = "10.48550/arXiv."
        guard doi.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(doi.dropFirst(prefix.count))
    }

    private func constructFallbackPDFURL(doi: String) -> URL? {
        // Fallback URL construction for unknown publishers
        // This is less reliable but provides a last resort
        nil
    }

    private func applyProxy(to url: URL, settings: PDFSettings) -> URL {
        guard settings.proxyEnabled, !settings.libraryProxyURL.isEmpty else {
            return url
        }

        let proxyURL = settings.libraryProxyURL.trimmingCharacters(in: .whitespaces)
        let proxiedURLString = proxyURL + url.absoluteString

        return URL(string: proxiedURLString) ?? url
    }
}

// MARK: - URL Validator Service

/// Simple URL validator for PDF checks.
actor URLValidatorService {

    private let session: URLSession
    private static let pdfMagicBytes: [UInt8] = [0x25, 0x50, 0x44, 0x46]  // %PDF

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15",
            "Accept": "application/pdf,*/*"
        ]
        self.session = URLSession(configuration: config)
    }

    func validate(url: URL) async -> URLValidationResult {
        // Try HEAD request first
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError(url: url, error: URLError(.badServerResponse))
            }

            return analyzeResponse(httpResponse, url: url)
        } catch {
            return .networkError(url: url, error: error)
        }
    }

    private func analyzeResponse(_ response: HTTPURLResponse, url: URL) -> URLValidationResult {
        let statusCode = response.statusCode
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let contentLength = response.expectedContentLength

        switch statusCode {
        case 200, 206:
            if contentType.contains("application/pdf") {
                return .validPDF(url: url, contentLength: contentLength > 0 ? contentLength : nil)
            }
            if contentType.contains("text/html") {
                return .htmlContent(url: url, title: nil)
            }
            // Unknown content type - might be PDF
            return .validPDF(url: url, contentLength: contentLength > 0 ? contentLength : nil)

        case 401, 403:
            return .requiresAuthentication(url: url, authType: detectAuthType(url: url))

        case 404:
            return .notFound(url: url)

        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            return .rateLimited(url: url, retryAfter: retryAfter)

        case 301, 302, 303, 307, 308:
            if let location = response.value(forHTTPHeaderField: "Location"),
               isCaptchaURL(location) {
                let domain = URL(string: location)?.host ?? url.host ?? "unknown"
                return .captchaRequired(url: url, domain: domain)
            }
            return .htmlContent(url: url, title: nil)

        default:
            return .networkError(url: url, error: URLError(.badServerResponse))
        }
    }

    private func detectAuthType(url: URL) -> AuthenticationType {
        let urlString = url.absoluteString.lowercased()
        if urlString.contains("shibboleth") || urlString.contains("saml") {
            return .shibboleth
        }
        if urlString.contains("idm.oclc.org") || urlString.contains("ezproxy") {
            return .proxy
        }
        return .unknown
    }

    private func isCaptchaURL(_ urlString: String) -> Bool {
        let patterns = ["captcha", "recaptcha", "hcaptcha", "cloudflare", "challenge"]
        let lowercased = urlString.lowercased()
        return patterns.contains { lowercased.contains($0) }
    }
}
