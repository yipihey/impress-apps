//
//  NLSearchOverlayView.swift
//  PublicationManagerCore
//
//  Spotlight-like overlay for natural language search powered by Apple Foundation Models.
//  Translates plain English into ADS/SciX queries for review and execution.
//

import SwiftUI
import OSLog

#if os(macOS)

// MARK: - NL Search Overlay View

/// A Spotlight-style overlay that accepts natural language search descriptions
/// and translates them into ADS query syntax using the on-device Foundation Model.
/// The user reviews the translated query and presses Enter/Search to execute.
///
/// Triggered by Cmd+S. Results appear in the Exploration section of the sidebar,
/// following the same flow as other search forms.
public struct NLSearchOverlayView: View {

    // MARK: - Bindings

    @Binding var isPresented: Bool

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(NLSearchService.self) private var nlService

    // MARK: - State

    @State private var inputText = ""
    @State private var editableQuery = ""
    @State private var isEditingQuery = false
    @State private var translationTask: Task<Void, Never>?
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

                // Source, max results, refereed options
                optionsBar

                Divider()

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
            // Don't fully reset — preserve results so user can re-open and refine.
            // A new conversation will start on next translate() call.
            nlService.startNewConversation()
        }
    }

    // MARK: - Dynamic Height

    private var dynamicHeight: CGFloat {
        let optionsHeight: CGFloat = 36  // options bar + divider
        switch nlService.state {
        case .idle: return 140 + optionsHeight
        case .thinking: return 180 + optionsHeight
        case .translated: return 260 + optionsHeight
        case .searching: return 200 + optionsHeight
        case .complete: return 200 + optionsHeight
        case .error: return 240 + optionsHeight
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

    // MARK: - Options Bar

    @ViewBuilder
    private var optionsBar: some View {
        @Bindable var service = nlService

        HStack(spacing: 12) {
            // Source pills
            HStack(spacing: 4) {
                sourcePill("ADS", id: "ads")
                sourcePill("arXiv", id: "arxiv")
                sourcePill("OpenAlex", id: "openalex")
            }

            Divider()
                .frame(height: 16)

            // Max results
            HStack(spacing: 4) {
                Text("Max:")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: $service.maxResults) {
                    Text("Default").tag(0)
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .frame(width: 70)
            }

            Divider()
                .frame(height: 16)

            // Refereed toggle
            Toggle(isOn: $service.refereedOnly) {
                Text("Refereed")
                    .font(.caption2)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func sourcePill(_ label: String, id: String) -> some View {
        let isSelected = nlService.selectedSourceIDs.contains(id)
        Button {
            if isSelected && nlService.selectedSourceIDs.count > 1 {
                nlService.selectedSourceIDs.remove(id)
            } else if !isSelected {
                nlService.selectedSourceIDs.insert(id)
            }
        } label: {
            Text(label)
                .font(.caption2)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                .clipShape(Capsule())
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
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

            HStack(spacing: 8) {
                Button("Try Again") {
                    let text = inputText
                    Task { await nlService.translate(text) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Search as Keywords") {
                    let query = inputText
                    let sourceIDs = nlService.selectedSourceIDs
                    searchViewModel.query = query
                    searchViewModel.selectedSourceIDs = sourceIDs
                    searchViewModel.editFormType = .nlSearch
                    let vm = searchViewModel
                    Task { await vm.search() }
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Open ADS Form") {
                    // Copy input to clipboard and switch to ADS Modern form
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(inputText, forType: .string)
                    dismiss()
                    // Post notification to switch to ADS Modern form
                    NotificationCenter.default.post(
                        name: .switchToSearchForm,
                        object: SearchFormType.adsModern
                    )
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

        // Cancel any in-flight translation before starting a new one
        translationTask?.cancel()
        translationTask = Task {
            let _ = await nlService.translate(text)
        }
    }

    private func executeSearch(query: String) {
        nlService.markSearching()

        searchViewModel.query = query
        searchViewModel.selectedSourceIDs = nlService.selectedSourceIDs
        searchViewModel.nlSearchMaxResults = nlService.maxResults
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

    private func reExecuteQuery() {
        let query = editableQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        executeSearch(query: query)
    }

    private func dismiss() {
        translationTask?.cancel()
        translationTask = nil
        isPresented = false
    }
}

#endif
