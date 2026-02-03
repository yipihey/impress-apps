//
//  OpenAlexAutocompleteView.swift
//  PublicationManagerCore
//
//  Autocomplete dropdown component for OpenAlex search.
//  Shows suggestions grouped by entity type with keyboard navigation.
//

import SwiftUI

// MARK: - Autocomplete View Model

/// View model for managing OpenAlex autocomplete state.
@MainActor
@Observable
public final class OpenAlexAutocompleteViewModel {

    // MARK: - Properties

    /// Current autocomplete suggestions grouped by type.
    public private(set) var suggestions: OpenAlexAutocompleteService.GroupedSuggestions?

    /// Whether suggestions are being fetched.
    public private(set) var isLoading = false

    /// Error message if autocomplete fails.
    public private(set) var errorMessage: String?

    /// Currently selected suggestion index (for keyboard navigation).
    public var selectedIndex: Int = -1

    /// The current query being autocompleted.
    private var currentQuery: String = ""

    /// Task for debouncing autocomplete requests.
    private var debounceTask: Task<Void, Never>?

    /// The autocomplete service.
    private let service = OpenAlexAutocompleteService.shared

    /// Debounce delay in milliseconds.
    private let debounceDelayMs: UInt64 = 300

    // MARK: - Computed Properties

    /// All suggestions in a flat list for keyboard navigation.
    public var allSuggestions: [OpenAlexAutocompleteSuggestion] {
        guard let suggestions = suggestions else { return [] }
        return suggestions.authors + suggestions.institutions + suggestions.sources + suggestions.topics
    }

    /// Whether there are any suggestions to show.
    public var hasSuggestions: Bool {
        !(suggestions?.isEmpty ?? true)
    }

    /// The currently selected suggestion.
    public var selectedSuggestion: OpenAlexAutocompleteSuggestion? {
        guard selectedIndex >= 0, selectedIndex < allSuggestions.count else {
            return nil
        }
        return allSuggestions[selectedIndex]
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Update the query and fetch new suggestions.
    public func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        // Only autocomplete if we're at the end of a word that looks like a partial entity name
        // Don't autocomplete if the query ends with a filter separator (colon)
        guard !trimmed.isEmpty,
              !trimmed.hasSuffix(":"),
              trimmed.count >= 2 else {
            clear()
            return
        }

        // Extract the last "word" for autocompletion
        // If the user is typing in a filter value, don't autocomplete
        let lastPart = extractAutocompleteCandidate(from: trimmed)
        guard lastPart.count >= 2 else {
            clear()
            return
        }

        currentQuery = lastPart

        // Cancel previous task
        debounceTask?.cancel()

        // Start new debounced task
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: debounceDelayMs * 1_000_000)

                guard !Task.isCancelled else { return }

                isLoading = true
                errorMessage = nil

                let results = try await service.autocompleteMultiple(query: lastPart, maxPerType: 4)

                guard !Task.isCancelled else { return }

                suggestions = results
                selectedIndex = -1
                isLoading = false

            } catch is CancellationError {
                // Ignore cancellation
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    /// Clear all suggestions.
    public func clear() {
        debounceTask?.cancel()
        suggestions = nil
        selectedIndex = -1
        isLoading = false
        errorMessage = nil
        currentQuery = ""
    }

    /// Move selection up.
    public func selectPrevious() {
        guard !allSuggestions.isEmpty else { return }
        if selectedIndex > 0 {
            selectedIndex -= 1
        } else {
            selectedIndex = allSuggestions.count - 1
        }
    }

    /// Move selection down.
    public func selectNext() {
        guard !allSuggestions.isEmpty else { return }
        if selectedIndex < allSuggestions.count - 1 {
            selectedIndex += 1
        } else {
            selectedIndex = 0
        }
    }

    // MARK: - Private Methods

    /// Extract the part of the query that should be autocompleted.
    private func extractAutocompleteCandidate(from query: String) -> String {
        // If query contains a colon, check if we're in a filter value
        if let colonRange = query.range(of: ":", options: .backwards) {
            let afterColon = String(query[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            // If there's nothing after the colon or it's quoted, don't autocomplete
            if afterColon.isEmpty || afterColon.hasPrefix("\"") {
                return ""
            }

            // If the filter field is a known search field, autocomplete the value
            let beforeColon = query[..<colonRange.lowerBound].split(separator: " ").last ?? ""
            let field = String(beforeColon).lowercased()

            // Only autocomplete for certain fields
            if field.contains("author") || field.contains("institution") ||
               field.contains("source") || field.contains("topic") {
                return afterColon
            }

            // For other fields (like year, type, etc.), don't autocomplete
            return ""
        }

        // No colon - this is plain text search
        // Use the entire query for autocomplete (like OpenAlex website does)
        // This helps with author names like "Tom Abel" or "Risa H. Wechsler"
        return query
    }
}

// MARK: - Autocomplete Dropdown View

/// Dropdown view showing autocomplete suggestions.
public struct OpenAlexAutocompleteDropdown: View {

    @Bindable var viewModel: OpenAlexAutocompleteViewModel
    let onSelect: (OpenAlexAutocompleteSuggestion) -> Void

    public init(viewModel: OpenAlexAutocompleteViewModel, onSelect: @escaping (OpenAlexAutocompleteSuggestion) -> Void) {
        self.viewModel = viewModel
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if let suggestions = viewModel.suggestions, !suggestions.isEmpty {
                suggestionsList(suggestions)
            }
        }
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Searching...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Suggestions List

    @ViewBuilder
    private func suggestionsList(_ suggestions: OpenAlexAutocompleteService.GroupedSuggestions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !suggestions.authors.isEmpty {
                    sectionHeader("Authors", icon: "person.fill")
                    ForEach(suggestions.authors) { suggestion in
                        suggestionRow(suggestion, type: .authors)
                    }
                }

                if !suggestions.institutions.isEmpty {
                    sectionHeader("Institutions", icon: "building.2.fill")
                    ForEach(suggestions.institutions) { suggestion in
                        suggestionRow(suggestion, type: .institutions)
                    }
                }

                if !suggestions.sources.isEmpty {
                    sectionHeader("Journals & Sources", icon: "books.vertical.fill")
                    ForEach(suggestions.sources) { suggestion in
                        suggestionRow(suggestion, type: .sources)
                    }
                }

                if !suggestions.topics.isEmpty {
                    sectionHeader("Topics", icon: "tag.fill")
                    ForEach(suggestions.topics) { suggestion in
                        suggestionRow(suggestion, type: .topics)
                    }
                }
            }
        }
        .frame(maxHeight: 300)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Suggestion Row

    private func suggestionRow(_ suggestion: OpenAlexAutocompleteSuggestion, type: OpenAlexEntityType) -> some View {
        let isSelected = viewModel.selectedSuggestion?.id == suggestion.id

        return Button {
            onSelect(suggestion)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.displayName)
                        .font(.callout)
                        .lineLimit(1)

                    if let hint = suggestion.hint, !hint.isEmpty {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Stats
                if let worksCount = suggestion.worksCount, worksCount > 0 {
                    Text(formatCount(worksCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? selectedBackground : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var backgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    private var selectedBackground: Color {
        Color.accentColor.opacity(0.15)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return "\(count / 1_000_000)M works"
        } else if count >= 1_000 {
            return "\(count / 1_000)K works"
        }
        return "\(count) works"
    }
}

// MARK: - Compact Autocomplete Badge

/// A compact badge showing autocomplete is available.
public struct AutocompleteBadge: View {

    let hasResults: Bool

    public init(hasResults: Bool) {
        self.hasResults = hasResults
    }

    public var body: some View {
        if hasResults {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(.blue)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Autocomplete Dropdown") {
    VStack {
        Text("Autocomplete Preview")
            .padding(.bottom, 20)

        // This would need actual viewModel setup in a real preview
        OpenAlexAutocompleteDropdown(
            viewModel: OpenAlexAutocompleteViewModel(),
            onSelect: { _ in }
        )
        .frame(width: 300)
    }
    .padding()
}
#endif
