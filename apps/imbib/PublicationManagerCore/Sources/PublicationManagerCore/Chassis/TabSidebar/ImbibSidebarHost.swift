#if os(macOS)
// Chassis file — macOS-only.
//
//  ImbibSidebarHost.swift
//  PublicationManagerCore
//
//  The chassis sidebar, hostable anywhere: the outline column and every piece
//  of plumbing that keeps it alive.
//
//  It used to be inlined in `TabContentView`, which was its only host. The
//  layout tree's `outline` pane (plan wave 6, W3) is the second, and it must
//  be the SAME sidebar — the same context menus, the same inline rename, the
//  same drop handling, the same delete confirmations, the same badge counts —
//  not a second implementation of any of them (CLAUDE.md: two definitions of
//  one capability drift). So the column and its lifecycle moved here verbatim
//  and both hosts apply them; `TabContentView` renders exactly what it did.
//

import ImpressFTUI
import ImpressKit
import ImpressSidebar
import ImpressStoreKit
import OSLog
import SwiftUI

// MARK: - The column

/// The outline plus the Tags filter at its foot.
struct ImbibSidebarColumn: View {

    let viewModel: ImbibSidebarViewModel

    var body: some View {
        VStack(spacing: 0) {
            SidebarOutlineView<ImbibSidebarNode>(
                selectedNodeID: Binding(
                    get: { viewModel.selectedNodeID },
                    set: { viewModel.selectedNodeID = $0 }),
                expansionState: viewModel.expansionState,
                configuration: viewModel.outlineConfiguration,
                dataVersion: viewModel.dataVersion,
                editingNodeID: Binding(
                    get: { viewModel.editingNodeID },
                    set: { viewModel.editingNodeID = $0 })
            )
            tagFilterField
        }
    }

    // MARK: Tag filter

    /// The Tags section's filter field, at the FOOT of the sidebar.
    ///
    /// imbib alone has 23,916 tag definitions, so the tree is unusable without
    /// one. The foot is where a navigator's filter field lives on this platform
    /// (Xcode's is in exactly this spot, and this sidebar is a navigator) — and
    /// unlike the section header, it is a place an `NSOutlineView` row does not
    /// have to become a text field to reach.
    ///
    /// The shared `ImpressFTUI.FilterInput`, in its always-on shape: no `?`
    /// help (that button documents the publication query language, which this
    /// field does not implement) and no auto-focus (a field that is simply part
    /// of the sidebar must not take the keyboard every time the sidebar draws).
    /// ESC therefore keeps its "clear the filter" half and drops its "put the
    /// field away" half, because there is nowhere to put it.
    @ViewBuilder
    private var tagFilterField: some View {
        if viewModel.showsTagFilter {
            Divider()
            FilterInput(
                isPresented: .constant(true),
                text: Binding(
                    get: { viewModel.tagFilter },
                    set: { viewModel.tagFilter = $0 }),
                // The count is the honest report of a narrowing the user cannot
                // otherwise see the size of — including when it is too broad to
                // auto-reveal (`tagRevealLimit`).
                matchCount: viewModel.tagFilter.isEmpty
                    ? nil : viewModel.filteredTagPaths.count,
                label: "TAGS",
                placeholder: "filter tags...",
                showsHelp: false,
                autoFocus: false,
                fieldAccessibilityIdentifier: "sidebar.tagFilter")
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - The lifecycle

/// Everything the sidebar needs besides its rows: applying the shell identity
/// and configuring the view model, the store-event subscription, the snapshot
/// rebuild trigger, the navigation notifications, and the confirmations and
/// sheets its context menus raise (a Delete Library menu item only SETS
/// `showDeleteConfirmation`; the alert that acts on it has to be on screen).
///
/// `prepare` runs once, before `configure()`, for a host that has to set
/// something on the view model before its first tree is built (the layout
/// outline's section filter). `configured` runs after every `configure()`.
struct ImbibSidebarLifecycle: ViewModifier {

    let viewModel: ImbibSidebarViewModel
    var prepare: (ImbibSidebarViewModel) -> Void = { _ in }
    var configured: (ImbibSidebarViewModel) -> Void = { _ in }

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel

    /// Thin-twin app identity — restricts visible sections + default landing
    /// (imbib = everything; imprint = Manuscripts facet). Injected at the app
    /// root; defaults to `.imbib` so imbib is unchanged.
    @Environment(\.appShellConfiguration) private var shellConfiguration

    /// The composed sidebar, when this shell has one. nil in the five sibling
    /// apps; `.impress` in impress, supplied by its root. Applied alongside
    /// `shellConfiguration` below, before `configure()`, so the very first tree
    /// the outline builds is already the composed one.
    @Environment(\.sidebarComposition) private var sidebarComposition

    @State private var didApplyShellConfig = false
    @State private var scixViewModel = SciXLibraryViewModel()

    /// SciX library repository for conditional SciX section and content
    private let scixRepository = SciXLibraryRepository.shared

    func body(content: Content) -> some View {
        @Bindable var viewModel = viewModel
        return content
            .task {
                // Thin-twin: apply the app-shell identity BEFORE configure() so the
                // default section + section visibility reflect this app (imbib vs
                // imprint). Idempotent across .task re-runs.
                if !didApplyShellConfig {
                    viewModel.shellConfiguration = shellConfiguration
                    // nil for the five single-preset shells, so this line is the
                    // no-op it looks like there; `.impress` for impress, which is
                    // what turns the flat sidebar into five app groups.
                    viewModel.sidebarComposition = sidebarComposition
                    prepare(viewModel)
                    didApplyShellConfig = true
                }
                // Wire up dependencies
                viewModel.configure(
                    libraryManager: libraryManager,
                    libraryViewModel: libraryViewModel,
                    searchViewModel: searchViewModel
                )
                configured(viewModel)

                // Compute initial flag counts
                viewModel.refreshFlagCounts()

                // Check for ADS/SciX API key. Only shells that surface external
                // search (imbib) may touch these credentials: the keychain items
                // are ACL'd to imbib's code signature, so a sibling app reading
                // them blocks its cooperative pool on a SecurityAgent password
                // prompt (impart/impel/implore each stalled on this at launch).
                // Two gates, and they say different things. `permits(.search)` is
                // the shell's DECLARATION that it surfaces external search (imbib
                // and impress). `itemsAreReadableWithoutPrompting` is the
                // REACHABILITY fact that the items are ACL'd to imbib's code
                // signature — the second half of the ADR-0022 D9 signing decision,
                // which impress's shipping made due.
                guard shellConfiguration.permits(.search),
                      CredentialManager.itemsAreReadableWithoutPrompting else { return }
                let adsKey = await CredentialManager.shared.apiKey(for: "ads")
                let scixKey = await CredentialManager.shared.apiKey(for: "scix")
                if adsKey != nil || scixKey != nil {
                    viewModel.hasSciXAPIKey = true
                    scixRepository.loadLibraries()
                    viewModel.scixSyncing = true
                    viewModel.scixSyncError = nil
                    viewModel.bumpDataVersion()
                    Task.detached {
                        do {
                            try await SciXSyncManager.shared.pullLibraries()
                            await MainActor.run {
                                viewModel.scixSyncing = false
                                viewModel.bumpDataVersion()
                            }
                        } catch {
                            Logger.library.errorCapture("SciX library sync failed: \(error.localizedDescription)", category: "scix")
                            await MainActor.run {
                                viewModel.scixSyncError = error.localizedDescription
                                viewModel.scixSyncing = false
                                viewModel.bumpDataVersion()
                            }
                        }
                    }
                }
            }
            .task {
                // Subscribe to the gateway's event stream directly.
                // Structural events re-read the full sidebar; field-only
                // mutations just bump flag counts + a light data version.
                //
                // Under `sidebar.snapshotTree` (P2) the roles invert: the
                // MAINTAINER hears these same events and gathers fresh tree data
                // off-main, and the sidebar rebuilds when the snapshot PUBLISHES
                // (see .sidebarSnapshotDidUpdate below) — never from a store
                // event directly, so a rebuild can never observe half-written
                // state or pay store reads on the main thread. The tag caches
                // still need invalidating on structural changes either way.
                for await event in ImbibImpressStore.shared.events.subscribe() {
                    let snapshotDriven = viewModel.snapshotTreeEnabled
                    switch event {
                    case .structural:
                        if snapshotDriven { viewModel.invalidateTagCache() } else {
                            viewModel.refreshFromStore()
                        }
                    case .itemsMutated:
                        viewModel.refreshFlagCounts()
                        viewModel.bumpDataVersionLight()
                    case .collectionMembershipChanged:
                        if snapshotDriven { viewModel.invalidateTagCache() } else {
                            viewModel.refreshFromStore()
                        }
                    }
                }
            }
            .onNotifications([
                (.sidebarSnapshotDidUpdate, { _ in
                    // Snapshot refreshed in the background. Flag off: only badges
                    // changed — light bump. Flag on (P2): the snapshot IS the tree
                    // data, so this is the structural rebuild trigger.
                    if viewModel.snapshotTreeEnabled {
                        viewModel.refreshFromStore()
                    } else {
                        viewModel.bumpDataVersionLight()
                    }
                }),
                (.navigateToCollection, { notification in
                    if let collectionID = notification.userInfo?["collectionID"] as? UUID {
                        libraryManager.loadLibraries()
                        viewModel.navigateToTab(.explorationCollection(collectionID))
                        viewModel.explorationRefreshTrigger = UUID()
                        viewModel.bumpDataVersion()
                    }
                }),
                (.explorationLibraryDidChange, { _ in
                    libraryManager.loadLibraries()
                    viewModel.explorationRefreshTrigger = UUID()
                    viewModel.bumpDataVersion()
                }),
                (.navigateToSmartSearch, { notification in
                    if let searchID = notification.object as? UUID {
                        viewModel.navigateToTab(.exploration(searchID))
                        viewModel.explorationRefreshTrigger = UUID()
                        viewModel.bumpDataVersion()
                    }
                }),
                // View ▸ Show Library (⌘1) / Show Inbox (⌘3), and the URL
                // scheme's library/collection "show". Observed only by the iOS
                // root since b748151d deleted the pre-chassis macOS handlers, so
                // on the Mac both menu items did nothing. Gated on the shell:
                // a host without the section has nowhere to go.
                (.showLibrary, { notification in
                    guard shellConfiguration.permits(.libraries),
                          let tab = Self.libraryTab(for: notification, libraryManager: libraryManager)
                    else { return }
                    viewModel.navigateToTab(tab)
                }),
                (.showInbox, { _ in
                    guard shellConfiguration.permits(.inbox) else { return }
                    viewModel.navigateToTab(.inbox)
                }),
                (.openStoreSearch, { _ in
                    // WP G4 (ADR-0022 D6): ⌘⇧F in shells with nothing else bound
                    // (implore, impel) selects the chassis's builtin search
                    // surface. The surface is always registered
                    // (`CustomSurfaceRegistry.builtin`), so this never dead-ends.
                    viewModel.navigateToTab(.customSurface(StoreSearchSurface.surfaceID))
                }),
                // Stage 4c (ADR-0021 seam, ChassisNavigation.swift): the general
                // case of the two lines above. An app whose DEFAULT window is the
                // chassis has to be able to drive it from its own menu commands
                // (impart's ⌘1-5) and URL scheme (impel://navigate/...), neither of
                // which can reach `viewModel` — and neither of which should learn
                // `ImbibTab`.
                (.chassisNavigateToSurface, { notification in
                    guard let surfaceID = notification.object as? String,
                          shellConfiguration.customSurfaces[surfaceID] != nil else {
                        // An id no surface claims navigates nowhere, rather than to
                        // an "unavailable surface" pane the user did not ask for.
                        return
                    }
                    viewModel.navigateToTab(.customSurface(surfaceID))
                }),
                (.chassisNavigateToDefaultSection, { _ in
                    viewModel.selectDefaultSectionLeaf()
                }),
            ])
            .alert("Delete Library", isPresented: $viewModel.showDeleteConfirmation, presenting: viewModel.libraryToDelete) { library in
                Button("Delete", role: .destructive) {
                    try? libraryManager.deleteLibrary(id: library.id)
                    viewModel.bumpDataVersion()
                }
                Button("Cancel", role: .cancel) {}
            } message: { library in
                Text("Are you sure you want to delete \"\(library.name)\"? This cannot be undone.")
            }
            .alert(
                "Delete \(viewModel.librariesPendingBulkDelete.count) Libraries?",
                isPresented: $viewModel.showDeleteMultipleLibrariesConfirmation
            ) {
                Button("Delete \(viewModel.librariesPendingBulkDelete.count) Libraries", role: .destructive) {
                    viewModel.performBulkDeleteLibraries()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.librariesPendingBulkDelete = []
                }
            } message: {
                let names = viewModel.librariesPendingBulkDelete.map { $0.name }
                let preview = names.prefix(3).joined(separator: ", ")
                let suffix = names.count > 3 ? ", and \(names.count - 3) more" : ""
                Text("\"\(preview)\(suffix)\" will be removed from the sidebar. The papers they contain are not deleted — they remain in any other libraries they belong to. Papers that are only in these libraries will be unlinked and can be recovered via Edit → Undo.")
            }
            .alert(
                "Delete \(viewModel.collectionsPendingBulkDelete.count) Collections?",
                isPresented: $viewModel.showDeleteMultipleCollectionsConfirmation
            ) {
                Button("Delete \(viewModel.collectionsPendingBulkDelete.count) Collections", role: .destructive) {
                    viewModel.performBulkDeleteCollections()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.collectionsPendingBulkDelete = []
                }
            } message: {
                Text("\(viewModel.collectionsPendingBulkDelete.count) collections will be removed. The papers they contain stay in their libraries. Recoverable via Edit → Undo.")
            }
            .alert("Delete SciX Library", isPresented: $viewModel.showSciXDeleteConfirmation, presenting: viewModel.scixLibraryToDelete) { library in
                Button("Delete", role: .destructive) {
                    Task { try? await scixViewModel.deleteLibrary(library, deleteRemote: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { library in
                Text("Are you sure you want to remove \"\(library.name)\" from imbib? This removes the local copy; the ADS library is not deleted.")
            }
            .sheet(item: $viewModel.scixLibraryToShowInfo) { library in
                SciXLibraryInfoSheet(library: library, viewModel: scixViewModel)
            }
            .sheet(item: $viewModel.scixLibraryToEdit) { library in
                SciXEditLibrarySheet(library: library, viewModel: scixViewModel)
            }
            // ADR-0023 W5 — the PDFs a watched folder could not attach on its own.
            .sheet(item: $viewModel.attachmentReviewRequest) { request in
                WatchedAttachmentOffersView(
                    folderName: request.folderName,
                    offers: request.offers,
                    onAttach: { offer, candidate in
                        viewModel.confirmAttachment(offer, to: candidate)
                    },
                    onDismiss: { viewModel.attachmentReviewRequest = nil })
            }
            // NO retention cleanup here. This modifier is applied by every
            // host of the sidebar — the layout tree's `outline` pane in all
            // six chassis apps, remounted on every split — and a view's
            // lifecycle is not the app's. imbib schedules it once per launch
            // from `InboxCoordinator.start` (review PH-H2).
    }
}

extension ImbibSidebarLifecycle {
    /// Where ⌘1 / `.showLibrary` goes: the collection or library the poster
    /// named (`userInfo["collectionID"]` / `["libraryID"]`, UUID or string,
    /// or a UUID object), else the active library, else the first library
    /// that is not a triage place (Inbox, Dismissed, Exploration).
    @MainActor
    static func libraryTab(for notification: Notification, libraryManager: LibraryManager) -> ImbibTab? {
        func uuid(_ key: String) -> UUID? {
            (notification.userInfo?[key] as? UUID)
                ?? (notification.userInfo?[key] as? String).flatMap(UUID.init(uuidString:))
        }
        if let collectionID = uuid("collectionID") { return .collection(collectionID) }
        if let libraryID = uuid("libraryID") ?? (notification.object as? UUID) {
            return .library(libraryID)
        }
        let triage = Set([libraryManager.dismissedLibrary?.id, libraryManager.explorationLibrary?.id]
            .compactMap { $0 })
        let filing = libraryManager.libraries.filter { !$0.isInbox && !triage.contains($0.id) }
        if let active = libraryManager.activeLibrary, filing.contains(where: { $0.id == active.id }) {
            return .library(active.id)
        }
        return filing.first.map { .library($0.id) }
    }
}
#endif
