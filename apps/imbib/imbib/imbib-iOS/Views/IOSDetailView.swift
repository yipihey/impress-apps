//
//  IOSDetailView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "detail")

/// Tab selection for iOS detail view.
enum IOSDetailTab: String, CaseIterable {
    case info
    case bibtex
    case pdf
    case notes

    var label: String {
        switch self {
        case .info: return "Info"
        case .bibtex: return "BibTeX"
        case .pdf: return "PDF"
        case .notes: return "Notes"
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .bibtex: return "doc.text"
        case .pdf: return "doc.richtext"
        case .notes: return "note.text"
        }
    }
}

/// iOS detail view showing publication information with tabbed interface.
///
/// Matches macOS DetailView with 4 tabs: Info, BibTeX, PDF, Notes.
struct DetailView: View {
    let publication: CDPublication
    let libraryID: UUID
    let listID: ListViewID?
    @Binding var selectedPublication: CDPublication?

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: IOSDetailTab = .info
    @State private var isPDFFullscreen: Bool = false

    init?(publication: CDPublication, libraryID: UUID, selectedPublication: Binding<CDPublication?>, listID: ListViewID? = nil) {
        guard !publication.isDeleted, publication.managedObjectContext != nil else {
            return nil
        }
        self.publication = publication
        self.libraryID = libraryID
        self.listID = listID
        self._selectedPublication = selectedPublication
    }

    var body: some View {
        Group {
            if isPDFFullscreen {
                // Fullscreen PDF - no tab bar, no navigation bar
                IOSPDFTab(publication: publication, libraryID: libraryID, isFullscreen: $isPDFFullscreen)
            } else {
                // Normal tabbed view
                TabView(selection: $selectedTab) {
                    IOSInfoTab(publication: publication, libraryID: libraryID)
                        .tabItem { Label(IOSDetailTab.info.label, systemImage: IOSDetailTab.info.icon) }
                        .tag(IOSDetailTab.info)
                        .accessibilityIdentifier(AccessibilityID.Detail.Tabs.info)

                    IOSBibTeXTab(publication: publication)
                        .tabItem { Label(IOSDetailTab.bibtex.label, systemImage: IOSDetailTab.bibtex.icon) }
                        .tag(IOSDetailTab.bibtex)
                        .accessibilityIdentifier(AccessibilityID.Detail.Tabs.bibtex)

                    IOSPDFTab(publication: publication, libraryID: libraryID, isFullscreen: $isPDFFullscreen)
                        .tabItem { Label(IOSDetailTab.pdf.label, systemImage: IOSDetailTab.pdf.icon) }
                        .tag(IOSDetailTab.pdf)
                        .accessibilityIdentifier(AccessibilityID.Detail.Tabs.pdf)

                    IOSNotesTab(publication: publication)
                        .tabItem { Label(IOSDetailTab.notes.label, systemImage: IOSDetailTab.notes.icon) }
                        .tag(IOSDetailTab.notes)
                        .accessibilityIdentifier(AccessibilityID.Detail.Tabs.notes)
                }
            }
        }
        .navigationTitle(isPDFFullscreen ? "" : (publication.title ?? "Details"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPDFFullscreen)
        .toolbar(isPDFFullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !isPDFFullscreen {
                ToolbarItem(placement: .topBarTrailing) {
                    moreMenu
                }
            }
        }
        .task(id: publication.id) {
            // Auto-mark as read after brief delay (Apple Mail style)
            await autoMarkAsRead()
        }
        .onChange(of: selectedTab) { _, newTab in
            // Post notification when tab changes so parent can update search context
            NotificationCenter.default.post(
                name: .detailTabDidChange,
                object: nil,
                userInfo: ["tab": newTab.rawValue]
            )
        }
        .onAppear {
            // Post initial tab state
            NotificationCenter.default.post(
                name: .detailTabDidChange,
                object: nil,
                userInfo: ["tab": selectedTab.rawValue]
            )
        }
        .onDisappear {
            // Clear persisted state to prevent loadState() from re-selecting on view reload
            // Note: We do NOT set selectedPublication = nil here because:
            // 1. onDisappear can fire during push animations, not just pops
            // 2. navigationDestination(item:) automatically manages the binding when user taps back
            if let listID = listID {
                Task {
                    await ListViewStateStore.shared.clearSelection(for: listID)
                }
            }
        }
    }

    // MARK: - Auto-Mark as Read

    private func autoMarkAsRead() async {
        guard !publication.isRead else { return }

        // Wait 1 second before marking as read (like Mail)
        do {
            try await Task.sleep(for: .seconds(1))
            await libraryViewModel.markAsRead(publication)
            logger.debug("Auto-marked as read: \(publication.citeKey)")
        } catch {
            // Task was cancelled (user navigated away quickly)
        }
    }

    // MARK: - Navigation

    private func goBack() {
        // Use dismiss to pop navigation (same as swipe gesture)
        // Also clear selection to keep state in sync
        dismiss()
        selectedPublication = nil
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        Menu {
            Button {
                toggleReadStatus()
            } label: {
                Label(
                    publication.isRead ? "Mark as Unread" : "Mark as Read",
                    systemImage: publication.isRead ? "envelope.badge" : "envelope.open"
                )
            }

            Button {
                copyBibTeX()
            } label: {
                Label("Copy BibTeX", systemImage: "doc.on.doc")
            }

            Button {
                copyCiteKey()
            } label: {
                Label("Copy Cite Key", systemImage: "key")
            }

            Divider()

            if let doi = publication.doi {
                Button {
                    openURL("https://doi.org/\(doi)")
                } label: {
                    Label("Open DOI", systemImage: "arrow.up.right.square")
                }
            }

            if let arxivID = publication.arxivID {
                Button {
                    openURL("https://arxiv.org/abs/\(arxivID)")
                } label: {
                    Label("Open arXiv", systemImage: "arrow.up.right.square")
                }
            }

            if let bibcode = publication.bibcode {
                Button {
                    openURL("https://ui.adsabs.harvard.edu/abs/\(bibcode)")
                } label: {
                    Label("Open ADS", systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Actions

    private func toggleReadStatus() {
        Task {
            await libraryViewModel.toggleReadStatus(publication)
        }
    }

    private func copyBibTeX() {
        Task {
            await libraryViewModel.copyToClipboard([publication.id])
        }
    }

    private func copyCiteKey() {
        UIPasteboard.general.string = publication.citeKey
    }

    private func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            _ = FileManager_Opener.shared.openURL(url)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        if let view = DetailView(
            publication: CDPublication(),
            libraryID: UUID(),
            selectedPublication: .constant(nil)
        ) {
            view
                .environment(LibraryViewModel())
                .environment(LibraryManager())
        }
    }
}
