//
//  ArXivAdvancedSearchView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-15.
//

import SwiftUI

#if os(macOS)

// MARK: - arXiv Advanced Search Form View

/// Form-only view for the detail pane (right side)
/// Results are shown in the middle pane via SearchResultsListView
public struct ArXivAdvancedSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Local State (not persisted)

    @State private var expandedGroups: Set<String> = []
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
                    Label("arXiv Advanced Search", systemImage: "text.magnifyingglass")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Multi-field search with category filters")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Search Terms Section
                searchTermsSection

                // Query assistance feedback
                if !queryAssistanceViewModel.isEmpty {
                    QueryAssistanceView(viewModel: queryAssistanceViewModel)
                }

                // Categories Section
                categoriesSection

                // Date Filter Section
                dateFilterSection

                // Options Section
                optionsSection

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
                        // Edit mode: Save button
                        Button("Save") {
                            searchViewModel.saveToSmartSearch()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFormEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    } else {
                        // Normal mode: Search button only
                        Button("Search") {
                            performSearch()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFormEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier(AccessibilityID.Search.searchButton)
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            searchViewModel.setLibraryManager(libraryManager)
            // Initialize query assistance for arXiv
            queryAssistanceViewModel.setSource(.arxiv)
            await QueryAssistanceService.shared.register(ArXivQueryAssistant())
        }
        .onChange(of: searchViewModel.arxivFormState.searchTerms) { _, _ in
            updateQueryAssistance()
        }
        .onChange(of: searchViewModel.arxivFormState.selectedCategories) { _, _ in
            updateQueryAssistance()
        }
    }

    // MARK: - Query Assistance

    /// Update query assistance with the current built query
    private func updateQueryAssistance() {
        let state = searchViewModel.arxivFormState
        let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(
            searchTerms: state.searchTerms,
            categories: state.selectedCategories,
            includeCrossListed: state.includeCrossListed,
            dateFilter: state.dateFilter,
            sortBy: state.sortBy
        )
        queryAssistanceViewModel.updateQuery(query)
    }

    // MARK: - Search Terms Section

    @ViewBuilder
    private var searchTermsSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Search Terms")
                .font(.headline)

            ForEach(viewModel.arxivFormState.searchTerms.indices, id: \.self) { index in
                ArXivSearchTermRow(
                    term: $viewModel.arxivFormState.searchTerms[index],
                    isFirst: index == 0,
                    onDelete: {
                        if viewModel.arxivFormState.searchTerms.count > 1 {
                            viewModel.arxivFormState.searchTerms.remove(at: index)
                        }
                    }
                )
            }

            Button {
                viewModel.arxivFormState.searchTerms.append(ArXivSearchTerm())
            } label: {
                Label("Add another term", systemImage: "plus.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Categories Section

    @ViewBuilder
    private var categoriesSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Subject Categories")
                .font(.headline)

            ArXivCategoryPickerView(
                selectedCategories: $viewModel.arxivFormState.selectedCategories,
                expandedGroups: $expandedGroups
            )

            Toggle("Include cross-listed papers", isOn: $viewModel.arxivFormState.includeCrossListed)
                .toggleStyle(.checkbox)
                .font(.subheadline)

            // Quick actions for categories
            HStack {
                Button("Clear All") {
                    viewModel.arxivFormState.selectedCategories.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Date Filter Section

    @ViewBuilder
    private var dateFilterSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Date Filter")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                // All dates
                RadioButton(
                    isSelected: isAllDates,
                    label: "All dates"
                ) {
                    viewModel.arxivFormState.dateFilter = .allDates
                }

                // Past 12 months
                RadioButton(
                    isSelected: isPastMonths,
                    label: "Past 12 months"
                ) {
                    viewModel.arxivFormState.dateFilter = .pastMonths(12)
                }

                // Specific year
                HStack {
                    RadioButton(
                        isSelected: isSpecificYear,
                        label: "Specific year:"
                    ) {
                        viewModel.arxivFormState.dateFilter = .specificYear(Calendar.current.component(.year, from: Date()))
                    }

                    if case .specificYear(let year) = viewModel.arxivFormState.dateFilter {
                        TextField("", value: Binding(
                            get: { year },
                            set: { viewModel.arxivFormState.dateFilter = .specificYear($0) }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    }
                }

                // Date range
                HStack {
                    RadioButton(
                        isSelected: isDateRange,
                        label: "Date range:"
                    ) {
                        viewModel.arxivFormState.dateFilter = .dateRange(from: nil, to: nil)
                    }

                    if case .dateRange(let from, let to) = viewModel.arxivFormState.dateFilter {
                        DatePicker(
                            "From",
                            selection: Binding(
                                get: { from ?? Date() },
                                set: { viewModel.arxivFormState.dateFilter = .dateRange(from: $0, to: to) }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .frame(width: 100)

                        Text("to")
                            .foregroundStyle(.secondary)

                        DatePicker(
                            "To",
                            selection: Binding(
                                get: { to ?? Date() },
                                set: { viewModel.arxivFormState.dateFilter = .dateRange(from: from, to: $0) }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Options Section

    @ViewBuilder
    private var optionsSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Options")
                .font(.headline)

            HStack(spacing: 20) {
                HStack {
                    Text("Sort by:")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $viewModel.arxivFormState.sortBy) {
                        ForEach(ArXivSortBy.allCases, id: \.self) { sort in
                            Text(sort.displayName).tag(sort)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                HStack {
                    Text("Results:")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $viewModel.arxivFormState.resultsPerPage) {
                        Text("25").tag(25)
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("200").tag(200)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
            }

            HStack {
                Text("Max Results:")
                    .foregroundStyle(.secondary)
                TextField("default", value: $viewModel.arxivFormState.maxResults, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("(0 = use default)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helper Properties

    private var isFormEmpty: Bool {
        searchViewModel.arxivFormState.isEmpty
    }

    private var isAllDates: Bool {
        if case .allDates = searchViewModel.arxivFormState.dateFilter {
            return true
        }
        return false
    }

    private var isPastMonths: Bool {
        if case .pastMonths = searchViewModel.arxivFormState.dateFilter {
            return true
        }
        return false
    }

    private var isSpecificYear: Bool {
        if case .specificYear = searchViewModel.arxivFormState.dateFilter {
            return true
        }
        return false
    }

    private var isDateRange: Bool {
        if case .dateRange = searchViewModel.arxivFormState.dateFilter {
            return true
        }
        return false
    }

    // MARK: - Actions

    private func performSearch() {
        guard !isFormEmpty else { return }

        let state = searchViewModel.arxivFormState
        let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(
            searchTerms: state.searchTerms,
            categories: state.selectedCategories,
            includeCrossListed: state.includeCrossListed,
            dateFilter: state.dateFilter,
            sortBy: state.sortBy
        )

        searchViewModel.query = query
        // Use arXiv source for this search
        searchViewModel.selectedSourceIDs = ["arxiv"]

        Task {
            await searchViewModel.search()
        }
    }

    private func clearForm() {
        searchViewModel.arxivFormState.clear()
    }
}

// MARK: - Category Picker View

struct ArXivCategoryPickerView: View {
    @Binding var selectedCategories: Set<String>
    @Binding var expandedGroups: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ArXivCategories.groups) { group in
                categoryGroupView(for: group)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func categoryGroupView(for group: ArXivCategoryGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedGroups.contains(group.id) },
                set: { isExpanded in
                    if isExpanded {
                        expandedGroups.insert(group.id)
                    } else {
                        expandedGroups.remove(group.id)
                    }
                }
            )
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 4) {
                ForEach(group.categories) { category in
                    categoryToggle(for: category)
                }
            }
            .padding(.leading, 16)
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(group.name)
                    .font(.subheadline)
                let count = selectedCount(in: group)
                if count > 0 {
                    Text("(\(count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryToggle(for category: ArXivCategory) -> some View {
        Toggle(isOn: Binding(
            get: { selectedCategories.contains(category.id) },
            set: { isSelected in
                if isSelected {
                    selectedCategories.insert(category.id)
                } else {
                    selectedCategories.remove(category.id)
                }
            }
        )) {
            Text(category.id)
                .font(.caption)
        }
        .toggleStyle(.checkbox)
        .help(category.name)
    }

    private func selectedCount(in group: ArXivCategoryGroup) -> Int {
        group.categories.filter { selectedCategories.contains($0.id) }.count
    }
}

// MARK: - Search Term Row

struct ArXivSearchTermRow: View {
    @Binding var term: ArXivSearchTerm
    let isFirst: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Logic operator (hidden for first term)
            if !isFirst {
                Picker("", selection: $term.logicOperator) {
                    ForEach(ArXivLogicOperator.allCases, id: \.self) { op in
                        Text(op.displayName).tag(op)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            } else {
                // Placeholder to maintain alignment
                Color.clear
                    .frame(width: 100)
            }

            // Field selector
            Picker("", selection: $term.field) {
                ForEach(ArXivSearchField.allCases, id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            // Search term text
            TextField("Search term", text: $term.term)
                .textFieldStyle(.roundedBorder)

            // Delete button (disabled if only one term)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isFirst)
            .opacity(isFirst ? 0.3 : 1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Radio Button

struct RadioButton: View {
    let isSelected: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(label)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

#elseif os(iOS)

// MARK: - iOS arXiv Advanced Search Form View

/// iOS form for arXiv advanced multi-field search
public struct ArXivAdvancedSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Local State

    @State private var expandedGroups: Set<String> = []
    @State private var queryAssistanceViewModel = QueryAssistanceViewModel()

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        Form {
            // Search Terms Section
            Section("Search Terms") {
                ForEach(viewModel.arxivFormState.searchTerms.indices, id: \.self) { index in
                    IOSArXivSearchTermRow(
                        term: $viewModel.arxivFormState.searchTerms[index],
                        isFirst: index == 0,
                        onDelete: {
                            if viewModel.arxivFormState.searchTerms.count > 1 {
                                viewModel.arxivFormState.searchTerms.remove(at: index)
                            }
                        }
                    )
                }

                Button {
                    viewModel.arxivFormState.searchTerms.append(ArXivSearchTerm())
                } label: {
                    Label("Add another term", systemImage: "plus.circle")
                }

                // Query assistance feedback (inline in form)
                if !queryAssistanceViewModel.isEmpty {
                    QueryAssistanceView(viewModel: queryAssistanceViewModel, showPreview: true, maxIssues: 2)
                }
            }

            // Categories Section
            Section("Subject Categories") {
                IOSArXivCategoryPickerView(
                    selectedCategories: $viewModel.arxivFormState.selectedCategories,
                    expandedGroups: $expandedGroups
                )

                Toggle("Include cross-listed papers", isOn: $viewModel.arxivFormState.includeCrossListed)

                if !viewModel.arxivFormState.selectedCategories.isEmpty {
                    Text("\(viewModel.arxivFormState.selectedCategories.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Date Filter Section
            Section("Date Filter") {
                Picker("Date Range", selection: Binding(
                    get: { dateFilterSelection },
                    set: { applyDateFilter($0) }
                )) {
                    Text("All dates").tag(0)
                    Text("Past 12 months").tag(1)
                    Text("Specific year").tag(2)
                    Text("Date range").tag(3)
                }

                if case .specificYear(let year) = viewModel.arxivFormState.dateFilter {
                    Stepper("Year: \(year)", value: Binding(
                        get: { year },
                        set: { viewModel.arxivFormState.dateFilter = .specificYear($0) }
                    ), in: 1991...Calendar.current.component(.year, from: Date()))
                }

                if case .dateRange(let from, let to) = viewModel.arxivFormState.dateFilter {
                    DatePicker("From", selection: Binding(
                        get: { from ?? Date() },
                        set: { viewModel.arxivFormState.dateFilter = .dateRange(from: $0, to: to) }
                    ), displayedComponents: .date)

                    DatePicker("To", selection: Binding(
                        get: { to ?? Date() },
                        set: { viewModel.arxivFormState.dateFilter = .dateRange(from: from, to: $0) }
                    ), displayedComponents: .date)
                }
            }

            // Options Section
            Section("Options") {
                Picker("Sort by", selection: $viewModel.arxivFormState.sortBy) {
                    ForEach(ArXivSortBy.allCases, id: \.self) { sort in
                        Text(sort.displayName).tag(sort)
                    }
                }

                Picker("Results", selection: $viewModel.arxivFormState.resultsPerPage) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                }

                HStack {
                    Text("Max Results")
                    Spacer()
                    TextField("default", value: $viewModel.arxivFormState.maxResults, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
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

            // Action Buttons
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
                    searchViewModel.arxivFormState.clear()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("arXiv Advanced")
        .task {
            searchViewModel.setLibraryManager(libraryManager)
            // Initialize query assistance for arXiv
            queryAssistanceViewModel.setSource(.arxiv)
            await QueryAssistanceService.shared.register(ArXivQueryAssistant())
        }
        .onChange(of: searchViewModel.arxivFormState.searchTerms) { _, _ in
            updateQueryAssistance()
        }
        .onChange(of: searchViewModel.arxivFormState.selectedCategories) { _, _ in
            updateQueryAssistance()
        }
    }

    // MARK: - Query Assistance

    /// Update query assistance with the current built query
    private func updateQueryAssistance() {
        let state = searchViewModel.arxivFormState
        let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(
            searchTerms: state.searchTerms,
            categories: state.selectedCategories,
            includeCrossListed: state.includeCrossListed,
            dateFilter: state.dateFilter,
            sortBy: state.sortBy
        )
        queryAssistanceViewModel.updateQuery(query)
    }

    // MARK: - Helper Properties

    private var isFormEmpty: Bool {
        searchViewModel.arxivFormState.isEmpty
    }

    private var dateFilterSelection: Int {
        switch searchViewModel.arxivFormState.dateFilter {
        case .allDates: return 0
        case .pastMonths: return 1
        case .specificYear: return 2
        case .dateRange: return 3
        }
    }

    private func applyDateFilter(_ selection: Int) {
        switch selection {
        case 0: searchViewModel.arxivFormState.dateFilter = .allDates
        case 1: searchViewModel.arxivFormState.dateFilter = .pastMonths(12)
        case 2: searchViewModel.arxivFormState.dateFilter = .specificYear(Calendar.current.component(.year, from: Date()))
        case 3: searchViewModel.arxivFormState.dateFilter = .dateRange(from: nil, to: nil)
        default: break
        }
    }

    // MARK: - Actions

    private func performSearch() {
        guard !isFormEmpty else { return }

        let state = searchViewModel.arxivFormState
        let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(
            searchTerms: state.searchTerms,
            categories: state.selectedCategories,
            includeCrossListed: state.includeCrossListed,
            dateFilter: state.dateFilter,
            sortBy: state.sortBy
        )

        searchViewModel.query = query
        searchViewModel.selectedSourceIDs = ["arxiv"]

        Task {
            await searchViewModel.search()
        }
    }
}

// MARK: - iOS Search Term Row

struct IOSArXivSearchTermRow: View {
    @Binding var term: ArXivSearchTerm
    let isFirst: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isFirst {
                Picker("Logic", selection: $term.logicOperator) {
                    ForEach(ArXivLogicOperator.allCases, id: \.self) { op in
                        Text(op.displayName).tag(op)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Picker("Field", selection: $term.field) {
                    ForEach(ArXivSearchField.allCases, id: \.self) { field in
                        Text(field.displayName).tag(field)
                    }
                }
                .frame(width: 100)

                TextField("Search term", text: $term.term)
                    .textFieldStyle(.roundedBorder)

                if !isFirst {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - iOS Category Picker View

struct IOSArXivCategoryPickerView: View {
    @Binding var selectedCategories: Set<String>
    @Binding var expandedGroups: Set<String>

    var body: some View {
        ForEach(ArXivCategories.groups) { group in
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedGroups.contains(group.id) },
                    set: { isExpanded in
                        if isExpanded {
                            expandedGroups.insert(group.id)
                        } else {
                            expandedGroups.remove(group.id)
                        }
                    }
                )
            ) {
                ForEach(group.categories) { category in
                    Toggle(isOn: Binding(
                        get: { selectedCategories.contains(category.id) },
                        set: { isSelected in
                            if isSelected {
                                selectedCategories.insert(category.id)
                            } else {
                                selectedCategories.remove(category.id)
                            }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(category.id)
                                .font(.subheadline)
                            Text(category.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(group.name)
                    let count = group.categories.filter { selectedCategories.contains($0.id) }.count
                    if count > 0 {
                        Text("(\(count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if !selectedCategories.isEmpty {
            Button("Clear All Categories", role: .destructive) {
                selectedCategories.removeAll()
            }
        }
    }
}

#endif  // os(macOS/iOS)
