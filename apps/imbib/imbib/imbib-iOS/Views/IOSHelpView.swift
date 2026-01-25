//
//  IOSHelpView.swift
//  imbib-iOS
//
//  iOS-specific view for browsing help documentation.
//

import SwiftUI
import PublicationManagerCore

/// iOS help view presented as a sheet from Settings.
///
/// Uses a NavigationStack for the navigation pattern on iOS.
struct IOSHelpView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var viewModel = HelpBrowserViewModel()
    @State private var showSearchPalette = false
    @State private var navigationPath = NavigationPath()

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            helpList
                .navigationTitle("Help")
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(for: HelpDocument.self) { document in
                    IOSHelpDocumentView(document: document)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
        .task {
            await viewModel.loadIndex()
        }
        .sheet(isPresented: $showSearchPalette) {
            searchPaletteSheet
        }
    }

    // MARK: - Subviews

    private var helpList: some View {
        List {
            // Quick actions
            Section {
                Button {
                    showSearchPalette = true
                } label: {
                    Label("Search Help", systemImage: "magnifyingglass")
                }
            }

            // Categories
            ForEach(viewModel.visibleCategories, id: \.self) { category in
                categorySection(for: category)
            }

            // Developer docs toggle
            Section {
                Toggle(isOn: $viewModel.showDeveloperDocs) {
                    Label("Developer Documentation", systemImage: "building.columns")
                }
            }
        }
    }

    private func categorySection(for category: HelpCategory) -> some View {
        Section(category.rawValue) {
            ForEach(viewModel.visibleDocuments(for: category)) { document in
                NavigationLink(value: document) {
                    Label(document.title, systemImage: category.iconName)
                }
            }
        }
    }

    private var searchPaletteSheet: some View {
        HelpSearchPaletteView(
            isPresented: $showSearchPalette,
            onSelect: { documentID in
                navigateToDocument(id: documentID)
            }
        )
        .presentationDetents([.medium, .large])
    }

    // MARK: - Navigation

    private func navigateToDocument(id: String) {
        let allDocuments = viewModel.documentsByCategory.values.flatMap { $0 }
        if let document = allDocuments.first(where: { $0.id == id }) {
            navigationPath.append(document)
        }
    }
}

/// iOS help document view with scroll and share.
struct IOSHelpDocumentView: View {

    let document: HelpDocument

    @State private var content: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Summary
                if !document.summary.isEmpty {
                    Text(document.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Content (rendered as RichText for markdown support)
                if !content.isEmpty {
                    RichTextView(content: content, mode: .markdown)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding()
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            content = await HelpIndexService.shared.loadContent(for: document)
        }
    }
}

// MARK: - Preview

#Preview {
    IOSHelpView()
}
