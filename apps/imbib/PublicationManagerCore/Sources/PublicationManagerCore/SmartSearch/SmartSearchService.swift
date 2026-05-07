//
//  SmartSearchService.swift
//  PublicationManagerCore
//
//  Orchestrates the new Cmd+S "Smart Search" feature. Replaces NLSearchService.
//
//  Flow per submission:
//   1. IntentClassifier categorises the input (deterministic, no LLM).
//   2. Dispatch by intent:
//      - .identifier  → AutomationService.resolveStructuredCitation
//      - .fielded     → SourceManager.search(sourceID: "ads") passthrough
//      - .reference   → ReferenceParser → resolveStructuredCitation per block
//      - .freeText    → FreeTextQueryRewriter → SourceManager.search
//   3. Render candidates inline. NO auto-import.
//   4. User picks 1+ → AutomationService.addPapers(identifiers:)
//
//  Esc-cancellation flows through structured Task.cancellation. The service
//  preserves the last input + last results across overlay open/close so the
//  user can refine without retyping.
//

import Foundation
import ImpressSmartSearch
import OSLog

// MARK: - Public types

/// Top-level state of the Smart Search overlay.
public enum SmartSearchState: Sendable, Equatable {
    /// Empty input — show example chips.
    case idle
    /// Input present, deterministic classifier has run.
    case classified(intent: SmartSearchIntentSnapshot)
    /// LLM is parsing a single reference block.
    case parsing
    /// LLM is rewriting free-text into an ADS query.
    case rewriting
    /// Doing the actual external search / cascade.
    case resolving(detail: String)
    /// Single-block result: list of candidates.
    case candidates([SmartSearchCandidate])
    /// Multi-block bibliography paste: per-block status.
    case batch([SmartSearchBlock])
    /// Search complete with no relevant results.
    case empty(reason: String)
    /// Unrecoverable error.
    case error(String)
    /// Adding the user-checked candidates to the library.
    case adding(count: Int)
    /// Adds completed; toast and dismiss the overlay.
    case added(count: Int)
}

/// Lightweight Equatable mirror of `SearchIntent` — we don't put the heavy
/// `PaperIdentifier` enum into the state because the UI only needs labels.
public struct SmartSearchIntentSnapshot: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case identifier, fielded, reference, freeText, url
    }
    public let kind: Kind
    public let label: String
    public let blockCount: Int
}

/// One candidate to display in the inline list. Stable id allows SwiftUI to
/// animate selection without churn.
public struct SmartSearchCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String?
    /// Best identifier for `addPapers` (DOI > arXiv > bibcode).
    public let identifier: PaperIdentifier?
    /// Source label for the source-badge ("ADS", "arXiv", "OpenAlex"…).
    public let sourceLabel: String
    /// 0…1 confidence, when known (resolveStructured cascade only).
    public let confidence: Double?
    /// Non-nil when this paper is already in the user's library.
    public let alreadyInLibrary: PaperResult?
}

/// One block of a multi-block reference paste.
public struct SmartSearchBlock: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let raw: String
    public var status: Status

    public enum Status: Sendable, Equatable {
        case pending
        case parsing
        case resolving
        /// Single high-confidence match — auto-checked for Add.
        case resolved(SmartSearchCandidate)
        /// Multiple candidates — user picks one.
        case candidates([SmartSearchCandidate])
        case notFound(reason: String)
        case error(message: String)
    }

    public init(id: UUID = UUID(), raw: String, status: Status = .pending) {
        self.id = id
        self.raw = raw
        self.status = status
    }
}

// MARK: - SmartSearchService

/// @Observable, @MainActor service that orchestrates the Smart Search overlay.
@MainActor
@Observable
public final class SmartSearchService {

    // MARK: Stored state

    public private(set) var state: SmartSearchState = .idle
    public private(set) var lastInput: String = ""

    /// Selected candidate ids (single-block path). Mutable so the view can
    /// bind a checkbox.
    public var selectedCandidateIDs: Set<String> = []

    /// Selected candidate ids per block (multi-block path).
    public var selectedBatchCandidates: [UUID: String] = [:]

    /// Highlighted row for arrow-key navigation. nil when nothing focused.
    public var highlightedCandidateID: String?

    // MARK: Configuration

    /// Primary source for `.freeText` and `.fielded`. ADS speaks our query
    /// dialect; arXiv and OpenAlex are queried separately (with the original
    /// raw input, not the ADS rewrite) only as a fallback when ADS comes back
    /// empty.
    public var primarySourceID: String = "ads"

    /// Fallback sources used when ADS returns 0. Queried with the user's
    /// original free-text input (not the ADS-syntax rewrite), since arXiv and
    /// OpenAlex don't parse ADS Lucene.
    public var fallbackSourceIDs: [String] = ["arxiv", "openalex"]

    /// Hard cap per source. Total candidates are clipped after merging.
    public var maxResultsPerSource: Int = 30

    /// Explicit override for the import target library. Normally nil — leave
    /// it that way and the service resolves to `LibraryManager.getOrCreateSaveLibrary()`
    /// (the same destination as the inbox "Save" triage shortcut).
    public var addTargetLibraryID: UUID? = nil

    /// Optional LibraryManager — when set, papers added via Smart Search go
    /// to the user's "Save" library (matching the inbox-triage `s` shortcut).
    /// When nil, falls back to AutomationService's default-library cascade.
    public weak var libraryManager: LibraryManager?

    /// Hard cap on multi-block bibliography paste in v1.
    public static let maxReferenceBlocks: Int = 25

    // MARK: Dependencies

    private let automation: AutomationService
    private let sourceManager: SourceManager
    private let engine: SmartSearchEngine

    /// In-flight task for cancellation.
    private var currentTask: Task<Void, Never>?

    /// Whether `sourceManager.registerBuiltInSources()` has been called.
    /// Done lazily on first submit since init can't be async.
    private var sourceManagerReady = false

    // MARK: Init

    public init(
        automation: AutomationService = .shared,
        sourceManager: SourceManager = SourceManager(),
        libraryManager: LibraryManager? = nil,
        cloudRunner: ImpressSmartSearch.ReferenceParser.CloudRunner? = nil
    ) {
        self.automation = automation
        self.sourceManager = sourceManager
        self.libraryManager = libraryManager
        self.engine = SmartSearchEngine(cloudRunner: cloudRunner)
    }

    /// Resolved library ID where Add lands. Order: explicit override →
    /// LibraryManager.getOrCreateSaveLibrary (matches inbox triage "s" key)
    /// → nil (AutomationService falls back to default library).
    private func resolvedAddTargetLibraryID() -> UUID? {
        if let id = addTargetLibraryID { return id }
        return libraryManager?.getOrCreateSaveLibrary().id
    }

    // MARK: - Lifecycle

    /// Reset to idle and clear inputs.
    public func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        lastInput = ""
        selectedCandidateIDs.removeAll()
        selectedBatchCandidates.removeAll()
        highlightedCandidateID = nil
    }

    /// Cancel any running task without wiping state — used on Esc.
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Live classification (no LLM, every keystroke)

    /// Re-classify the input. Cheap; safe to call on every keystroke.
    /// Does NOT trigger any external work — call `submit()` for that.
    public func updateInput(_ raw: String) {
        lastInput = raw
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if !isSubmitting { state = .idle }
            return
        }
        let intent = ImpressSmartSearch.IntentClassifier.classify(raw)
        let snapshot = Self.snapshot(of: intent)
        if !isSubmitting {
            state = .classified(intent: snapshot)
        }
    }

    private var isSubmitting: Bool {
        switch state {
        case .parsing, .rewriting, .resolving, .adding:
            return true
        default:
            return false
        }
    }

    private static func snapshot(of intent: ImpressSmartSearch.SearchIntent) -> SmartSearchIntentSnapshot {
        switch intent {
        case .identifier:
            return SmartSearchIntentSnapshot(kind: .identifier, label: intent.label, blockCount: 1)
        case .fielded:
            return SmartSearchIntentSnapshot(kind: .fielded, label: intent.label, blockCount: 1)
        case .reference(let blocks):
            return SmartSearchIntentSnapshot(kind: .reference, label: intent.label, blockCount: blocks.count)
        case .freeText:
            return SmartSearchIntentSnapshot(kind: .freeText, label: intent.label, blockCount: 1)
        case .url:
            return SmartSearchIntentSnapshot(kind: .url, label: intent.label, blockCount: 1)
        }
    }

    // MARK: - Submit

    /// Run the search. Cancels any in-flight task.
    public func submit() {
        currentTask?.cancel()
        let raw = lastInput
        let intent = ImpressSmartSearch.IntentClassifier.classify(raw)
        switch intent {
        case .identifier(let lite):
            let id = Self.adapt(lite)
            currentTask = Task { [weak self] in
                await self?.prepareSources()
                await self?.runIdentifier(id, freeText: raw)
            }
        case .fielded(let q):
            currentTask = Task { [weak self] in
                await self?.prepareSources()
                await self?.runFielded(query: q)
            }
        case .reference(let blocks):
            currentTask = Task { [weak self] in
                await self?.prepareSources()
                await self?.runReference(blocks: blocks)
            }
        case .freeText(let q):
            currentTask = Task { [weak self] in
                await self?.prepareSources()
                await self?.runFreeText(query: q)
            }
        case .url(let url):
            currentTask = Task { [weak self] in
                await self?.prepareSources()
                await self?.runURL(url)
            }
        }
    }

    /// Adapt the library's `PaperIdentifierLite` (4 cases) to imbib's full
    /// `PaperIdentifier` enum (8 cases). Library only emits doi/arxiv/bibcode/pmid.
    private static func adapt(_ lite: ImpressSmartSearch.PaperIdentifierLite) -> PaperIdentifier {
        switch lite {
        case .doi(let v): return .doi(v)
        case .arxiv(let v): return .arxiv(v)
        case .bibcode(let v): return .bibcode(v)
        case .pmid(let v): return .pmid(v)
        }
    }

    /// Adapt the library's `CitationInputLite` to imbib's `CitationInput`.
    private static func adapt(_ lite: ImpressSmartSearch.CitationInputLite, rawBibtex: String? = nil) -> CitationInput {
        CitationInput(
            authors: lite.authors,
            title: lite.title,
            year: lite.year,
            journal: lite.journal,
            volume: lite.volume,
            pages: lite.pages,
            doi: lite.doi,
            arxiv: lite.arxiv,
            bibcode: lite.bibcode,
            rawBibtex: rawBibtex,
            freeText: lite.freeText,
            preferredDatabase: nil
        )
    }

    /// Idempotent registration of built-in source plugins. Logs once.
    private func prepareSources() async {
        guard !sourceManagerReady else { return }
        await sourceManager.registerBuiltInSources()
        sourceManagerReady = true
        let available = await sourceManager.availableSources.map { $0.id }
        Logger.smartSearch.infoCapture(
            "smartsearch: registered sources [\(available.joined(separator: ", "))]",
            category: "smartsearch"
        )
    }

    // MARK: - Path: identifier

    private func runIdentifier(_ id: PaperIdentifier, freeText: String) async {
        state = .resolving(detail: "Looking up \(id.typeName)…")
        Logger.smartSearch.infoCapture(
            "smartsearch: identifier path \(id.typeName)=\(id.value)",
            category: "smartsearch"
        )
        let input = CitationInput(
            authors: [],
            doi: id.kindIs(.doi) ? id.value : nil,
            arxiv: id.kindIs(.arxiv) ? id.value : nil,
            bibcode: id.kindIs(.bibcode) ? id.value : nil,
            freeText: freeText
        )
        await runResolveAndRender(input, fallbackQuery: freeText)
    }

    // MARK: - Path: fielded

    private func runFielded(query: String) async {
        state = .resolving(detail: "Searching \(Self.sourceLabelFor(primarySourceID))…")
        Logger.smartSearch.infoCapture("smartsearch: fielded query '\(query)'", category: "smartsearch")
        do {
            let results = try await sourceManager.search(
                query: query,
                sourceID: primarySourceID,
                maxResults: maxResultsPerSource
            )
            await renderSearchResults(results, sourceLabel: Self.sourceLabelFor(primarySourceID))
        } catch {
            await handleSearchError(error, query: query)
        }
    }

    // MARK: - Path: free-text

    private func runFreeText(query: String) async {
        state = .rewriting
        let plan = await engine.rewriteFreeText(query)
        Logger.smartSearch.infoCapture(
            "smartsearch: rewrote '\(query)' → '\(plan.query)' source=\(plan.source.rawValue)",
            category: "smartsearch"
        )
        if Task.isCancelled { return }
        guard !plan.query.isEmpty else {
            state = .empty(reason: "Couldn't build an ADS query for that input. Try rephrasing.")
            return
        }

        // Step 1: query ADS with the rewritten Lucene query.
        state = .resolving(detail: "Searching \(Self.sourceLabelFor(primarySourceID))…")
        var primaryResults: [SearchResult] = []
        do {
            primaryResults = try await sourceManager.search(
                query: plan.query,
                sourceID: primarySourceID,
                maxResults: maxResultsPerSource
            )
            Logger.smartSearch.infoCapture(
                "smartsearch: \(primarySourceID) returned \(primaryResults.count) results for '\(plan.query)'",
                category: "smartsearch"
            )
        } catch {
            Logger.smartSearch.warningCapture(
                "smartsearch: \(primarySourceID) failed: \(error.localizedDescription)",
                category: "smartsearch"
            )
        }

        if !primaryResults.isEmpty {
            await renderSearchResults(primaryResults, sourceLabel: nil)
            return
        }

        // Step 2: fall back to arXiv + OpenAlex with the user's RAW input,
        // not the ADS Lucene rewrite (those sources can't parse ADS syntax).
        if Task.isCancelled { return }
        let labels = fallbackSourceIDs.map(Self.sourceLabelFor).joined(separator: " · ")
        state = .resolving(detail: "Trying \(labels)…")
        let options = SearchOptions(
            maxResults: maxResultsPerSource * fallbackSourceIDs.count,
            sourceIDs: fallbackSourceIDs
        )
        do {
            let results = try await sourceManager.search(query: query, options: options)
            await renderSearchResults(results, sourceLabel: nil)
        } catch {
            await handleSearchError(error, query: query)
        }
    }

    // MARK: - Path: URL

    /// Fetch a URL, extract any paper identifiers, render each as a batch
    /// row, and resolve them through the same SciX/ADS cascade used by
    /// reference-paste. Caps the result list at `maxReferenceBlocks`.
    private func runURL(_ url: URL) async {
        state = .resolving(detail: "Fetching \(url.host ?? url.absoluteString)…")
        Logger.smartSearch.infoCapture(
            "smartsearch: URL path \(url.absoluteString)",
            category: "smartsearch"
        )

        let extraction = await engine.extractFromURL(url)
        if Task.isCancelled { return }

        let reasonSuffix = extraction.reason.map { " — \($0)" } ?? ""
        Logger.smartSearch.infoCapture(
            "smartsearch: URL extracted \(extraction.identifiers.count) identifier(s) from \(url.host ?? "page") (final URL: \(extraction.url.absoluteString))\(reasonSuffix)",
            category: "smartsearch"
        )

        guard !extraction.identifiers.isEmpty else {
            let suffix = extraction.reason.map { " — \($0)" } ?? ""
            state = .empty(reason: "No paper identifiers found on this page\(suffix).")
            return
        }

        // Cap and render as batch.
        let cappedIDs = Array(extraction.identifiers.prefix(Self.maxReferenceBlocks))
        let pending = cappedIDs.map { id in
            SmartSearchBlock(raw: "\(id.typeName.uppercased()): \(id.value)", status: .pending)
        }
        state = .batch(pending)

        // Resolve each identifier through the existing cascade.
        for index in pending.indices {
            if Task.isCancelled { return }
            let lite = cappedIDs[index]
            updateBlock(at: index, status: .resolving)

            // Build a minimal CitationInput with only the identifier — the
            // resolveStructuredCitation cascade will hit SciX/ADS for full
            // metadata and import the paper if it's not already local.
            let citation = CitationInput(
                authors: [],
                doi: { if case .doi(let v) = lite { return v } else { return nil } }(),
                arxiv: { if case .arxiv(let v) = lite { return v } else { return nil } }(),
                bibcode: { if case .bibcode(let v) = lite { return v } else { return nil } }(),
                freeText: pending[index].raw
            )

            let resolution = await resolveCitation(citation, fallbackQuery: pending[index].raw)
            switch resolution {
            case .single(let c):
                updateBlock(at: index, status: .resolved(c))
                // Only auto-check if the paper isn't already in the library.
                // Otherwise the row is informational ("In library") and Add
                // would be a no-op.
                if c.alreadyInLibrary == nil {
                    selectedBatchCandidates[pending[index].id] = c.id
                }
            case .candidates(let list) where !list.isEmpty:
                updateBlock(at: index, status: .candidates(list))
            case .candidates:
                updateBlock(at: index, status: .notFound(reason: "No candidates"))
            case .notFound(let reason):
                updateBlock(at: index, status: .notFound(reason: reason))
            case .error(let msg):
                updateBlock(at: index, status: .error(message: msg))
            }
        }

        if extraction.identifiers.count > Self.maxReferenceBlocks {
            Logger.smartSearch.infoCapture(
                "smartsearch: URL had \(extraction.identifiers.count) identifiers, processed first \(Self.maxReferenceBlocks)",
                category: "smartsearch"
            )
        }
    }

    // MARK: - Path: reference (single or multi-block)

    private func runReference(blocks: [String]) async {
        if blocks.count == 1 {
            await runSingleReference(blocks[0])
        } else {
            await runBatchReference(blocks)
        }
    }

    private func runSingleReference(_ block: String) async {
        state = .parsing
        guard let lite = await engine.parseReference(block) else {
            Logger.smartSearch.infoCapture(
                "smartsearch: reference parser unavailable, falling back to freeText",
                category: "smartsearch"
            )
            await runFreeText(query: block)
            return
        }
        if Task.isCancelled { return }
        await runResolveAndRender(Self.adapt(lite), fallbackQuery: block)
    }

    private func runBatchReference(_ blocks: [String]) async {
        let cappedBlocks = Array(blocks.prefix(Self.maxReferenceBlocks))
        let pending = cappedBlocks.map { SmartSearchBlock(raw: $0, status: .pending) }
        state = .batch(pending)
        Logger.smartSearch.infoCapture(
            "smartsearch: batch reference (\(cappedBlocks.count) of \(blocks.count) blocks)",
            category: "smartsearch"
        )

        for index in pending.indices {
            if Task.isCancelled { return }
            updateBlock(at: index, status: .parsing)

            let raw = pending[index].raw
            guard let lite = await engine.parseReference(raw) else {
                updateBlock(at: index, status: .notFound(reason: "Couldn't parse this reference"))
                continue
            }
            if Task.isCancelled { return }
            updateBlock(at: index, status: .resolving)

            let resolution: BlockResolveResult = await resolveCitation(Self.adapt(lite), fallbackQuery: raw)
            switch resolution {
            case .single(let candidate):
                updateBlock(at: index, status: .resolved(candidate))
                if candidate.alreadyInLibrary == nil {
                    selectedBatchCandidates[pending[index].id] = candidate.id
                }
            case .candidates(let list) where !list.isEmpty:
                updateBlock(at: index, status: .candidates(list))
            case .candidates:
                updateBlock(at: index, status: .notFound(reason: "No candidates found"))
            case .notFound(let reason):
                updateBlock(at: index, status: .notFound(reason: reason))
            case .error(let msg):
                updateBlock(at: index, status: .error(message: msg))
            }
        }
    }

    private func updateBlock(at index: Int, status: SmartSearchBlock.Status) {
        guard case .batch(var blocks) = state, blocks.indices.contains(index) else { return }
        blocks[index].status = status
        state = .batch(blocks)
    }

    // MARK: - Resolve cascade

    private enum BlockResolveResult {
        case single(SmartSearchCandidate)
        case candidates([SmartSearchCandidate])
        case notFound(reason: String)
        case error(String)
    }

    /// Single-block resolve + render directly into top-level state.
    private func runResolveAndRender(_ input: CitationInput, fallbackQuery: String) async {
        state = .resolving(detail: "Resolving citation…")
        let result = await resolveCitation(input, fallbackQuery: fallbackQuery)
        if Task.isCancelled { return }
        switch result {
        case .single(let cand):
            state = .candidates([cand])
            highlightedCandidateID = cand.id
            // Don't auto-check rows that are already in the library — Add
            // would be a no-op and the UI would lie about pending action.
            selectedCandidateIDs = cand.alreadyInLibrary == nil ? [cand.id] : []
        case .candidates(let list):
            if list.isEmpty {
                state = .empty(reason: "No matches in ADS or arXiv. Try rephrasing.")
            } else {
                state = .candidates(list)
                highlightedCandidateID = list.first?.id
            }
        case .notFound(let reason):
            state = .empty(reason: reason)
        case .error(let msg):
            state = .error(msg)
        }
    }

    private func resolveCitation(_ input: CitationInput, fallbackQuery: String) async -> BlockResolveResult {
        do {
            let result = try await automation.resolveStructuredCitation(
                input,
                library: resolvedAddTargetLibraryID(),
                downloadPDFs: false,
                importIfMissing: false
            )
            switch result.via {
            case "local-identifier", "local-text":
                guard let paper = result.paper else {
                    return .notFound(reason: result.reason ?? "Local match missing payload")
                }
                let cand = Self.candidate(fromLocal: paper, sourceLabel: "Library", confidence: 1.0)
                return .single(cand)

            case "duplicate":
                guard let paper = result.paper else {
                    return .notFound(reason: "Duplicate detected but no payload")
                }
                let cand = Self.candidate(fromLocal: paper, sourceLabel: "Library", confidence: 1.0)
                return .single(cand)

            case "external-identifier-preview", "ads-high-confidence-preview":
                let cands = (result.candidates ?? []).map(Self.candidate(fromRanked:))
                guard let cand = cands.first else {
                    return .notFound(reason: result.reason ?? "Preview returned no candidate")
                }
                return .single(cand)

            case "ads-candidates", "all-sources-fallback":
                let cands = (result.candidates ?? []).map(Self.candidate(fromRanked:))
                return .candidates(cands)

            case "not-found":
                return .notFound(reason: result.reason ?? "No match found")

            default:
                return .notFound(reason: result.reason ?? "Unknown resolve path: \(result.via)")
            }
        } catch {
            Logger.smartSearch.warningCapture(
                "smartsearch: resolveStructuredCitation failed: \(error.localizedDescription)",
                category: "smartsearch"
            )
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Free-text / fielded rendering

    private func renderSearchResults(_ results: [SearchResult], sourceLabel: String?) async {
        if Task.isCancelled { return }
        let totalCap = maxResultsPerSource * (1 + fallbackSourceIDs.count)
        let candidates = results.prefix(totalCap)
            .map { Self.candidate(fromSearch: $0, fallbackSourceLabel: sourceLabel) }
        // Dedup by best identifier — DOI > arXiv > bibcode > title+year hash.
        let deduped = Self.dedup(candidates)
        Logger.smartSearch.infoCapture(
            "smartsearch: search returned \(results.count) raw, \(deduped.count) after dedup",
            category: "smartsearch"
        )
        if deduped.isEmpty {
            state = .empty(reason: "No results. Try a broader query or different keywords.")
            return
        }
        state = .candidates(deduped)
        highlightedCandidateID = deduped.first?.id
    }

    private func handleSearchError(_ error: Error, query: String) async {
        let msg: String
        if let e = error as? SourceError {
            switch e {
            case .authenticationRequired(let src):
                msg = "\(src.uppercased()) API key not configured (Settings → Sources)."
            case .rateLimited(let retry):
                msg = "Rate-limited. Try again in \(retry.map(String.init(describing:)) ?? "a moment")."
            default:
                msg = e.localizedDescription
            }
        } else {
            msg = error.localizedDescription
        }
        Logger.smartSearch.warningCapture(
            "smartsearch: search failed for '\(query)': \(msg)",
            category: "smartsearch"
        )
        state = .error(msg)
    }

    // MARK: - Add to library

    /// Add the user-selected candidates to the target library.
    public func addSelected() {
        let ids = currentlySelectedIdentifiers()
        guard !ids.isEmpty else { return }
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runAdd(identifiers: ids)
        }
    }

    private func currentlySelectedIdentifiers() -> [PaperIdentifier] {
        switch state {
        case .candidates(let list):
            return list
                .filter { selectedCandidateIDs.contains($0.id) && $0.alreadyInLibrary == nil }
                .compactMap { $0.identifier }
        case .batch(let blocks):
            return blocks.compactMap { block -> PaperIdentifier? in
                guard let candID = selectedBatchCandidates[block.id] else { return nil }
                switch block.status {
                case .resolved(let c) where c.id == candID:
                    return c.alreadyInLibrary == nil ? c.identifier : nil
                case .candidates(let list):
                    return list.first(where: { $0.id == candID })?.identifier
                default:
                    return nil
                }
            }
        default:
            return []
        }
    }

    private func runAdd(identifiers: [PaperIdentifier]) async {
        state = .adding(count: identifiers.count)
        let target = resolvedAddTargetLibraryID()
        Logger.smartSearch.infoCapture(
            "smartsearch: adding \(identifiers.count) paper(s) to library \(target?.uuidString ?? "<default>")",
            category: "smartsearch"
        )
        do {
            let result = try await automation.addPapers(
                identifiers: identifiers,
                collection: nil,
                library: target,
                downloadPDFs: false
            )
            let total = result.added.count + result.duplicates.count
            state = .added(count: total)
            Logger.smartSearch.infoCapture(
                "smartsearch: added \(result.added.count) + \(result.duplicates.count) duplicates, \(result.failed.count) failed",
                category: "smartsearch"
            )

            // Index newly-added papers for Cmd+F (global / full-text search)
            // immediately. Detached so the .added toast is shown without
            // waiting on the indexer. addPapers returns only after the store
            // write commits, so the data is available for indexing right now.
            let addedIDs = result.added.map { $0.id }
            if !addedIDs.isEmpty {
                Task.detached(priority: .userInitiated) {
                    await FullTextSearchService.shared.indexPublications(ids: addedIDs)
                    Logger.smartSearch.infoCapture(
                        "smartsearch: indexed \(addedIDs.count) new paper(s) for full-text search",
                        category: "smartsearch"
                    )
                }
            }

            // Tell the host UI to navigate to the library where these
            // papers landed and select the first one so the user can begin
            // reading. Posted on main so observers can update SwiftUI
            // state synchronously. Includes both newly-added IDs and the
            // resolved UUIDs of duplicates (already-present papers) so
            // re-adding an existing paper still reveals it. Newly added
            // come first so they win the "first" selection.
            let revealIDs = addedIDs + result.duplicateIDs
            if !revealIDs.isEmpty {
                var userInfo: [String: Any] = ["publicationIDs": revealIDs]
                if let target { userInfo["libraryID"] = target }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .smartSearchAddDidComplete,
                        object: nil,
                        userInfo: userInfo
                    )
                }
            }
        } catch {
            state = .error("Add failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Static factories

    private static func candidate(fromRanked rc: RankedCandidate) -> SmartSearchCandidate {
        let r = rc.result
        let id: PaperIdentifier? = {
            if let doi = r.doi, !doi.isEmpty { return .doi(doi) }
            if let arxiv = r.arxivID, !arxiv.isEmpty { return .arxiv(arxiv) }
            if let bib = r.bibcode, !bib.isEmpty { return .bibcode(bib) }
            return nil
        }()
        return SmartSearchCandidate(
            id: stableID(sourceID: r.sourceID, identifier: id, title: r.title, year: r.year),
            title: r.title,
            authors: r.authors,
            year: r.year,
            venue: r.venue.isEmpty ? nil : r.venue,
            identifier: id,
            sourceLabel: sourceLabelFor(r.sourceID),
            confidence: rc.confidence,
            alreadyInLibrary: nil
        )
    }

    private static func candidate(fromLocal p: PaperResult, sourceLabel: String, confidence: Double) -> SmartSearchCandidate {
        let id: PaperIdentifier? = {
            if let doi = p.doi, !doi.isEmpty { return .doi(doi) }
            if let arxiv = p.arxivID, !arxiv.isEmpty { return .arxiv(arxiv) }
            if let bib = p.bibcode, !bib.isEmpty { return .bibcode(bib) }
            return .uuid(p.id)
        }()
        return SmartSearchCandidate(
            id: stableID(sourceID: "library", identifier: id, title: p.title, year: p.year),
            title: p.title,
            authors: p.authors,
            year: p.year,
            venue: p.venue,
            identifier: id,
            sourceLabel: sourceLabel,
            confidence: confidence,
            alreadyInLibrary: p
        )
    }

    private static func candidate(fromSearch s: SearchResult, fallbackSourceLabel: String?) -> SmartSearchCandidate {
        let id: PaperIdentifier? = {
            if let doi = s.doi, !doi.isEmpty { return .doi(doi) }
            if let arxiv = s.arxivID, !arxiv.isEmpty { return .arxiv(arxiv) }
            if let bib = s.bibcode, !bib.isEmpty { return .bibcode(bib) }
            if let pmid = s.pmid, !pmid.isEmpty { return .pmid(pmid) }
            return nil
        }()
        let label = fallbackSourceLabel ?? sourceLabelFor(s.sourceID)
        return SmartSearchCandidate(
            id: stableID(sourceID: s.sourceID, identifier: id, title: s.title, year: s.year),
            title: s.title,
            authors: s.authors,
            year: s.year,
            venue: s.venue,
            identifier: id,
            sourceLabel: label,
            confidence: nil,
            alreadyInLibrary: nil
        )
    }

    private static func stableID(
        sourceID: String,
        identifier: PaperIdentifier?,
        title: String,
        year: Int?
    ) -> String {
        if let id = identifier {
            return "\(sourceID):\(id.typeName):\(id.value)"
        }
        let titleKey = title.lowercased().filter { !$0.isWhitespace }.prefix(60)
        return "\(sourceID):title:\(titleKey):\(year ?? 0)"
    }

    private static func sourceLabelFor(_ id: String) -> String {
        switch id.lowercased() {
        case "ads": return "ADS"
        case "arxiv": return "arXiv"
        case "openalex": return "OpenAlex"
        case "crossref": return "Crossref"
        case "pubmed": return "PubMed"
        case "semanticscholar", "semantic_scholar": return "Semantic Scholar"
        case "dblp": return "DBLP"
        default: return id
        }
    }

    private static func dedup(_ candidates: [SmartSearchCandidate]) -> [SmartSearchCandidate] {
        var seen: Set<String> = []
        var out: [SmartSearchCandidate] = []
        for c in candidates {
            let key: String
            if let id = c.identifier {
                key = "\(id.typeName):\(id.value.lowercased())"
            } else {
                let titleKey = c.title.lowercased().filter { !$0.isWhitespace }.prefix(80)
                key = "title:\(titleKey):\(c.year ?? 0)"
            }
            if seen.insert(key).inserted {
                out.append(c)
            }
        }
        return out
    }

}

// MARK: - PaperIdentifier convenience

private extension PaperIdentifier {
    enum Kind { case doi, arxiv, bibcode, pmid, citeKey, uuid, semanticScholar, openAlex }
    func kindIs(_ k: Kind) -> Bool {
        switch (self, k) {
        case (.doi, .doi), (.arxiv, .arxiv), (.bibcode, .bibcode), (.pmid, .pmid),
             (.citeKey, .citeKey), (.uuid, .uuid),
             (.semanticScholar, .semanticScholar), (.openAlex, .openAlex):
            return true
        default:
            return false
        }
    }
}
