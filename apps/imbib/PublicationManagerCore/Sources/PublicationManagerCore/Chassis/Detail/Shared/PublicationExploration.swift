//
//  PublicationExploration.swift
//  PublicationManagerCore
//
//  Stage 5b (SPLIT rule) — the Info tab's Explore row, as DATA + one runner.
//
//  Both Info tabs offer the same ADS/SciX explorations (references, citations,
//  similar, co-reads, and — iOS only until now — Web-of-Science related) and
//  both drove them the same way: set a per-button `isExploring` flag, resolve
//  the enrichment service, hand the library manager to `ExplorationService`,
//  await one `explore*` call, clear the flag, surface `error.localizedDescription`.
//
//  macOS wrote that block out FOUR times (once per button, ~20 lines each);
//  iOS had already factored its five into one `explore(_:_:)` helper — which
//  is the shape this file generalises. What stays per-platform is the button
//  ROW (macOS: a fixed `HStack` of four `.bordered` buttons with hover help;
//  iOS: a horizontal `ScrollView` of five), because a pointer surface with
//  tooltips and a scrollable thumb surface are genuinely different chrome.
//
//  The availability vocabulary (`notEnriched` / `hasResults` / `noResults` /
//  `unavailable`) was macOS-only and drove its labels, disabled state and help
//  text; it is here so iOS reads the same rules instead of `count > 0`.
//

import Foundation

// MARK: - Exploration kind

/// One exploration a publication can offer. `allCases` IS the display order.
public enum PublicationExplorationKind: String, CaseIterable, Identifiable, Sendable {
    case references
    case citations
    case similar
    case coReads
    case wosRelated

    public var id: String { rawValue }

    /// Button label without a count, frozen from both shipped surfaces.
    public var baseLabel: String {
        switch self {
        case .references: return "References"
        case .citations: return "Citations"
        case .similar: return "Similar"
        case .coReads: return "Co-Reads"
        case .wosRelated: return "WoS Related"
        }
    }

    public var systemImage: String {
        switch self {
        case .references: return "doc.text"
        case .citations: return "quote.bubble"
        case .similar: return "sparkles"
        case .coReads: return "books.vertical"
        case .wosRelated: return "globe.americas"
        }
    }

    /// Whether the count of already-enriched results participates in this
    /// kind's label and availability. Similar / co-reads / WoS are computed
    /// remotely on demand and have no stored count.
    public var isCounted: Bool {
        self == .references || self == .citations
    }

    /// WoS co-citation lookup keys on a DOI; the others accept any identifier.
    public var requiresDOI: Bool { self == .wosRelated }

    /// macOS hover help for the uncounted kinds (frozen strings).
    fileprivate var staticHelpText: String? {
        switch self {
        case .similar: return "Show papers with similar content"
        case .coReads: return "Show papers frequently read together"
        case .wosRelated: return "Show papers related by Web of Science co-citation"
        default: return nil
        }
    }
}

// MARK: - Availability

/// Whether an exploration can produce anything, and whether it already has.
public enum PublicationExplorationAvailability: Equatable, Sendable {
    /// Identifiers exist but the paper has not been enriched yet.
    case notEnriched
    /// Enrichment found this many results.
    case hasResults(Int)
    /// Enrichment ran and found none.
    case noResults
    /// No identifiers to look anything up with.
    case unavailable
}

// MARK: - Model

/// The Explore row's data for one paper: which explorations are offered, what
/// each button says, and whether it can be pressed.
public struct PublicationExplorationModel: Equatable, Sendable {

    private let hasDOI: Bool
    private let hasArxivID: Bool
    private let hasBibcode: Bool
    private let isLoaded: Bool
    private let referenceCount: Int
    private let citationCount: Int

    public init(
        doi: String?, arxivID: String?, bibcode: String?,
        referenceCount: Int, citationCount: Int, isLoaded: Bool = true
    ) {
        self.hasDOI = doi?.isEmpty == false
        self.hasArxivID = arxivID?.isEmpty == false
        self.hasBibcode = bibcode?.isEmpty == false
        self.referenceCount = referenceCount
        self.citationCount = citationCount
        self.isLoaded = isLoaded
    }

    /// From a loaded store row. A `nil` publication means "not loaded yet",
    /// which resolves every availability to `.unavailable` — the state macOS's
    /// `guard let pub = publication else { return .unavailable }` expressed.
    public init(publication: PublicationModel?) {
        if let publication {
            self.init(
                doi: publication.doi, arxivID: publication.arxivID,
                bibcode: publication.bibcode,
                referenceCount: publication.referenceCount,
                citationCount: publication.citationCount)
        } else {
            self.init(
                doi: nil, arxivID: nil, bibcode: nil,
                referenceCount: 0, citationCount: 0, isLoaded: false)
        }
    }

    /// Whether the Explore section renders at all.
    ///
    /// macOS computed this from the PAPER (which exists for an online search
    /// result too) while the per-button availability came from the loaded
    /// publication; that split is preserved by building the model from the
    /// publication and asking `canExplore(withIdentifiersFrom:)` when a paper
    /// is the only thing in hand.
    public var canExplore: Bool { hasBibcode || hasDOI || hasArxivID }

    /// The paper-level gate macOS's `canExploreReferences` applied.
    public static func canExplore(paper: any PaperRepresentable) -> Bool {
        paper.bibcode != nil || paper.doi != nil || paper.arxivID != nil
    }

    /// Kinds offered for this paper, in declaration order. WoS is dropped
    /// without a DOI (iOS's `if pub.doi != nil` rule, now declared).
    public var offeredKinds: [PublicationExplorationKind] {
        PublicationExplorationKind.allCases.filter { !$0.requiresDOI || hasDOI }
    }

    public func availability(of kind: PublicationExplorationKind) -> PublicationExplorationAvailability {
        guard isLoaded else { return .unavailable }
        guard kind.isCounted else {
            return canExplore ? .notEnriched : .unavailable
        }
        let count = kind == .references ? referenceCount : citationCount
        if count > 0 { return .hasResults(count) }
        return canExplore ? .notEnriched : .unavailable
    }

    /// Button label including the count when one is known.
    public func label(for kind: PublicationExplorationKind) -> String {
        switch availability(of: kind) {
        case .hasResults(let count): return "\(kind.baseLabel) (\(count))"
        case .noResults: return "\(kind.baseLabel) (0)"
        default: return kind.baseLabel
        }
    }

    /// Hover-help text. Frozen from macOS's `referencesHelpText` /
    /// `citationsHelpText` and its two static strings.
    public func helpText(for kind: PublicationExplorationKind) -> String {
        if let staticHelp = kind.staticHelpText { return staticHelp }
        let noun = kind == .references ? "papers this paper cites" : "papers that cite this paper"
        switch availability(of: kind) {
        case .notEnriched:
            return "Click to find \(noun)"
        case .hasResults(let count):
            return kind == .references
                ? "Show \(count) referenced papers"
                : "Show \(count) citing papers"
        case .noResults:
            return "No \(kind.baseLabel.lowercased()) available for this paper"
        case .unavailable:
            return "No identifiers available for lookup"
        }
    }

    /// A kind whose availability is `.noResults` cannot be pressed — the rule
    /// macOS spelled as `refAvail == .noResults || isExploring` per button.
    public func isEnabled(_ kind: PublicationExplorationKind) -> Bool {
        availability(of: kind) != .noResults
    }
}

// MARK: - Runner

/// Runs one exploration at a time and reports which is in flight.
///
/// One `running` value replaces the four (macOS) / five (iOS) parallel
/// `isExploringX` booleans: every button was already disabled while any
/// exploration ran, so the booleans could never legitimately disagree.
@MainActor
@Observable
public final class PublicationExplorationRunner {

    /// The exploration currently in flight, if any.
    public private(set) var running: PublicationExplorationKind?

    /// Last failure, for the host's alert. Cleared when a new run starts.
    public var errorMessage: String?

    public init() {}

    public var isExploring: Bool { running != nil }

    public func isRunning(_ kind: PublicationExplorationKind) -> Bool {
        running == kind
    }

    /// Reset between papers — the ephemeral state both shells cleared by hand
    /// in `onChange(of: publicationID)`.
    public func reset() {
        running = nil
        errorMessage = nil
    }

    /// Run `kind` for `publicationID`.
    ///
    /// `ExplorationService` creates the exploration collection and posts
    /// `.navigateToCollection`; both shells' sidebars already consume it, so
    /// this method deliberately returns nothing but the failure state.
    public func run(
        _ kind: PublicationExplorationKind,
        for publicationID: UUID,
        libraryManager: LibraryManager
    ) async {
        running = kind
        errorMessage = nil
        do {
            let enrichmentService = await EnrichmentCoordinator.shared.enrichmentService
            ExplorationService.shared.setEnrichmentService(enrichmentService)
            ExplorationService.shared.setLibraryManager(libraryManager)
            switch kind {
            case .references:
                _ = try await ExplorationService.shared.exploreReferences(of: publicationID)
            case .citations:
                _ = try await ExplorationService.shared.exploreCitations(of: publicationID)
            case .similar:
                _ = try await ExplorationService.shared.exploreSimilar(of: publicationID)
            case .coReads:
                _ = try await ExplorationService.shared.exploreCoReads(of: publicationID)
            case .wosRelated:
                _ = try await ExplorationService.shared.exploreWoSRelated(of: publicationID)
            }
            running = nil
        } catch {
            running = nil
            errorMessage = error.localizedDescription
        }
    }
}
