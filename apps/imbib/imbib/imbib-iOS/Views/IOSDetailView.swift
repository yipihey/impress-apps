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
            IOSBibTeXTab(publicationID: publicationID)
                .accessibilityIdentifier(AccessibilityID.Detail.Tabs.bibtex)
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
            // Auto-mark as read after brief delay (Apple Mail style)
            await autoMarkAsRead()
        }
        .task(id: publicationID) {
            // Opening a paper is a user-initiated view — it belongs in Recent.
            // The one-second dwell keeps rapid scrubbing through a list from
            // filling Recent with papers the user merely passed over; the task
            // is cancelled as soon as the selection changes.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            RustStoreAdapter.shared.recordRecentView(id: publicationID)
        }
        .task(id: publicationID) {
            // Keep the OPEN detail in sync with background mutations
            // (enrichment filling in abstract/PDF, tag/flag changes from
            // other surfaces). Previously the detail loaded once and went
            // stale until re-navigation.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if case .itemsMutated(_, let ids) = event, ids.contains(publicationID) {
                    loadPublication()
                }
            }
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

    // MARK: - Auto-Mark as Read

    private func autoMarkAsRead() async {
        guard let pub = publication, !pub.isRead else { return }

        // Wait 1 second before marking as read (like Mail)
        do {
            try await Task.sleep(for: .seconds(1))
            RustStoreAdapter.shared.setRead(ids: [publicationID], read: true)
            loadPublication()
            logger.debug("Auto-marked as read: \(pub.citeKey)")
        } catch {
            // Task was cancelled (user navigated away quickly)
        }
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

            if let doi = pub.doi {
                Button {
                    openURL("https://doi.org/\(doi)")
                } label: {
                    Label("Open DOI", systemImage: "arrow.up.right.square")
                }
            }

            if let arxivID = pub.arxivID {
                Button {
                    openURL("https://arxiv.org/abs/\(arxivID)")
                } label: {
                    Label("Open arXiv", systemImage: "arrow.up.right.square")
                }
            }

            if let bibcode = pub.bibcode {
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
