//
//  OpenAlexEnhancedSearchFormView.swift
//  PublicationManagerCore
//
//  Enhanced OpenAlex search interface with:
//  - OpenAlex branding
//  - Live result count preview
//  - Autocomplete suggestions
//  - Query validation with hints/warnings
//  - Quick start examples
//

import SwiftUI

#if os(macOS)

// MARK: - OpenAlex Enhanced Search Form View (macOS)

/// Enhanced OpenAlex search form with branding, autocomplete, and rich feedback.
public struct OpenAlexEnhancedSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Local State

    @State private var queryAssistanceViewModel = QueryAssistanceViewModel()
    @State private var autocompleteViewModel = OpenAlexAutocompleteViewModel()
    @State private var showAutocomplete = false
    @FocusState private var isSearchFocused: Bool

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // OpenAlex Header with Branding
                headerSection

                // Search Field with Autocomplete
                searchSection

                // Query Assistance Feedback
                if !queryAssistanceViewModel.isEmpty {
                    QueryAssistanceView(viewModel: queryAssistanceViewModel, showHints: true)
                }

                // Quick Start Examples
                quickStartSection

                // Filters Section
                filtersSection

                // Open Access Section
                openAccessSection

                // Requirements Section
                requirementsSection

                // Syntax Help Section
                syntaxHelpSection

                Divider()
                    .padding(.vertical, 8)

                // Edit mode header
                if searchViewModel.isEditMode, let smartSearch = searchViewModel.editingSmartSearch {
                    editModeHeader(smartSearch)
                }

                // Action buttons
                actionButtons
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            searchViewModel.setLibraryManager(libraryManager)
            queryAssistanceViewModel.setSource(.openalex)
            await QueryAssistanceService.shared.register(OpenAlexQueryAssistant())
        }
        .onChange(of: searchViewModel.openAlexFormState.searchText) { _, _ in
            updateQueryAssistance()
            updateAutocomplete()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            // OpenAlex Logo/Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [Color.orange.opacity(0.8), Color.red.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 44, height: 44)

                Image(systemName: "book.pages.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("OpenAlex")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Search 240M+ scholarly works")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Live result count badge
            if let count = queryAssistanceViewModel.previewCount {
                resultCountBadge(count)
            } else if queryAssistanceViewModel.isFetchingPreview {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Search Section

    @ViewBuilder
    private var searchSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Search")
                .font(.headline)

            ZStack(alignment: .topLeading) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("author:\"Einstein\" title:\"relativity\"", text: $viewModel.openAlexFormState.searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onSubmit {
                            showAutocomplete = false
                            performSearch()
                        }
                        .accessibilityIdentifier("OpenAlexSearchField")

                    // Status indicators
                    if queryAssistanceViewModel.hasErrors {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    } else if queryAssistanceViewModel.hasWarnings {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if autocompleteViewModel.hasSuggestions {
                        AutocompleteBadge(hasResults: true)
                    }

                    if !viewModel.openAlexFormState.searchText.isEmpty {
                        Button {
                            viewModel.openAlexFormState.searchText = ""
                            autocompleteViewModel.clear()
                            queryAssistanceViewModel.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(searchFieldBorderColor, lineWidth: 1)
                )

                // Autocomplete dropdown
                if showAutocomplete && autocompleteViewModel.hasSuggestions {
                    OpenAlexAutocompleteDropdown(viewModel: autocompleteViewModel) { suggestion in
                        insertAutocomplete(suggestion)
                    }
                    .frame(width: 350)
                    .offset(y: 48)
                    .zIndex(100)
                }
            }
        }
    }

    private var searchFieldBorderColor: Color {
        if queryAssistanceViewModel.hasErrors {
            return .red.opacity(0.5)
        } else if queryAssistanceViewModel.hasWarnings {
            return .orange.opacity(0.5)
        } else if isSearchFocused {
            return .accentColor.opacity(0.5)
        }
        return .secondary.opacity(0.3)
    }

    // MARK: - Quick Start Section

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Start")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickStartExamples, id: \.label) { example in
                        QuickStartChip(
                            label: example.label,
                            icon: example.icon
                        ) {
                            applyQuickStart(example)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filters Section

    @ViewBuilder
    private var filtersSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 12) {
            Text("Filters")
                .font(.headline)

            // Year Range
            HStack {
                Text("Year:")
                    .frame(width: 100, alignment: .leading)

                TextField("From", value: $viewModel.openAlexFormState.yearFrom, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                Text("to")

                TextField("To", value: $viewModel.openAlexFormState.yearTo, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            // Work Type
            HStack {
                Text("Type:")
                    .frame(width: 100, alignment: .leading)

                Picker("", selection: $viewModel.openAlexFormState.workType) {
                    ForEach(OpenAlexWorkTypeFilter.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            // Minimum Citations
            HStack {
                Text("Min. citations:")
                    .frame(width: 100, alignment: .leading)

                TextField("", value: $viewModel.openAlexFormState.minCitations, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
        }
    }

    // MARK: - Open Access Section

    @ViewBuilder
    private var openAccessSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 12) {
            Text("Open Access")
                .font(.headline)

            HStack {
                Text("Status:")
                    .frame(width: 100, alignment: .leading)

                Picker("", selection: $viewModel.openAlexFormState.oaStatus) {
                    ForEach(OpenAlexOAStatusFilter.allCases, id: \.self) { status in
                        HStack {
                            if status != .any {
                                Circle()
                                    .fill(oaStatusColor(status))
                                    .frame(width: 8, height: 8)
                            }
                            Text(status.displayName)
                        }
                        .tag(status)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        }
    }

    private func oaStatusColor(_ status: OpenAlexOAStatusFilter) -> Color {
        switch status {
        case .any: return .clear
        case .gold, .diamond: return .yellow
        case .green: return .green
        case .hybrid: return .orange
        case .bronze: return .brown
        case .closed: return .gray
        case .openOnly: return .blue
        }
    }

    // MARK: - Requirements Section

    @ViewBuilder
    private var requirementsSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Requirements")
                .font(.headline)

            HStack(spacing: 16) {
                Toggle("Has DOI", isOn: $viewModel.openAlexFormState.hasDOI)
                Toggle("Has Abstract", isOn: $viewModel.openAlexFormState.hasAbstract)
                Toggle("Has PDF", isOn: $viewModel.openAlexFormState.hasPDF)
            }
        }
    }

    // MARK: - Syntax Help Section

    private var syntaxHelpSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(syntaxHelpItems, id: \.field) { item in
                    SyntaxHelpRow(field: item.field, example: item.example, description: item.description)
                }

                Divider()
                    .padding(.vertical, 8)

                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("Boolean operators: AND, OR, NOT (must be uppercase)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Link(destination: URL(string: "https://docs.openalex.org/api-entities/works/filter-works")!) {
                    HStack {
                        Image(systemName: "link")
                        Text("Full OpenAlex Documentation")
                    }
                    .font(.caption)
                }
                .padding(.top, 8)
            }
            .padding(.vertical, 8)
        } label: {
            Label("Query Syntax Help", systemImage: "questionmark.circle")
                .font(.subheadline)
        }
    }

    // MARK: - Edit Mode Header

    private func editModeHeader(_ smartSearch: CDSmartSearch) -> some View {
        HStack {
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.orange)
            Text("Editing: \(smartSearch.name)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                searchViewModel.exitEditMode()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            Button("Clear") {
                clearForm()
            }
            .buttonStyle(.bordered)

            Spacer()

            if searchViewModel.isEditMode {
                Button("Save") {
                    searchViewModel.saveToSmartSearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFormEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button("Search") {
                    performSearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFormEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("OpenAlexSearchButton")
            }
        }
    }

    // MARK: - Result Count Badge

    private func resultCountBadge(_ count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: badgeIcon(for: count))
                .font(.caption)
            Text(formatCount(count))
                .font(.caption.monospacedDigit())
            Text("works")
                .font(.caption)
        }
        .foregroundStyle(badgeColor(for: count))
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(badgeColor(for: count).opacity(0.1))
        .clipShape(Capsule())
    }

    private func badgeIcon(for count: Int) -> String {
        switch count {
        case 0: return "exclamationmark.triangle"
        case 1...10_000: return "checkmark.circle"
        default: return "info.circle"
        }
    }

    private func badgeColor(for count: Int) -> Color {
        switch count {
        case 0: return .orange
        case 1...10_000: return .green
        default: return .blue
        }
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    // MARK: - Helpers

    private var isFormEmpty: Bool {
        searchViewModel.openAlexFormState.isEmpty
    }

    private func clearForm() {
        searchViewModel.openAlexFormState.clear()
        autocompleteViewModel.clear()
        queryAssistanceViewModel.clear()
    }

    private func performSearch() {
        guard !isFormEmpty else { return }

        let state = searchViewModel.openAlexFormState
        let query = buildQuery(from: state)
        searchViewModel.query = query
        searchViewModel.selectedSourceIDs = ["openalex"]
        Task {
            await searchViewModel.search()
        }
    }

    private func updateQueryAssistance() {
        let state = searchViewModel.openAlexFormState
        let query = buildQuery(from: state)
        queryAssistanceViewModel.updateQuery(query)
    }

    private func updateAutocomplete() {
        let text = searchViewModel.openAlexFormState.searchText
        if !text.isEmpty && isSearchFocused {
            autocompleteViewModel.updateQuery(text)
            showAutocomplete = true
        } else {
            showAutocomplete = false
        }
    }

    private func insertAutocomplete(_ suggestion: OpenAlexAutocompleteSuggestion) {
        // When user selects an autocomplete suggestion, replace the query with
        // the precise ID-based filter. This is more accurate than name search.
        let filter: String

        if let entityType = suggestion.parsedEntityType {
            // Use ID-based filter for precision (e.g., author.id:A5085208759)
            filter = "\(entityType.filterPrefix)\(suggestion.shortID)"
        } else {
            // Fallback to quoted name
            filter = "\"\(suggestion.displayName)\""
        }

        searchViewModel.openAlexFormState.searchText = filter
        showAutocomplete = false
        autocompleteViewModel.clear()
    }

    private func applyQuickStart(_ example: QuickStartExample) {
        searchViewModel.openAlexFormState.searchText = example.query
        updateQueryAssistance()
    }

    private func buildQuery(from state: OpenAlexFormState) -> String {
        var parts: [String] = []

        if !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(state.searchText)
        }

        if let yearFrom = state.yearFrom, let yearTo = state.yearTo {
            parts.append("publication_year:\(yearFrom)-\(yearTo)")
        } else if let yearFrom = state.yearFrom {
            parts.append("publication_year:>\(yearFrom - 1)")
        } else if let yearTo = state.yearTo {
            parts.append("publication_year:<\(yearTo + 1)")
        }

        if state.workType != .any {
            parts.append("type:\(state.workType.rawValue)")
        }

        switch state.oaStatus {
        case .any:
            break
        case .openOnly:
            parts.append("open_access.is_oa:true")
        default:
            parts.append("open_access.oa_status:\(state.oaStatus.rawValue)")
        }

        if state.hasDOI {
            parts.append("has_doi:true")
        }
        if state.hasAbstract {
            parts.append("has_abstract:true")
        }
        if state.hasPDF {
            parts.append("has_pdf_url:true")
        }

        if let minCitations = state.minCitations, minCitations > 0 {
            parts.append("cited_by_count:>\(minCitations - 1)")
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Quick Start Chip

private struct QuickStartChip: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Syntax Help Row

private struct SyntaxHelpRow: View {
    let field: String
    let example: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(field)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 180, alignment: .leading)

            Text(example)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)

            Text(description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Quick Start Examples

private struct QuickStartExample {
    let label: String
    let icon: String
    let query: String
}

private let quickStartExamples: [QuickStartExample] = [
    QuickStartExample(
        label: "Recent AI",
        icon: "cpu",
        query: "title.search:\"artificial intelligence\" publication_year:2023-2024"
    ),
    QuickStartExample(
        label: "Highly Cited",
        icon: "star.fill",
        query: "cited_by_count:>1000 open_access.is_oa:true"
    ),
    QuickStartExample(
        label: "Reviews 2024",
        icon: "doc.text.magnifyingglass",
        query: "type:review publication_year:2024"
    ),
    QuickStartExample(
        label: "Open Access",
        icon: "lock.open.fill",
        query: "open_access.is_oa:true has_pdf_url:true publication_year:2024"
    ),
    QuickStartExample(
        label: "Climate Science",
        icon: "leaf.fill",
        query: "title.search:\"climate change\" type:article publication_year:2020-2024"
    )
]

// MARK: - Syntax Help Items

private struct SyntaxHelpItem {
    let field: String
    let example: String
    let description: String
}

private let syntaxHelpItems: [SyntaxHelpItem] = [
    SyntaxHelpItem(field: "author:", example: "author:\"Einstein, Albert\"", description: "Search by author name"),
    SyntaxHelpItem(field: "title.search:", example: "title.search:\"neural network\"", description: "Search in title"),
    SyntaxHelpItem(field: "abstract.search:", example: "abstract.search:\"machine learning\"", description: "Search in abstract"),
    SyntaxHelpItem(field: "publication_year:", example: "publication_year:2020-2024", description: "Year or range"),
    SyntaxHelpItem(field: "cited_by_count:", example: "cited_by_count:>100", description: "Citation threshold"),
    SyntaxHelpItem(field: "open_access.is_oa:", example: "open_access.is_oa:true", description: "Open access filter"),
    SyntaxHelpItem(field: "type:", example: "type:article", description: "Work type"),
    SyntaxHelpItem(field: "doi:", example: "doi:10.1234/example", description: "Exact DOI lookup"),
    SyntaxHelpItem(field: "authorships.author.orcid:", example: "orcid:0000-0001-2345-6789", description: "Author by ORCID"),
    SyntaxHelpItem(field: "authorships.institutions.display_name.search:", example: "institution:\"MIT\"", description: "Affiliation search")
]

#elseif os(iOS)

// MARK: - OpenAlex Enhanced Search Form View (iOS)

/// Enhanced OpenAlex search form for iOS with branding and rich feedback.
public struct OpenAlexEnhancedSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Local State

    @State private var queryAssistanceViewModel = QueryAssistanceViewModel()
    @FocusState private var isSearchFocused: Bool

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        Form {
            // Header Section
            Section {
                HStack(alignment: .center, spacing: 12) {
                    // OpenAlex Icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(
                                colors: [Color.orange.opacity(0.8), Color.red.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 40, height: 40)

                        Image(systemName: "book.pages.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenAlex")
                            .font(.headline)
                            .fontWeight(.bold)

                        Text("240M+ scholarly works")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Result count
                    if let count = queryAssistanceViewModel.previewCount {
                        iOSResultCountBadge(count)
                    } else if queryAssistanceViewModel.isFetchingPreview {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            // Search Section
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("author:\"Einstein\" title:\"relativity\"", text: $viewModel.openAlexFormState.searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            performSearch()
                        }

                    if queryAssistanceViewModel.hasErrors {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    } else if queryAssistanceViewModel.hasWarnings {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    if !viewModel.openAlexFormState.searchText.isEmpty {
                        Button {
                            viewModel.openAlexFormState.searchText = ""
                            queryAssistanceViewModel.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Query assistance
                if !queryAssistanceViewModel.isEmpty {
                    QueryAssistanceView(viewModel: queryAssistanceViewModel, showHints: true, maxIssues: 2)
                }
            } header: {
                Text("Search")
            }

            // Quick Start Section
            Section("Quick Start") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickStartExamples, id: \.label) { example in
                            Button {
                                searchViewModel.openAlexFormState.searchText = example.query
                                updateQueryAssistance()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: example.icon)
                                        .font(.caption2)
                                    Text(example.label)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Filters Section
            Section("Filters") {
                HStack {
                    Text("Year From")
                    Spacer()
                    TextField("", value: $viewModel.openAlexFormState.yearFrom, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }

                HStack {
                    Text("Year To")
                    Spacer()
                    TextField("", value: $viewModel.openAlexFormState.yearTo, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }

                Picker("Work Type", selection: $viewModel.openAlexFormState.workType) {
                    ForEach(OpenAlexWorkTypeFilter.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                HStack {
                    Text("Min. Citations")
                    Spacer()
                    TextField("", value: $viewModel.openAlexFormState.minCitations, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }

            // Open Access Section
            Section("Open Access") {
                Picker("OA Status", selection: $viewModel.openAlexFormState.oaStatus) {
                    ForEach(OpenAlexOAStatusFilter.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
            }

            // Requirements Section
            Section("Requirements") {
                Toggle("Has DOI", isOn: $viewModel.openAlexFormState.hasDOI)
                Toggle("Has Abstract", isOn: $viewModel.openAlexFormState.hasAbstract)
                Toggle("Has PDF", isOn: $viewModel.openAlexFormState.hasPDF)
            }

            // Syntax Help Section
            Section("Query Syntax") {
                DisclosureGroup("View Examples") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(syntaxHelpItems.prefix(6), id: \.field) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.example)
                                    .font(.system(.caption, design: .monospaced))
                                Text(item.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Link(destination: URL(string: "https://docs.openalex.org/api-entities/works/filter-works")!) {
                    HStack {
                        Image(systemName: "link")
                        Text("Full Documentation")
                    }
                }
            }

            // Edit mode indicator
            if searchViewModel.isEditMode, let smartSearch = searchViewModel.editingSmartSearch {
                Section {
                    HStack {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Editing: \(smartSearch.name)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            searchViewModel.exitEditMode()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }

            // Actions Section
            Section {
                if searchViewModel.isEditMode {
                    Button("Save") {
                        searchViewModel.saveToSmartSearch()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isFormEmpty)
                } else {
                    Button {
                        performSearch()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Search")
                            Spacer()
                        }
                    }
                    .disabled(isFormEmpty)
                }

                Button("Clear", role: .destructive) {
                    searchViewModel.openAlexFormState.clear()
                    queryAssistanceViewModel.clear()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("OpenAlex")
        .task {
            searchViewModel.setLibraryManager(libraryManager)
            queryAssistanceViewModel.setSource(.openalex)
            await QueryAssistanceService.shared.register(OpenAlexQueryAssistant())
        }
        .onChange(of: searchViewModel.openAlexFormState.searchText) { _, _ in
            updateQueryAssistance()
        }
    }

    // MARK: - iOS Result Count Badge

    private func iOSResultCountBadge(_ count: Int) -> some View {
        HStack(spacing: 4) {
            Text(formatCount(count))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(badgeColor(for: count))
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(badgeColor(for: count).opacity(0.1))
        .clipShape(Capsule())
    }

    private func badgeColor(for count: Int) -> Color {
        switch count {
        case 0: return .orange
        case 1...10_000: return .green
        default: return .blue
        }
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    // MARK: - Helpers

    private var isFormEmpty: Bool {
        searchViewModel.openAlexFormState.isEmpty
    }

    private func performSearch() {
        guard !isFormEmpty else { return }

        let state = searchViewModel.openAlexFormState
        let query = buildQuery(from: state)
        searchViewModel.query = query
        searchViewModel.selectedSourceIDs = ["openalex"]
        Task {
            await searchViewModel.search()
        }
    }

    private func updateQueryAssistance() {
        let state = searchViewModel.openAlexFormState
        let query = buildQuery(from: state)
        queryAssistanceViewModel.updateQuery(query)
    }

    private func buildQuery(from state: OpenAlexFormState) -> String {
        var parts: [String] = []

        if !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(state.searchText)
        }

        if let yearFrom = state.yearFrom, let yearTo = state.yearTo {
            parts.append("publication_year:\(yearFrom)-\(yearTo)")
        } else if let yearFrom = state.yearFrom {
            parts.append("publication_year:>\(yearFrom - 1)")
        } else if let yearTo = state.yearTo {
            parts.append("publication_year:<\(yearTo + 1)")
        }

        if state.workType != .any {
            parts.append("type:\(state.workType.rawValue)")
        }

        switch state.oaStatus {
        case .any:
            break
        case .openOnly:
            parts.append("open_access.is_oa:true")
        default:
            parts.append("open_access.oa_status:\(state.oaStatus.rawValue)")
        }

        if state.hasDOI {
            parts.append("has_doi:true")
        }
        if state.hasAbstract {
            parts.append("has_abstract:true")
        }
        if state.hasPDF {
            parts.append("has_pdf_url:true")
        }

        if let minCitations = state.minCitations, minCitations > 0 {
            parts.append("cited_by_count:>\(minCitations - 1)")
        }

        return parts.joined(separator: " ")
    }
}

#endif
