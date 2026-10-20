//
//  BrowserURLProvider.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import OSLog

/// Protocol for sources that can provide URLs for interactive PDF browsing.
///
/// Each source (ADS, Crossref, Semantic Scholar, etc.) can implement this
/// protocol to provide source-specific URLs that work best for browser-based
/// PDF retrieval.
///
/// Example (ADS):
/// ```swift
/// enum ADSBrowserURLs: BrowserURLProvider {
///     public static var sourceID: String { "ads" }
///
///     public static func browserPDFURL(for publication: PublicationModel) -> URL? {
///         guard let bibcode = publication.bibcode else { return nil }
///         return URL(string: "https://ui.adsabs.harvard.edu/link_gateway/\(bibcode)/PUB_PDF")
///     }
/// }
/// ```
public protocol BrowserURLProvider {
    /// Unique identifier for this source (e.g., "ads", "crossref")
    static var sourceID: String { get }

    /// Return the best URL to open in a browser for interactive PDF fetch.
    ///
    /// This should return a URL that, when opened in a browser, leads to
    /// the publication's PDF (possibly after authentication).
    ///
    /// - Parameter publication: The publication to find a PDF for
    /// - Returns: A URL to open in the browser, or nil if this source can't help
    static func browserPDFURL(for publication: PublicationModel) -> URL?
}

/// Registry of BrowserURLProvider implementations.
///
/// Sources register themselves on app startup, and the registry
/// tries each provider in turn to find a suitable browser URL.
///
/// Usage:
/// ```swift
/// // On app startup:
/// await BrowserURLProviderRegistry.shared.register(ADSBrowserURLs.self)
/// await BrowserURLProviderRegistry.shared.register(ArXivBrowserURLs.self)
///
/// // When opening browser:
/// let url = await BrowserURLProviderRegistry.shared.browserURL(for: publication)
/// ```
public actor BrowserURLProviderRegistry {

    // MARK: - Shared Instance

    public static let shared = BrowserURLProviderRegistry()

    // MARK: - Properties

    /// Registered providers by source ID
    private var providers: [String: any BrowserURLProvider.Type] = [:]

    /// Provider priority order (higher priority sources tried first)
    private var priorityOrder: [String] = []

    // MARK: - Initialization

    private init() {
        Logger.pdfBrowser.info("BrowserURLProviderRegistry initialized")
    }

    // MARK: - Registration

    /// Register a provider.
    ///
    /// - Parameter provider: The provider type to register
    /// - Parameter priority: Higher values are tried first (default: 0)
    public func register(_ provider: any BrowserURLProvider.Type, priority: Int = 0) {
        let sourceID = provider.sourceID
        providers[sourceID] = provider

        // Insert into priority order
        if !priorityOrder.contains(sourceID) {
            priorityOrder.append(sourceID)
        }

        Logger.pdfBrowser.info("Registered BrowserURLProvider: \(sourceID)")
    }

    /// Unregister a provider.
    public func unregister(_ sourceID: String) {
        providers.removeValue(forKey: sourceID)
        priorityOrder.removeAll { $0 == sourceID }

        Logger.pdfBrowser.info("Unregistered BrowserURLProvider: \(sourceID)")
    }

    /// Get all registered source IDs.
    public var registeredSources: [String] {
        Array(providers.keys)
    }

    // MARK: - URL Resolution

    /// Get the best browser URL for a publication.
    ///
    /// Tries registered providers in priority order, then falls back to:
    /// 1. DOI resolver
    /// 2. Any PDF-related URL from fields
    ///
    /// - Parameter publication: The publication to find a PDF URL for
    /// - Returns: A URL to open in the browser, or nil if none found
    public func browserURL(for publication: PublicationModel) -> URL? {
        Logger.pdfBrowser.debug("Looking for browser URL for: \(publication.title)")

        // Try registered providers in priority order
        for sourceID in priorityOrder {
            guard let provider = providers[sourceID] else { continue }

            if let url = provider.browserPDFURL(for: publication) {
                Logger.pdfBrowser.info("Found browser URL from \(sourceID): \(url.absoluteString)")
                return url
            }
        }

        // Try all providers (in case priority order is incomplete)
        for (sourceID, provider) in providers {
            if priorityOrder.contains(sourceID) { continue } // Already tried

            if let url = provider.browserPDFURL(for: publication) {
                Logger.pdfBrowser.info("Found browser URL from \(sourceID): \(url.absoluteString)")
                return url
            }
        }

        // Fallback 1: DOI resolver
        if let doi = publication.doi {
            let url = URL(string: "https://doi.org/\(doi)")
            Logger.pdfBrowser.info("Using DOI fallback: \(url?.absoluteString ?? "nil")")
            return url
        }

        // Fallback 2: URL field
        if let urlString = publication.url, let url = URL(string: urlString) {
            Logger.pdfBrowser.info("Using URL field fallback: \(url.absoluteString)")
            return url
        }

        Logger.pdfBrowser.warning("No browser URL found for publication")
        return nil
    }

    /// Get browser URL from a specific source.
    ///
    /// - Parameters:
    ///   - sourceID: The source to use (e.g., "ads")
    ///   - publication: The publication to find a PDF URL for
    /// - Returns: A URL from that specific source, or nil
    public func browserURL(from sourceID: String, for publication: PublicationModel) -> URL? {
        guard let provider = providers[sourceID] else {
            Logger.pdfBrowser.warning("Source not registered: \(sourceID)")
            return nil
        }

        return provider.browserPDFURL(for: publication)
    }
}

// MARK: - Default Providers

/// Default fallback provider that uses DOI and URL fields.
///
/// This is automatically used as a fallback, but can also be
/// registered explicitly if needed.
public struct DefaultBrowserURLProvider: BrowserURLProvider {
    public static var sourceID: String { "default" }

    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        // Try DOI first
        if let doi = publication.doi {
            return URL(string: "https://doi.org/\(doi)")
        }

        // Try URL field
        if let urlString = publication.url, let url = URL(string: urlString) {
            return url
        }

        return nil
    }
}

// MARK: - The suite's providers

/// NASA ADS: DOI resolver → ADS abstract page → arXiv PDF.
public enum ADSBrowserURLs: BrowserURLProvider {
    public static var sourceID: String { "ads" }

    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        if let doi = publication.doi, !doi.isEmpty {
            Logger.pdfBrowser.debug("ADS: Using DOI resolver for: \(doi)")
            return URL(string: "https://doi.org/\(doi)")
        }
        if let bibcode = publication.bibcode {
            Logger.pdfBrowser.debug("ADS: Using abstract page for bibcode: \(bibcode)")
            return URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)/abstract")
        }
        if let arxivID = publication.arxivID, !arxivID.isEmpty {
            Logger.pdfBrowser.debug("ADS: Using arXiv PDF for: \(arxivID)")
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
        }
        return nil
    }
}

/// SciX: DOI resolver → SciX abstract page.
public enum SciXBrowserURLs: BrowserURLProvider {
    public static var sourceID: String { "scix" }

    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        if let doi = publication.doi, !doi.isEmpty {
            Logger.pdfBrowser.debug("SciX: Using DOI resolver for: \(doi)")
            return URL(string: "https://doi.org/\(doi)")
        }
        if let bibcode = publication.bibcode {
            Logger.pdfBrowser.debug("SciX: Using abstract page for bibcode: \(bibcode)")
            return URL(string: "https://scixplorer.org/abs/\(bibcode)/abstract")
        }
        return nil
    }
}

/// arXiv: the PDF directly.
public enum ArXivBrowserURLs: BrowserURLProvider {
    public static var sourceID: String { "arxiv" }

    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        guard let arxivID = publication.arxivID, !arxivID.isEmpty else { return nil }
        let cleanID = arxivID.trimmingCharacters(in: .whitespaces)
        Logger.pdfBrowser.debug("ArXiv: Using direct PDF URL for: \(cleanID)")
        return URL(string: "https://arxiv.org/pdf/\(cleanID).pdf")
    }
}

/// OpenAlex: DOI resolver → the work page → the record's URL.
public enum OpenAlexBrowserURLs: BrowserURLProvider {
    public static var sourceID: String { "openalex" }

    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        if let doi = publication.doi, !doi.isEmpty {
            Logger.pdfBrowser.debug("OpenAlex: Using DOI resolver for: \(doi)")
            return URL(string: "https://doi.org/\(doi)")
        }
        if let openAlexID = publication.fields["openalex_id"] {
            Logger.pdfBrowser.debug("OpenAlex: Using work page for: \(openAlexID)")
            return URL(string: "https://openalex.org/works/\(openAlexID)")
        }
        if let urlString = publication.url, let url = URL(string: urlString) {
            return url
        }
        return nil
    }
}
