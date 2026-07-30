#if os(macOS)
//
//  ImpressApp.swift
//  impress
//
//  The macOS scene tree. One window (the chassis), one Settings scene, one
//  Console window — the suite's standard three — plus the SHARED command sets
//  and nothing bespoke. ADR-0022 D9's "no seventh codebase" is a claim about
//  this file as much as about the root: an app that had to hand-write menus
//  would be an app that had opinions the chassis could not express.
//

import ImpressAutomation
import ImpressKit
import ImpressLogging
import ImpressTheme
import PublicationManagerCore
import SwiftUI

@main
struct ImpressApp: App {

    @Environment(\.openWindow) private var openWindow

    init() {
        // The port is a LOOKUP into `SiblingApp.descriptors`, never a literal
        // (CLAUDE.md: "servers align TO the table").
        UserDefaults.standard.register(defaults: [
            "httpAutomationEnabled": true,
            "httpAutomationPort": Int(ImpressHTTPServer.defaultPort),
        ])
        Task { @MainActor in await ImpressHTTPServer.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ImpressChassisRoot()
                .task {
                    // SiblingDiscovery's liveness signal. Every app in the
                    // suite announces itself the same way; impress must too, or
                    // the other five believe it is closed.
                    while !Task.isCancelled {
                        ImpressNotification.postHeartbeat(from: .impress)
                        try? await Task.sleep(for: .seconds(25))
                    }
                }
        }
        .commands { sharedCommands }

        Settings {
            ImpressSettingsScene()
        }

        Window("Console", id: "console") {
            ConsoleView(appName: "impress")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .defaultSize(width: 800, height: 400)
    }

    /// Only shared command sets, plus the pane toggles.
    ///
    /// `ImpressFindCommands` (⌘F → the frontmost record list's filter) and
    /// `ImpressStoreSearchCommands` (⌘⇧F → the builtin grouped-search surface)
    /// are `Commands` values the chassis ships. impress has nothing else bound
    /// to either chord, so it takes both as written — implore and impel are the
    /// precedent.
    ///
    /// The three pane toggles are NOT shared and are hand-written here, exactly
    /// as impart and imprint hand-write them. That is a finding, recorded in
    /// the D9 report: `PaneLayoutStore` is chassis state with a chassis-wide
    /// keyboard grammar (docs/keyboard-grammar.md) and no chassis `Commands`
    /// value, so the fourth adopter re-typed it for the fourth time.
    @CommandsBuilder
    private var sharedCommands: some Commands {
        ImpressFindCommands()
        ImpressStoreSearchCommands()

        CommandGroup(after: .sidebar) {
            Button("Toggle Detail Pane") {
                PaneLayoutStore.shared.current.detailPaneVisible.toggle()
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("Toggle List") {
                PaneLayoutStore.shared.current.listPaneVisible.toggle()
            }
            .keyboardShortcut("0", modifiers: [.option, .command])

            Button("Toggle Sidebar") {
                PaneLayoutStore.shared.current.sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Divider()

            Button("Show Console") { openWindow(id: "console") }
                .keyboardShortcut("c", modifiers: [.control, .command])
        }
    }
}

// MARK: - Appearance

/// The suite's `appearanceMode` key (`system` / `light` / `dark`) — the same
/// key `AppearanceSettingsPane` (the chassis settings builtin impress adopts)
/// writes.
///
/// FINDING: this modifier is byte-identical in imprint's and impart's app
/// files and is now written a third time, because `withAppearance()` is an
/// app-local convention rather than something `ImpressTheme` ships. The package
/// exports `AppearanceMode` and `AppearanceSettingsSection` — the enum and the
/// picker — but not the one line that applies the choice.
private struct AppearanceModifier: ViewModifier {
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    func body(content: Content) -> some View {
        content.preferredColorScheme(colorScheme)
    }
}

extension View {
    func withAppearance() -> some View { modifier(AppearanceModifier()) }
}
#endif // os(macOS)
