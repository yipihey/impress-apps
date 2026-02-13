//
//  GlobalSearchPaletteView.swift
//  PublicationManagerCore
//
//  Command palette UI for global search.
//

import SwiftUI

// MARK: - Global Search Palette View

/// A command palette overlay for global search.
///
/// Displays a centered modal with:
/// - Auto-focused search field
/// - Scrollable results list (max ~10 visible)
/// - Keyboard navigation (arrow keys, Enter, Escape)
/// - Match type badges (Text, Similar, Both)
/// - Search scope indicator (iOS)
public struct GlobalSearchPaletteView: View {

    // MARK: - Bindings

    @Binding var isPresented: Bool

    /// Callback when a publication is selected
    var onSelect: (UUID) -> Void

    /// Callback for PDF search - triggered when context is PDF
    var onPDFSearch: ((String) -> Void)?

    // MARK: - Environment

    @Environment(\.searchContext) private var searchContext
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var viewModel = GlobalSearchViewModel()
    @FocusState private var isSearchFieldFocused: Bool

    // MARK: - Body

    public init(
        isPresented: Binding<Bool>,
        onSelect: @escaping (UUID) -> Void,
        onPDFSearch: ((String) -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.onSelect = onSelect
        self.onPDFSearch = onPDFSearch
    }

    public var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Palette container
            VStack(spacing: 0) {
                // Scope picker (always visible)
                scopePicker

                // Search field
                searchField

                Divider()

                // Results or empty state
                if viewModel.isSearching {
                    loadingView
                } else if viewModel.results.isEmpty {
                    if viewModel.query.isEmpty {
                        emptyPromptView
                    } else {
                        noResultsView
                    }
                } else {
                    resultsList
                }
            }
            .frame(width: paletteWidth, height: paletteHeight)
            .background(paletteBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            // Keyboard handlers at container level so they work regardless of content
            .onKeyPress(.upArrow) {
                viewModel.selectPrevious()
                return .handled
            }
            .onKeyPress(.downArrow) {
                viewModel.selectNext()
                return .handled
            }
            .onKeyPress(.return) {
                selectCurrentResult()
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
        }
        .onAppear {
            // Initialize with global scope (user can narrow via scope picker)
            viewModel.setContext(.global)

            // Delay focus slightly to ensure the view is fully rendered
            // Only focus if the view is actually being presented
            if isPresented {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFieldFocused = true
                }
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)

            TextField(searchPlaceholder, text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    handleSearchSubmit()
                }
                .onChange(of: viewModel.query) { _, _ in
                    // Don't auto-search for PDF context (requires explicit submit)
                    if !viewModel.effectiveContext.isPDFSearch {
                        viewModel.search()
                    }
                }

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            #if os(iOS)
            // Explicit close button for iOS
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        resultRow(result: result, index: index)
                    }
                }
            }
            .onChange(of: viewModel.selectedIndex) { _, newIndex in
                if let result = viewModel.results[safe: newIndex] {
                    proxy.scrollTo(result.id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func resultRow(result: GlobalSearchResult, index: Int) -> some View {
        let isSelected = index == viewModel.selectedIndex

        return Button {
            onSelect(result.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    Text(result.title.isEmpty ? result.citeKey : result.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    // Authors and year
                    HStack(spacing: 8) {
                        Text(result.authors)
                            .lineLimit(1)

                        if let year = result.year {
                            Text("(\(year))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)

                    // Library/collection info
                    if !result.libraryNames.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.caption2)
                            Text(result.libraryNames.joined(separator: ", "))
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.6) : .secondary.opacity(0.7))
                    }

                    // Snippet (if available)
                    if let snippet = result.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Match type badge
                matchTypeBadge(result.matchType, isSelected: isSelected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(result.id)
    }

    private func matchTypeBadge(_ matchType: GlobalSearchMatchType, isSelected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: matchType.iconName)
                .font(.caption2)
            Text(matchType.label)
                .font(.caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeBackground(for: matchType, isSelected: isSelected))
        .foregroundStyle(isSelected ? .white : badgeForegroundColor(for: matchType))
        .clipShape(Capsule())
    }

    private func badgeBackground(for matchType: GlobalSearchMatchType, isSelected: Bool) -> some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.white.opacity(0.2))
        }

        switch matchType {
        case .fulltext:
            return AnyShapeStyle(Color.blue.opacity(0.15))
        case .semantic:
            return AnyShapeStyle(Color.purple.opacity(0.15))
        case .both:
            return AnyShapeStyle(Color.orange.opacity(0.15))
        }
    }

    private func badgeForegroundColor(for matchType: GlobalSearchMatchType) -> Color {
        switch matchType {
        case .fulltext:
            return .blue
        case .semantic:
            return .purple
        case .both:
            return .orange
        }
    }

    // MARK: - Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Searching...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPromptView: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.effectiveContext.iconName)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(emptyPromptText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Search tips
            VStack(alignment: .leading, spacing: 4) {
                searchTip("gevolution", "partial words match automatically")
                searchTip("dark matter", "AND by default (both words must match)")
                searchTip("dark OR matter", "match either term")
                searchTip("\"dark matter\"", "exact phrase")
                searchTip("title:gevolution", "search specific field (title, authors, abstract)")
                searchTip("cosmo*", "wildcard prefix")
                searchTip("-excluded", "exclude a term")
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func searchTip(_ query: String, _ description: String) -> some View {
        HStack(spacing: 6) {
            Text(query)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 160, alignment: .trailing)
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyPromptText: String {
        switch viewModel.effectiveContext {
        case .global:
            return "Search across all your papers"
        case .library(_, let name):
            return "Search in \(name)"
        case .collection(_, let name):
            return "Search in \(name)"
        case .smartSearch(_, let name):
            return "Search in \(name)"
        case .publication(_, _):
            return "Search in this paper"
        case .pdf(_, _):
            return "Search in PDF"
        }
    }

    // MARK: - Scope Picker

    private var scopePicker: some View {
        HStack(spacing: 8) {
            Text("Search in:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                // All Papers (Global)
                Button {
                    viewModel.selectScope(.global)
                } label: {
                    Label("All Papers", systemImage: "magnifyingglass")
                }

                Divider()

                // Libraries section
                ForEach(libraryManager.libraries, id: \.id) { library in
                    libraryMenu(for: library)
                }

                // Smart searches section
                smartSearchesSection
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.effectiveContext.iconName)
                    Text(viewModel.effectiveContext.displayName)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            // Sort menu
            sortMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Sort Menu

    private var sortMenu: some View {
        Menu {
            ForEach(GlobalSearchSortOrder.allCases) { order in
                Button {
                    if viewModel.sortOrder == order {
                        // Same order selected - toggle direction
                        viewModel.sortAscending.toggle()
                    } else {
                        // Different order - set new order with default direction
                        viewModel.sortOrder = order
                        viewModel.sortAscending = order.defaultAscending
                    }
                    viewModel.resortResults()
                } label: {
                    HStack {
                        Label(order.displayName, systemImage: order.iconName)
                        Spacer()
                        if viewModel.sortOrder == order {
                            Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text(viewModel.sortOrder.displayName)
                Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .help("Change sort order (click again to reverse)")
    }

    /// Menu for a single library with its collections
    @ViewBuilder
    private func libraryMenu(for library: LibraryModel) -> some View {
        let collections = RustStoreAdapter.shared.listCollections(libraryId: library.id)
            .filter { !$0.isSmart }
            .sorted { $0.name < $1.name }

        if collections.isEmpty {
            // No collections - just a button
            Button {
                viewModel.selectScope(.library(library.id, library.name))
            } label: {
                Label(library.name, systemImage: "books.vertical")
            }
        } else {
            // Has collections - show as submenu
            Menu(library.name) {
                Button {
                    viewModel.selectScope(.library(library.id, library.name))
                } label: {
                    Label("All in \(library.name)", systemImage: "books.vertical")
                }

                Divider()

                ForEach(collections, id: \.id) { collection in
                    Button {
                        viewModel.selectScope(.collection(collection.id, collection.name))
                    } label: {
                        Label(collection.name, systemImage: "folder")
                    }
                }
            }
        }
    }

    /// Smart searches section for the scope picker
    @ViewBuilder
    private var smartSearchesSection: some View {
        let allSmartSearches: [(SmartSearch, LibraryModel)] = libraryManager.libraries.flatMap { library -> [(SmartSearch, LibraryModel)] in
            let searches = SmartSearchRepository.shared.smartSearches(for: library.id)
            return searches.map { ($0, library) }
        }
        .sorted { $0.0.name < $1.0.name }

        if !allSmartSearches.isEmpty {
            Divider()

            ForEach(allSmartSearches, id: \.0.id) { smartSearch, _ in
                Button {
                    viewModel.selectScope(.smartSearch(smartSearch.id, smartSearch.name))
                } label: {
                    Label(smartSearch.name, systemImage: "sparkle.magnifyingglass")
                }
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No results found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Try different keywords or a broader search")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func dismiss() {
        isPresented = false
        // Don't clear the search - keep query and results for next Cmd+K
        // User can clear explicitly with the X button in the search field
    }

    private func selectCurrentResult() {
        if let result = viewModel.selectedResult {
            onSelect(result.id)
            dismiss()
        }
    }

    private func handleSearchSubmit() {
        // For PDF context, trigger PDF search callback
        if viewModel.effectiveContext.isPDFSearch {
            if let callback = onPDFSearch, !viewModel.query.isEmpty {
                callback(viewModel.query)
                dismiss()
            }
        } else {
            // Normal behavior - select current result
            selectCurrentResult()
        }
    }

    private var searchPlaceholder: String {
        switch viewModel.effectiveContext {
        case .pdf:
            return "Search in PDF..."
        case .publication:
            return "Search in paper..."
        case .library(_, let name):
            return "Search in \(name)..."
        case .collection(_, let name):
            return "Search in \(name)..."
        default:
            return "Search papers..."
        }
    }

    // MARK: - Layout Constants

    private var paletteWidth: CGFloat {
        #if os(macOS)
        return 700
        #else
        return UIScreen.main.bounds.width - 40
        #endif
    }

    private var paletteHeight: CGFloat {
        #if os(macOS)
        return 600
        #else
        return UIScreen.main.bounds.height * 0.7
        #endif
    }

    private var paletteBackground: some ShapeStyle {
        #if os(macOS)
        return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        #else
        return AnyShapeStyle(Color(.systemBackground))
        #endif
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Preview

#Preview {
    GlobalSearchPaletteView(
        isPresented: .constant(true),
        onSelect: { _ in }
    )
    .environment(LibraryManager())
}
