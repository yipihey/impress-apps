//
//  OpenAlexSearchFormView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import SwiftUI

#if os(macOS)

// MARK: - OpenAlex Search Form View (macOS)

/// Form-only view for OpenAlex search (detail pane)
/// Results are shown in the middle pane via SearchResultsListView
public struct OpenAlexSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Local State

    @State private var queryAssistanceViewModel = QueryAssistanceViewModel()

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Label("OpenAlex Search", systemImage: "book.pages")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("240M+ works with open access and citation data")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Search field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search")
                        .font(.headline)

                    TextField("Title, abstract, author...", text: $viewModel.openAlexFormState.searchText)
                        .textFieldStyle(.roundedBorder)
                }

                // Query assistance feedback
                if !queryAssistanceViewModel.isEmpty {
                    QueryAssistanceView(viewModel: queryAssistanceViewModel)
                }

                // Filters Section
                filtersSection

                // Open Access Section
                openAccessSection

                // Options Section
                optionsSection

                // Query Syntax Help
                syntaxHelpSection

                Divider()
                    .padding(.vertical, 8)

                // Edit mode header
                if searchViewModel.isEditMode, let smartSearch = searchViewModel.editingSmartSearch {
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

                // Action buttons
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
                    }
                }
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
        }
    }

    // MARK: - Query Assistance

    private func updateQueryAssistance() {
        let state = searchViewModel.openAlexFormState
        let query = buildQuery(from: state)
        queryAssistanceViewModel.updateQuery(query)
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
                    .frame(width: 80, alignment: .leading)

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
                    .frame(width: 80, alignment: .leading)

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
                    .frame(width: 80, alignment: .leading)

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
                    .frame(width: 80, alignment: .leading)

                Picker("", selection: $viewModel.openAlexFormState.oaStatus) {
                    ForEach(OpenAlexOAStatusFilter.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }
    }

    // MARK: - Options Section

    @ViewBuilder
    private var optionsSection: some View {
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

    @ViewBuilder
    private var syntaxHelpSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    syntaxRow("title.search:neural network", "Search in titles")
                    syntaxRow("abstract.search:climate", "Search in abstracts")
                    syntaxRow("authorships.author.display_name.search:Einstein", "Author name")
                    syntaxRow("publication_year:2020-2024", "Year range")
                    syntaxRow("open_access.is_oa:true", "Open access only")
                    syntaxRow("cited_by_count:>100", "Minimum citations")
                    syntaxRow("type:article", "Work type")
                }
                .font(.system(.caption, design: .monospaced))

                Divider()
                    .padding(.vertical, 4)

                Text("Operators: AND, OR, NOT (must be uppercase)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } label: {
            Label("Query Syntax Help", systemImage: "questionmark.circle")
                .font(.subheadline)
        }
    }

    private func syntaxRow(_ example: String, _ description: String) -> some View {
        HStack {
            Text(example)
                .foregroundStyle(.primary)
            Spacer()
            Text(description)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var isFormEmpty: Bool {
        searchViewModel.openAlexFormState.isEmpty
    }

    private func clearForm() {
        searchViewModel.openAlexFormState.clear()
    }

    private func performSearch() {
        guard !isFormEmpty else { return }

        let state = searchViewModel.openAlexFormState
        let query = buildQuery(from: state)
        searchViewModel.query = query
        // Ensure OpenAlex is selected as the source
        searchViewModel.selectedSourceIDs = ["openalex"]
        Task {
            await searchViewModel.search()
        }
    }

    private func buildQuery(from state: OpenAlexFormState) -> String {
        var parts: [String] = []

        // Main search text
        if !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(state.searchText)
        }

        // Year filter
        if let yearFrom = state.yearFrom, let yearTo = state.yearTo {
            parts.append("publication_year:\(yearFrom)-\(yearTo)")
        } else if let yearFrom = state.yearFrom {
            parts.append("publication_year:>\(yearFrom - 1)")
        } else if let yearTo = state.yearTo {
            parts.append("publication_year:<\(yearTo + 1)")
        }

        // Work type
        if state.workType != .any {
            parts.append("type:\(state.workType.rawValue)")
        }

        // OA status
        switch state.oaStatus {
        case .any:
            break
        case .openOnly:
            parts.append("open_access.is_oa:true")
        default:
            parts.append("open_access.oa_status:\(state.oaStatus.rawValue)")
        }

        // Boolean filters
        if state.hasDOI {
            parts.append("has_doi:true")
        }
        if state.hasAbstract {
            parts.append("has_abstract:true")
        }
        if state.hasPDF {
            parts.append("has_pdf_url:true")
        }

        // Minimum citations
        if let minCitations = state.minCitations, minCitations > 0 {
            parts.append("cited_by_count:>\(minCitations - 1)")
        }

        return parts.joined(separator: " ")
    }
}

#elseif os(iOS)

// MARK: - OpenAlex Search Form View (iOS)

public struct OpenAlexSearchFormView: View {

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    public init() {}

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        Form {
            Section("Search") {
                TextField("Title, abstract, author...", text: $viewModel.openAlexFormState.searchText)
            }

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

            Section("Open Access") {
                Picker("OA Status", selection: $viewModel.openAlexFormState.oaStatus) {
                    ForEach(OpenAlexOAStatusFilter.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
            }

            Section("Requirements") {
                Toggle("Has DOI", isOn: $viewModel.openAlexFormState.hasDOI)
                Toggle("Has Abstract", isOn: $viewModel.openAlexFormState.hasAbstract)
                Toggle("Has PDF", isOn: $viewModel.openAlexFormState.hasPDF)
            }

            Section {
                Button("Search") {
                    performSearch()
                }
                .disabled(searchViewModel.openAlexFormState.isEmpty)

                Button("Clear", role: .destructive) {
                    searchViewModel.openAlexFormState.clear()
                }
            }
        }
        .navigationTitle("OpenAlex Search")
        .task {
            searchViewModel.setLibraryManager(libraryManager)
        }
    }

    private var isFormEmpty: Bool {
        searchViewModel.openAlexFormState.isEmpty
    }

    private func performSearch() {
        guard !isFormEmpty else { return }

        let state = searchViewModel.openAlexFormState
        let query = buildQuery(from: state)
        searchViewModel.query = query
        // Ensure OpenAlex is selected as the source
        searchViewModel.selectedSourceIDs = ["openalex"]
        Task {
            await searchViewModel.search()
        }
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
