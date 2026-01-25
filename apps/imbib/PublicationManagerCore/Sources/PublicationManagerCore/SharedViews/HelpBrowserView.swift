//
//  HelpBrowserView.swift
//  PublicationManagerCore
//
//  Main NavigationSplitView for browsing help documentation.
//

import SwiftUI

/// Main help browser view with sidebar navigation and document display.
public struct HelpBrowserView: View {

    // MARK: - State

    @State private var viewModel = HelpBrowserViewModel()
    @State private var showSearchPalette = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        NavigationSplitView {
            HelpSidebarView(
                viewModel: viewModel,
                onSearchTap: { showSearchPalette = true }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier(AccessibilityID.Help.window)
        .task {
            await viewModel.loadIndex()
        }
        .onChange(of: viewModel.selectedDocumentID) { _, newID in
            if let id = newID {
                viewModel.selectDocument(id: id)
            }
        }
        .sheet(isPresented: $showSearchPalette) {
            HelpSearchPaletteView(
                isPresented: $showSearchPalette,
                onSelect: { documentID in
                    viewModel.selectDocument(id: documentID)
                }
            )
        }
        // Keyboard shortcuts
        .onKeyPress(.escape) {
            if showSearchPalette {
                showSearchPalette = false
                return .handled
            }
            return .ignored
        }
        #if os(macOS)
        .onKeyPress("/") {
            showSearchPalette = true
            return .handled
        }
        #endif
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let document = viewModel.selectedDocument {
            HelpDocumentView(
                document: document,
                content: viewModel.currentContent
            )
            .id(document.id)
            .toolbar {
                #if os(macOS)
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        viewModel.selectPreviousDocument()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canNavigatePrevious)
                    .accessibilityIdentifier(AccessibilityID.Help.backButton)

                    Button {
                        viewModel.selectNextDocument()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canNavigateNext)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSearchPalette = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("/", modifiers: [])
                }
                #endif
            }
        } else {
            HelpWelcomeView {
                viewModel.selectDocument(id: "getting-started")
            }
        }
    }

    // MARK: - Navigation State

    private var canNavigatePrevious: Bool {
        guard let document = viewModel.selectedDocument,
              let docs = viewModel.documentsByCategory[document.category],
              let index = docs.firstIndex(where: { $0.id == document.id }) else {
            return false
        }
        return index > 0
    }

    private var canNavigateNext: Bool {
        guard let document = viewModel.selectedDocument,
              let docs = viewModel.documentsByCategory[document.category],
              let index = docs.firstIndex(where: { $0.id == document.id }) else {
            return false
        }
        return index + 1 < docs.count
    }
}

// MARK: - Preview

#Preview {
    HelpBrowserView()
        .frame(width: 900, height: 700)
}
