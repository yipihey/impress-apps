import SwiftUI
import ImpressKit

/// implore - Scientific Data Visualization
///
/// A high-performance, keyboard-driven visualization tool for
/// large-scale scientific datasets. Part of the impress suite.
@main
struct ImploreApp: App {
    @State private var appState = AppState()

    /// Whether running in UI testing mode
    private static let isUITesting = CommandLine.arguments.contains("--ui-testing")

    /// Whether to reset app state
    private static let shouldResetState = CommandLine.arguments.contains("--reset-state")

    /// Whether to load sample dataset
    private static let useSampleDataset = CommandLine.arguments.contains("--sample-dataset")

    /// Whether to skip welcome screen (still no data, but useful for some tests)
    private static let skipWelcome = CommandLine.arguments.contains("--skip-welcome")

    init() {
        // Configure app for testing if needed
        if Self.isUITesting {
            configureForUITesting()
        }

        // Start HTTP automation server
        Task {
            await HTTPAutomationServer.shared.start()
        }
    }

    /// Handle incoming URLs for imprint integration
    private func handleURL(_ url: URL) {
        Task { @MainActor in
            _ = FigureLinkService.shared.handleURL(url)
        }
    }

    private func configureForUITesting() {
        // Reset user defaults if requested
        if Self.shouldResetState {
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)

                // Also clear the Saved Application State to prevent window restoration
                if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
                    let savedStateURL = libraryURL
                        .appendingPathComponent("Saved Application State")
                        .appendingPathComponent("\(bundleID).savedState")
                    try? FileManager.default.removeItem(at: savedStateURL)
                }
            }
        }

        // Disable window restoration for testing
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Disable animations for faster testing
        UITestingSupport.disableAnimations()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    // Start heartbeat for SiblingDiscovery
                    Task.detached {
                        while !Task.isCancelled {
                            ImpressNotification.postHeartbeat(from: .implore)
                            try? await Task.sleep(for: .seconds(25))
                        }
                    }
                }
                .onOpenURL { url in
                    handleURL(url)
                }
        }
        .handlesExternalEvents(matching: Set(["implore"]))
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open Dataset...") {
                    appState.showOpenPanel()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Export Figure...") {
                    appState.showExportPanel()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.currentSession == nil)
            }

            // View menu
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Science 2D Mode") {
                    appState.setRenderMode(.science2D)
                }
                .keyboardShortcut("1")

                Button("Box 3D Mode") {
                    appState.setRenderMode(.box3D)
                }
                .keyboardShortcut("2")

                Button("Art Shader Mode") {
                    appState.setRenderMode(.artShader)
                }
                .keyboardShortcut("3")

                Button("Histogram 1D Mode") {
                    appState.setRenderMode(.histogram1D)
                }
                .keyboardShortcut("4")

                Divider()

                Button("Cycle Mode") {
                    appState.cycleRenderMode()
                }
                .keyboardShortcut(.tab, modifiers: [])
            }

            // Selection menu
            CommandMenu("Selection") {
                Button("Select All") {
                    appState.selectAll()
                }
                .keyboardShortcut("a")

                Button("Select None") {
                    appState.selectNone()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Invert Selection") {
                    appState.invertSelection()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button("Selection Grammar...") {
                    appState.showSelectionGrammar()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// Global application state
@MainActor @Observable
class AppState {
    var currentSession: VisualizationSession?
    var renderMode: RenderMode = .science2D
    var isLoading: Bool = false
    var errorMessage: String?

    // UI state
    var showingOpenPanel: Bool = false
    var showingExportPanel: Bool = false
    var showingSelectionGrammar: Bool = false

    init() {
        // Load sample dataset for testing if requested
        if CommandLine.arguments.contains("--sample-dataset") {
            currentSession = VisualizationSession.sampleSession()
        }
    }

    func showOpenPanel() {
        showingOpenPanel = true
    }

    func showExportPanel() {
        showingExportPanel = true
    }

    func showSelectionGrammar() {
        showingSelectionGrammar = true
    }

    func setRenderMode(_ mode: RenderMode) {
        renderMode = mode
    }

    func cycleRenderMode() {
        switch renderMode {
        case .science2D:
            renderMode = .box3D
        case .box3D:
            renderMode = .artShader
        case .artShader:
            renderMode = .histogram1D
        case .histogram1D:
            renderMode = .science2D
        }
    }

    func selectAll() {
        // Implement selection
    }

    func selectNone() {
        // Implement selection
    }

    func invertSelection() {
        // Implement selection
    }

    func loadDataset(url: URL) async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Load dataset using Rust core
            let session = VisualizationSession(name: url.lastPathComponent)
            currentSession = session
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Render modes supported by implore
enum RenderMode: String, CaseIterable {
    case science2D = "Science 2D"
    case box3D = "Box 3D"
    case artShader = "Art Shader"
    case histogram1D = "Histogram 1D"
}

/// Placeholder for Rust type
struct VisualizationSession {
    let id: UUID = UUID()
    let name: String
    var pointCount: Int = 0
    var fieldNames: [String] = []

    /// Create a sample session for testing
    static func sampleSession() -> VisualizationSession {
        var session = VisualizationSession(name: "sample.csv")
        session.pointCount = 20
        session.fieldNames = ["x", "y", "z", "color", "size", "density"]
        return session
    }
}

// MARK: - UI Testing Support

/// Helpers for UI testing mode
enum UITestingSupport {
    /// Disable animations for faster test execution
    static func disableAnimations() {
        #if os(macOS)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
        }
        #endif
    }
}

