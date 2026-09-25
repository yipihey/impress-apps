//
//  HelpBrowserView.swift
//  PublicationManagerCore
//
//  Main NavigationSplitView for browsing help documentation.
//

import SwiftUI

/// Help ▸ Search Help… (⇧⌘?) opens the Help window and then asks for its
/// search palette — but a window that was closed has no view to hear the
/// post yet, which is why the menu item did nothing until 2026-09-25. The
/// menu leaves a request here first; the browser takes it when it appears,
/// or on the post when it is already open.
@MainActor
public enum HelpSearchPaletteRequest {
    private static var pending = false

    /// Called by the menu item before it opens the window and posts.
    public static func request() { pending = true }

    /// True once per request.
    public static func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

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
        .onAppear { showPaletteIfRequested(via: "window opened") }
        .onReceive(NotificationCenter.default.publisher(for: .showHelpSearchPalette)) { _ in
            showPaletteIfRequested(via: "window already open")
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

    /// Help ▸ Search Help…: raise the palette (its field takes focus on
    /// appear) if the menu asked for it.
    private func showPaletteIfRequested(via route: String) {
        guard HelpSearchPaletteRequest.consume() else { return }
        logInfo("Help ▸ Search Help: palette shown (\(route))", category: "help")
        showSearchPalette = true
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
