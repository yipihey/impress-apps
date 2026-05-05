//
//  IOSSidebarViewStub.swift
//  imbib-iOS
//
//  Temporary working replacement for the pre-Rust-migration
//  IOSSidebarView.swift. The original file is excluded from the iOS
//  build because it still uses Core Data types (CDLibrary,
//  CDSmartSearch, CDCollection) and Core Data relationships. This stub
//  keeps the iOS app navigable: it renders libraries, flagged, and the
//  new "Cited in Manuscripts" section using value types from
//  RustStoreAdapter.
//
//  Feature gaps vs. the original: inbox subtree, smart searches,
//  collections, exploration library, artifacts, SciX libraries, and
//  every drag-drop / edit affordance are deferred as migration debt.
//  See docs/adr/ios-migration-debt.md for the tracking list.
//

import SwiftUI
import PublicationManagerCore

struct IOSSidebarView: View {

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(LibraryViewModel.self) private var libraryViewModel

    // MARK: - Bindings

    @Binding var selection: SidebarSection?

    /// Kept for the iPhone drill-down callback that legacy call sites
    /// still pass even though smart-search navigation isn't wired yet.
    var onNavigateToSmartSearch: ((UUID) -> Void)?

    // MARK: - State

    @State private var libraries: [LibraryModel] = []
    @State private var citedCount: Int = 0

    var body: some View {
        List(selection: $selection) {
            inboxSection
            librariesSection
            flaggedSection
            citedInManuscriptsSection
            migrationNotice
        }
        .listStyle(.sidebar)
        .refreshable {
            await refresh()
        }
        .task {
            await refresh()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var inboxSection: some View {
        if let inbox = RustStoreAdapter.shared.getInboxLibrary() {
            Section("Inbox") {
                NavigationLink(value: SidebarSection.inbox) {
                    Label(inbox.name, systemImage: "tray")
                }
            }
        }
    }

    private var librariesSection: some View {
        Section("Libraries") {
            ForEach(libraries, id: \.id) { library in
                NavigationLink(value: SidebarSection.library(library.id)) {
                    Label(library.name, systemImage: "books.vertical")
                }
            }
        }
    }

    private var flaggedSection: some View {
        Section("Flagged") {
            NavigationLink(value: SidebarSection.flagged(nil)) {
                Label("All Flagged", systemImage: "flag.fill")
            }
        }
    }

    @ViewBuilder
    private var citedInManuscriptsSection: some View {
        if citedCount > 0 {
            Section("Cited in Manuscripts") {
                NavigationLink(value: SidebarSection.citedInManuscripts) {
                    Label {
                        Text("All Cited Papers")
                    } icon: {
                        Image(systemName: "text.book.closed.fill")
                    }
                    .badge(citedCount)
                }
            }
        }
    }

    private var migrationNotice: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("iOS rebuild in progress")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("Smart searches, collections, exploration and artifacts are temporarily hidden while the iOS sidebar is migrated off Core Data.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        libraries = RustStoreAdapter.shared.listLibraries().filter { !$0.isInbox }
        await CitedInManuscriptsSnapshot.shared.refresh()
        citedCount = CitedInManuscriptsSnapshot.shared.citedPaperIDs.count
    }
}
