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
/// - Landing page scraping for PDF discovery
/// - Publisher registry for URL construction
/// - Parallel proxy testing
/// - Rich access status reporting
///
/// Works with PublicationModel (domain type).
public actor PDFURLResolverV2 {

    // MARK: - Singleton

    public static let shared = PDFURLResolverV2()

    // MARK: - Properties

    private let openAlexService: OpenAlexPDFService
    private let publisherRegistry: PublisherRegistry
    private let landingPageResolver: LandingPagePDFResolver
    private let validator: URLValidatorService

    // MARK: - Initialization

    public init(
        openAlexService: OpenAlexPDFService? = nil,
        publisherRegistry: PublisherRegistry? = nil,
        landingPageResolver: LandingPagePDFResolver? = nil
    ) {
        self.openAlexService = openAlexService ?? OpenAlexPDFService.shared
        self.publisherRegistry = publisherRegistry ?? PublisherRegistry.shared
        self.landingPageResolver = landingPageResolver ?? LandingPagePDFResolver.shared
        self.validator = URLValidatorService()
    }

    // MARK: - Resolution

    /// Resolve PDF access status for a publication.
    public func resolve(
        for publication: PublicationModel,
        settings: PDFSettings
    ) async -> PDFAccessStatus {
        Logger.files.infoCapture(
            "[PDFURLResolverV2] Resolving for: '\(publication.citeKey)'",
            category: "pdf"
        )

        // 1. Check for arXiv
        if settings.sourcePriority == .preprint || isArXivOnlyPaper(publication) {
            if let arxivURL = arxivPDFURL(for: publication) {
                Logger.files.infoCapture("[PDFURLResolverV2] Using arXiv: \(arxivURL.absoluteString)", category: "pdf")
                return .available(source: ResolvedPDFSource(type: .arxiv, url: arxivURL, name: "arXiv"))
            }
        }

        // 2. Try OpenAlex OA locations
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

            // 2b. Try landing page scraping
            let rule = await publisherRegistry.rule(forDOI: doi)
            if rule?.supportsLandingPageScraping ?? true {
                let landingPageStatus = await resolveLandingPagePDF(doi: doi, settings: settings)
                if landingPageStatus.isAccessible {
                    return landingPageStatus
                }
            }
        }

        // 3. Try publisher rules with validation
        if let doi = publication.doi, !doi.isEmpty, !isArXivDOI(doi) {
            let publisherStatus = await resolvePublisherPDF(doi: doi, settings: settings)
            if publisherStatus.isAccessible {
                return publisherStatus
            }

            if publisherStatus.requiresUserAction {
                if let adsScanURL = adsScanURL(for: publication) {
                    Logger.files.infoCapture("[PDFURLResolverV2] Publisher blocked, using ADS scan: \(adsScanURL.absoluteString)", category: "pdf")
                    return .available(source: ResolvedPDFSource(type: .adsScan, url: adsScanURL, name: "ADS Scan"))
                }
                return publisherStatus
            }
        }

        // 4. arXiv fallback
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
    public func resolve(for publication: PublicationModel) async -> PDFAccessStatus {
        let settings = await PDFSettingsStore.shared.settings
        return await resolve(for: publication, settings: settings)
    }

    // MARK: - Landing Page Resolution

    private func resolveLandingPagePDF(doi: String, settings: PDFSettings) async -> PDFAccessStatus {
        guard let landingPageURL = await openAlexService.fetchLandingPageURL(doi: doi) else {
            return .unavailable(reason: .noPDFFound)
        }

        Logger.files.infoCapture(
            "[PDFURLResolverV2] Trying landing page: \(landingPageURL.absoluteString)",
            category: "pdf"
        )

        let rule = await publisherRegistry.rule(forDOI: doi)
        let publisherName = rule?.name ?? "Publisher"

        let directResult = await landingPageResolver.resolve(
            landingPageURL: landingPageURL,
            useProxy: false
        )

        switch directResult.status {
        case .found:
            if let pdfURL = directResult.pdfURL {
                let validationResult = await validator.validate(url: pdfURL)
                if validationResult.isSuccess {
                    Logger.files.infoCapture(
                        "[PDFURLResolverV2] Landing page found PDF: \(pdfURL.absoluteString)",
                        category: "pdf"
                    )
                    return .available(source: ResolvedPDFSource(
                        type: .landingPage,
                        url: pdfURL,
                        name: publisherName
                    ))
                }
            }

        case .requiresAuthentication:
            if settings.proxyEnabled, !settings.libraryProxyURL.isEmpty {
                let proxyResult = await landingPageResolver.resolve(
                    landingPageURL: landingPageURL,
                    useProxy: true,
                    proxyPrefix: settings.libraryProxyURL
                )

                if proxyResult.status == .found, let pdfURL = proxyResult.pdfURL {
                    let proxiedPDFURL = applyProxy(to: pdfURL, settings: settings)
                    let validationResult = await validator.validate(url: proxiedPDFURL)
                    if validationResult.isSuccess {
                        Logger.files.infoCapture(
                            "[PDFURLResolverV2] Landing page (proxied) found PDF: \(proxiedPDFURL.absoluteString)",
                            category: "pdf"
                        )
                        return .requiresProxy(source: ResolvedPDFSource(
                            type: .landingPage,
                            url: proxiedPDFURL,
                            name: publisherName
                        ))
                    }
                }

                let browserURL = applyProxy(to: landingPageURL, settings: settings)
                return .paywalled(publisher: publisherName, browserURL: browserURL)
            }

            return .paywalled(publisher: publisherName, browserURL: landingPageURL)

        case .captchaBlocked:
            let browserURL = settings.proxyEnabled
                ? applyProxy(to: landingPageURL, settings: settings)
                : landingPageURL
            return .captchaBlocked(publisher: publisherName, browserURL: browserURL)

        case .rateLimited:
            Logger.files.info("[PDFURLResolverV2] Rate limited on landing page, skipping")
            break

        case .notFound, .fetchFailed:
            break
        }

        return .unavailable(reason: .noPDFFound)
    }

    // MARK: - Publisher Resolution

    private func resolvePublisherPDF(doi: String, settings: PDFSettings) async -> PDFAccessStatus {
        let rule = await publisherRegistry.rule(forDOI: doi)
        let publisherName = rule?.name ?? "Publisher"

        if rule?.preferOpenAlex == true {
            if let browserURL = URL(string: "https://doi.org/\(doi)") {
                let proxiedURL = settings.proxyEnabled && rule?.requiresProxy == true
                    ? applyProxy(to: browserURL, settings: settings)
                    : browserURL

                if rule?.captchaRisk == .high {
                    return .captchaBlocked(publisher: publisherName, browserURL: proxiedURL)
                }
            }
            return .unavailable(reason: .noPDFFound)
        }

        guard let pdfURL = rule?.constructPDFURL(doi: doi) ?? constructFallbackPDFURL(doi: doi) else {
            return .unavailable(reason: .noPDFFound)
        }

        let needsProxy = rule?.requiresProxy ?? true

        if needsProxy && settings.proxyEnabled {
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
                let browserURL = URL(string: "https://doi.org/\(doi)")!
                let proxiedBrowserURL = applyProxy(to: browserURL, settings: settings)
                return .paywalled(publisher: publisherName, browserURL: proxiedBrowserURL)

            default:
                break
            }
        }

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

    private func arxivPDFURL(for publication: PublicationModel) -> URL? {
        if let arxivID = publication.arxivID, !arxivID.isEmpty {
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
        }

        if let doi = publication.doi, let arxivID = extractArXivIDFromDOI(doi) {
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
        }

        return nil
    }

    private func adsScanURL(for publication: PublicationModel) -> URL? {
        if let bibcode = publication.bibcode, !bibcode.isEmpty {
            return URL(string: "https://articles.adsabs.harvard.edu/pdf/\(bibcode)")
        }
        return nil
    }

    private func isArXivOnlyPaper(_ publication: PublicationModel) -> Bool {
        guard publication.arxivID != nil else { return false }

        if let doi = publication.doi {
            return isArXivDOI(doi)
        }

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
