//
//  ScixConversions.swift
//  PublicationManagerCore
//
//  Type conversions between ImpressScixCore (scix-client-ffi) types and
//  PublicationManagerCore domain types (SearchResult, PaperStub, PDFLink).
//

import Foundation
import ImpressScixCore

// MARK: - ScixPaper → SearchResult / PaperStub

extension ScixPaper {

    /// Convert to a SearchResult for display in the search UI.
    ///
    /// - Parameter sourceID: "ads" or "scix" — controls which web URLs are used.
    func toSearchResult(sourceID: String = "ads") -> SearchResult {
        let pdfLinks = toPdfLinks(sourceID: sourceID)

        // Build web URL: SciX uses scixplorer.org, ADS uses ui.adsabs.harvard.edu
        let webURL: URL?
        let bibtexURL: URL?
        if sourceID == "scix" {
            webURL = URL(string: "https://scixplorer.org/abs/\(bibcode)")
            bibtexURL = URL(string: "https://scixplorer.org/abs/\(bibcode)/exportcitation")
        } else {
            webURL = URL(string: webUrl)
            bibtexURL = URL(string: "\(webUrl)/exportcitation")
        }

        return SearchResult(
            id: bibcode,
            sourceID: sourceID,
            title: title,
            authors: authors.map { $0.name },
            year: year.map { Int($0) },
            venue: publication,
            abstract: abstractText,
            doi: doi,
            arxivID: arxivId,
            pmid: nil,
            bibcode: bibcode,
            pdfLinks: pdfLinks,
            webURL: webURL,
            bibtexURL: bibtexURL
        )
    }

    /// Convert to a PaperStub for references/citations display.
    func toPaperStub() -> PaperStub {
        PaperStub(
            id: bibcode,
            title: title,
            authors: authors.map { $0.name },
            year: year.map { Int($0) },
            venue: publication,
            doi: doi,
            arxivID: arxivId,
            citationCount: citationCount.map { Int($0) },
            referenceCount: nil,  // Computed from fetched references list, not from scix-client
            isOpenAccess: isOpenAccess ? true : nil,
            abstract: abstractText
        )
    }

    /// Extract PDF links in PublicationManagerCore's format.
    func toPdfLinks(sourceID: String = "ads") -> [PDFLink] {
        // Convert scix-client links
        var links: [PDFLink] = pdfLinks.compactMap { link in
            guard let url = URL(string: link.url) else { return nil }
            let linkType: PDFLinkType
            switch link.linkType {
            case "ArXiv": linkType = .preprint
            case "AdsScan": linkType = .adsScan
            default: linkType = .publisher
            }
            return PDFLink(url: url, type: linkType, sourceID: sourceID)
        }

        // Fallback: if scix-client returned no links, build from arXiv/DOI
        if links.isEmpty {
            if let arxiv = arxivId, !arxiv.isEmpty,
               let url = URL(string: "https://arxiv.org/pdf/\(arxiv).pdf") {
                links.append(PDFLink(url: url, type: .preprint, sourceID: sourceID))
            }
            if let doi = doi, !doi.isEmpty,
               let url = URL(string: "https://doi.org/\(doi)") {
                links.append(PDFLink(url: url, type: .publisher, sourceID: sourceID))
            }
        }

        return links
    }
}

// MARK: - ScixFfiError → SourceError / EnrichmentError

extension ScixFfiError {

    /// Convert to a SourceError for SourcePlugin conformers.
    func toSourceError(sourceID: String) -> SourceError {
        switch self {
        case .Unauthorized:
            return .authenticationRequired(sourceID)
        case .RateLimited:
            return .rateLimited(retryAfter: nil)
        case .NotFound:
            return .notFound("Not found in \(sourceID)")
        case .NetworkError:
            return .networkError(URLError(.badServerResponse))
        case .ApiError(let message):
            return .parseError(message)
        case .Internal(let message):
            return .parseError("Internal error: \(message)")
        }
    }

    /// Convert to an EnrichmentError for EnrichmentPlugin conformers.
    func toEnrichmentError(sourceID: String) -> EnrichmentError {
        switch self {
        case .Unauthorized:
            return .authenticationRequired(sourceID)
        case .RateLimited:
            return .rateLimited(retryAfter: nil)
        case .NotFound:
            return .notFound
        case .NetworkError(let message):
            return .networkError(message)
        case .ApiError(let message):
            return .parseError(message)
        case .Internal(let message):
            return .parseError("Internal error: \(message)")
        }
    }
}
