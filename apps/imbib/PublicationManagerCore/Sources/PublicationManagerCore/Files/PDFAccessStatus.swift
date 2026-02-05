//
//  PDFAccessStatus.swift
//  PublicationManagerCore
//
//  Types for representing PDF access status.
//

import Foundation

// MARK: - PDF Access Status

/// Status of PDF access for a publication.
///
/// This enum provides rich information about PDF availability and access requirements,
/// enabling the UI to show appropriate messages and actions.
public enum PDFAccessStatus: Sendable, Equatable {
    /// PDF is available and can be downloaded directly.
    case available(source: ResolvedPDFSource)

    /// PDF is available but requires proxy authentication.
    case requiresProxy(source: ResolvedPDFSource)

    /// PDF is blocked by CAPTCHA verification.
    case captchaBlocked(publisher: String, browserURL: URL)

    /// PDF is behind a paywall.
    case paywalled(publisher: String, browserURL: URL)

    /// PDF is not available from any source.
    case unavailable(reason: UnavailableReason)

    /// PDF access is being determined.
    case checking

    // MARK: - Convenience Properties

    /// Whether the PDF can be accessed (available or requires proxy).
    public var isAccessible: Bool {
        switch self {
        case .available, .requiresProxy:
            return true
        default:
            return false
        }
    }

    /// Whether user action is required to access the PDF.
    public var requiresUserAction: Bool {
        switch self {
        case .captchaBlocked, .paywalled:
            return true
        default:
            return false
        }
    }

    /// Get the PDF URL if available.
    public var pdfURL: URL? {
        switch self {
        case .available(let source), .requiresProxy(let source):
            return source.url
        default:
            return nil
        }
    }

    /// Get the browser fallback URL if applicable.
    public var browserURL: URL? {
        switch self {
        case .captchaBlocked(_, let url), .paywalled(_, let url):
            return url
        default:
            return nil
        }
    }

    /// User-facing description of the status.
    public var displayDescription: String {
        switch self {
        case .available(let source):
            return "Available from \(source.displayName)"
        case .requiresProxy(let source):
            return "Available via proxy from \(source.displayName)"
        case .captchaBlocked(let publisher, _):
            return "\(publisher) requires verification"
        case .paywalled(let publisher, _):
            return "Subscription required for \(publisher)"
        case .unavailable(let reason):
            return reason.displayDescription
        case .checking:
            return "Checking availability..."
        }
    }
}

// MARK: - Resolved PDF Source

/// Source of a resolved PDF file.
public struct ResolvedPDFSource: Sendable, Equatable {
    public let type: ResolvedPDFSourceType
    public let url: URL
    public let name: String?

    public init(type: ResolvedPDFSourceType, url: URL, name: String? = nil) {
        self.type = type
        self.url = url
        self.name = name
    }

    public var displayName: String {
        name ?? type.displayName
    }
}

/// Type of resolved PDF source.
public enum ResolvedPDFSourceType: String, Sendable, Codable, CaseIterable {
    case arxiv
    case openAlex
    case publisher
    case landingPage  // Resolved from landing page scraping
    case adsScan
    case repository
    case unknown

    public var displayName: String {
        switch self {
        case .arxiv: return "arXiv"
        case .openAlex: return "Open Access"
        case .publisher: return "Publisher"
        case .landingPage: return "Publisher"  // Display same as publisher
        case .adsScan: return "ADS Scan"
        case .repository: return "Repository"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Unavailable Reason

/// Reason why a PDF is not available.
public enum UnavailableReason: Sendable, Equatable {
    case noPDFFound
    case allSourcesFailed
    case networkError(String)
    case invalidDOI

    public var displayDescription: String {
        switch self {
        case .noPDFFound:
            return "No PDF available"
        case .allSourcesFailed:
            return "Could not access any PDF source"
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidDOI:
            return "Invalid DOI"
        }
    }
}

// MARK: - Validation Result

/// Result of validating a PDF URL.
public enum URLValidationResult: Sendable {
    /// URL points to a valid PDF file.
    case validPDF(url: URL, contentLength: Int64?)

    /// URL requires authentication.
    case requiresAuthentication(url: URL, authType: AuthenticationType)

    /// URL requires CAPTCHA verification.
    case captchaRequired(url: URL, domain: String)

    /// URL is behind a paywall.
    case paywall(url: URL, publisher: String)

    /// URL returns HTML content instead of PDF.
    case htmlContent(url: URL, title: String?)

    /// URL is rate limited.
    case rateLimited(url: URL, retryAfter: TimeInterval?)

    /// URL not found (404).
    case notFound(url: URL)

    /// Network or other error.
    case networkError(url: URL, error: Error)

    /// Whether this result indicates success.
    public var isSuccess: Bool {
        if case .validPDF = self { return true }
        return false
    }
}

/// Type of authentication required.
public enum AuthenticationType: String, Sendable {
    case proxy
    case shibboleth
    case oauth
    case basicAuth
    case unknown
}
