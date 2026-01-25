//
//  HelpSearchPaletteView.swift
//  PublicationManagerCore
//
//  Command palette for searching help documentation.
//

import SwiftUI

/// A command palette overlay for searching help documentation.
///
/// Displays a centered modal with:
/// - Auto-focused search field
/// - Scrollable results list
/// - Keyboard navigation (arrow keys, Enter, Escape)
/// - Match type badges (Title, Keyword, Content, Related)
public struct HelpSearchPaletteView: View {

    // MARK: - Bindings

    @Binding var isPresented: Bool

    /// Callback when a document is selected
    var onSelect: (String) -> Void

    // MARK: - State

    @State private var viewModel = HelpSearchViewModel()
    @FocusState private var isSearchFieldFocused: Bool

    // MARK: - Initialization

    public init(
        isPresented: Binding<Bool>,
        onSelect: @escaping (String) -> Void
    ) {
        self._isPresented = isPresented
        self.onSelect = onSelect
    }

    // MARK: - Body

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
            // Keyboard handlers at container level
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
            isSearchFieldFocused = true
        }
        .accessibilityIdentifier(AccessibilityID.Help.searchPalette)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)

            TextField("Search help...", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    selectCurrentResult()
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
        .accessibilityIdentifier(AccessibilityID.Help.searchResults)
    }

    private func resultRow(result: HelpSearchResult, index: Int) -> some View {
        let isSelected = index == viewModel.selectedIndex

        return Button {
            onSelect(result.documentID)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // Category badge
                    HStack(spacing: 4) {
                        Image(systemName: result.category.iconName)
                            .font(.caption2)
                        Text(result.category.rawValue)
                            .font(.caption2)
                    }
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)

                    // Title
                    Text(result.documentTitle)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    // Snippet
                    if let snippet = result.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption)
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
        .accessibilityIdentifier(AccessibilityID.Help.searchResult(index))
    }

    private func matchTypeBadge(_ matchType: HelpSearchMatchType, isSelected: Bool) -> some View {
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

    private func badgeBackground(for matchType: HelpSearchMatchType, isSelected: Bool) -> some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.white.opacity(0.2))
        }

        switch matchType {
        case .title:
            return AnyShapeStyle(Color.blue.opacity(0.15))
        case .keyword:
            return AnyShapeStyle(Color.green.opacity(0.15))
        case .content:
            return AnyShapeStyle(Color.orange.opacity(0.15))
        case .semantic:
            return AnyShapeStyle(Color.purple.opacity(0.15))
        }
    }

    private func badgeForegroundColor(for matchType: HelpSearchMatchType) -> Color {
        switch matchType {
        case .title:
            return .blue
        case .keyword:
            return .green
        case .content:
            return .orange
        case .semantic:
            return .purple
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
        VStack(spacing: 8) {
            Image(systemName: "book.pages")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Search help documentation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Type keywords or describe what you're looking for")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No results found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Try different keywords")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func dismiss() {
        isPresented = false
        viewModel.clear()
    }

    private func selectCurrentResult() {
        if let result = viewModel.selectedResult {
            onSelect(result.documentID)
            dismiss()
        }
    }

    // MARK: - Layout Constants

    private var paletteWidth: CGFloat {
        #if os(macOS)
        return 600
        #else
        return UIScreen.main.bounds.width - 40
        #endif
    }

    private var paletteHeight: CGFloat {
        #if os(macOS)
        return 400
        #else
        return UIScreen.main.bounds.height * 0.6
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
    HelpSearchPaletteView(
        isPresented: .constant(true),
        onSelect: { _ in }
    )
}
