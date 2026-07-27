//
//  ImpartChassisRoot.swift
//  impart (macOS)
//
//  Stage 2-A of the GUI unification: impart's MAIL BROWSING on the SAME
//  chassis as imbib/imprint/implore — PublicationManagerCore's
//  `TabContentView` — filtered to the Mail facet via
//  `AppShellConfiguration.impart`. "impart = imbib filtered to mail": the
//  sidebar shows only the Mail section (All Inboxes / accounts / folders,
//  read from the shared store's Stage-0 mail rows), and the chat / research
//  / development experiences ride along as app-owned CUSTOM SURFACES (WP-X0)
//  wrapping the EXISTING views — no rewrites.
//
//  This root replicates implore's ImploreChassisRoot exactly: the chassis
//  reads three `@Environment` view models — PMC's `LibraryManager`,
//  `LibraryViewModel`, `SearchViewModel` — plus the injected
//  `\.appShellConfiguration`. Everything else the chassis needs
//  (`RustStoreAdapter.shared`, `MailStoreReader.shared`, …) is a PMC
//  singleton impart gets for free by linking PublicationManagerCore, reading
//  the SAME shared store impart's MessageManagerCore mirror writes
//  (ADR-0001: same data, different facet).
//
//  DELIBERATE deviation from implore (Stage 2-A plan): this chassis does NOT
//  replace impart's default window. Mail is a daily driver and
//  compose/reply/IMAP flows aren't wired into the chassis yet, so the
//  classic ContentView stays primary behind the "impart.useChassisWindow"
//  flag (see ImpartApp).
//
//  Launch TCC hang avoidance (see ImprintChassisRoot): the shared store's
//  first `open()` can block on a TCC prompt / WAL lock, so it is warmed on a
//  DETACHED background task before the main-actor view models exist.
//

import SwiftUI
import ImpressLogging
import MessageManagerCore
import PublicationManagerCore

/// Holds the three chassis view models. Constructed once, on the main actor,
/// only AFTER the shared store has been warmed off-main.
@MainActor
final class ChassisViewModels {
    let libraryManager: PublicationManagerCore.LibraryManager
    let libraryViewModel: PublicationManagerCore.LibraryViewModel
    let searchViewModel: PublicationManagerCore.SearchViewModel

    init() {
        let libraryManager = PublicationManagerCore.LibraryManager()
        let libraryViewModel = PublicationManagerCore.LibraryViewModel()
        let searchViewModel = PublicationManagerCore.SearchViewModel()
        searchViewModel.setLibraryManager(libraryManager)
        self.libraryManager = libraryManager
        self.libraryViewModel = libraryViewModel
        self.searchViewModel = searchViewModel
    }
}

/// Shared context for the custom surfaces: the view models outlive any
/// single surface view (the chassis constructs surface views lazily per
/// selection), so they live here rather than in view `@State` — the
/// ImploreSurfaceContext pattern.
@MainActor
final class ImpartSurfaceContext {
    static let shared = ImpartSurfaceContext()
    let inboxViewModel = InboxViewModel()
    let developmentViewModel = DevelopmentConversationViewModel()
    private init() {}
}

/// impart's chassis root: the shared chassis (`TabContentView`) restricted
/// to the Mail facet, with Chat/Research/Development registered as custom
/// surfaces. Gated behind an off-main store warm-up so the window never
/// blocks on the shared store open.
struct ImpartChassisRoot: View {
    @State private var models: ChassisViewModels?

    /// The impart shell: PMC's `.impart` preset (Mail section, detail-pane
    /// open behavior) EXTENDED app-side with the custom surfaces — the
    /// preset cannot hold app-target views (WP-X0 seam).
    private static let shellConfiguration: AppShellConfiguration =
        AppShellConfiguration.impart.withCustomSurfaces([
            CustomSurfaceDescriptor(
                id: "chat", title: "Chat", systemImage: "bubble.left.and.bubble.right",
                makeView: { AnyView(ChatSurface()) }),
            CustomSurfaceDescriptor(
                id: "research", title: "Research", systemImage: "brain.head.profile",
                makeView: { AnyView(ResearchSurface()) }),
            CustomSurfaceDescriptor(
                id: "development", title: "Development", systemImage: "hammer",
                makeView: { AnyView(DevelopmentSurface()) }),
        ])

    var body: some View {
        Group {
            if let models {
                TabContentView()
                    .environment(models.libraryManager)
                    .environment(models.libraryViewModel)
                    .environment(models.searchViewModel)
                    .environment(\.appShellConfiguration, Self.shellConfiguration)
            } else {
                loadingView
            }
        }
        .task {
            guard models == nil else { return }
            // Warm the shared store OFF the main thread (see header note).
            await Self.warmSharedStore()
            models = ChassisViewModels()
            logInfo("ImpartChassisRoot: chassis environment ready (Mail facet)", category: "app")
        }
    }

    /// Force the shared-store open onto a background thread and await completion.
    private static func warmSharedStore() async {
        await Task.detached(priority: .userInitiated) {
            _ = RustStoreAdapter.shared
        }.value
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Opening workspace…")
                .font(.headline)
            Text("If macOS asks to allow access to data from other apps, click Allow.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Custom surfaces (wrap the EXISTING views — no rewrites)

/// The existing chat-bubble view as a full-pane surface. Conversation
/// selection still comes from the classic window's sidebar (the shared
/// InboxViewModel); without one it shows its own placeholder — honest v1.
struct ChatSurface: View {
    var body: some View {
        ChatView(
            viewModel: ImpartSurfaceContext.shared.inboxViewModel,
            currentUserEmail: ImpartSurfaceContext.shared.inboxViewModel.currentAccountEmail ?? ""
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The existing research-conversation stack as a full-pane surface, hosted
/// in its own NavigationStack (it was built for a split-view column).
struct ResearchSurface: View {
    var body: some View {
        NavigationStack {
            ResearchConversationListView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The existing development stack as a full-pane surface: conversation list
/// on the left, the chat transcript on the right, sharing one view model.
struct DevelopmentSurface: View {
    var body: some View {
        HSplitView {
            DevelopmentConversationListView(
                viewModel: ImpartSurfaceContext.shared.developmentViewModel)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                .frame(maxHeight: .infinity)
            DevelopmentChatView(
                viewModel: ImpartSurfaceContext.shared.developmentViewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // HSplitView does NOT fill like NavigationSplitView — the fill
        // frame is mandatory (impress-swiftui-pitfalls rule).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
