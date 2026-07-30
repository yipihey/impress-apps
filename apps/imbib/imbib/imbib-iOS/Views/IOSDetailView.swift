//
//  IOSDetailView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore

// The file-scope `logger` went with `autoMarkAsRead`, whose only log line it
// carried; the shell lifecycle it moved to is PMC's
// `publicationDetailLifecycle`.

/// iOS detail view showing publication information with tabbed interface.
///
/// Matches macOS DetailView with 4 tabs: Info, PDF, Notes, BibTeX.
/// Uses RustStoreAdapter for all data access (no Core Data).
struct DetailView: View {
    let publicationID: UUID
    let libraryID: UUID
    let listID: ListViewID?
    @Binding var selectedPublicationID: UUID?

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: DetailTab = .info
    @State private var isPDFFullscreen: Bool = false
    @State private var publication: PublicationModel?

    init(publicationID: UUID, libraryID: UUID, selectedPublicationID: Binding<UUID?>, listID: ListViewID? = nil) {
        self.publicationID = publicationID
        self.libraryID = libraryID
        self.listID = listID
        self._selectedPublicationID = selectedPublicationID
    }

    // MARK: - Declarative tab set

    /// The publication kind's tabs, for this paper.
    ///
    /// iOS used to list four `Tab`s inline — a second truth table beside
    /// macOS's literal array, which is how the two shells drift about which
    /// tabs exist and in which order. `isEditable` is `true` because this view
    /// is only reachable for a LIBRARY publication (it requires a
    /// `libraryID`), which is the same condition macOS's `canEdit`
    /// (`publicationID != nil`) expresses.
    private var tabContext: RecordTabContext { RecordTabContext(isEditable: true) }

    private var availableTabs: [DetailTab] {
        PublicationRecordKind.descriptor.availableTabs(for: tabContext)
    }

    /// The pane for one tab. A `switch` here is per-tab VIEW construction —
    /// the thing ADR-0021 D2 deliberately keeps hand-written — not a second
    /// statement of which tabs a publication has.
    @ViewBuilder
    private func tabContent(_ tab: DetailTab) -> some View {
        switch tab {
        case .info:
            IOSInfoTab(publicationID: publicationID, libraryID: libraryID)
                .accessibilityIdentifier(AccessibilityID.Detail.Tabs.info)
        case .pdf:
            IOSPDFTab(
                publicationID: publicationID, libraryID: libraryID,
                isFullscreen: $isPDFFullscreen)
                .accessibilityIdentifier(AccessibilityID.Detail.Tabs.pdf)
        case .notes:
            IOSNotesTab(publicationID: publicationID)
                .accessibilityIdentifier(AccessibilityID.Detail.Tabs.notes)
        case .bibtex:
            // The SHARED tab (Stage 5b). `IOSBibTeXTab` was this view with a
            // weaker save path — it looped `updateField` over the parsed
            // entry's fields, so an edited cite key or entry type, or a
            // deleted field, silently did nothing. Deleted.
            if let tab = BibTeXTab(publicationID: publicationID) {
                tab.accessibilityIdentifier(AccessibilityID.Detail.Tabs.bibtex)
            } else {
                ContentUnavailableView(
                    "No BibTeX", systemImage: "doc.text",
                    description: Text("BibTeX is not available for this paper"))
                    .accessibilityIdentifier(AccessibilityID.Detail.Tabs.bibtex)
            }
        case .source:
            // Manuscript-only tab; the publication descriptor never offers it.
            EmptyView()
        }
    }

    var body: some View {
        Group {
            if let pub = publication {
                if isPDFFullscreen {
                    // Fullscreen PDF - no tab bar, no navigation bar
                    IOSPDFTab(publicationID: publicationID, libraryID: libraryID, isFullscreen: $isPDFFullscreen)
                } else {
                    // Normal tabbed view. WHICH tabs and in WHAT ORDER is
                    // `PublicationRecordKind.descriptor`, the same declaration
                    // macOS's DetailView cycles through — see `availableTabs`.
                    TabView(selection: $selectedTab) {
                        ForEach(availableTabs) { tab in
                            Tab(tab.label, systemImage: tab.icon, value: tab) {
                                tabContent(tab)
                            }
                        }
                    }
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .onChange(of: availableTabs, initial: true) { _, tabs in
                        // Keep the selection valid if the descriptor's rules
                        // stop offering it (a paper that loses editability).
                        guard !tabs.contains(selectedTab) else { return }
                        selectedTab = PublicationRecordKind.descriptor.coercedTab(
                            selectedTab, for: tabContext)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Publication Not Found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This publication is no longer available.")
                )
            }
        }
        .navigationTitle(isPDFFullscreen ? "" : (publication?.title ?? "Details"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPDFFullscreen)
        .toolbar(isPDFFullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !isPDFFullscreen, let pub = publication {
                ToolbarItem(placement: .topBarTrailing) {
                    moreMenu(for: pub)
                }
            }
        }
        .task(id: publicationID) {
            loadPublication()
        }
        // Auto-mark-as-read, the Recent-view dwell and the live store-event
        // refresh are the shell behaviour BOTH detail panes share; they are one
        // modifier in PMC since Stage 5b (`publicationDetailLifecycle`), where
        // macOS's `DetailView` applies the same three tasks.
        .publicationDetailLifecycle(
            publicationID: publicationID,
            isRead: { publication?.isRead },
            markAsRead: { id in
                RustStoreAdapter.shared.setRead(ids: [id], read: true)
            },
            reload: { loadPublication() })
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
            if let listID = listID {
                Task {
                    await ListViewStateStore.shared.clearSelection(for: listID)
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadPublication() {
        publication = RustStoreAdapter.shared.getPublicationDetail(id: publicationID)
    }

    // MARK: - Navigation

    private func goBack() {
        dismiss()
        selectedPublicationID = nil
    }

    // MARK: - More Menu

    private func moreMenu(for pub: PublicationModel) -> some View {
        Menu {
            Button {
                toggleReadStatus()
            } label: {
                Label(
                    pub.isRead ? "Mark as Unread" : "Mark as Read",
                    systemImage: pub.isRead ? "envelope.badge" : "envelope.open"
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

            // The identifier rows come from `PublicationIdentifierLink`
            // (Stage 5b) — the same declaration both Info tabs read. This menu
            // hardcoded three of the four URL templates and had no PubMed row
            // at all; now it cannot disagree with the Info tab about which
            // identifiers exist or where they point.
            ForEach(PublicationIdentifierLink.all(for: pub)) { link in
                Button {
                    openURL(link.urlString)
                } label: {
                    Label(link.menuTitle, systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Actions

    private func toggleReadStatus() {
        guard let pub = publication else { return }
        RustStoreAdapter.shared.setRead(ids: [publicationID], read: !pub.isRead)
        loadPublication()
    }

    private func copyBibTeX() {
        Task {
            await libraryViewModel.copyToClipboard([publicationID])
        }
    }

    private func copyCiteKey() {
        UIPasteboard.general.string = publication?.citeKey
    }

    private func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            _ = FileManager_Opener.shared.openURL(url)
        }
    }
}
