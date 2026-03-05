//
//  NLSearchOverlayView.swift
//  PublicationManagerCore
//
//  Spotlight-like overlay for natural language search powered by Apple Foundation Models.
//  Translates plain English into ADS/SciX queries and auto-executes.
//

import SwiftUI
import OSLog

#if os(macOS)

// MARK: - NL Search Overlay View

/// A Spotlight-style overlay that accepts natural language search descriptions,
/// translates them into ADS query syntax using the on-device Foundation Model,
/// and auto-executes the search.
///
/// Triggered by Cmd+S. Results appear in the Exploration section of the sidebar,
/// following the same flow as other search forms.
public struct NLSearchOverlayView: View {

    // MARK: - Bindings

    @Binding var isPresented: Bool

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var nlService = NLSearchService()
    @State private var inputText = ""
    @State private var editableQuery = ""
    @State private var isEditingQuery = false
    @FocusState private var isInputFocused: Bool
    @FocusState private var isQueryFieldFocused: Bool

    // MARK: - Initialization

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Main panel
            VStack(spacing: 0) {
                // Header
                headerBar

                Divider()

                // Input field
                inputField

                // State-dependent content
                stateContent
            }
            .frame(width: 600, idealHeight: dynamicHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
            .onKeyPress(.return) {
                if isInputFocused && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submitNaturalLanguage()
                    return .handled
                } else if isQueryFieldFocused {
                    reExecuteQuery()
                    return .handled
                }
                return .ignored
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
        }
        .onDisappear {
            nlService.reset()
        }
    }

    // MARK: - Dynamic Height

    private var dynamicHeight: CGFloat {
        switch nlService.state {
        case .idle: return 140
        case .thinking: return 180
        case .translated: return 260
        case .searching: return 200
        case .complete: return 200
        case .error: return 220
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)

            Text("Smart Search")
                .font(.headline)

            Spacer()

            if NLSearchService.isAvailable {
                Label("On-Device AI", systemImage: "apple.intelligence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Keyword Fallback", systemImage: "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Input Field

    @ViewBuilder
    private var inputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)

            TextField(
                "Describe what you're looking for...",
                text: $inputText
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($isInputFocused)
            .onSubmit {
                submitNaturalLanguage()
            }

            if nlService.state.isWorking {
                ProgressView()
                    .controlSize(.small)
            } else if !inputText.isEmpty {
                Button {
                    inputText = ""
                    nlService.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - State Content

    @ViewBuilder
    private var stateContent: some View {
        switch nlService.state {
        case .idle:
            idleHints

        case .thinking:
            thinkingView

        case .translated(let query, let interpretation, let estimatedCount):
            translatedView(query: query, interpretation: interpretation, estimatedCount: estimatedCount)

        case .searching:
            searchingView

        case .complete(let query, let resultCount):
            completeView(query: query, resultCount: resultCount)

        case .error(let message):
            errorView(message: message)
        }
    }

    // MARK: - Idle Hints

    @ViewBuilder
    private var idleHints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try:")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                exampleChip("papers on dark energy by Riess since 2020")
                exampleChip("galaxy rotation curves 1970s")
            }
            HStack(spacing: 8) {
                exampleChip("CMB anisotropy refereed")
                exampleChip("recent JWST deep field observations")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func exampleChip(_ text: String) -> some View {
        Button {
            inputText = text
            submitNaturalLanguage()
        } label: {
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Thinking View

    @ViewBuilder
    private var thinkingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.regular)
            Text("Translating to ADS query...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Translated View

    @ViewBuilder
    private func translatedView(query: String, interpretation: String, estimatedCount: UInt32?) -> some View {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            // Interpretation
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(interpretation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Estimated count badge (from scix_count)
                if let count = estimatedCount {
                    Text("~\(count) results")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                        .foregroundStyle(.blue)
                }
            }

            // Generated query (editable)
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)

                TextField("ADS Query", text: $editableQuery)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($isQueryFieldFocused)
                    .onSubmit { reExecuteQuery() }

                Button("Search") {
                    reExecuteQuery()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(8)
            .background(Color.blue.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Conversation hint
            if nlService.conversationTurnCount > 0 {
                Text("Type to refine: \"narrow to refereed\" or \"also by Perlmutter\"")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Press Enter to search, or edit the query above")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear {
            editableQuery = query
            // Auto-execute the search
            autoExecuteSearch(query: query)
        }
    }

    // MARK: - Searching View

    @ViewBuilder
    private var searchingView: some View {
        Divider()

        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.regular)

            Text("Searching SciX/ADS...")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(nlService.lastGeneratedQuery)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Complete View

    @ViewBuilder
    private func completeView(query: String, resultCount: Int) -> some View {
        Divider()

        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                if resultCount > 0 {
                    Text("\(resultCount) papers found")
                        .font(.callout)
                        .fontWeight(.medium)
                } else {
                    Text("No results found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(query)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(2)

            if resultCount > 0 {
                Text("Results are in the Exploration section — type to refine further")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Try rephrasing or broadening your search")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(message: String) -> some View {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Translation failed")
                    .font(.callout)
                    .fontWeight(.medium)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack {
                Button("Try Again") {
                    let query = inputText
                    Task { await nlService.translate(query) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Search as Keywords") {
                    // Fall back to raw text search
                    let query = inputText
                    searchViewModel.query = query
                    searchViewModel.selectedSourceIDs = ["ads"]
                    searchViewModel.editFormType = .nlSearch
                    let vm = searchViewModel
                    Task { await vm.search() }
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func submitNaturalLanguage() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Capture before Task
        Task {
            let _ = await nlService.translate(text)
        }
    }

    private func executeSearch(query: String) {
        nlService.markSearching()

        searchViewModel.query = query
        searchViewModel.selectedSourceIDs = ["ads"]
        searchViewModel.editFormType = .nlSearch

        // Capture before Task
        let vm = searchViewModel
        let manager = libraryManager
        Task {
            await vm.search()

            // Count results from the Last Search collection
            var count = 0
            if let collection = manager.getOrCreateLastSearchCollection() {
                count = RustStoreAdapter.shared.countPublications(
                    for: .collection(collection.id)
                )
            }
            await nlService.markComplete(resultCount: count)

            // Navigate to the search results in the sidebar
            await MainActor.run {
                NotificationCenter.default.post(name: .lastSearchUpdated, object: nil)
            }
        }
    }

    private func autoExecuteSearch(query: String) {
        executeSearch(query: query)
    }

    private func reExecuteQuery() {
        let query = editableQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        executeSearch(query: query)
    }

    private func dismiss() {
        isPresented = false
    }
}

#endif
