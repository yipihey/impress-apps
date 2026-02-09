//
//  SearchViewModel.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog
import SwiftUI

// MARK: - Classic Form State

/// Stores the state of the ADS Classic search form for persistence across navigation
public struct ClassicFormState {
    /// Raw query text for advanced/modern query building
    public var rawQuery: String = ""

    // Classic form fields
    public var authors: String = ""
    public var objects: String = ""
    public var titleWords: String = ""
    public var titleLogic: QueryLogic = .and
    public var abstractWords: String = ""
    public var abstractLogic: QueryLogic = .and
    public var yearFrom: Int? = nil
    public var yearTo: Int? = nil
    public var database: ADSDatabase = .all
    public var refereedOnly: Bool = false
    public var articlesOnly: Bool = false
    /// Maximum results to return (0 = use global default)
    public var maxResults: Int = 0

    public init() {}

    public mutating func clear() {
        rawQuery = ""
        authors = ""
        objects = ""
        titleWords = ""
        titleLogic = .and
        abstractWords = ""
        abstractLogic = .and
        yearFrom = nil
        yearTo = nil
        database = .all
        refereedOnly = false
        articlesOnly = false
        maxResults = 0
    }

    public var isEmpty: Bool {
        let hasRawQuery = !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasClassicFields = !SearchFormQueryBuilder.isClassicFormEmpty(
            authors: authors,
            objects: objects,
            titleWords: titleWords,
            abstractWords: abstractWords,
            yearFrom: yearFrom,
            yearTo: yearTo
        )
        return !hasRawQuery && !hasClassicFields
    }
}

// MARK: - Paper Form State

/// Stores the state of the ADS Paper search form for persistence across navigation
public struct PaperFormState {
    public var bibcode: String = ""
    public var doi: String = ""
    public var arxivID: String = ""
    /// Maximum results to return (0 = use global default)
    public var maxResults: Int = 0

    public init() {}

    public mutating func clear() {
        bibcode = ""
        doi = ""
        arxivID = ""
        maxResults = 0
    }

    public var isEmpty: Bool {
        SearchFormQueryBuilder.isPaperFormEmpty(
            bibcode: bibcode,
            doi: doi,
            arxivID: arxivID
        )
    }
}

// MARK: - Modern Form State

/// Stores the state of the ADS Modern search form for persistence across navigation
public struct ModernFormState {
    public var searchText: String = ""
    /// Maximum results to return (0 = use global default)
    public var maxResults: Int = 0

    public init() {}

    public mutating func clear() {
        searchText = ""
        maxResults = 0
    }

    public var isEmpty: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - arXiv Search Field

/// Field types for arXiv advanced search
public enum ArXivSearchField: String, CaseIterable, Sendable {
    case all = "all"
    case title = "ti"
    case author = "au"
    case abstract = "abs"
    case comments = "co"
    case journalRef = "jr"
    case reportNumber = "rn"
    case arxivId = "id"
    case doi = "doi"

    public var displayName: String {
        switch self {
        case .all: return "All fields"
        case .title: return "Title"
        case .author: return "Author(s)"
        case .abstract: return "Abstract"
        case .comments: return "Comments"
        case .journalRef: return "Journal reference"
        case .reportNumber: return "Report number"
        case .arxivId: return "arXiv identifier"
        case .doi: return "DOI"
        }
    }
}

// MARK: - arXiv Logic Operator

/// Boolean operators for arXiv advanced search
public enum ArXivLogicOperator: String, CaseIterable, Sendable {
    case and = "AND"
    case or = "OR"
    case andNot = "ANDNOT"  // arXiv uses ANDNOT, not AND_NOT

    public var displayName: String {
        switch self {
        case .and: return "AND"
        case .or: return "OR"
        case .andNot: return "AND NOT"
        }
    }
}

// MARK: - arXiv Search Term

/// A single search term in the arXiv advanced search
public struct ArXivSearchTerm: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var term: String
    public var field: ArXivSearchField
    public var logicOperator: ArXivLogicOperator  // Applied BEFORE this term

    public init(
        id: UUID = UUID(),
        term: String = "",
        field: ArXivSearchField = .all,
        logicOperator: ArXivLogicOperator = .and
    ) {
        self.id = id
        self.term = term
        self.field = field
        self.logicOperator = logicOperator
    }
}

// MARK: - arXiv Date Filter

/// Date filter options for arXiv search
public enum ArXivDateFilter: Equatable, Sendable {
    case allDates
    case pastMonths(Int)  // e.g., 12 for past 12 months
    case specificYear(Int)
    case dateRange(from: Date?, to: Date?)
}

// MARK: - arXiv Sort Order

/// Sort options for arXiv search results
public enum ArXivSortBy: String, CaseIterable, Sendable {
    case relevance = "relevance"
    case submittedDateDesc = "submittedDate-desc"
    case submittedDateAsc = "submittedDate-asc"
    case lastUpdatedDesc = "lastUpdatedDate-desc"

    public var displayName: String {
        switch self {
        case .relevance: return "Relevance"
        case .submittedDateDesc: return "Newest first"
        case .submittedDateAsc: return "Oldest first"
        case .lastUpdatedDesc: return "Recently updated"
        }
    }

    /// arXiv API sort parameter
    public var apiValue: String {
        switch self {
        case .relevance: return "relevance"
        case .submittedDateDesc, .submittedDateAsc: return "submittedDate"
        case .lastUpdatedDesc: return "lastUpdatedDate"
        }
    }

    /// arXiv API sort order
    public var apiOrder: String {
        switch self {
        case .relevance, .submittedDateDesc, .lastUpdatedDesc: return "descending"
        case .submittedDateAsc: return "ascending"
        }
    }
}

// MARK: - arXiv Form State

/// Stores the state of the arXiv Advanced search form for persistence across navigation
public struct ArXivFormState {
    public var searchTerms: [ArXivSearchTerm]
    public var selectedCategories: Set<String>  // e.g., "cs.LG", "math.CO"
    public var includeCrossListed: Bool
    public var dateFilter: ArXivDateFilter
    public var sortBy: ArXivSortBy
    public var resultsPerPage: Int
    /// Maximum results to return (0 = use global default)
    public var maxResults: Int

    public init(
        searchTerms: [ArXivSearchTerm] = [ArXivSearchTerm()],
        selectedCategories: Set<String> = [],
        includeCrossListed: Bool = true,
        dateFilter: ArXivDateFilter = .allDates,
        sortBy: ArXivSortBy = .submittedDateDesc,
        resultsPerPage: Int = 50,
        maxResults: Int = 0
    ) {
        self.searchTerms = searchTerms
        self.selectedCategories = selectedCategories
        self.includeCrossListed = includeCrossListed
        self.dateFilter = dateFilter
        self.sortBy = sortBy
        self.resultsPerPage = resultsPerPage
        self.maxResults = maxResults
    }

    public mutating func clear() {
        searchTerms = [ArXivSearchTerm()]
        selectedCategories = []
        includeCrossListed = true
        dateFilter = .allDates
        sortBy = .submittedDateDesc
        resultsPerPage = 50
        maxResults = 0
    }

    public var isEmpty: Bool {
        searchTerms.allSatisfy { $0.term.trimmingCharacters(in: .whitespaces).isEmpty } &&
        selectedCategories.isEmpty
    }
}

// MARK: - OpenAlex Form State

/// Stores the state of the OpenAlex search form for persistence across navigation
public struct OpenAlexFormState {
    public var searchText: String
    public var yearFrom: Int?
    public var yearTo: Int?
    public var oaStatus: OpenAlexOAStatusFilter
    public var workType: OpenAlexWorkTypeFilter
    public var hasDOI: Bool
    public var hasAbstract: Bool
    public var hasPDF: Bool
    public var minCitations: Int?
    /// Maximum results to return (0 = use global default)
    public var maxResults: Int

    public init(
        searchText: String = "",
        yearFrom: Int? = nil,
        yearTo: Int? = nil,
        oaStatus: OpenAlexOAStatusFilter = .any,
        workType: OpenAlexWorkTypeFilter = .any,
        hasDOI: Bool = false,
        hasAbstract: Bool = false,
        hasPDF: Bool = false,
        minCitations: Int? = nil,
        maxResults: Int = 0
    ) {
        self.searchText = searchText
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.oaStatus = oaStatus
        self.workType = workType
        self.hasDOI = hasDOI
        self.hasAbstract = hasAbstract
        self.hasPDF = hasPDF
        self.minCitations = minCitations
        self.maxResults = maxResults
    }

    public mutating func clear() {
        searchText = ""
        yearFrom = nil
        yearTo = nil
        oaStatus = .any
        workType = .any
        hasDOI = false
        hasAbstract = false
        hasPDF = false
        minCitations = nil
        maxResults = 0
    }

    public var isEmpty: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty &&
        yearFrom == nil &&
        yearTo == nil &&
        oaStatus == .any &&
        workType == .any &&
        !hasDOI &&
        !hasAbstract &&
        !hasPDF &&
        minCitations == nil
    }
}

/// Open access status filter options for OpenAlex search
public enum OpenAlexOAStatusFilter: String, CaseIterable, Sendable {
    case any = "any"
    case gold = "gold"
    case green = "green"
    case hybrid = "hybrid"
    case bronze = "bronze"
    case diamond = "diamond"
    case closed = "closed"
    case openOnly = "open"

    public var displayName: String {
        switch self {
        case .any: return "Any"
        case .gold: return "Gold OA"
        case .green: return "Green OA"
        case .hybrid: return "Hybrid OA"
        case .bronze: return "Bronze OA"
        case .diamond: return "Diamond OA"
        case .closed: return "Closed Access"
        case .openOnly: return "Open Access Only"
        }
    }
}

/// Work type filter options for OpenAlex search
public enum OpenAlexWorkTypeFilter: String, CaseIterable, Sendable {
    case any = "any"
    case article = "article"
    case bookChapter = "book-chapter"
    case book = "book"
    case dataset = "dataset"
    case dissertation = "dissertation"
    case proceedings = "proceedings-article"
    case review = "review"
    case report = "report"
    case preprint = "preprint"

    public var displayName: String {
        switch self {
        case .any: return "Any Type"
        case .article: return "Article"
        case .bookChapter: return "Book Chapter"
        case .book: return "Book"
        case .dataset: return "Dataset"
        case .dissertation: return "Dissertation"
        case .proceedings: return "Conference Paper"
        case .review: return "Review"
        case .report: return "Report"
        case .preprint: return "Preprint"
        }
    }
}

// MARK: - Search View Model

/// View model for searching across publication sources.
///
/// ADR-016: Search results are auto-imported to the active library's "Last Search"
/// collection. This provides immediate persistence and full editing capabilities
/// for all search results.
@MainActor
@Observable
public final class SearchViewModel {

    // MARK: - Published State

    public private(set) var isSearching = false
    public private(set) var error: Error?

    public var query = ""
    public var selectedSourceIDs: Set<String> = []
    public var selectedPublicationIDs: Set<UUID> = []

    // MARK: - Form State (persisted across navigation)

    /// Classic form state - persists when navigating away and back
    public var classicFormState = ClassicFormState()

    /// Paper form state - persists when navigating away and back
    public var paperFormState = PaperFormState()

    /// Modern form state - persists when navigating away and back
    public var modernFormState = ModernFormState()

    /// arXiv Advanced form state - persists when navigating away and back
    public var arxivFormState = ArXivFormState()

    /// OpenAlex form state - persists when navigating away and back
    public var openAlexFormState = OpenAlexFormState()

    /// Vague Memory form state - persists when navigating away and back
    public var vagueMemoryFormState = VagueMemoryFormState()

    // MARK: - Edit Mode State

    /// The smart search being edited (nil = new search / ad-hoc search mode)
    public var editingSmartSearch: SmartSearch?

    /// Whether we're in edit mode (editing an existing smart search)
    public var isEditMode: Bool {
        editingSmartSearch != nil
    }

    /// Which form type is being used for editing
    public enum EditFormType {
        case classic
        case modern
        case paper
        case arxiv
        case openalex
        case vagueMemory
    }

    /// The form type to use for the current edit (determined when loading)
    public var editFormType: EditFormType = .modern

    // MARK: - Dependencies

    public let sourceManager: SourceManager
    private let deduplicationService: DeduplicationService
    private weak var libraryManager: LibraryManager?

    // MARK: - Initialization

    public init(
        sourceManager: SourceManager = SourceManager(),
        deduplicationService: DeduplicationService = DeduplicationService(),
        libraryManager: LibraryManager? = nil
    ) {
        self.sourceManager = sourceManager
        self.deduplicationService = deduplicationService
        self.libraryManager = libraryManager
    }

    /// Set the library manager (called from view layer after environment injection)
    public func setLibraryManager(_ manager: LibraryManager) {
        self.libraryManager = manager
    }

    // MARK: - Last Search Collection

    /// Publications from the Last Search collection
    public var publications: [PublicationRowData] {
        guard let collectionId = libraryManager?.getOrCreateLastSearchCollection()?.id else {
            return []
        }
        return RustStoreAdapter.shared.listCollectionMembers(collectionId: collectionId)
    }

    // MARK: - Available Sources

    public var availableSources: [SourceMetadata] {
        get async {
            await sourceManager.availableSources
        }
    }

    // MARK: - Max Results Helper

    /// Get the maxResults value to use for the current search.
    ///
    /// Returns the form-specific maxResults if set (> 0), otherwise falls back to the global default.
    private func currentMaxResults() async -> Int {
        let formValue: Int
        switch editFormType {
        case .classic: formValue = classicFormState.maxResults
        case .modern: formValue = modernFormState.maxResults
        case .paper: formValue = paperFormState.maxResults
        case .arxiv: formValue = arxivFormState.maxResults
        case .openalex: formValue = openAlexFormState.maxResults
        case .vagueMemory: formValue = vagueMemoryFormState.maxResults
        }
        if formValue > 0 { return formValue }
        return Int(await SmartSearchSettingsStore.shared.settings.defaultMaxResults)
    }

    // MARK: - Search (ADR-016: Auto-Import)

    /// Execute search and auto-import results to Last Search collection.
    ///
    /// This method:
    /// 1. Clears the previous Last Search results
    /// 2. Executes the search query
    /// 3. Deduplicates against existing library publications
    /// 4. Imports new results as publications via the Rust store
    /// 5. Adds all results to the Last Search collection
    public func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        guard let manager = libraryManager else {
            Logger.viewModels.errorCapture("No library manager available for search", category: "search")
            return
        }

        guard let collectionModel = manager.getOrCreateLastSearchCollection() else {
            Logger.viewModels.errorCapture("Could not create Last Search collection", category: "search")
            return
        }

        let collectionId = collectionModel.id

        Logger.viewModels.entering()
        defer { Logger.viewModels.exiting() }

        isSearching = true
        error = nil

        // Clear previous Last Search results
        manager.clearLastSearchCollection()

        do {
            let sourceIDs = Array(selectedSourceIDs)
            let maxResults = await currentMaxResults()
            let options = SearchOptions(
                maxResults: maxResults,
                sortOrder: .relevance,
                sourceIDs: selectedSourceIDs.isEmpty ? nil : sourceIDs
            )

            let rawResults = try await sourceManager.search(query: query, options: options)

            // Deduplicate results
            let deduped = await deduplicationService.deduplicate(rawResults)

            Logger.viewModels.infoCapture("Search returned \(deduped.count) deduplicated results", category: "search")

            // Auto-import results to Last Search collection via Rust store
            let store = RustStoreAdapter.shared
            var importedCount = 0
            var existingCount = 0

            for result in deduped {
                // Check for existing publication by identifiers
                let existingPubs = store.findByIdentifiers(
                    doi: result.primary.doi,
                    arxivId: result.primary.arxivID,
                    bibcode: result.primary.bibcode
                )
                if let existingPub = existingPubs.first {
                    // Add existing publication to Last Search collection
                    store.addToCollection(publicationIds: [existingPub.id], collectionId: collectionId)
                    existingCount += 1
                } else {
                    // Import new publication via BibTeX and add to collection
                    let bibtex = result.primary.toBibTeX(abstractOverride: result.bestAbstract)
                    let libraryId = libraryManager?.activeLibrary?.id
                    guard let libraryId else { continue }
                    let ids = store.importBibTeX(bibtex, libraryId: libraryId)
                    if let newId = ids.first {
                        store.addToCollection(publicationIds: [newId], collectionId: collectionId)
                    }
                    importedCount += 1
                }
            }

            Logger.viewModels.infoCapture("Search: imported \(importedCount) new, linked \(existingCount) existing", category: "search")

            // Get imported publication IDs from the collection
            let collectionPubIds = store.listCollectionMembers(collectionId: collectionId).map(\.id)

            // Create exploration smart search for sidebar display
            await createExplorationSearch(
                query: query,
                sourceIDs: sourceIDs,
                publicationIds: collectionPubIds,
                maxResults: maxResults
            )

            // Notify that Last Search collection has been updated
            await MainActor.run {
                NotificationCenter.default.post(name: .lastSearchUpdated, object: nil)
            }

        } catch {
            self.error = error
            Logger.viewModels.errorCapture("Search failed: \(error.localizedDescription)", category: "search")
        }

        isSearching = false
    }

    // MARK: - Exploration Search

    /// Create a smart search in the Exploration library for sidebar display.
    ///
    /// This allows users to see their search in the Exploration section and
    /// edit the query via right-click context menu.
    private func createExplorationSearch(
        query: String,
        sourceIDs: [String],
        publicationIds: [UUID],
        maxResults: Int
    ) async {
        Logger.viewModels.infoCapture("createExplorationSearch called with query: \(query), \(publicationIds.count) publications", category: "search")

        guard let manager = libraryManager else {
            Logger.viewModels.errorCapture("No library manager available for exploration search", category: "search")
            return
        }

        let store = RustStoreAdapter.shared

        // Get or create the exploration library (ensures it exists)
        let explorationLib = manager.getOrCreateExplorationLibrary()

        let existingSmartSearches = store.listSmartSearches(libraryId: explorationLib.id)
        Logger.viewModels.infoCapture("Exploration library found: \(explorationLib.name), has \(existingSmartSearches.count) smart searches", category: "search")

        // Truncate query for display name (no "Search:" prefix - icon indicates it's a search)
        let truncatedQuery = String(query.prefix(50)) + (query.count > 50 ? "…" : "")
        let searchName = truncatedQuery

        // Check if a search with the same query already exists
        if let existing = existingSmartSearches.first(where: { $0.query == query }) {
            Logger.viewModels.infoCapture("Found existing exploration search: \(existing.name), navigating to it", category: "search")

            // Index publications for global search (Cmd+F) after a short delay
            let capturedIds = publicationIds
            Task {
                try? await Task.sleep(for: .seconds(1))
                for pubId in capturedIds {
                    await FullTextSearchService.shared.indexPublication(id: pubId)
                }
                Logger.viewModels.infoCapture("Indexed \(capturedIds.count) exploration search results for global search", category: "search")
            }

            // Navigate to the existing search
            NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
            NotificationCenter.default.post(name: .navigateToSmartSearch, object: existing.id)
            return
        }

        // Create new smart search in exploration library via Rust store
        let sourceIdsJson = "[" + sourceIDs.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let smartSearch = store.createSmartSearch(
            name: searchName,
            query: query,
            libraryId: explorationLib.id,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(maxResults),
            autoRefreshEnabled: false,
            refreshIntervalSeconds: 86400
        )

        guard let smartSearch else {
            Logger.viewModels.errorCapture("Failed to create exploration search", category: "search")
            return
        }

        Logger.viewModels.infoCapture("Created exploration search: \(searchName) with \(publicationIds.count) results", category: "search")

        // Index publications for global search (Cmd+F) after a short delay
        let capturedIds = publicationIds
        Task {
            try? await Task.sleep(for: .seconds(1))
            for pubId in capturedIds {
                await FullTextSearchService.shared.indexPublication(id: pubId)
            }
            Logger.viewModels.infoCapture("Indexed \(capturedIds.count) exploration search results for global search", category: "search")
        }

        // Notify sidebar to refresh and navigate to the new search
        NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
        NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
    }

    // MARK: - Selection

    public func toggleSelection(_ id: UUID) {
        if selectedPublicationIDs.contains(id) {
            selectedPublicationIDs.remove(id)
        } else {
            selectedPublicationIDs.insert(id)
        }
    }

    public func selectAll() {
        selectedPublicationIDs = Set(publications.map { $0.id })
    }

    public func clearSelection() {
        selectedPublicationIDs.removeAll()
    }

    // MARK: - Source Selection

    public func toggleSource(_ sourceID: String) {
        if selectedSourceIDs.contains(sourceID) {
            selectedSourceIDs.remove(sourceID)
        } else {
            selectedSourceIDs.insert(sourceID)
        }
    }

    public func selectAllSources() async {
        selectedSourceIDs = Set(await availableSources.map { $0.id })
    }

    public func clearSourceSelection() {
        selectedSourceIDs.removeAll()
    }

    // MARK: - Smart Search Edit Mode

    /// Load a smart search for editing.
    ///
    /// Attempts to parse the query back to the classic form if possible,
    /// otherwise falls back to the modern form.
    public func loadSmartSearch(_ smartSearch: SmartSearch) {
        editingSmartSearch = smartSearch
        query = smartSearch.query
        selectedSourceIDs = Set(smartSearch.sourceIDs)

        // Clear all forms first
        classicFormState.clear()
        paperFormState.clear()
        modernFormState.clear()
        arxivFormState.clear()

        // Load maxResults from smart search (will be applied to the detected form)
        let storedMaxResults = Int(smartSearch.maxResults)

        // Try to parse the query back to form fields
        // Paper form first (most specific: only identifiers)
        if let paperState = parsePaperQuery(smartSearch.query) {
            paperFormState = paperState
            paperFormState.maxResults = storedMaxResults
            editFormType = .paper
            Logger.viewModels.infoCapture("Loaded smart search '\(smartSearch.name)' into Paper form", category: "search-edit")
        }
        // arXiv form (detects cat: and arXiv-specific fields)
        else if let arxivState = parseArXivQuery(smartSearch.query) {
            arxivFormState = arxivState
            arxivFormState.maxResults = storedMaxResults
            editFormType = .arxiv
            Logger.viewModels.infoCapture("Loaded smart search '\(smartSearch.name)' into arXiv form", category: "search-edit")
        }
        // Classic form (ADS-specific fields)
        else if let classicState = parseClassicQuery(smartSearch.query) {
            classicFormState = classicState
            classicFormState.maxResults = storedMaxResults
            editFormType = .classic
            Logger.viewModels.infoCapture("Loaded smart search '\(smartSearch.name)' into Classic form", category: "search-edit")
        }
        // Fall back to modern form (any query works here)
        else {
            modernFormState.searchText = smartSearch.query
            modernFormState.maxResults = storedMaxResults
            editFormType = .modern
            Logger.viewModels.infoCapture("Loaded smart search '\(smartSearch.name)' into Modern form (fallback)", category: "search-edit")
        }
    }

    /// Save the current form state back to the editing smart search.
    ///
    /// Updates the smart search's query based on the current form type.
    public func saveToSmartSearch() {
        guard let smartSearch = editingSmartSearch else {
            Logger.viewModels.errorCapture("saveToSmartSearch called but no smart search is being edited", category: "search-edit")
            return
        }

        // Build the query from the current form
        let newQuery: String
        switch editFormType {
        case .classic:
            newQuery = SearchFormQueryBuilder.buildClassicQuery(
                authors: classicFormState.authors,
                objects: classicFormState.objects,
                titleWords: classicFormState.titleWords,
                titleLogic: classicFormState.titleLogic,
                abstractWords: classicFormState.abstractWords,
                abstractLogic: classicFormState.abstractLogic,
                yearFrom: classicFormState.yearFrom,
                yearTo: classicFormState.yearTo,
                database: classicFormState.database,
                refereedOnly: classicFormState.refereedOnly,
                articlesOnly: classicFormState.articlesOnly
            )
        case .paper:
            newQuery = SearchFormQueryBuilder.buildPaperQuery(
                bibcode: paperFormState.bibcode,
                doi: paperFormState.doi,
                arxivID: paperFormState.arxivID
            )
        case .modern:
            newQuery = modernFormState.searchText
        case .arxiv:
            newQuery = SearchFormQueryBuilder.buildArXivAdvancedQuery(
                searchTerms: arxivFormState.searchTerms,
                categories: arxivFormState.selectedCategories,
                includeCrossListed: arxivFormState.includeCrossListed,
                dateFilter: arxivFormState.dateFilter,
                sortBy: arxivFormState.sortBy
            )
        case .openalex:
            newQuery = openAlexFormState.searchText
        case .vagueMemory:
            newQuery = VagueMemoryQueryBuilder.buildQuery(from: vagueMemoryFormState)
        }

        // Get maxResults from the current form
        let formMaxResults: Int
        switch editFormType {
        case .classic: formMaxResults = classicFormState.maxResults
        case .modern: formMaxResults = modernFormState.maxResults
        case .paper: formMaxResults = paperFormState.maxResults
        case .arxiv: formMaxResults = arxivFormState.maxResults
        case .openalex: formMaxResults = openAlexFormState.maxResults
        case .vagueMemory: formMaxResults = vagueMemoryFormState.maxResults
        }

        // Update the smart search via the Rust store
        let store = RustStoreAdapter.shared
        let sourceIdsJson: String? = selectedSourceIDs.isEmpty ? nil : {
            let arr = Array(selectedSourceIDs)
            if let data = try? JSONEncoder().encode(arr) {
                return String(data: data, encoding: .utf8)
            }
            return nil
        }()
        store.updateSmartSearch(
            id: smartSearch.id,
            name: smartSearch.name,
            query: newQuery,
            sourceIdsJson: sourceIdsJson,
            maxResults: Int64(formMaxResults)
        )
        Logger.viewModels.infoCapture("Saved smart search '\(smartSearch.name)' with query: \(newQuery)", category: "search-edit")

        // Exit edit mode
        exitEditMode()
    }

    /// Exit edit mode without saving.
    public func exitEditMode() {
        editingSmartSearch = nil
        editFormType = .modern
        classicFormState.clear()
        paperFormState.clear()
        modernFormState.clear()
        arxivFormState.clear()
        vagueMemoryFormState.clear()
        selectedSourceIDs.removeAll()
        query = ""
    }

    // MARK: - Query Parsing

    /// Try to parse an ADS query back to classic form fields.
    ///
    /// Returns nil if the query can't be parsed to classic form
    /// (e.g., uses advanced syntax not supported by the form).
    private func parseClassicQuery(_ query: String) -> ClassicFormState? {
        var state = ClassicFormState()
        var unmatchedParts: [String] = []

        // Regex patterns for field extraction
        let authorPattern = #"author:"([^"]+)""#
        let objectPattern = #"object:"([^"]+)""#
        let titlePattern = #"title:(\([^)]+\)|[^\s]+)"#
        let absPattern = #"abs:(\([^)]+\)|[^\s]+)"#
        let yearPattern = #"year:(\d{4})?-?(\d{4})?"#
        let collectionPattern = #"collection:(astronomy|physics)"#
        let eprintPattern = #"property:eprint"#
        let refereedPattern = #"property:refereed"#
        let doctypePattern = #"doctype:article"#

        var remainingQuery = query

        // Extract authors
        if let regex = try? NSRegularExpression(pattern: authorPattern, options: []) {
            let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))
            let authors = matches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: query) else { return nil }
                return String(query[range])
            }
            if !authors.isEmpty {
                state.authors = authors.joined(separator: "\n")
            }
            // Remove matched parts from remaining query
            for match in matches.reversed() {
                if let range = Range(match.range, in: remainingQuery) {
                    remainingQuery.removeSubrange(range)
                }
            }
        }

        // Extract object
        if let regex = try? NSRegularExpression(pattern: objectPattern, options: []) {
            if let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                state.objects = String(query[range])
            }
            if let match = regex.firstMatch(in: remainingQuery, options: [], range: NSRange(remainingQuery.startIndex..., in: remainingQuery)),
               let range = Range(match.range, in: remainingQuery) {
                remainingQuery.removeSubrange(range)
            }
        }

        // Extract title
        if let regex = try? NSRegularExpression(pattern: titlePattern, options: []) {
            if let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                let titlePart = String(query[range])
                // Remove parentheses and logic operators
                let cleaned = titlePart
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .replacingOccurrences(of: " AND ", with: " ")
                    .replacingOccurrences(of: " OR ", with: " ")
                state.titleWords = cleaned

                // Detect logic
                if titlePart.contains(" OR ") {
                    state.titleLogic = .or
                }
            }
            if let match = regex.firstMatch(in: remainingQuery, options: [], range: NSRange(remainingQuery.startIndex..., in: remainingQuery)),
               let range = Range(match.range, in: remainingQuery) {
                remainingQuery.removeSubrange(range)
            }
        }

        // Extract abstract
        if let regex = try? NSRegularExpression(pattern: absPattern, options: []) {
            if let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                let absPart = String(query[range])
                let cleaned = absPart
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .replacingOccurrences(of: " AND ", with: " ")
                    .replacingOccurrences(of: " OR ", with: " ")
                state.abstractWords = cleaned

                if absPart.contains(" OR ") {
                    state.abstractLogic = .or
                }
            }
            if let match = regex.firstMatch(in: remainingQuery, options: [], range: NSRange(remainingQuery.startIndex..., in: remainingQuery)),
               let range = Range(match.range, in: remainingQuery) {
                remainingQuery.removeSubrange(range)
            }
        }

        // Extract year
        if let regex = try? NSRegularExpression(pattern: yearPattern, options: []) {
            if let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)) {
                if let fromRange = Range(match.range(at: 1), in: query) {
                    state.yearFrom = Int(query[fromRange])
                }
                if let toRange = Range(match.range(at: 2), in: query) {
                    state.yearTo = Int(query[toRange])
                }
            }
            if let match = regex.firstMatch(in: remainingQuery, options: [], range: NSRange(remainingQuery.startIndex..., in: remainingQuery)),
               let range = Range(match.range, in: remainingQuery) {
                remainingQuery.removeSubrange(range)
            }
        }

        // Extract collection
        if let regex = try? NSRegularExpression(pattern: collectionPattern, options: []) {
            if let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                let collection = String(query[range])
                if collection == "astronomy" {
                    state.database = .astronomy
                } else if collection == "physics" {
                    state.database = .physics
                }
            }
            if let match = regex.firstMatch(in: remainingQuery, options: [], range: NSRange(remainingQuery.startIndex..., in: remainingQuery)),
               let range = Range(match.range, in: remainingQuery) {
                remainingQuery.removeSubrange(range)
            }
        }

        // Extract eprint (arxiv database)
        if query.contains("property:eprint") {
            state.database = .arxiv
            remainingQuery = remainingQuery.replacingOccurrences(of: "property:eprint", with: "")
        }

        // Extract refereed
        if query.contains("property:refereed") {
            state.refereedOnly = true
            remainingQuery = remainingQuery.replacingOccurrences(of: "property:refereed", with: "")
        }

        // Extract doctype:article
        if query.contains("doctype:article") {
            state.articlesOnly = true
            remainingQuery = remainingQuery.replacingOccurrences(of: "doctype:article", with: "")
        }

        // Clean up remaining query
        remainingQuery = remainingQuery
            .replacingOccurrences(of: " AND ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If there's significant unmatched content, the query can't be represented in classic form
        if !remainingQuery.isEmpty && remainingQuery.count > 5 {
            Logger.viewModels.infoCapture("Query has unmatched parts, can't use classic form: '\(remainingQuery)'", category: "search-edit")
            return nil
        }

        // Return state if we extracted at least one field
        if state.isEmpty {
            return nil
        }

        return state
    }

    /// Try to parse an ADS query to paper form fields.
    ///
    /// Returns nil if the query can't be parsed to paper form.
    private func parsePaperQuery(_ query: String) -> PaperFormState? {
        var state = PaperFormState()

        let bibcodePattern = #"bibcode:([^\s]+)"#
        let doiPattern = #"doi:([^\s]+)"#
        let arxivPattern = #"arXiv:([^\s]+)"#

        var hasMatch = false

        if let regex = try? NSRegularExpression(pattern: bibcodePattern, options: []),
           let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            state.bibcode = String(query[range])
            hasMatch = true
        }

        if let regex = try? NSRegularExpression(pattern: doiPattern, options: []),
           let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            state.doi = String(query[range])
            hasMatch = true
        }

        if let regex = try? NSRegularExpression(pattern: arxivPattern, options: []),
           let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            state.arxivID = String(query[range])
            hasMatch = true
        }

        // Paper form queries should only contain identifiers
        // If there's other content, it's not a paper form query
        var cleaned = query
            .replacingOccurrences(of: #"bibcode:[^\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"doi:[^\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"arXiv:[^\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " OR ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleaned.isEmpty {
            return nil  // Has non-identifier content
        }

        return hasMatch ? state : nil
    }

    /// Try to parse an arXiv query back to arXiv form fields.
    ///
    /// Returns nil if the query can't be parsed as an arXiv query.
    /// Detects arXiv queries by looking for cat: prefixes or arXiv-specific field prefixes.
    private func parseArXivQuery(_ query: String) -> ArXivFormState? {
        var state = ArXivFormState()

        // Check if this looks like an arXiv query by looking for cat: or arXiv field prefixes
        let hasCategory = query.contains("cat:")
        let hasArXivFields = query.contains("ti:") || query.contains("au:") || query.contains("abs:") ||
                             query.contains("co:") || query.contains("jr:") || query.contains("rn:") ||
                             query.contains("id:") || query.contains("submittedDate:")

        // If no arXiv indicators, this isn't an arXiv query
        if !hasCategory && !hasArXivFields {
            return nil
        }

        // Parse categories
        let catPattern = #"cat:([^\s()]+)"#
        if let regex = try? NSRegularExpression(pattern: catPattern, options: []) {
            let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))
            for match in matches {
                if let range = Range(match.range(at: 1), in: query) {
                    state.selectedCategories.insert(String(query[range]))
                }
            }
        }

        // Parse search terms - this is a simplified parser that extracts field:term patterns
        var searchTerms: [ArXivSearchTerm] = []
        let remainingQuery = query
            .replacingOccurrences(of: #"cat:[^\s()]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^\)]+\)"#, with: "", options: .regularExpression) // Remove parenthesized groups
            .replacingOccurrences(of: #"submittedDate:\[[^\]]+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Split by boolean operators and extract terms
        let parts = remainingQuery.components(separatedBy: " ")
        var currentOperator: ArXivLogicOperator = .and
        var currentTerms: [String] = []

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed.uppercased() == "AND" {
                currentOperator = .and
            } else if trimmed.uppercased() == "OR" {
                currentOperator = .or
            } else if trimmed.uppercased() == "ANDNOT" {
                currentOperator = .andNot
            } else {
                // Parse field:value
                var field = ArXivSearchField.all
                var value = trimmed

                if trimmed.contains(":") {
                    let colonIndex = trimmed.firstIndex(of: ":")!
                    let prefix = String(trimmed[..<colonIndex])
                    value = String(trimmed[trimmed.index(after: colonIndex)...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                    switch prefix.lowercased() {
                    case "ti": field = .title
                    case "au": field = .author
                    case "abs": field = .abstract
                    case "co": field = .comments
                    case "jr": field = .journalRef
                    case "rn": field = .reportNumber
                    case "id": field = .arxivId
                    case "doi": field = .doi
                    default: break
                    }
                }

                if !value.isEmpty {
                    let term = ArXivSearchTerm(
                        term: value,
                        field: field,
                        logicOperator: searchTerms.isEmpty ? .and : currentOperator
                    )
                    searchTerms.append(term)
                }
            }
        }

        // If we parsed terms, use them; otherwise create a default empty term
        if !searchTerms.isEmpty {
            state.searchTerms = searchTerms
        }

        // Parse date filter
        let datePattern = #"submittedDate:\[(\d+|\*) TO (\d+|\*)\]"#
        if let regex = try? NSRegularExpression(pattern: datePattern, options: []),
           let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)) {
            let fromRange = Range(match.range(at: 1), in: query)
            let toRange = Range(match.range(at: 2), in: query)

            let fromStr = fromRange.map { String(query[$0]) } ?? "*"
            let toStr = toRange.map { String(query[$0]) } ?? "*"

            if fromStr != "*" && toStr != "*" && fromStr.count >= 4 && toStr.count >= 4 {
                // Check if it's a specific year (YYYYMMDD format for Jan 1 to Dec 31)
                let fromYear = String(fromStr.prefix(4))
                let toYear = String(toStr.prefix(4))
                if fromYear == toYear && fromStr.hasSuffix("0101") && toStr.hasSuffix("1231") {
                    state.dateFilter = .specificYear(Int(fromYear) ?? Calendar.current.component(.year, from: Date()))
                } else {
                    // Date range
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyyMMdd"
                    let fromDate = formatter.date(from: fromStr)
                    let toDate = formatter.date(from: toStr)
                    state.dateFilter = .dateRange(from: fromDate, to: toDate)
                }
            }
        }

        return state
    }
}
