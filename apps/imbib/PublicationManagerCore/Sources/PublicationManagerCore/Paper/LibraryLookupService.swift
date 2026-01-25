//
//  LibraryLookupService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - Default Library Lookup Service

/// Default implementation of LibraryLookupService using PublicationRepository.
public actor DefaultLibraryLookupService: LibraryLookupService {

    // MARK: - Properties

    private let repository: PublicationRepository

    /// Cached identifier index for fast lookups
    private var doiIndex: Set<String> = []
    private var arxivIndex: Set<String> = []
    private var bibcodeIndex: Set<String> = []
    private var lastRefresh: Date?

    /// How long to cache the index
    private static let cacheExpiry: TimeInterval = 60 // 1 minute

    // MARK: - Singleton

    public static let shared = DefaultLibraryLookupService()

    // MARK: - Initialization

    public init(repository: PublicationRepository = PublicationRepository()) {
        self.repository = repository
    }

    // MARK: - LibraryLookupService

    public func contains(identifiers: [IdentifierType: String]) async -> Bool {
        await refreshIndexIfNeeded()

        for (type, value) in identifiers {
            switch type {
            case .doi:
                if doiIndex.contains(value.lowercased()) { return true }
            case .arxiv:
                if arxivIndex.contains(value.lowercased()) { return true }
            case .bibcode:
                if bibcodeIndex.contains(value.lowercased()) { return true }
            default:
                break
            }
        }
        return false
    }

    public func contains(doi: String) async -> Bool {
        await refreshIndexIfNeeded()
        return doiIndex.contains(doi.lowercased())
    }

    public func contains(arxivID: String) async -> Bool {
        await refreshIndexIfNeeded()
        return arxivIndex.contains(arxivID.lowercased())
    }

    public func contains(bibcode: String) async -> Bool {
        await refreshIndexIfNeeded()
        return bibcodeIndex.contains(bibcode.lowercased())
    }

    // MARK: - Index Management

    /// Force refresh the identifier index
    public func refreshIndex() async {
        let publications = await repository.fetchAll(sortedBy: "dateAdded", ascending: false)

        var dois = Set<String>()
        var arxivs = Set<String>()
        var bibcodes = Set<String>()

        for pub in publications {
            // DOI
            if let doi = pub.doi ?? pub.fields["doi"], !doi.isEmpty {
                dois.insert(doi.lowercased())
            }

            // arXiv ID
            let fields = pub.fields
            if let arxiv = fields["eprint"] ?? fields["arxiv"], !arxiv.isEmpty {
                arxivs.insert(arxiv.lowercased())
            }

            // Bibcode
            if let bibcode = fields["bibcode"], !bibcode.isEmpty {
                bibcodes.insert(bibcode.lowercased())
            }
            // Also extract from ADS URL
            if let adsurl = fields["adsurl"],
               let extracted = extractBibcode(from: adsurl) {
                bibcodes.insert(extracted.lowercased())
            }
        }

        doiIndex = dois
        arxivIndex = arxivs
        bibcodeIndex = bibcodes
        lastRefresh = Date()
    }

    /// Invalidate the cache (call after imports/deletes)
    public func invalidateCache() {
        lastRefresh = nil
    }

    // MARK: - Private Helpers

    private func refreshIndexIfNeeded() async {
        if let lastRefresh = lastRefresh,
           Date().timeIntervalSince(lastRefresh) < Self.cacheExpiry {
            return
        }
        await refreshIndex()
    }

    private func extractBibcode(from url: String) -> String? {
        guard let url = URL(string: url),
              url.host?.contains("adsabs") == true,
              url.pathComponents.contains("abs"),
              let bibcodeIndex = url.pathComponents.firstIndex(of: "abs"),
              bibcodeIndex + 1 < url.pathComponents.count else {
            return nil
        }
        return url.pathComponents[bibcodeIndex + 1]
    }
}

// MARK: - Library State

/// Represents the state of a paper relative to the library
public enum LibraryState: Sendable, Equatable {
    /// Paper is in the library
    case inLibrary

    /// Paper is not in the library
    case notInLibrary

    /// State is being determined
    case checking

    /// State is unknown (no identifiers to check)
    case unknown
}

// MARK: - Paper Extension

public extension PaperRepresentable {
    /// Check if this paper is in the library
    func checkLibraryState(using service: LibraryLookupService = DefaultLibraryLookupService.shared) async -> LibraryState {
        let identifiers = allIdentifiers
        if identifiers.isEmpty {
            return .unknown
        }
        let isInLibrary = await service.contains(identifiers: identifiers)
        return isInLibrary ? .inLibrary : .notInLibrary
    }
}
