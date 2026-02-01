//
//  ValidationTypes.swift
//  PDFResolutionTest
//
//  Types for URL validation results.
//

import Foundation

// MARK: - URL Validation Result

/// Result of validating a PDF URL before download.
public enum URLValidationResult: Sendable, CustomStringConvertible {
    /// URL points to a valid PDF file
    case validPDF(url: URL, contentLength: Int64?)

    /// URL requires authentication (redirect to login page)
    case requiresAuthentication(url: URL, authType: AuthType)

    /// URL requires CAPTCHA verification
    case captchaRequired(url: URL, domain: String)

    /// URL is behind a paywall
    case paywall(url: URL, publisher: String)

    /// URL returns HTML content instead of PDF
    case htmlContent(url: URL, title: String?)

    /// URL is rate limited
    case rateLimited(url: URL, retryAfter: TimeInterval?)

    /// URL not found (404)
    case notFound(url: URL)

    /// Network or other error
    case networkError(url: URL, error: Error)

    public var description: String {
        switch self {
        case .validPDF(let url, let size):
            let sizeStr = size.map { "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "unknown size"
            return "Valid PDF (\(sizeStr)): \(url.absoluteString)"
        case .requiresAuthentication(let url, let authType):
            return "Requires \(authType.rawValue) authentication: \(url.absoluteString)"
        case .captchaRequired(let url, let domain):
            return "CAPTCHA required by \(domain): \(url.absoluteString)"
        case .paywall(let url, let publisher):
            return "Paywall (\(publisher)): \(url.absoluteString)"
        case .htmlContent(let url, let title):
            let titleStr = title ?? "unknown"
            return "HTML content (title: \(titleStr)): \(url.absoluteString)"
        case .rateLimited(let url, let retryAfter):
            let retryStr = retryAfter.map { "retry after \(Int($0))s" } ?? "no retry info"
            return "Rate limited (\(retryStr)): \(url.absoluteString)"
        case .notFound(let url):
            return "Not found (404): \(url.absoluteString)"
        case .networkError(let url, let error):
            return "Network error (\(error.localizedDescription)): \(url.absoluteString)"
        }
    }

    /// Whether this result indicates success (valid PDF found)
    public var isSuccess: Bool {
        if case .validPDF = self { return true }
        return false
    }

    /// The URL associated with this result
    public var url: URL {
        switch self {
        case .validPDF(let url, _),
             .requiresAuthentication(let url, _),
             .captchaRequired(let url, _),
             .paywall(let url, _),
             .htmlContent(let url, _),
             .rateLimited(let url, _),
             .notFound(let url),
             .networkError(let url, _):
            return url
        }
    }
}

// MARK: - Authentication Type

/// Type of authentication required
public enum AuthType: String, Sendable {
    case proxy = "Proxy"
    case shibboleth = "Shibboleth"
    case oauth = "OAuth"
    case basicAuth = "Basic Auth"
    case unknown = "Unknown"
}

// MARK: - Publisher Info

/// Information about a known publisher
public struct PublisherInfo: Sendable, Codable {
    public let id: String
    public let name: String
    public let doiPrefixes: [String]
    public let pdfURLPattern: String?
    public let requiresProxy: Bool
    public let captchaRisk: CaptchaRisk
    public let preferOpenAlex: Bool
    public let notes: String?

    public init(
        id: String,
        name: String,
        doiPrefixes: [String],
        pdfURLPattern: String? = nil,
        requiresProxy: Bool = false,
        captchaRisk: CaptchaRisk = .low,
        preferOpenAlex: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.doiPrefixes = doiPrefixes
        self.pdfURLPattern = pdfURLPattern
        self.requiresProxy = requiresProxy
        self.captchaRisk = captchaRisk
        self.preferOpenAlex = preferOpenAlex
        self.notes = notes
    }
}

/// CAPTCHA encounter risk level
public enum CaptchaRisk: String, Sendable, Codable {
    case low
    case medium
    case high
}

// MARK: - Test Fixture

/// A test case for PDF resolution
public struct TestFixture: Sendable, Codable {
    public let doi: String
    public let title: String
    public let publisher: String
    public let expectedSource: ExpectedSource
    public let hasArxiv: Bool
    public let hasOpenAlex: Bool
    public let notes: String?

    public init(
        doi: String,
        title: String,
        publisher: String,
        expectedSource: ExpectedSource,
        hasArxiv: Bool = false,
        hasOpenAlex: Bool = false,
        notes: String? = nil
    ) {
        self.doi = doi
        self.title = title
        self.publisher = publisher
        self.expectedSource = expectedSource
        self.hasArxiv = hasArxiv
        self.hasOpenAlex = hasOpenAlex
        self.notes = notes
    }
}

/// Expected PDF source for a test fixture
public enum ExpectedSource: String, Sendable, Codable {
    case arxiv
    case openAlex
    case publisherDirect
    case publisherProxy
    case unavailable
}

// MARK: - Test Result

/// Result of testing a single fixture
public struct TestResult: Sendable {
    public let fixture: TestFixture
    public let startTime: Date
    public let endTime: Date
    public let directResult: URLValidationResult?
    public let proxiedResult: URLValidationResult?
    public let openAlexResult: OpenAlexLookupResult?
    public let arxivResult: URLValidationResult?
    public let actualSource: ExpectedSource?
    public let notes: [String]

    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    public var success: Bool {
        actualSource == fixture.expectedSource
    }
}

/// Result of looking up OA locations from OpenAlex
public struct OpenAlexLookupResult: Sendable {
    public let doi: String
    public let locations: [OpenAlexOALocation]
    public let bestPDFURL: URL?
    public let oaStatus: String?

    public init(doi: String, locations: [OpenAlexOALocation], bestPDFURL: URL?, oaStatus: String?) {
        self.doi = doi
        self.locations = locations
        self.bestPDFURL = bestPDFURL
        self.oaStatus = oaStatus
    }
}

/// Simplified OA location from OpenAlex
public struct OpenAlexOALocation: Sendable {
    public let isOA: Bool
    public let pdfURL: URL?
    public let landingPageURL: URL?
    public let sourceName: String?
    public let version: String?
    public let license: String?

    public init(
        isOA: Bool,
        pdfURL: URL?,
        landingPageURL: URL?,
        sourceName: String?,
        version: String?,
        license: String?
    ) {
        self.isOA = isOA
        self.pdfURL = pdfURL
        self.landingPageURL = landingPageURL
        self.sourceName = sourceName
        self.version = version
        self.license = license
    }
}

// MARK: - Test Metrics

/// Aggregated metrics from test runs
public struct TestMetrics: Sendable {
    public var totalTests: Int = 0
    public var successCount: Int = 0
    public var failureCount: Int = 0

    public var resultsByPublisher: [String: PublisherMetrics] = [:]
    public var openAlexHits: Int = 0
    public var openAlexMisses: Int = 0
    public var captchaEncounters: Int = 0
    public var proxySuccesses: Int = 0
    public var proxyFailures: Int = 0
    public var directSuccesses: Int = 0
    public var directFailures: Int = 0

    public var totalDuration: TimeInterval = 0

    public var successRate: Double {
        guard totalTests > 0 else { return 0 }
        return Double(successCount) / Double(totalTests)
    }

    public var openAlexHitRate: Double {
        let total = openAlexHits + openAlexMisses
        guard total > 0 else { return 0 }
        return Double(openAlexHits) / Double(total)
    }

    public mutating func record(_ result: TestResult) {
        totalTests += 1
        if result.success {
            successCount += 1
        } else {
            failureCount += 1
        }

        // Track by publisher
        var publisherMetrics = resultsByPublisher[result.fixture.publisher] ?? PublisherMetrics(publisher: result.fixture.publisher)
        publisherMetrics.totalTests += 1
        if result.success {
            publisherMetrics.successCount += 1
        }
        resultsByPublisher[result.fixture.publisher] = publisherMetrics

        // Track OpenAlex
        if result.openAlexResult != nil {
            if result.openAlexResult?.bestPDFURL != nil {
                openAlexHits += 1
            } else {
                openAlexMisses += 1
            }
        }

        // Track CAPTCHA
        if case .captchaRequired = result.directResult {
            captchaEncounters += 1
        }
        if case .captchaRequired = result.proxiedResult {
            captchaEncounters += 1
        }

        // Track proxy vs direct
        if case .validPDF = result.directResult {
            directSuccesses += 1
        } else if result.directResult != nil {
            directFailures += 1
        }

        if case .validPDF = result.proxiedResult {
            proxySuccesses += 1
        } else if result.proxiedResult != nil {
            proxyFailures += 1
        }

        totalDuration += result.duration
    }
}

/// Metrics for a specific publisher
public struct PublisherMetrics: Sendable {
    public let publisher: String
    public var totalTests: Int = 0
    public var successCount: Int = 0

    public var successRate: Double {
        guard totalTests > 0 else { return 0 }
        return Double(successCount) / Double(totalTests)
    }
}
