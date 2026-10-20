//
//  OpenAlexPDFService.swift
//  PublicationManagerCore
//
//  Open Access PDF locations for a DOI, cached. The record comes from the
//  Rust source verbs (`bib-source-service_fetch`, scoped to OpenAlex: its
//  adapter fills `locations` from the work's OA locations — source convention
//  S6); this actor keeps the cache and the priority order the PDF resolver
//  relies on. It replaces the Swift OpenAlex plugin's own HTTP client.
//

import Foundation
import OSLog

// MARK: - OpenAlex PDF Service

/// Cached Open Access PDF locations from OpenAlex.
///
/// ```swift
/// if let location = await OpenAlexPDFService.shared.fetchBestOALocation(doi: "10.1234/example") {
///     print("Found OA PDF: \(location.pdfURL)")
/// }
/// ```
public actor OpenAlexPDFService {

    // MARK: - Singleton

    public static let shared = OpenAlexPDFService()

    // MARK: - Properties

    private let client: SourceClient
    private let cache = NSCache<NSString, CachedOAResult>()
    private let cacheTTL: TimeInterval

    /// Default cache TTL: 24 hours
    public static let defaultCacheTTL: TimeInterval = 24 * 60 * 60

    // MARK: - Initialization

    public init(
        client: SourceClient = SourceClient(),
        cacheTTL: TimeInterval = OpenAlexPDFService.defaultCacheTTL,
        cacheCountLimit: Int = 1000
    ) {
        self.client = client
        self.cacheTTL = cacheTTL
        cache.countLimit = cacheCountLimit
    }

    // MARK: - OA Location Lookup

    /// The best OA location with a PDF for a DOI, or nil. Cached.
    public func fetchBestOALocation(doi: String) async -> OALocation? {
        await lookup(doi: cleanDOI(doi)).bestLocation
    }

    /// Every OA location for a DOI, by priority. Cached.
    public func fetchAllOALocations(doi: String) async -> [OALocation] {
        await lookup(doi: cleanDOI(doi)).locations
    }

    /// The landing page for a DOI: the best location's, else the record's
    /// primary location's, else the DOI resolver.
    public func fetchLandingPageURL(doi: String) async -> URL? {
        let clean = cleanDOI(doi)
        let result = await lookup(doi: clean)
        if let landing = result.locations.first?.landingPageURL { return landing }
        if let primary = result.primaryLandingPageURL { return primary }
        return URL(string: "https://doi.org/\(clean)")
    }

    /// Best OA locations for several DOIs (one fetch each; cached).
    public func fetchOALocationsBatch(dois: [String]) async -> [String: OALocation?] {
        guard !dois.isEmpty else { return [:] }
        var results: [String: OALocation?] = [:]
        let cleaned = dois.map { cleanDOI($0) }
        let uncached = cleaned.filter { getCachedResult(for: $0) == nil }.count
        Logger.sources.infoCapture("[OpenAlexPDFService] Batch: \(cleaned.count) total, \(uncached) uncached", category: "sources")
        for doi in cleaned {
            results[doi] = await lookup(doi: doi).bestLocation
        }
        return results
    }

    // MARK: - Cache Management

    public func clearCache() {
        cache.removeAllObjects()
        Logger.sources.info("[OpenAlexPDFService] Cache cleared")
    }

    public func cacheStats() -> (count: Int, limit: Int) {
        (count: 0, limit: cache.countLimit)
    }

    // MARK: - Private

    private func lookup(doi: String) async -> OALookupResult {
        if let cached = getCachedResult(for: doi) {
            Logger.sources.debug("[OpenAlexPDFService] Cache hit for \(doi)")
            return cached
        }
        let result: OALookupResult
        do {
            let locations = try await client.fetchLocations(id: "doi:\(doi)", sources: ["openalex"])
            result = Self.extract(from: locations, doi: doi)
            Logger.sources.infoCapture(
                "[OpenAlexPDFService] \(doi): \(result.locations.count) OA location(s) with a PDF",
                category: "sources"
            )
        } catch {
            Logger.sources.warningCapture(
                "[OpenAlexPDFService] Failed to fetch OA for \(doi): \(error.localizedDescription)",
                category: "sources"
            )
            result = OALookupResult(doi: doi, locations: [], timestamp: Date())
        }
        cacheResult(result, for: doi)
        return result
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

    private func getCachedResult(for doi: String) -> OALookupResult? {
        guard let cached = cache.object(forKey: doi as NSString) else { return nil }
        if Date().timeIntervalSince(cached.result.timestamp) > cacheTTL {
            cache.removeObject(forKey: doi as NSString)
            return nil
        }
        return cached.result
    }

    private func cacheResult(_ result: OALookupResult, for doi: String) {
        cache.setObject(CachedOAResult(result: result), forKey: doi as NSString)
    }

    /// The record's locations as OA locations: those with a PDF, the
    /// primary one first.
    static func extract(from locations: [WorkLocation], doi: String) -> OALookupResult {
        var out: [OALocation] = []
        for location in locations {
            guard let pdf = location.pdf else { continue }
            let candidate = OALocation(
                pdfURL: pdf,
                landingPageURL: location.url,
                sourceName: location.source,
                version: location.version,
                license: location.license,
                isOA: location.isOpenAccess,
                priority: location.primary ? .best : .standard
            )
            if !out.contains(where: { $0.pdfURL == candidate.pdfURL }) {
                out.append(candidate)
            }
        }
        out.sort { $0.priority.rawValue < $1.priority.rawValue }
        let primaryLanding = locations.first(where: \.primary)?.url ?? locations.first?.url
        return OALookupResult(doi: doi, locations: out, timestamp: Date(), primaryLandingPageURL: primaryLanding)
    }
}

// MARK: - Supporting Types

/// Open Access location with PDF URL.
public struct OALocation: Sendable, Equatable {
    public let pdfURL: URL
    public let landingPageURL: URL?
    public let sourceName: String?
    public let version: String?
    public let license: String?
    public let isOA: Bool
    public let priority: OALocationPriority

    public init(
        pdfURL: URL,
        landingPageURL: URL? = nil,
        sourceName: String? = nil,
        version: String? = nil,
        license: String? = nil,
        isOA: Bool = true,
        priority: OALocationPriority = .standard
    ) {
        self.pdfURL = pdfURL
        self.landingPageURL = landingPageURL
        self.sourceName = sourceName
        self.version = version
        self.license = license
        self.isOA = isOA
        self.priority = priority
    }
}

/// Priority level for OA locations.
public enum OALocationPriority: Int, Sendable {
    case best = 0       // the record's primary location
    case standard = 1   // other locations
    case fallback = 2   // last resort
}

/// Result of an OA lookup, including timestamp for cache expiry.
public struct OALookupResult: Sendable {
    public let doi: String
    public let locations: [OALocation]
    public let timestamp: Date
    /// The landing page of the record's primary location, PDF or not.
    public let primaryLandingPageURL: URL?

    public init(doi: String, locations: [OALocation], timestamp: Date, primaryLandingPageURL: URL? = nil) {
        self.doi = doi
        self.locations = locations
        self.timestamp = timestamp
        self.primaryLandingPageURL = primaryLandingPageURL
    }

    public var bestLocation: OALocation? { locations.first }
    public var hasPDF: Bool { !locations.isEmpty }
}

/// Cache wrapper for NSCache (must be a class).
private final class CachedOAResult: NSObject {
    let result: OALookupResult
    init(result: OALookupResult) { self.result = result }
}
