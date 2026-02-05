//
//  PublisherHTMLParsers.swift
//  PublicationManagerCore
//
//  Publisher-specific HTML parsing strategies for extracting PDF URLs from landing pages.
//

import Foundation
import OSLog

// MARK: - Publisher HTML Parsers

/// Publisher-specific HTML parsers for extracting PDF URLs from landing pages.
///
/// Each parser understands the DOM structure of a specific publisher's website and
/// can reliably extract PDF download links.
///
/// ## Supported Publishers
///
/// - IOP Science (ApJ, AJ, JCAP, etc.)
/// - APS (Physical Review journals)
/// - Nature Publishing Group
/// - Oxford Academic (MNRAS, etc.)
/// - Elsevier/ScienceDirect
/// - A&A (EDP Sciences)
/// - Generic fallback for unknown publishers
public struct PublisherHTMLParsers: Sendable {

    // MARK: - Initialization

    public init() {}

    // MARK: - Parsing

    /// Parse HTML and extract PDF URL using publisher-specific logic.
    ///
    /// - Parameters:
    ///   - html: The HTML content of the landing page
    ///   - baseURL: The URL of the landing page (for resolving relative URLs)
    ///   - publisherHost: The hostname (e.g., "iopscience.iop.org")
    /// - Returns: PDF URL if found, nil otherwise
    public func parse(html: String, baseURL: URL, publisherHost: String) -> URL? {
        // Select parser based on publisher host
        let parser = selectParser(for: publisherHost)
        return parser(html, baseURL)
    }

    /// Get parser ID for a publisher host (for logging/debugging).
    public func parserID(for publisherHost: String) -> String {
        if publisherHost.contains("iopscience.iop.org") { return "iop" }
        if publisherHost.contains("link.aps.org") || publisherHost.contains("journals.aps.org") { return "aps" }
        if publisherHost.contains("nature.com") { return "nature" }
        if publisherHost.contains("academic.oup.com") { return "oxford" }
        if publisherHost.contains("sciencedirect.com") { return "elsevier" }
        if publisherHost.contains("aanda.org") { return "aanda" }
        if publisherHost.contains("science.org") { return "science" }
        if publisherHost.contains("wiley.com") || publisherHost.contains("onlinelibrary.wiley.com") { return "wiley" }
        if publisherHost.contains("springer.com") || publisherHost.contains("link.springer.com") { return "springer" }
        if publisherHost.contains("cambridge.org") { return "cambridge" }
        if publisherHost.contains("annualreviews.org") { return "annual-reviews" }
        if publisherHost.contains("mdpi.com") { return "mdpi" }
        if publisherHost.contains("frontiersin.org") { return "frontiers" }
        if publisherHost.contains("plos.org") || publisherHost.contains("journals.plos.org") { return "plos" }
        if publisherHost.contains("aip.org") || publisherHost.contains("aip.scitation.org") { return "aip" }
        return "generic"
    }

    private func selectParser(for publisherHost: String) -> (String, URL) -> URL? {
        switch parserID(for: publisherHost) {
        case "iop": return parseIOP
        case "aps": return parseAPS
        case "nature": return parseNature
        case "oxford": return parseOxford
        case "elsevier": return parseElsevier
        case "aanda": return parseAandA
        case "science": return parseScience
        case "wiley": return parseWiley
        case "springer": return parseSpringer
        case "cambridge": return parseCambridge
        case "annual-reviews": return parseAnnualReviews
        case "mdpi": return parseMDPI
        case "frontiers": return parseFrontiers
        case "plos": return parsePLOS
        case "aip": return parseAIP
        default: return parseGeneric
        }
    }

    // MARK: - IOP Science Parser

    /// Parse IOP Science landing pages (ApJ, AJ, JCAP, CQG, etc.)
    ///
    /// IOP structure:
    /// - Article page: `/article/{doi}`
    /// - PDF link: `/article/{doi}/pdf` or download button with class `btn-download`
    private func parseIOP(html: String, baseURL: URL) -> URL? {
        // Try meta tag first (most reliable)
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // IOP uses a simple pattern: article URL + /pdf
        let articlePath = baseURL.path
        if articlePath.contains("/article/") && !articlePath.hasSuffix("/pdf") {
            let pdfPath = articlePath + "/pdf"
            if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                components.path = pdfPath
                return components.url
            }
        }

        // Try download button pattern
        let downloadPattern = #"<a[^>]+class\s*=\s*["'][^"']*btn-download[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: downloadPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - APS Parser

    /// Parse APS landing pages (Physical Review journals)
    ///
    /// APS structure:
    /// - Abstract page: `/abstract/{doi}`
    /// - PDF link: `/pdf/{doi}`
    private func parseAPS(html: String, baseURL: URL) -> URL? {
        // APS pattern: replace /abstract/ with /pdf/
        let path = baseURL.path
        if path.contains("/abstract/") {
            let pdfPath = path.replacingOccurrences(of: "/abstract/", with: "/pdf/")
            if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                components.path = pdfPath
                return components.url
            }
        }

        // Try meta tag
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Try PDF link pattern
        let pdfLinkPattern = #"<a[^>]+href\s*=\s*["']([^"']*pdf[^"']*)["'][^>]*>\s*(?:PDF|Download PDF)"#
        if let url = extractURL(from: html, pattern: pdfLinkPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - Nature Parser

    /// Parse Nature landing pages
    ///
    /// Nature structure:
    /// - Article page: `/articles/{article-id}`
    /// - PDF link: `/articles/{article-id}.pdf`
    /// - PDF download button: `data-track-action="download pdf"`
    private func parseNature(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Nature pattern: article ID + .pdf
        let path = baseURL.path
        if path.contains("/articles/") && !path.hasSuffix(".pdf") {
            if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                components.path = path + ".pdf"
                return components.url
            }
        }

        // Try download button with data attribute
        let downloadPattern = #"<a[^>]+data-track-action\s*=\s*["']download pdf["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: downloadPattern, baseURL: baseURL) {
            return url
        }

        // Alternative pattern
        let altDownloadPattern = #"<a[^>]+href\s*=\s*["']([^"']+)["'][^>]+data-track-action\s*=\s*["']download pdf["']"#
        if let url = extractURL(from: html, pattern: altDownloadPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - Oxford Academic Parser

    /// Parse Oxford Academic landing pages (MNRAS, etc.)
    ///
    /// Oxford structure:
    /// - Article page: `/mnras/article/{ids}`
    /// - PDF link: in article-actions section, or via "View PDF" link
    private func parseOxford(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Oxford pattern: look for PDF link in article-actions
        let pdfLinkPattern = #"<a[^>]+class\s*=\s*["'][^"']*pdf-link[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: pdfLinkPattern, baseURL: baseURL) {
            return url
        }

        // Alternative: look for "PDF" in button/link text
        let altPattern = #"<a[^>]+href\s*=\s*["']([^"']+\.pdf[^"']*)["'][^>]*>(?:\s*<[^>]*>)*\s*(?:View\s+)?PDF"#
        if let url = extractURL(from: html, pattern: altPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - Elsevier/ScienceDirect Parser

    /// Parse Elsevier/ScienceDirect landing pages
    ///
    /// ScienceDirect structure:
    /// - Article page: `/science/article/pii/{pii}`
    /// - PDF in JavaScript data or via specific download link
    private func parseElsevier(html: String, baseURL: URL) -> URL? {
        // ScienceDirect embeds PDF URL in JavaScript
        // Look for pdfLink in page data
        let pdfLinkPattern = #""pdfLink"\s*:\s*"([^"]+)""#
        if let url = extractURL(from: html, pattern: pdfLinkPattern, baseURL: baseURL) {
            return url
        }

        // Try download button
        let downloadPattern = #"<a[^>]+id\s*=\s*["']pdfLink["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: downloadPattern, baseURL: baseURL) {
            return url
        }

        // Alternative: link with pdf-download class
        let altPattern = #"<a[^>]+class\s*=\s*["'][^"']*pdf-download[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: altPattern, baseURL: baseURL) {
            return url
        }

        // Try meta tag
        return extractMetaCitationPDF(html: html, baseURL: baseURL)
    }

    // MARK: - A&A (EDP Sciences) Parser

    /// Parse A&A (Astronomy & Astrophysics) landing pages
    ///
    /// A&A structure:
    /// - Article page: `/articles/{vol}/{article}`
    /// - PDF in downloads section
    private func parseAandA(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // A&A pattern: look for PDF in downloads
        let pdfPattern = #"<a[^>]+href\s*=\s*["']([^"']+\.pdf)["'][^>]*>\s*(?:<[^>]*>)*\s*PDF"#
        if let url = extractURL(from: html, pattern: pdfPattern, baseURL: baseURL) {
            return url
        }

        // Alternative: downloads section
        let altPattern = #"<div[^>]+class\s*=\s*["'][^"']*downloads[^"']*["'][^>]*>.*?<a[^>]+href\s*=\s*["']([^"']+\.pdf)["']"#
        if let url = extractURL(from: html, pattern: altPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - Science (AAAS) Parser

    /// Parse Science/Science Advances landing pages
    private func parseScience(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Science pattern: /doi/pdf/{doi}
        let path = baseURL.path
        if path.contains("/doi/") && !path.contains("/pdf/") {
            let pdfPath = path.replacingOccurrences(of: "/doi/", with: "/doi/pdf/")
            if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                components.path = pdfPath
                return components.url
            }
        }

        return nil
    }

    // MARK: - Wiley Parser

    /// Parse Wiley Online Library landing pages
    private func parseWiley(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Wiley pattern: /doi/epdf/{doi}
        let path = baseURL.path
        if path.contains("/doi/") && !path.contains("/epdf/") && !path.contains("/pdf/") {
            // Try epdf first (enhanced PDF)
            let epdfPath = path.replacingOccurrences(of: "/doi/", with: "/doi/epdf/")
            if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                components.path = epdfPath
                return components.url
            }
        }

        // Look for PDF tools link
        let pdfToolsPattern = #"<a[^>]+class\s*=\s*["'][^"']*pdf-tools[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: pdfToolsPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - Springer Parser

    /// Parse Springer landing pages
    private func parseSpringer(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Springer pattern: look for PDF download link
        let downloadPattern = #"<a[^>]+data-track-action\s*=\s*["']Download Article["'][^>]+href\s*=\s*["']([^"']+\.pdf[^"']*)["']"#
        if let url = extractURL(from: html, pattern: downloadPattern, baseURL: baseURL) {
            return url
        }

        // Alternative: PDF link in article actions
        let altPattern = #"<a[^>]+href\s*=\s*["']([^"']+content/pdf[^"']+)["']"#
        if let url = extractURL(from: html, pattern: altPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - Cambridge Parser

    /// Parse Cambridge University Press landing pages
    private func parseCambridge(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Cambridge pattern: /article/.../pdf suffix
        let path = baseURL.path
        if path.contains("/article/") && !path.hasSuffix("/pdf") {
            if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                components.path = path + "/pdf"
                return components.url
            }
        }

        return nil
    }

    // MARK: - Annual Reviews Parser

    /// Parse Annual Reviews landing pages
    private func parseAnnualReviews(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Annual Reviews pattern: look for PDF link
        let pdfPattern = #"<a[^>]+href\s*=\s*["']([^"']+/pdf/[^"']+)["']"#
        if let url = extractURL(from: html, pattern: pdfPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - MDPI Parser

    /// Parse MDPI landing pages (fully open access)
    private func parseMDPI(html: String, baseURL: URL) -> URL? {
        // Try meta tag first (MDPI uses standard meta tags)
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // MDPI pattern: /pdf suffix
        let path = baseURL.path
        if !path.hasSuffix("/pdf") {
            if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                components.path = path + "/pdf"
                return components.url
            }
        }

        return nil
    }

    // MARK: - Frontiers Parser

    /// Parse Frontiers landing pages (fully open access)
    private func parseFrontiers(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // Frontiers pattern: look for download link
        let downloadPattern = #"<a[^>]+class\s*=\s*["'][^"']*download-files-pdf[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: downloadPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - PLOS Parser

    /// Parse PLOS landing pages (fully open access)
    private func parsePLOS(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // PLOS pattern: look for Download PDF link
        let downloadPattern = #"<a[^>]+id\s*=\s*["']downloadPdf["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: downloadPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - AIP Parser

    /// Parse AIP/Scitation landing pages
    private func parseAIP(html: String, baseURL: URL) -> URL? {
        // Try meta tag first
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // AIP pattern: look for PDF link
        let pdfPattern = #"<a[^>]+class\s*=\s*["'][^"']*pdf-link[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: pdfPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - Generic Parser

    /// Generic parser for unknown publishers.
    /// Tries common patterns that work across many publishers.
    private func parseGeneric(html: String, baseURL: URL) -> URL? {
        // 1. Try standard citation_pdf_url meta tag
        if let url = extractMetaCitationPDF(html: html, baseURL: baseURL) {
            return url
        }

        // 2. Try alternate link tag
        let alternatePDFPattern = #"<link[^>]+rel\s*=\s*["']alternate["'][^>]+type\s*=\s*["']application/pdf["'][^>]+href\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: alternatePDFPattern, baseURL: baseURL) {
            return url
        }

        // 3. Look for explicit "Download PDF" links
        let downloadPDFPattern = #"<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>(?:\s*<[^>]*>)*\s*(?:Download\s+)?PDF"#
        if let url = extractURL(from: html, pattern: downloadPDFPattern, baseURL: baseURL) {
            // Verify it looks like a PDF URL
            let urlString = url.absoluteString.lowercased()
            if urlString.contains(".pdf") || urlString.contains("/pdf") {
                return url
            }
        }

        // 4. Look for links ending in .pdf
        let pdfExtensionPattern = #"<a[^>]+href\s*=\s*["']([^"']+\.pdf)["']"#
        if let url = extractURL(from: html, pattern: pdfExtensionPattern, baseURL: baseURL) {
            return url
        }

        return nil
    }

    // MARK: - Helpers

    /// Extract PDF URL from citation_pdf_url meta tag.
    private func extractMetaCitationPDF(html: String, baseURL: URL) -> URL? {
        // Pattern 1: name before content
        let pattern1 = #"<meta\s+name\s*=\s*["']citation_pdf_url["']\s+content\s*=\s*["']([^"']+)["']"#
        if let url = extractURL(from: html, pattern: pattern1, baseURL: baseURL) {
            return url
        }

        // Pattern 2: content before name
        let pattern2 = #"<meta\s+content\s*=\s*["']([^"']+)["']\s+name\s*=\s*["']citation_pdf_url["']"#
        return extractURL(from: html, pattern: pattern2, baseURL: baseURL)
    }

    /// Extract URL from HTML using regex pattern.
    private func extractURL(from html: String, pattern: String, baseURL: URL) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
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

    /// Resolve potentially relative URL against base URL.
    private func resolveURL(_ urlString: String, baseURL: URL) -> URL? {
        // Decode HTML entities
        let decoded = urlString
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Try as absolute URL first
        if let url = URL(string: decoded), url.scheme != nil {
            return url
        }

        // Resolve as relative URL
        return URL(string: decoded, relativeTo: baseURL)?.absoluteURL
    }
}
