import SwiftUI
import ImpelCore

/// Main application entry point for impel
///
/// impel is a monitoring dashboard for the impel agent orchestration system,
/// providing a read-only view of research threads, agent status, and escalations.
@main
struct ImpelApp: App {
    @StateObject private var client = ImpelClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .onAppear {
                    // Load mock data for development
                    client.loadMockData()
                }
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Refresh") {
                    Task { await client.refresh() }
                }
                .keyboardShortcut("R", modifiers: [.command])
            }

            CommandMenu("Server") {
                Button("Connect...") {
                    // TODO: Show connection dialog
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])

                Button("Disconnect") {
                    client.disconnect()
                }
                .disabled(!client.isConnected)

                Divider()

                Button("Load Demo Data") {
                    client.loadMockData()
                }
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
