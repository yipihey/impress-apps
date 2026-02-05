//
//  OpenAlexPDFService.swift
//  PublicationManagerCore
//
//  Service for fetching and caching OA PDF locations from OpenAlex.
//

import Foundation
import OSLog

// MARK: - OpenAlex PDF Service

/// Service for fetching and caching Open Access PDF locations from OpenAlex.
///
/// This service provides:
/// - Cached OA location lookups with configurable TTL
/// - Batch fetching for multiple DOIs
/// - Priority ordering of OA locations
///
/// ## Usage
///
/// ```swift
/// // Single lookup
/// if let location = await OpenAlexPDFService.shared.fetchBestOALocation(doi: "10.1234/example") {
///     print("Found OA PDF: \(location.pdfURL)")
/// }
///
/// // Batch lookup
/// let results = await OpenAlexPDFService.shared.fetchOALocationsBatch(dois: dois)
/// ```
public actor OpenAlexPDFService {

    // MARK: - Singleton

    public static let shared = OpenAlexPDFService()

    // MARK: - Properties

    private let source: OpenAlexSource
    private let cache = NSCache<NSString, CachedOAResult>()
    private let cacheTTL: TimeInterval

    /// Default cache TTL: 24 hours
    public static let defaultCacheTTL: TimeInterval = 24 * 60 * 60

    // MARK: - Initialization

    public init(
        source: OpenAlexSource? = nil,
        cacheTTL: TimeInterval = OpenAlexPDFService.defaultCacheTTL,
        cacheCountLimit: Int = 1000
    ) {
        self.source = source ?? OpenAlexSource()
        self.cacheTTL = cacheTTL
        cache.countLimit = cacheCountLimit
    }

    // MARK: - OA Location Lookup

    /// Fetch the best OA location for a DOI.
    ///
    /// Returns the highest-priority OA location with a PDF URL, or nil if none found.
    /// Results are cached for the configured TTL.
    ///
    /// - Parameter doi: The DOI to look up
    /// - Returns: The best OA location, or nil if none available
    public func fetchBestOALocation(doi: String) async -> OALocation? {
        let cleanDOI = cleanDOI(doi)

        // Check cache
        if let cached = getCachedResult(for: cleanDOI) {
            Logger.sources.debug("[OpenAlexPDFService] Cache hit for \(cleanDOI)")
            return cached.bestLocation
        }

        // Fetch from API
        do {
            let work = try await source.fetchWorkByDOI(cleanDOI)
            let result = extractOALocations(from: work, doi: cleanDOI)
            cacheResult(result, for: cleanDOI)
            return result.bestLocation
        } catch {
            Logger.sources.warning("[OpenAlexPDFService] Failed to fetch OA for \(cleanDOI): \(error.localizedDescription)")
            // Cache the failure to avoid repeated requests
            cacheResult(OALookupResult(doi: cleanDOI, locations: [], timestamp: Date()), for: cleanDOI)
            return nil
        }
    }

    /// Fetch all OA locations for a DOI.
    ///
    /// Returns all known OA locations, sorted by priority.
    /// Results are cached for the configured TTL.
    public func fetchAllOALocations(doi: String) async -> [OALocation] {
        let cleanDOI = cleanDOI(doi)

        // Check cache
        if let cached = getCachedResult(for: cleanDOI) {
            return cached.locations
        }

        // Fetch from API
        do {
            let work = try await source.fetchWorkByDOI(cleanDOI)
            let result = extractOALocations(from: work, doi: cleanDOI)
            cacheResult(result, for: cleanDOI)
            return result.locations
        } catch {
            Logger.sources.warning("[OpenAlexPDFService] Failed to fetch OA for \(cleanDOI): \(error.localizedDescription)")
            cacheResult(OALookupResult(doi: cleanDOI, locations: [], timestamp: Date()), for: cleanDOI)
            return []
        }
    }

    /// Fetch landing page URL for a DOI.
    ///
    /// Returns the best landing page URL from OpenAlex data, which can be used
    /// for landing page scraping when no direct PDF URL is available.
    ///
    /// - Parameter doi: The DOI to look up
    /// - Returns: Landing page URL, or DOI URL as fallback
    public func fetchLandingPageURL(doi: String) async -> URL? {
        let cleanDOI = cleanDOI(doi)

        // Check cache for existing result with landing page
        if let cached = getCachedResult(for: cleanDOI) {
            // Return landing page from best location, or from any location
            if let landingPage = cached.locations.first?.landingPageURL {
                return landingPage
            }
        }

        // Fetch from API
        do {
            let work = try await source.fetchWorkByDOI(cleanDOI)
            let result = extractOALocations(from: work, doi: cleanDOI)
            cacheResult(result, for: cleanDOI)

            // Try to get landing page from best OA location
            if let landingPage = result.locations.first?.landingPageURL {
                return landingPage
            }

            // Try primary location
            if let primaryLanding = work.primaryLocation?.landingPageUrl,
               let url = URL(string: primaryLanding) {
                return url
            }

            // Fall back to DOI URL
            return URL(string: "https://doi.org/\(cleanDOI)")

        } catch {
            Logger.sources.debug("[OpenAlexPDFService] Could not fetch landing page for \(cleanDOI): \(error.localizedDescription)")
            // Fall back to DOI URL
            return URL(string: "https://doi.org/\(cleanDOI)")
        }
    }

    /// Batch fetch OA locations for multiple DOIs.
    ///
    /// Uses OpenAlex batch API for efficiency. Results are cached individually.
    ///
    /// - Parameter dois: The DOIs to look up
    /// - Returns: Dictionary mapping DOIs to their best OA locations
    public func fetchOALocationsBatch(dois: [String]) async -> [String: OALocation?] {
        guard !dois.isEmpty else { return [:] }

        let cleanDOIs = dois.map { cleanDOI($0) }
        var results: [String: OALocation?] = [:]
        var uncachedDOIs: [String] = []

        // Check cache first
        for doi in cleanDOIs {
            if let cached = getCachedResult(for: doi) {
                results[doi] = cached.bestLocation
            } else {
                uncachedDOIs.append(doi)
            }
        }

        Logger.sources.info("[OpenAlexPDFService] Batch: \(cleanDOIs.count) total, \(uncachedDOIs.count) uncached")

        // Fetch uncached DOIs in batches of 50
        let batchSize = 50
        for batch in stride(from: 0, to: uncachedDOIs.count, by: batchSize) {
            let batchDOIs = Array(uncachedDOIs[batch..<min(batch + batchSize, uncachedDOIs.count)])

            do {
                let stubs = try await source.fetchWorksBatch(ids: batchDOIs.map { "https://doi.org/\($0)" })

                // Process each result
                for stub in stubs {
                    if let doi = stub.doi {
                        let cleanedDOI = cleanDOI(doi)
                        // We need to fetch the full work to get OA locations
                        // PaperStub doesn't have OA info, so we mark as fetched but no OA
                        let result = OALookupResult(doi: cleanedDOI, locations: [], timestamp: Date())
                        cacheResult(result, for: cleanedDOI)
                        results[cleanedDOI] = nil
                    }
                }

                // For DOIs not in results, fetch individually (they might have OA info)
                for doi in batchDOIs where results[doi] == nil {
                    if let location = await fetchBestOALocation(doi: doi) {
                        results[doi] = location
                    } else {
                        results[doi] = nil
                    }
                }
            } catch {
                Logger.sources.warning("[OpenAlexPDFService] Batch fetch failed: \(error.localizedDescription)")
                // Mark failed DOIs as having no OA
                for doi in batchDOIs {
                    results[doi] = nil
                    cacheResult(OALookupResult(doi: doi, locations: [], timestamp: Date()), for: doi)
                }
            }
        }

        return results
    }

    // MARK: - Cache Management

    /// Clear the cache.
    public func clearCache() {
        cache.removeAllObjects()
        Logger.sources.info("[OpenAlexPDFService] Cache cleared")
    }

    /// Get cache statistics.
    public func cacheStats() -> (count: Int, limit: Int) {
        // NSCache doesn't expose count, so we can't get actual count
        return (count: 0, limit: cache.countLimit)
    }

    // MARK: - Private Methods

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
        guard let cached = cache.object(forKey: doi as NSString) else {
            return nil
        }

        // Check if expired
        if Date().timeIntervalSince(cached.result.timestamp) > cacheTTL {
            cache.removeObject(forKey: doi as NSString)
            return nil
        }

        return cached.result
    }

    private func cacheResult(_ result: OALookupResult, for doi: String) {
        cache.setObject(CachedOAResult(result: result), forKey: doi as NSString)
    }

    private func extractOALocations(from work: OpenAlexWork, doi: String) -> OALookupResult {
        var locations: [OALocation] = []

        // Extract from best_oa_location
        if let bestOA = work.bestOaLocation {
            if let location = convertLocation(bestOA, priority: .best) {
                locations.append(location)
            }
        }

        // Extract from locations array
        if let workLocations = work.locations {
            for loc in workLocations {
                if let location = convertLocation(loc, priority: .standard) {
                    // Avoid duplicates
                    if !locations.contains(where: { $0.pdfURL == location.pdfURL }) {
                        locations.append(location)
                    }
                }
            }
        }

        // Sort by priority
        locations.sort { $0.priority.rawValue < $1.priority.rawValue }

        return OALookupResult(doi: doi, locations: locations, timestamp: Date())
    }

    private func convertLocation(_ location: OpenAlexLocation, priority: OALocationPriority) -> OALocation? {
        guard let pdfURLString = location.pdfUrl,
              let pdfURL = URL(string: pdfURLString) else {
            return nil
        }

        return OALocation(
            pdfURL: pdfURL,
            landingPageURL: location.landingPageUrl.flatMap { URL(string: $0) },
            sourceName: location.source?.displayName,
            version: location.version,
            license: location.license,
            isOA: location.isOa ?? false,
            priority: priority
        )
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
    case best = 0       // OpenAlex best_oa_location
    case standard = 1   // Other locations
    case fallback = 2   // Last resort
}

/// Result of an OA lookup, including timestamp for cache expiry.
public struct OALookupResult: Sendable {
    public let doi: String
    public let locations: [OALocation]
    public let timestamp: Date

    public var bestLocation: OALocation? {
        locations.first
    }

    public var hasPDF: Bool {
        !locations.isEmpty
    }
}

/// Cache wrapper for NSCache (must be a class).
private final class CachedOAResult: NSObject {
    let result: OALookupResult

    init(result: OALookupResult) {
        self.result = result
    }
}
