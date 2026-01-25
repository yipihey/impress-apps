//
//  HelpSidebarView.swift
//  PublicationManagerCore
//
//  Sidebar view for help category navigation.
//

import SwiftUI

/// Sidebar view for navigating help categories and documents.
public struct HelpSidebarView: View {

    // MARK: - Properties

    @Bindable var viewModel: HelpBrowserViewModel
    var onSearchTap: () -> Void

    // MARK: - Initialization

    public init(viewModel: HelpBrowserViewModel, onSearchTap: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onSearchTap = onSearchTap
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Search button
            searchButton
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Category list
            List(selection: $viewModel.selectedDocumentID) {
                ForEach(viewModel.visibleCategories, id: \.self) { category in
                    categorySection(category)
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier(AccessibilityID.Help.sidebar)

            // Developer docs toggle
            #if os(macOS)
            Divider()
            developerDocsToggle
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            #endif
        }
    }

    // MARK: - Search Button

    private var searchButton: some View {
        Button(action: onSearchTap) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Search Help")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("?")
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(searchButtonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Help.searchField)
    }

    private var searchButtonBackground: some ShapeStyle {
        #if os(macOS)
        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        #else
        return AnyShapeStyle(Color(.secondarySystemBackground))
        #endif
    }

    // MARK: - Category Section

    private func categorySection(_ category: HelpCategory) -> some View {
        Section(isExpanded: Binding(
            get: { viewModel.isCategoryExpanded(category) },
            set: { _ in viewModel.toggleCategory(category) }
        )) {
            ForEach(viewModel.visibleDocuments(for: category)) { document in
                documentRow(document)
            }
        } header: {
            categoryHeader(category)
        }
        .accessibilityIdentifier(AccessibilityID.Help.categorySection(category))
    }

    private func categoryHeader(_ category: HelpCategory) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.iconName)
                .font(.caption)
            Text(category.rawValue)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Document Row

    private func documentRow(_ document: HelpDocument) -> some View {
        HStack {
            Text(document.title)
                .lineLimit(1)

            if document.isDeveloperDoc {
                Spacer()
                Text("DEV")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
        }
        .tag(document.id)
        .accessibilityIdentifier(AccessibilityID.Help.sidebarDocument(document.id))
    }

    // MARK: - Developer Docs Toggle

    private var developerDocsToggle: some View {
        Toggle(isOn: $viewModel.showDeveloperDocs) {
            HStack {
                Image(systemName: "building.columns")
                    .foregroundStyle(.secondary)
                Text("Show Developer Docs")
                    .font(.caption)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Preview

#Preview {
    HelpSidebarView(
        viewModel: HelpBrowserViewModel(),
        onSearchTap: {}
    )
    .frame(width: 250, height: 500)
}
