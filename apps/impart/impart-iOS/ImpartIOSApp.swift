//
//  ImpartIOSApp.swift
//  impart-iOS
//
//  Main application entry point for impart on iOS.
//
//  Stage 5c: the mail facet is `IOSMailHostView` — PMC's `RecordSidebarView` +
//  `MessageDetailPane` over the shared store's mail rows — rather than the
//  hand-written `IOSContentView` TabView, and the target links
//  PublicationManagerCore for the first time. See `IOSMailHostView`'s header for
//  what does and does not run on iOS, and `ImpartSidebarBindings` for the rows.
//
//  `IOSAppState` is gone with the shell that needed it. Every field it held was
//  either dead (`selectedAccountId`/`selectedMailboxId`, assigned nowhere) or
//  compose state for a composer that could not send; selection now lives in the
//  one view that owns it, which is what makes the sidebar/list/detail columns
//  agree — the classic macOS window's equivalent bug was two unconnected
//  selection sets, and this shell had the same shape.
//

import MessageManagerCore
import PublicationManagerCore
import SwiftUI

@main
struct ImpartIOSApp: App {

    /// Applied at the root, from the SAME `appearanceMode` key macOS's
    /// `ImpartApp` reads and the chassis settings pane writes (three tags:
    /// system / light / dark). Declared here rather than in a view so one place
    /// owns the window's scheme.
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    init() {
        // Synchronous, before any view can read the store — the sibling apps'
        // rule. No-op unless the process was launched with `--uitesting-seed`.
        ImpartIOSUITestSeed.seedIfRequested()

        // iOS can sync conversation/message/task rows while the laptop model
        // host is offline. Startup work remains deferred by 120 seconds.
        CloudSyncEngineLauncher.startAfterGrace()
    }

    var body: some Scene {
        WindowGroup {
            ImpartIOSRootView()
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// Two declarative facets over shared cores. Mail remains the chassis-backed
/// default; Local AI is the same MessageManagerCore surface macOS registers in
/// its chassis and can queue/sync turns while the model host is offline.
private struct ImpartIOSRootView: View {
    var body: some View {
        TabView {
            Tab("Mail", systemImage: "envelope") {
                IOSMailHostView()
            }
            Tab("Local AI", systemImage: "sparkles") {
                AIConversationWorkspaceView()
            }
        }
    }
}
