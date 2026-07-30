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
//  Stage 4b: the chassis boilerplate this file used to carry — a
//  `ChassisViewModels` class (declared under that same name in FOUR app
//  targets), a `warmSharedStore()` and a loading view — now lives once, in PMC's
//  `ChassisRootView`. It injects the same environment: the chassis reads three
//  `@Environment` view models — PMC's `LibraryManager`, `LibraryViewModel`,
//  `SearchViewModel` — plus `\.appShellConfiguration`. Everything else the
//  chassis needs (`RustStoreAdapter.shared`, `MailStoreReader.shared`, …) is a
//  PMC singleton impart gets for free by linking PublicationManagerCore, reading
//  the SAME shared store impart's MessageManagerCore mirror writes (ADR-0001:
//  same data, different facet). It also keeps the off-main store warm-up (see
//  ImprintChassisRoot / MEMORY fix_imprint_launch_tcc_offmain_store): the first
//  `open()` can block on a TCC prompt / WAL lock.
//
//  Stage 4c: this IS impart's window. The classic three-column `ContentView`
//  and the `impart.useChassisWindow` flag are gone (see ImpartApp for why the
//  flag is not kept as a kill switch). Two things had to land first:
//
//    * COMPOSE and MARK-READ ON SELECT — the two gaps
//      docs/chassis-capability-matrix.md called out as blocking daily-driver
//      use. Both are verbs whose truth lives in Core Data / IMAP rather than the
//      store, so they are supplied by `MailChassisHost` (impart's side) through
//      the `RecordHostVerbs` seam (the chassis's side). Reply/Forward and
//      Check-Mail came along for free once the CD lookup existed.
//    * The CATEGORY surface. Chat / Research / Development were registered in
//      Stage 2-A but `.category` — one of the five view modes the classic
//      toolbar's picker and ⌘3 selected — was not, so it was the one view mode
//      the chassis window could not reach.
//
//  Still IMAP-owned and still deliberately absent (matrix row unchanged): no
//  message drag (move = IMAP move), no folder CRUD (IMAP owns folder
//  lifecycle), no chassis delete/dismiss.
//
//  What stays impart's: the four custom surface descriptors, the
//  `ImpartSurfaceContext` singleton behind them, and the surface views below.
//

import SwiftUI
import MessageManagerCore
import PublicationManagerCore

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

    /// The impart shell: PMC's `.impart` preset (Mail section, detail-pane
    /// open behavior) EXTENDED app-side with the custom surfaces — the
    /// preset cannot hold app-target views (WP-X0 seam).
    /// Internal, not private, so `impartTests` can assert that every ⌘1-5
    /// destination (`MailChassisHost.chassisDestination(for:)`) names a surface
    /// that is actually REGISTERED — the failure mode of a string-keyed
    /// navigation seam is a chord that silently navigates nowhere.
    static let shellConfiguration: AppShellConfiguration =
        AppShellConfiguration.impart.withCustomSurfaces([
            CustomSurfaceDescriptor(
                id: "chat", title: "Chat", systemImage: "bubble.left.and.bubble.right",
                makeView: { AnyView(ChatSurface()) }),
            CustomSurfaceDescriptor(
                id: "category", title: "Category", systemImage: "square.grid.2x2",
                makeView: { AnyView(CategorySurface()) }),
            CustomSurfaceDescriptor(
                id: "research", title: "Research", systemImage: "brain.head.profile",
                makeView: { AnyView(ResearchSurface()) }),
            CustomSurfaceDescriptor(
                id: "development", title: "Development", systemImage: "hammer",
                makeView: { AnyView(DevelopmentSurface()) }),
        ])

    var body: some View {
        ChassisRootView(
            configuration: Self.shellConfiguration,
            readyLogMessage: "ImpartChassisRoot: chassis environment ready (Mail facet)")
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

/// The existing conversations/broadcasts classifier view as a full-pane surface
/// (Stage 4c). Registered on exactly the terms `ChatSurface` already was: it
/// reads the SAME shared `InboxViewModel`, so it shows what that view model has
/// — which today is nothing, because no macOS code path assigns a mailbox. An
/// honest empty surface that ⌘3 reaches beats a view mode with no home.
struct CategorySurface: View {
    var body: some View {
        CategoryView(viewModel: ImpartSurfaceContext.shared.inboxViewModel)
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
