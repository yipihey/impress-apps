#if os(macOS)
import AppKit
import CoreData
import CoreSpotlight
import ImpressGit
import ImpressLogging
import ImprintCore
import ImpressKit
import ImpressSpotlight
import ImpressSyntaxHighlight
import ImpressToolbox
import SwiftUI

extension NSNotification.Name {
    static let openDocument = NSNotification.Name("com.imprint.openDocument")
}

// MARK: - Appearance Modifier

/// View modifier that applies user's color scheme preference
struct AppearanceModifier: ViewModifier {
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
    /// Apply user's appearance preference (system/light/dark)
    func withAppearance() -> some View {
        modifier(AppearanceModifier())
    }
}

/// App delegate to handle app lifecycle events
final class ImprintAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        logInfo("imprint launched", category: "app")
        // Route ImpressSyntaxHighlight logs into imprint's log capture
        ImpressSyntaxLog.callback = { message in
            logInfo(message, category: "syntax")
        }
        let port = UserDefaults.standard.integer(forKey: "httpAutomationPort")
        logInfo("HTTP server starting on port \(port)", category: "http-server")
        // Start HTTP automation server for AI/MCP integration
        Task {
            await ImprintHTTPServer.shared.start()
        }

        // Ensure default workspace and refresh metadata cache
        Task { @MainActor in
            ImprintPersistenceController.shared.ensureDefaultWorkspace()
            await DocumentMetadataCacheService.shared.refreshAll()
        }

        // Touch the shared store adapter to trigger its setup (opens shared workspace directory).
        // Non-fatal: if the app group container is unavailable, isReady stays false
        // and all storeSection() calls are no-ops.
        Task { @MainActor in
            _ = ImprintStoreAdapter.shared.isReady
        }

        // Open the shared publication database (imbib's publications) for direct SQL access.
        // Enables citation palette, hover preview, .bib projection, paper panel — all without HTTP.
        Task { @MainActor in
            ImprintPublicationService.shared.start()
        }

        // Start the snapshot maintainers that drive the live outline,
        // recent-documents sidebar, and cross-document search. All
        // three subscribe to `ImprintImpressStore.shared.events` on
        // background actors and publish @Observable snapshots on
        // MainActor — views never query the store directly.
        Task.detached(priority: .utility) {
            await OutlineSnapshotMaintainer.shared.start()
            await RecentDocumentsSnapshotMaintainer.shared.start()
            await ManuscriptSearchService.shared.start()
            // Resolver closure: cite key → imbib publication UUID string.
            // `ImprintPublicationService` is main-actor isolated, so we
            // hop onto MainActor to do the SQL lookup. The tracker's
            // refresh loop is coarse-grained enough that the round-trip
            // cost is negligible in practice.
            await CitationUsageTracker.shared.setPaperIDResolver { citeKey in
                await MainActor.run {
                    ImprintPublicationService.shared.findByCiteKey(citeKey)?.id
                }
            }
            await CitationUsageTracker.shared.start()
        }

        // Initialize the Tantivy-backed multi-term search index lazily on first
        // search use rather than at startup, so app launch isn't gated on it.

        // Auto-launch impress-toolbox for LaTeX compilation (bypasses sandbox)
        Task.detached {
            await ToolboxLifecycle.shared.ensureRunning()
        }

        // Discover TeX distribution early so LaTeX compilation works without
        // opening Settings first.
        Task { @MainActor in
            await TeXDistributionManager.shared.discoverDistribution()
        }

        // Handle `.openDocumentByID` notifications posted from the
        // project sidebar (recent-documents section) and cross-document
        // search window. If the document is already open we just
        // activate its window; otherwise we look up the file URL from
        // the document registry and ask NSDocumentController to open.
        NotificationCenter.default.addObserver(
            forName: .openDocumentByID,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let idString = notification.userInfo?["documentID"] as? String,
                let uuid = UUID(uuidString: idString)
            else { return }
            Task { @MainActor in
                if let url = DocumentRegistry.shared.urlByDocumentID[uuid] {
                    NSDocumentController.shared.openDocument(
                        withContentsOf: url,
                        display: true
                    ) { _, _, _ in }
                }
            }
        }

        // Spotlight indexing — deferred 90s per startup grace period
        Task.detached {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }

            let coordinator = SpotlightSyncCoordinator(provider: ImprintSpotlightProvider())
            await coordinator.initialRebuildIfNeeded()
            // Observe Core Data saves for incremental updates
            await coordinator.startObserving(
                mutationName: NSManagedObjectContext.didSaveObjectsNotification
            )
            await SpotlightBridge.shared.setCoordinator(coordinator)
        }
    }

    /// Prevent automatic "Open" dialog on launch - show project browser instead
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Show project browser when reactivated with no visible windows
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return flag
    }
}

/// Main application entry point for imprint (macOS)
///
/// imprint is a collaborative academic writing application that uses:
/// - Typst for fast, beautiful document rendering
/// - Automerge CRDT for conflict-free real-time collaboration
/// - imbib integration for citation management
@main
struct ImprintApp: App {
    @NSApplicationDelegateAdaptor(ImprintAppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var appState = AppState()

    /// Whether running in UI testing mode
    private static let isUITesting = CommandLine.arguments.contains("--ui-testing")

    /// Whether to reset app state
    private static let shouldResetState = CommandLine.arguments.contains("--reset-state")

    /// Whether to load sample document
    private static let useSampleDocument = CommandLine.arguments.contains("--sample-document")

    /// One-shot signal from a File-menu command to the
    /// `DocumentGroup` factory. The "New LaTeX Document" button sets
    /// this to `.latex` and calls `NSDocumentController.shared.newDocument(nil)`;
    /// `createInitialDocument()` reads it once and resets to `nil`.
    /// `nil` (the default) → standard Typst-format new document.
    nonisolated(unsafe) static var pendingNewDocumentFormat: DocumentFormat?

    init() {
        // Register default settings (HTTP automation enabled by default for MCP)
        UserDefaults.standard.register(defaults: [
            "httpAutomationEnabled": true,
            "httpAutomationPort": 23121
        ])

        // Configure app for testing if needed
        if Self.isUITesting {
            configureForUITesting()
        }

        // HTTP server is started via ImprintAppDelegate.applicationDidFinishLaunching
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
        // Project browser window
        WindowGroup("imprint", id: "project-browser") {
            ProjectBrowserView()
                .withAppearance()
        }
        .defaultSize(width: 800, height: 600)

        #if os(macOS)
        // Cross-document search window — indexed from the shared store
        // by `ManuscriptSearchService`. Opened with Cmd+Shift+F.
        Window("Search Across Manuscripts", id: "cross-document-search") {
            CrossDocumentSearchView(onClose: {
                NSApp.keyWindow?.close()
            })
            .withAppearance()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        #endif

        // Document editing windows (existing)
        DocumentGroup(newDocument: Self.createInitialDocument()) { file in
            ContentView(document: file.$document)
                .frame(minWidth: 700, minHeight: 400)
                .environment(appState)
                .withAppearance()
                .task {
                    // Start heartbeat for SiblingDiscovery
                    Task.detached {
                        while !Task.isCancelled {
                            ImpressNotification.postHeartbeat(from: .imprint)
                            try? await Task.sleep(for: .seconds(25))
                        }
                    }
                    // Observe library changes from imbib to invalidate citation cache
                    let _ = ImpressNotification.observe(ImpressNotification.libraryChanged, from: .imbib) {
                        Task { @MainActor in
                            NotificationCenter.default.post(name: .insertCitation, object: "refresh")
                        }
                    }
                }
                .onAppear {
                    // In UI testing mode, auto-create an untitled document if none open
                    if Self.isUITesting {
                        UITestingSupport.ensureDocumentOpen()
                    }

                    // Register document with HTTP API registry
                    DocumentRegistry.shared.register(file.document, fileURL: file.fileURL)

                    // Wire git lifecycle — notify integration of document open
                    ImprintGitIntegration.shared.documentOpened(at: file.fileURL)
                }
                .onDisappear {
                    // Unregister document when closed
                    DocumentRegistry.shared.unregister(file.document, fileURL: file.fileURL)

                    // Wire git lifecycle — notify integration of document close
                    ImprintGitIntegration.shared.documentClosed()
                }
                .onChange(of: file.document) { _, newDoc in
                    // Update registry when document changes
                    DocumentRegistry.shared.register(newDoc, fileURL: file.fileURL)
                }
                .onReceive(NotificationCenter.default.publisher(for: .imprintDocumentDidSave)) { _ in
                    // Wire git lifecycle — notify integration of document save
                    ImprintGitIntegration.shared.documentSaved(at: file.fileURL)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    _ = SpotlightDeepLinkHandler.handle(activity, currentApp: .imprint) { uuid, _ in
                        NotificationCenter.default.post(
                            name: .openDocument,
                            object: nil,
                            userInfo: ["documentID": uuid.uuidString]
                        )
                    }
                }
                .onOpenURL { url in
                    Task {
                        await URLSchemeHandler.shared.handleURL(url)
                    }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            // File menu additions — augment the standard "New" command
            // (which creates a Typst .imprint document) with a sibling
            // "New LaTeX Document" that creates a .tex-format buffer.
            CommandGroup(after: .newItem) {
                Button("New LaTeX Document") {
                    Self.pendingNewDocumentFormat = .latex
                    NSDocumentController.shared.newDocument(nil)
                }
                .keyboardShortcut("N", modifiers: [.command, .option])
            }

            // Edit menu additions
            CommandGroup(after: .textEditing) {
                Button("Insert Citation...") {
                    NotificationCenter.default.post(name: .insertCitation, object: nil)
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])

                Button("Add Comment...") {
                    NotificationCenter.default.post(name: .addCommentAtSelection, object: nil)
                }
                .keyboardShortcut("M", modifiers: [.command, .shift])

                Divider()

                Button("Symbol Palette...") {
                    NotificationCenter.default.post(name: .showSymbolPalette, object: nil)
                }
                .keyboardShortcut("Y", modifiers: [.command, .shift])

                Button("AI Assistant...") {
                    NotificationCenter.default.post(name: .showAIContextMenu, object: nil)
                }
                .keyboardShortcut("A", modifiers: [.command, .shift])

                Divider()

                Button("Compile to PDF") {
                    NotificationCenter.default.post(name: .compileDocument, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Divider()

                Button("Search Across Manuscripts…") {
                    openWindow(id: "cross-document-search")
                }
                .keyboardShortcut("F", modifiers: [.command, .shift])
            }

            // View menu additions
            CommandGroup(after: .sidebar) {
                Picker("Edit Mode", selection: $appState.editMode) {
                    Text("Direct PDF").tag(EditMode.directPdf)
                    Text("Split View").tag(EditMode.splitView)
                    Text("Text Only").tag(EditMode.textOnly)
                }
                .keyboardShortcut(.tab)

                Divider()

                Button(appState.isFocusMode ? "Exit Focus Mode" : "Focus Mode") {
                    NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
                }
                .keyboardShortcut("F", modifiers: [.command, .shift])

                Divider()

                Button(appState.showingAIAssistant ? "Hide AI Assistant" : "Show AI Assistant") {
                    NotificationCenter.default.post(name: .toggleAIAssistant, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command])

                Button(appState.showingComments ? "Hide Comments" : "Show Comments") {
                    NotificationCenter.default.post(name: .toggleCommentsSidebar, object: nil)
                }
                .keyboardShortcut("K", modifiers: [.command, .option])

                Divider()

                Button("Show Console") {
                    openWindow(id: "console")
                }
                .keyboardShortcut("C", modifiers: [.command, .shift])
            }

            // Format menu
            CommandMenu("Format") {
                Button("Bold") {
                    NotificationCenter.default.post(name: .formatBold, object: nil)
                }
                .keyboardShortcut("B", modifiers: [.command])

                Button("Italic") {
                    NotificationCenter.default.post(name: .formatItalic, object: nil)
                }
                .keyboardShortcut("I", modifiers: [.command])

                Divider()

                Menu("Heading") {
                    Button("Heading 1") {
                        NotificationCenter.default.post(name: .insertHeading, object: 1)
                    }
                    .keyboardShortcut("1", modifiers: [.command, .option])

                    Button("Heading 2") {
                        NotificationCenter.default.post(name: .insertHeading, object: 2)
                    }
                    .keyboardShortcut("2", modifiers: [.command, .option])

                    Button("Heading 3") {
                        NotificationCenter.default.post(name: .insertHeading, object: 3)
                    }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                }
            }

            // File menu: Print compiled PDF
            CommandGroup(replacing: .printItem) {
                Button("Print Compiled PDF...") {
                    NotificationCenter.default.post(name: .printPDF, object: nil)
                }
                .keyboardShortcut("P", modifiers: [.command])
            }

            // Git menu
            CommandMenu("Git") {
                Button("Commit...") {
                    NotificationCenter.default.post(name: .gitCommit, object: nil)
                }
                .keyboardShortcut("G", modifiers: [.command, .option])

                Button("Push") {
                    NotificationCenter.default.post(name: .gitPush, object: nil)
                }
                .keyboardShortcut("P", modifiers: [.command, .shift])

                Button("Pull") {
                    NotificationCenter.default.post(name: .gitPull, object: nil)
                }
                .keyboardShortcut("U", modifiers: [.command, .shift])

                Divider()

                Button("Link Repository...") {
                    NotificationCenter.default.post(name: .gitLink, object: nil)
                }

                Button("Create GitHub Repository...") {
                    NotificationCenter.default.post(name: .gitCreateRepo, object: nil)
                }

                Divider()

                Button("History...") {
                    NotificationCenter.default.post(name: .gitHistory, object: nil)
                }
            }

            // Document menu
            CommandMenu("Document") {
                Button("Export PDF...") {
                    NotificationCenter.default.post(name: .exportPDF, object: nil)
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])

                Button("Export to LaTeX...") {
                    NotificationCenter.default.post(name: .exportLatex, object: nil)
                }

                Button("Export Bibliography...") {
                    NotificationCenter.default.post(name: .exportBibliography, object: nil)
                }

                Divider()

                Button("Version History...") {
                    NotificationCenter.default.post(name: .showVersionHistory, object: nil)
                }
                .keyboardShortcut("H", modifiers: [.command, .option])

                Divider()

                Button("Share...") {
                    NotificationCenter.default.post(name: .shareDocument, object: nil)
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }
        }

        // Settings window
        #if os(macOS)
        Settings {
            SettingsView()
                .background(WindowShadowInvalidator())
        }

        // Console window
        Window("Console", id: "console") {
            ConsoleView(appName: "imprint")
        }
        .defaultSize(width: 800, height: 400)
        #endif
    }
}

// MARK: - App State

/// Global application state
@MainActor @Observable
class AppState {
    /// Current edit mode (cycles with Tab)
    var editMode: EditMode = .splitView

    /// Document format for the currently open document (set when document opens)
    var documentFormat: DocumentFormat = .typst

    /// Whether the citation picker is showing
    var showingCitationPicker = false

    /// Whether version history is showing
    var showingVersionHistory = false

    /// Whether focus mode is active (distraction-free editing)
    var isFocusMode = false

    /// Whether the AI assistant sidebar is visible
    var showingAIAssistant = false

    /// Whether the comments sidebar is visible
    var showingComments = false

    /// Currently selected text (for AI actions)
    var selectedText = ""

    /// Currently selected text range (for comments)
    var selectedRange: NSRange?
}

/// Editing modes for imprint
enum EditMode: String, CaseIterable {
    /// Direct PDF manipulation (WYSIWYG-like)
    case directPdf = "direct_pdf"

    /// Split view with source and preview
    case splitView = "split_view"

    /// Text only (focus mode)
    case textOnly = "text_only"

    /// Cycle to the next mode
    mutating func cycle() {
        switch self {
        case .directPdf: self = .splitView
        case .splitView: self = .textOnly
        case .textOnly: self = .directPdf
        }
    }

    /// SF Symbol name for the mode
    var iconName: String {
        switch self {
        case .directPdf: return "doc.richtext"
        case .splitView: return "rectangle.split.2x1"
        case .textOnly: return "doc.text"
        }
    }

    /// Help text for toolbar tooltip
    var helpText: String {
        switch self {
        case .directPdf: return "Direct PDF Mode"
        case .splitView: return "Split View Mode"
        case .textOnly: return "Text Only Mode"
        }
    }

    /// Accessibility identifier for UI testing
    var accessibilityIdentifier: String {
        switch self {
        case .directPdf: return "toolbar.mode.directPdf"
        case .splitView: return "toolbar.mode.splitView"
        case .textOnly: return "toolbar.mode.textOnly"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let insertCitation = Notification.Name("insertCitation")
    static let compileDocument = Notification.Name("compileDocument")
    static let formatBold = Notification.Name("formatBold")
    static let formatItalic = Notification.Name("formatItalic")
    static let insertHeading = Notification.Name("insertHeading")
    static let printPDF = Notification.Name("printPDF")
    static let exportPDF = Notification.Name("exportPDF")
    static let exportLatex = Notification.Name("exportLatex")
    static let exportBibliography = Notification.Name("exportBibliography")
    static let showVersionHistory = Notification.Name("showVersionHistory")
    static let shareDocument = Notification.Name("shareDocument")
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
    static let toggleAIAssistant = Notification.Name("toggleAIAssistant")
    static let toggleCommentsSidebar = Notification.Name("toggleCommentsSidebar")
    static let addCommentAtSelection = Notification.Name("addCommentAtSelection")
    static let showAIContextMenu = Notification.Name("showAIContextMenu")
    static let showSymbolPalette = Notification.Name("showSymbolPalette")
    static let formatDocument = Notification.Name("formatDocument")

    // Git
    static let gitCommit = Notification.Name("gitCommit")
    static let gitPush = Notification.Name("gitPush")
    static let gitPull = Notification.Name("gitPull")
    static let gitLink = Notification.Name("gitLink")
    static let gitCreateRepo = Notification.Name("gitCreateRepo")
    static let gitHistory = Notification.Name("gitHistory")

    // Document lifecycle
    static let imprintDocumentDidSave = Notification.Name("imprintDocumentDidSave")
}

// MARK: - Window Shadow Fix (macOS 26 compositor workaround)

/// NSViewRepresentable that disables the window shadow on its hosting window.
///
/// Works around a macOS 26 Liquid Glass compositor bug where opening a Settings
/// window causes the shadow on sibling windows to accumulate (grow) instead of
/// being properly composited. Disabling the shadow on the Settings window itself
/// prevents the compositor from entering the broken shadow-caching path.
private struct WindowShadowInvalidator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Find and disable shadow on the Settings window
            if let window = view.window {
                window.hasShadow = false
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - UI Testing Support

extension ImprintApp {
    /// Create the initial document based on launch arguments
    static func createInitialDocument() -> ImprintDocument {
        if useSampleDocument {
            return ImprintDocument.sampleDocument()
        }
        // One-shot consume of the pending format flag — set by the
        // "New LaTeX Document" menu command before calling
        // NSDocumentController.shared.newDocument(nil).
        if let pending = pendingNewDocumentFormat {
            pendingNewDocumentFormat = nil
            return ImprintDocument(format: pending)
        }
        return ImprintDocument()
    }
}

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

    /// Ensure at least one document window is open for testing
    static func ensureDocumentOpen() {
        #if os(macOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // If no windows are open, create a new document
            if NSApplication.shared.windows.filter({ $0.isVisible }).isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
        #endif
    }
}

// MARK: - Sample Document

extension ImprintDocument {
    /// Create a sample document for testing
    static func sampleDocument() -> ImprintDocument {
        var doc = ImprintDocument()
        doc.source = """
        = Sample Document

        This is a sample document for UI testing.

        == Introduction

        Lorem ipsum dolor sit amet, consectetur adipiscing elit.

        == Methods

        The methodology involves several steps:

        + First step
        + Second step
        + Third step

        == Results

        The equation $E = m c^2$ is fundamental to physics.

        == Conclusion

        In conclusion, this sample document demonstrates basic Typst features.
        """
        return doc
    }
}
#endif // os(macOS)
