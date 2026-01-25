//
//  ArXivCategoryBrowser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI

// MARK: - ArXiv Category Browser

/// A view for browsing and following arXiv categories.
///
/// Users can browse categories organized by group, search for specific categories,
/// and create smart searches to follow categories in their Inbox.
public struct ArXivCategoryBrowser: View {

    // MARK: - Properties

    /// Callback when user wants to follow a category
    public let onFollow: (ArXivCategory, String) -> Void

    /// Callback to dismiss the browser
    public let onDismiss: () -> Void

    // MARK: - State

    @State private var searchText: String = ""
    @State private var expandedGroups: Set<String> = []
    @State private var selectedCategory: ArXivCategory?
    @State private var feedName: String = ""
    @State private var showingFollowSheet: Bool = false

    // MARK: - Initialization

    public init(
        onFollow: @escaping (ArXivCategory, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onFollow = onFollow
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search field
                searchField
                    .padding()

                Divider()

                // Category list
                List {
                    // Suggested categories section
                    if searchText.isEmpty {
                        suggestedSection
                    }

                    // Filtered or all categories
                    ForEach(filteredGroups) { group in
                        categoryGroupSection(group)
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("Browse arXiv Categories")
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 500)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
            .sheet(isPresented: $showingFollowSheet) {
                if let category = selectedCategory {
                    followSheet(for: category)
                }
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search categories...", text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Suggested Section

    private var suggestedSection: some View {
        Section("Suggested for AI/ML") {
            ForEach(ArXivCategories.suggestedML) { category in
                categoryRow(category)
            }
        }
    }

    // MARK: - Category Group Section

    private func categoryGroupSection(_ group: ArXivCategoryGroup) -> some View {
        Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedGroups.contains(group.id) || !searchText.isEmpty },
                    set: { isExpanded in
                        if isExpanded {
                            expandedGroups.insert(group.id)
                        } else {
                            expandedGroups.remove(group.id)
                        }
                    }
                )
            ) {
                ForEach(filteredCategories(in: group)) { category in
                    categoryRow(category)
                }
            } label: {
                Label {
                    Text(group.name)
                        .font(.headline)
                } icon: {
                    Image(systemName: group.iconName)
                }
            }
        }
    }

    // MARK: - Category Row

    private func categoryRow(_ category: ArXivCategory) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(category.id)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)

                    Text(category.name)
                        .foregroundStyle(.secondary)
                }

                if let description = category.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button {
                selectedCategory = category
                feedName = "arXiv \(category.id)"
                showingFollowSheet = true
            } label: {
                Label("Follow", systemImage: "plus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Follow Sheet

    private func followSheet(for category: ArXivCategory) -> some View {
        NavigationStack {
            Form {
                Section("Category") {
                    HStack {
                        Text(category.id)
                            .font(.system(.title3, design: .monospaced))
                            .fontWeight(.semibold)
                        Spacer()
                        Text(category.name)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Feed Name") {
                    TextField("Name", text: $feedName)
                }

                if let description = category.description {
                    Section("Description") {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Follow Category")
            #if os(macOS)
            .frame(width: 350, height: 300)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingFollowSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Follow") {
                        onFollow(category, feedName)
                        showingFollowSheet = false
                        onDismiss()
                    }
                    .disabled(feedName.isEmpty)
                }
            }
        }
    }

    // MARK: - Filtering

    private var filteredGroups: [ArXivCategoryGroup] {
        if searchText.isEmpty {
            return ArXivCategories.groups
        }

        return ArXivCategories.groups.filter { group in
            !filteredCategories(in: group).isEmpty
        }
    }

    private func filteredCategories(in group: ArXivCategoryGroup) -> [ArXivCategory] {
        if searchText.isEmpty {
            return group.categories
        }

        let query = searchText.lowercased()
        return group.categories.filter { category in
            category.id.lowercased().contains(query) ||
            category.name.lowercased().contains(query) ||
            (category.description?.lowercased().contains(query) ?? false)
        }
    }
}

// MARK: - Preview

#Preview("Category Browser") {
    ArXivCategoryBrowser(
        onFollow: { category, name in
            print("Follow \(category.id) as '\(name)'")
        },
        onDismiss: {
            print("Dismissed")
        }
    )
}
