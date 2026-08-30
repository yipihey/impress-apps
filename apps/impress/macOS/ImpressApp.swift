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
    /// The three pane toggles WERE hand-written here, exactly as impart and
    /// imprint hand-wrote them, and that was the recorded D9 finding: chassis
    /// state with a chassis-wide keyboard grammar (docs/keyboard-grammar.md)
    /// and no chassis `Commands` value, retyped by the fourth adopter.
    /// `ImpressPaneLayoutButtons` closes it (ADR-0022 X2).
    ///
    /// Embedded as CONTENT rather than inserted as `ImpressPaneLayoutCommands()`
    /// because this group also carries the Console item below; a separate
    /// `Commands` value can only contribute a whole group, which would have
    /// moved the toggles away from the Divider they sit above.
    @CommandsBuilder
    private var sharedCommands: some Commands {
#if os(macOS)
            // "About <app>" with the BUILD STAMP (ImpressKit). Every app
            // self-installs its Debug build, so several builds and several
            // running instances pile up in a session; About is where the app
            // answers "am I the binary you just built?" without a terminal.
            ImpressAboutCommand()
#endif
        ImpressFindCommands()
        ImpressStoreSearchCommands()

        CommandGroup(after: .sidebar) {
            ImpressPaneLayoutButtons()

            Divider()

            Button("Show Console") { openWindow(id: "console") }
                .keyboardShortcut("c", modifiers: [.control, .command])
        }
    }
}

// MARK: - Appearance
//
// The 18-line `AppearanceModifier` that used to sit here — the THIRD verbatim
// copy, and the D9 finding — is `ImpressTheme`'s now (ADR-0022 X2). The package
// exported `AppearanceMode` and `AppearanceSettingsSection` (the enum and the
// picker) but not the one line that APPLIES the choice; it does now.
// `import ImpressTheme` above is the whole of impress's side of it, and
// `ImpressChassisRoot`'s `.withAppearance()` call site is unchanged.
//
// Deleting it stopped being optional the moment the package shipped its own: a
// module-local `withAppearance()` with the same signature as an imported one is
// AMBIGUOUS, not shadowed, and this file already imported ImpressTheme for the
// settings picker. Each of the three apps that carried a private copy gave it
// up in the same change that handed them a shared one — which is the honest
// shape of this kind of migration, and the reason it is done in one pass rather
// than app by app.
#endif // os(macOS)
