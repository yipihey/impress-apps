//
//  CitationPickerCoordinator.swift
//  imprint
//
//  State lift for the "pick an external candidate" flow — previously
//  scattered as `@State` across `CitedPapersSection`, which caused macOS
//  sheet flicker because the sheet was attached to a Section inside a
//  List whose body re-evaluated on every citation mutation.
//
//  This coordinator owns:
//    • which candidate picker is open (if any)
//    • which cite keys are currently being imported
//    • the result for each attempted import
//    • the cached list of import destinations (libraries / collections)
//
//  `ContentView.mainContent` attaches a single `.sheet(item: $coord.candidateSheet)`
//  at the top level — matching the existing pattern for the insertion
//  palette, version history, etc. The Section becomes a dumb view over
//  coordinator state, so Section body re-evals no longer touch the sheet.
//

import Foundation
import ImpressKit
import ImpressLogging
import OSLog

/// Outcome of an import attempt for display in the UI row.
public enum CitationImportResult: Sendable, Equatable {
    case success
    case failed(String)
}

/// Payload used by the `.sheet(item:)` modifier in ContentView to present
/// the external-candidate picker.
public struct CitationCandidateSheet: Identifiable, Sendable {
    public let id: String  // paper citeKey — also the sheet's Identifiable id
    public let paper: CitationResult
    public let destination: ImbibIntegrationService.ImportDestination?
    public let candidates: [ImbibExternalCandidate]

    public init(
        id: String,
        paper: CitationResult,
        destination: ImbibIntegrationService.ImportDestination?,
        candidates: [ImbibExternalCandidate]
    ) {
        self.id = id
        self.paper = paper
        self.destination = destination
        self.candidates = candidates
    }
}

/// Single source of truth for citation import UX state. Held as a top-level
/// `@State` / `@Environment` on `ContentView`, observed by `CitedPapersSection`
/// and the `ExternalCandidatePicker` sheet.
@MainActor
@Observable
public final class CitationPickerCoordinator {

    /// When non-nil, ContentView presents the external-candidate picker.
    public var candidateSheet: CitationCandidateSheet?

    /// Cite keys for which an import is currently in flight. Used by rows
    /// to show a spinner.
    public var importingKeys: Set<String> = []

    /// Outcome of the most recent import attempt per cite key. Used by rows
    /// to show a checkmark or an error.
    public var importResults: [String: CitationImportResult] = [:]

    /// Cached libraries + non-smart collections to use as import targets.
    public var destinations: [ImbibIntegrationService.ImportDestination] = []
    public var destinationError: String?
    public var isLoadingDestinations = false

    private let imbibService: ImbibIntegrationService
    private let client: CitationClient
    private let bibliographyGenerator: BibliographyGenerator

    public init(
        imbibService: ImbibIntegrationService = .shared,
        client: CitationClient = .shared,
        bibliographyGenerator: BibliographyGenerator = .shared
    ) {
        self.imbibService = imbibService
        self.client = client
        self.bibliographyGenerator = bibliographyGenerator
    }

    // MARK: - Destination loading

    public func loadDestinations() async {
        guard !isLoadingDestinations else { return }
        isLoadingDestinations = true
        destinationError = nil
        defer { isLoadingDestinations = false }

        do {
            destinations = try await imbibService.listDestinations()
            destinationError = nil
        } catch let error as ImbibIntegrationError {
            if case .automationDisabled = error {
                destinationError = "Enable HTTP server in imbib Settings > General > Automation"
            } else {
                destinationError = error.localizedDescription
            }
            logInfo("Failed to load imbib destinations: \(error.localizedDescription)", category: "imbib")
        } catch {
            destinationError = error.localizedDescription
            logInfo("Failed to load imbib destinations: \(error.localizedDescription)", category: "imbib")
        }
    }

    // MARK: - Resolve

    /// Ask imbib to resolve a cited paper. On `.found`, records success and
    /// triggers a bibliography refresh. On `.candidates`, populates
    /// `candidateSheet` for the picker. On `.notFound`, records failure.
    ///
    /// `document` / `bibliography` may be empty — the resolve cascade on
    /// the server side gracefully falls back to bibitem metadata.
    public func requestResolve(
        paper: CitationResult,
        destination: ImbibIntegrationService.ImportDestination?,
        newLibraryName: String? = nil,
        bibliography: [String: String] = [:]
    ) async {
        importingKeys.insert(paper.citeKey)
        defer { importingKeys.remove(paper.citeKey) }

        // Build the structured citation input from bibitem metadata when
        // we have it; otherwise, fall back to just citeKey + year.
        var input: ImbibCitationInput
        if let info = bibliographyGenerator.bibitemMetadata[paper.citeKey] {
            input = info.toCitationInput(citeKey: paper.citeKey)
        } else {
            input = ImbibCitationInput(
                authors: [],
                year: paper.year > 0 ? paper.year : nil,
                freeText: paper.citeKey,
                preferredDatabase: "astronomy"
            )
        }
        // Belt-and-braces guard against a 400 from the server: every
        // resolve call must carry *some* non-empty field. If bibitem
        // parsing produced literally nothing, at least hand over the
        // cite key as freeText so the server can try a text search.
        if (input.freeText ?? "").isEmpty
            && input.authors.isEmpty
            && !input.hasIdentifier
            && (input.rawBibtex ?? "").isEmpty
            && (input.title ?? "").isEmpty {
            input.freeText = paper.citeKey
        }
        // Prefer document-cached BibTeX over bibitem-derived one for
        // identifier extraction (it's richer: explicit DOI/eprint fields).
        if let cached = bibliography[paper.citeKey], !cached.isEmpty {
            input.rawBibtex = cached
        } else if paper.bibtex.isEmpty == false {
            input.rawBibtex = paper.bibtex
        }

        var targetLibraryID: UUID?
        if let newLibraryName, !newLibraryName.isEmpty {
            do {
                let id = try await imbibService.createLibrary(name: newLibraryName)
                targetLibraryID = UUID(uuidString: id)
            } catch {
                importResults[paper.citeKey] = .failed("Failed to create library: \(error.localizedDescription)")
                return
            }
        } else if let destination, destination.type == .library {
            targetLibraryID = UUID(uuidString: destination.id)
        }

        let resolution = await client.resolve(
            citeKey: paper.citeKey,
            input: input,
            libraryID: targetLibraryID
        )

        switch resolution {
        case .found:
            importResults[paper.citeKey] = .success
            if newLibraryName != nil {
                destinations = (try? await imbibService.listDestinations()) ?? destinations
            }
            NotificationCenter.default.post(name: .citedPapersShouldRefresh, object: nil)

        case .candidates(let list):
            candidateSheet = CitationCandidateSheet(
                id: paper.citeKey,
                paper: paper,
                destination: destination,
                candidates: list
            )

        case .notFound(let reason):
            importResults[paper.citeKey] = .failed(reason)
        }
    }

    // MARK: - Pick a candidate

    /// Import a specific candidate the user picked from the sheet.
    /// Called after `candidateSheet` has already been cleared — the
    /// sheet's dismiss animation runs uninterrupted.
    public func importPicked(
        _ candidate: ImbibExternalCandidate,
        for paper: CitationResult,
        destination: ImbibIntegrationService.ImportDestination?
    ) async {
        guard !candidate.identifier.isEmpty else {
            importResults[paper.citeKey] = .failed("Picked result has no DOI or arXiv id")
            return
        }
        importingKeys.insert(paper.citeKey)
        defer { importingKeys.remove(paper.citeKey) }

        do {
            let libraryID = destination?.type == .library ? destination?.id : nil
            let collectionID = destination?.type == .collection ? destination?.id : nil
            let result = try await imbibService.importPapers(
                citeKeys: [candidate.identifier],
                libraryID: libraryID,
                collectionID: collectionID
            )
            // Three shapes of success:
            //   added > 0      — new paper inserted into the library
            //   duplicates > 0 — paper was already in imbib (still a win)
            //   added == 0 && duplicates == 0 — real failure
            if result.added > 0 || result.duplicates > 0 {
                importResults[paper.citeKey] = .success
                let reason = result.added > 0
                    ? "added to library"
                    : "already in library (\(result.duplicates) duplicate)"
                logInfo(
                    "importPicked '\(paper.citeKey)' ⇒ .success (\(reason))",
                    category: "citations"
                )
                NotificationCenter.default.post(name: .citedPapersShouldRefresh, object: nil)
            } else {
                let msg = "imbib couldn't add the paper (failed=\(result.failed))"
                importResults[paper.citeKey] = .failed(msg)
                logInfo(
                    "importPicked '\(paper.citeKey)' ⇒ .failed (\(msg))",
                    category: "citations"
                )
            }
        } catch {
            importResults[paper.citeKey] = .failed(error.localizedDescription)
        }
    }

    public func dismissPicker() {
        candidateSheet = nil
    }
}

public extension Notification.Name {
    /// Posted when the cited-papers sidebar should re-fetch metadata
    /// (e.g. after a successful import). Observed by `CitedPapersSection`.
    static let citedPapersShouldRefresh = Notification.Name("imprint.citedPapersShouldRefresh")
}
