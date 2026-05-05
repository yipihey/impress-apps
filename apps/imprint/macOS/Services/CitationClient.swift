//
//  CitationClient.swift
//  imprint
//
//  Thin adapter that delegates citation resolution to imbib's structured
//  `/api/papers/resolve` endpoint via `ImbibBridge.resolveCitation`.
//
//  Replaces the old `CitationResolver` + ~400 lines of ad-hoc LaTeX /
//  query-syntax / identifier-extraction code that used to live in imprint.
//  All sanitation, ADS query construction, ranking, and multi-source
//  fallback now happens server-side using imbib's battle-tested plugins.
//

import Foundation
import ImbibRustCore
import ImpressKit
import ImpressLogging
import OSLog

/// Outcome of a citation resolution attempt. Mirrors the old
/// `CitationResolution` shape so callers don't need to change.
public enum CitationResolution: Sendable {
    /// Paper was found or auto-imported — already in imbib's library now.
    case found(CitationResult)

    /// Not auto-resolved — external sources returned ranked candidates.
    /// The user picks one to import.
    case candidates([ImbibExternalCandidate])

    /// Resolution failed with a human-readable reason.
    case notFound(reason: String)
}

/// Client for imbib's structured-citation resolution service.
///
/// Usage:
///
///     let input = BibliographyGenerator.BibitemInfo(...)
///         .toCitationInput(citeKey: "BBKS1986")
///     let outcome = await CitationClient.shared.resolve(
///         citeKey: "BBKS1986",
///         input: input,
///         libraryID: nil
///     )
///
/// Re-entrancy / rate limiting is handled upstream (SwiftUI `Task` in the
/// picker coordinator). This class is stateless.
@MainActor
public final class CitationClient {

    public static let shared = CitationClient()

    public init() {}

    // MARK: - Public API

    /// Resolve a citation. `input` is a structured `ImbibCitationInput`
    /// built from the manuscript's `\bibitem` metadata; `citeKey` is
    /// carried through for logging and for building `CitationResult`s
    /// when the server returns an `ImbibPaper`.
    public func resolve(
        citeKey: String,
        input: ImbibCitationInput,
        libraryID: UUID? = nil
    ) async -> CitationResolution {
        let start = Date()
        Logger.compilation.infoCapture(
            "CitationClient.resolve '\(citeKey)': authors=\(input.authors.count) year=\(input.year.map(String.init) ?? "?") hasID=\(input.doi != nil || input.arxiv != nil || input.bibcode != nil)",
            category: "citations"
        )
        let outcome: CitationResolution
        let viaTag: String
        do {
            let response = try await ImbibBridge.resolveCitation(input, library: libraryID)
            viaTag = response.via
            outcome = Self.map(response, citeKey: citeKey)
        } catch SiblingBridgeError.httpError(statusCode: 400) {
            // Server rejected the input — almost always because the bibitem
            // parsed empty (no authors, no year, no reference line). Treat
            // as "not found" with a diagnostic reason rather than
            // bubbling an opaque HTTP error to the user.
            viaTag = "empty-input"
            Logger.compilation.warningCapture(
                "CitationClient.resolve '\(citeKey)': imbib rejected as empty/malformed — bibitem metadata was probably not parseable. Try re-typing the \\bibitem line or adding a DOI.",
                category: "citations"
            )
            outcome = .notFound(reason: "Not enough metadata parsed from the \\bibitem for '\(citeKey)' — add a DOI/arXiv id or re-check the entry")
        } catch {
            viaTag = "error"
            Logger.compilation.warningCapture(
                "CitationClient.resolve '\(citeKey)' failed: \(error.localizedDescription)",
                category: "citations"
            )
            outcome = .notFound(reason: "imbib resolve failed: \(error.localizedDescription)")
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Logger.compilation.infoCapture(
            "CitationClient.resolve '\(citeKey)' ⇒ via=\(viaTag) \(Self.describe(outcome)) in \(ms)ms",
            category: "citations"
        )
        return outcome
    }

    // MARK: - Response mapping

    /// Convert an `ImbibResolveResponse` into the `CitationResolution` shape
    /// the picker already consumes.
    private static func map(
        _ response: ImbibResolveResponse,
        citeKey: String
    ) -> CitationResolution {
        if let paper = response.paper {
            return .found(toCitationResult(paper, fallbackCiteKey: citeKey))
        }
        if let ranked = response.candidates, !ranked.isEmpty {
            // Preserve the server's ranking (descending by confidence) when
            // mapping to the picker's unranked `ImbibExternalCandidate` type.
            let candidates = ranked
                .sorted { $0.confidence > $1.confidence }
                .map { $0.asExternalCandidate }
            return .candidates(candidates)
        }
        let reason = response.reason ?? "No candidates from any source"
        return .notFound(reason: reason)
    }

    /// Build the display-ready `CitationResult` from imbib's `ImbibPaper`.
    /// Uses the manuscript's cite key when the imbib paper's citeKey differs,
    /// so existing cached references in the `.tex` source still light up.
    private static func toCitationResult(
        _ paper: ImbibPaper,
        fallbackCiteKey: String
    ) -> CitationResult {
        let year = paper.year ?? 0
        return CitationResult(
            id: UUID(uuidString: paper.id) ?? UUID(),
            citeKey: paper.citeKey.isEmpty ? fallbackCiteKey : paper.citeKey,
            title: paper.title,
            authors: paper.authors,
            year: year,
            venue: paper.venue ?? "",
            formattedPreview: Self.formattedPreview(authors: paper.authors, year: year),
            bibtex: paper.bibtex ?? "",
            hasPDF: paper.hasPDF ?? false
        )
    }

    private static func formattedPreview(authors: String, year: Int) -> String {
        let firstAuthor = authors
            .components(separatedBy: ",").first?
            .components(separatedBy: " and ").first?
            .trimmingCharacters(in: .whitespaces) ?? authors
        let authorPart = authors.contains(" and ") || authors.contains(",") ? "\(firstAuthor) et al." : firstAuthor
        if year > 0 { return "\(authorPart) (\(year))" }
        return authorPart
    }

    private static func describe(_ r: CitationResolution) -> String {
        switch r {
        case .found(let c): return ".found(\(c.citeKey))"
        case .candidates(let cs): return ".candidates(\(cs.count))"
        case .notFound(let reason): return ".notFound(\(reason))"
        }
    }
}
