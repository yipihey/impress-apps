//
//  VagueMemorySearchFormView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import SwiftUI

#if os(macOS)

/// A fun "Vague Memory Search" form that helps astronomers find papers from
/// imperfect memories, inspired by Neal Dalal's wish.
///
/// Features:
/// - Decade picker with overlap buffers for fuzzy time matching
/// - Natural language topic input with synonym expansion
/// - Fuzzy author matching (e.g., "starts with R")
/// - Easter egg header with the inspiring quote
public struct VagueMemorySearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var showingQueryPreview = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Easter egg header with Neal's screenshot
                headerWithEasterEgg

                Divider()

                // Decade picker
                decadePickerSection

                // Custom year range (alternative to decade)
                customYearSection

                // Vague topic memory field
                topicMemorySection

                // Optional author hint field
                authorHintSection

                // Max results
                maxResultsSection

                // Query preview
                queryPreviewSection

                Divider()

                // Action buttons
                actionButtons
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            searchViewModel.setLibraryManager(libraryManager)
        }
    }

    // MARK: - Header with Easter Egg

    @ViewBuilder
    private var headerWithEasterEgg: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            Label("Vague Memory Search", systemImage: "brain.head.profile")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Find papers from your imperfect memories")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Neal Dalal's inspiring quote as an image
            if let image = loadEasterEggImage() {
                VStack(alignment: .leading, spacing: 4) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 500)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

                    Text("The inspiration for this feature")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
                .padding(.top, 8)
            } else {
                // Fallback if image can't be loaded
                VStack(alignment: .leading, spacing: 4) {
                    Text("\"if someone writes a version that can translate my vague 'hmm was there some paper in the 1970s on something related?' into an actual ADS reference, that will change all of our lives.\"")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)

                    Text("- Neal Dalal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Load the Neal Dalal quote image from bundle resources
    private func loadEasterEggImage() -> Image? {
        guard let url = Bundle.module.url(forResource: "neal_dalal_quote", withExtension: "jpg"),
              let nsImage = NSImage(contentsOf: url) else {
            return nil
        }
        return Image(nsImage: nsImage)
    }

    // MARK: - Decade Picker Section

    @ViewBuilder
    private var decadePickerSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("When was it published?")
                .font(.headline)

            Text("Select a decade (or use custom years below)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Grid of decade buttons
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(Decade.allCases) { decade in
                    Button {
                        if viewModel.vagueMemoryFormState.selectedDecade == decade {
                            viewModel.vagueMemoryFormState.selectedDecade = nil
                        } else {
                            viewModel.vagueMemoryFormState.selectedDecade = decade
                            // Clear custom years when selecting a decade
                            viewModel.vagueMemoryFormState.customYearFrom = nil
                            viewModel.vagueMemoryFormState.customYearTo = nil
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(decade.displayName)
                                .font(.body)
                                .fontWeight(viewModel.vagueMemoryFormState.selectedDecade == decade ? .semibold : .regular)
                            Text("\(decade.exactYearRange.start)-\(decade.exactYearRange.end)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            viewModel.vagueMemoryFormState.selectedDecade == decade
                                ? Color.accentColor.opacity(0.2)
                                : Color.secondary.opacity(0.1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let decade = viewModel.vagueMemoryFormState.selectedDecade {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Searching \(decade.yearRange.start)-\(decade.yearRange.end) (with buffer for fuzzy matching)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Custom Year Section

    @ViewBuilder
    private var customYearSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Or specify exact years")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("From:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("year", value: $viewModel.vagueMemoryFormState.customYearFrom, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: viewModel.vagueMemoryFormState.customYearFrom) { _, _ in
                            // Clear decade when using custom years
                            if viewModel.vagueMemoryFormState.customYearFrom != nil {
                                viewModel.vagueMemoryFormState.selectedDecade = nil
                            }
                        }
                }

                HStack(spacing: 4) {
                    Text("To:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("year", value: $viewModel.vagueMemoryFormState.customYearTo, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: viewModel.vagueMemoryFormState.customYearTo) { _, _ in
                            // Clear decade when using custom years
                            if viewModel.vagueMemoryFormState.customYearTo != nil {
                                viewModel.vagueMemoryFormState.selectedDecade = nil
                            }
                        }
                }

                Spacer()

                if viewModel.vagueMemoryFormState.customYearFrom != nil || viewModel.vagueMemoryFormState.customYearTo != nil {
                    Button("Clear") {
                        viewModel.vagueMemoryFormState.customYearFrom = nil
                        viewModel.vagueMemoryFormState.customYearTo = nil
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Topic Memory Section

    @ViewBuilder
    private var topicMemorySection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("What was it about?")
                .font(.headline)

            Text("Describe what you remember - it can be vague!")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.vagueMemoryFormState.vagueMemory)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if viewModel.vagueMemoryFormState.vagueMemory.isEmpty {
                        Text("e.g., \"something about galaxy rotation curves and dark matter\"")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            // Example suggestions
            VStack(alignment: .leading, spacing: 4) {
                Text("Examples:")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    exampleChip("galaxy rotation")
                    exampleChip("dark matter halos")
                    exampleChip("CMB anisotropy")
                    exampleChip("quasar variability")
                }
            }
        }
    }

    @ViewBuilder
    private func exampleChip(_ text: String) -> some View {
        @Bindable var viewModel = searchViewModel

        Button {
            if viewModel.vagueMemoryFormState.vagueMemory.isEmpty {
                viewModel.vagueMemoryFormState.vagueMemory = text
            } else {
                viewModel.vagueMemoryFormState.vagueMemory += " \(text)"
            }
        } label: {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Author Hint Section

    @ViewBuilder
    private var authorHintSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Remember the author?")
                .font(.headline)

            Text("Even a partial name or first letter helps")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("e.g., \"Rubin\", \"starts with R\", or \"R\"", text: $viewModel.vagueMemoryFormState.authorHint)
                .textFieldStyle(.roundedBorder)

            // Hint about what's supported
            HStack {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.yellow)
                Text("Try: full names, partial names, \"starts with X\", or just a first letter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Max Results Section

    @ViewBuilder
    private var maxResultsSection: some View {
        @Bindable var viewModel = searchViewModel

        VStack(alignment: .leading, spacing: 8) {
            Text("Maximum Results")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                TextField("", value: $viewModel.vagueMemoryFormState.maxResults, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                Text("(vague searches need more results)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Query Preview Section

    @ViewBuilder
    private var queryPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Search Preview")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button {
                    showingQueryPreview.toggle()
                } label: {
                    Image(systemName: showingQueryPreview ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Human-readable preview
            Text(VagueMemoryQueryBuilder.generatePreview(from: searchViewModel.vagueMemoryFormState))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Expandable raw query
            if showingQueryPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ADS Query:")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Text(VagueMemoryQueryBuilder.buildQuery(from: searchViewModel.vagueMemoryFormState))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.blue)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            Button("Clear") {
                searchViewModel.vagueMemoryFormState.clear()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                performSearch()
            } label: {
                Label("Search ADS", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(searchViewModel.vagueMemoryFormState.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Actions

    private func performSearch() {
        let query = VagueMemoryQueryBuilder.buildQuery(from: searchViewModel.vagueMemoryFormState)

        searchViewModel.query = query
        // Always use ADS for this search
        searchViewModel.selectedSourceIDs = ["ads"]

        // Set editFormType to track max results from this form
        searchViewModel.editFormType = .vagueMemory

        Task {
            await searchViewModel.search()
        }
    }
}

#elseif os(iOS)

/// iOS version of the Vague Memory Search form
public struct VagueMemorySearchFormView: View {

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    public init() {}

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        Form {
            // Header section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find papers from your imperfect memories")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("\"if someone writes a version that can translate my vague 'hmm was there some paper in the 1970s on something related?' into an actual ADS reference, that will change all of our lives.\"")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.tertiary)

                    Text("- Neal Dalal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Decade picker
            Section("When was it published?") {
                Picker("Decade", selection: $viewModel.vagueMemoryFormState.selectedDecade) {
                    Text("Any time").tag(nil as Decade?)
                    ForEach(Decade.allCases) { decade in
                        Text(decade.displayName).tag(decade as Decade?)
                    }
                }

                if viewModel.vagueMemoryFormState.selectedDecade == nil {
                    HStack {
                        Text("From")
                        Spacer()
                        TextField("year", value: $viewModel.vagueMemoryFormState.customYearFrom, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("To")
                        Spacer()
                        TextField("year", value: $viewModel.vagueMemoryFormState.customYearTo, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
            }

            // Topic memory
            Section("What was it about?") {
                TextEditor(text: $viewModel.vagueMemoryFormState.vagueMemory)
                    .frame(minHeight: 100)

                Text("Describe what you remember - it can be vague!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Author hint
            Section("Remember the author?") {
                TextField("e.g., \"Rubin\", \"starts with R\"", text: $viewModel.vagueMemoryFormState.authorHint)

                Text("Even a partial name or first letter helps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Max results
            Section {
                HStack {
                    Text("Max Results")
                    Spacer()
                    TextField("100", value: $viewModel.vagueMemoryFormState.maxResults, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } footer: {
                Text("Vague searches benefit from more results")
            }

            // Actions
            Section {
                Button {
                    performSearch()
                } label: {
                    HStack {
                        Spacer()
                        Label("Search ADS", systemImage: "magnifyingglass")
                        Spacer()
                    }
                }
                .disabled(viewModel.vagueMemoryFormState.isEmpty)

                Button("Clear", role: .destructive) {
                    viewModel.vagueMemoryFormState.clear()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Vague Memory Search")
        .task {
            searchViewModel.setLibraryManager(libraryManager)
        }
    }

    private func performSearch() {
        let query = VagueMemoryQueryBuilder.buildQuery(from: searchViewModel.vagueMemoryFormState)

        searchViewModel.query = query
        searchViewModel.selectedSourceIDs = ["ads"]
        searchViewModel.editFormType = .vagueMemory

        Task {
            await searchViewModel.search()
        }
    }
}

#endif
