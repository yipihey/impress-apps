//
//  ImpartIOSApp.swift
//  impart-iOS
//
//  Main application entry point for impart on iOS.
//
//  Stage 5c: the root is `IOSMailHostView` — PMC's `RecordSidebarView` +
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
    }

    var body: some Scene {
        WindowGroup {
            IOSMailHostView()
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
