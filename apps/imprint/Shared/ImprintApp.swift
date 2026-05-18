#if os(macOS)
import AppKit
import CoreData
import CoreSpotlight
import UniformTypeIdentifiers
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

        // Ensure default workspace exists for any one-shot migration
        // that still reads from the legacy Core Data store. The
        // metadata-cache refresh was retired in Phase F2 — the unified
        // store carries authoritative title/authors on each manuscript
        // item, so there's no separate cache to refresh.
        Task { @MainActor in
            ImprintPersistenceController.shared.ensureDefaultWorkspace()
        }

        // Register the App Intents service so Siri Shortcuts, App Intents, and
        // MCP-via-HTTP can all resolve to a single concrete implementation.
        Task { @MainActor in
            ImprintIntentServiceLocator.service = ImprintIntentServiceImpl.shared
        }

        // Touch the shared store adapter to trigger its setup (opens shared workspace directory).
        // Non-fatal: if the app group container is unavailable, isReady stays false
        // and all storeSection() calls are no-ops.
        Task { @MainActor in
            _ = ImprintStoreAdapter.shared.isReady
        }

        // Phase 3 of the unified-store pivot: run the one-shot migration
        // from CDWorkspace/CDFolder/CDDocumentReference into manuscript-
        // collection + manuscript items. Idempotent; safe to call on
        // every launch. Deferred 5s so it runs after the initial UI
        // settle (mirrors the 60-90s startup-render-loop precedent from
        // imbib's MEMORY but at a milder 5s — phase 3 is one-shot work,
        // not a recurring background service).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            _ = ManuscriptMigrationRunner.runIfNeeded()
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
                // Phase 4b: prefer the manuscript store (the new path).
                // The Spotlight provider indexes both store + legacy
                // CDDocumentReference entries; migration preserves UUIDs
                // so the same uuid resolves on both sides.
                if ManuscriptStoreAdapter.shared.manuscript(id: uuid) != nil {
                    NotificationCenter.default.post(
                        name: .openManuscriptInEditor,
                        object: nil,
                        userInfo: ["manuscriptID": uuid]
                    )
                    return
                }
                // Legacy fallback: registry was populated by
                // DocumentGroup. After Phase 4b that scene is gone,
                // so this path effectively never fires — kept for
                // forward compatibility if a future refactor
                // re-introduces transient documents.
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

    /// Foundation for the eventual DocumentGroup retirement (Phase 4b
    /// of /Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md).
    ///
    /// When the system asks the app to open file URLs (Finder
    /// double-click, drag-drop onto Dock icon), route them through
    /// `ManuscriptImporter` so they land in the unified store and open
    /// in the new editor — instead of becoming `FileDocument`-backed
    /// editor windows.
    ///
    /// Today this method coexists with `DocumentGroup`'s UTI binding:
    /// `DocumentGroup` claims the `.imprint` / `.tex` UTIs (per
    /// Info.plist's `CFBundleDocumentTypes`) and intercepts the URLs
    /// before this delegate sees them. The hook lives here so that
    /// when DocumentGroup is finally retired, no code change is
    /// needed to keep Finder opens working — just the Info.plist UTI
    /// claims (which already point at imprint) will be enough.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            for url in urls {
                // imprint:// URL scheme: handled by URLSchemeHandler
                // (the legacy path was an `.onOpenURL` on DocumentGroup).
                if url.scheme == "imprint" {
                    await URLSchemeHandler.shared.handleURL(url)
                    continue
                }
                // file:// URLs: import into the unified store.
                guard url.isFileURL else { continue }
                let ext = url.pathExtension.lowercased()
                guard ["tex", "ltx", "imprint"].contains(ext) else {
                    logInfo(
                        "Ignoring open for unsupported file extension: \(url.lastPathComponent)",
                        category: "documents"
                    )
                    continue
                }
                do {
                    let result = try ManuscriptImporter.importDocument(at: url)
                    NotificationCenter.default.post(
                        name: .openManuscriptInEditor,
                        object: nil,
                        userInfo: ["manuscriptID": result.manuscriptID]
                    )
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't import \(url.lastPathComponent)"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}

extension NSNotification.Name {
    /// Posted by `ImprintAppDelegate.application(_:open:)` after a
    /// successful import. A SwiftUI scene observes this and calls
    /// `openWindow(id: "manuscript-editor", value: manuscriptID)` to
    /// pop the editor — the delegate has no access to `openWindow`.
    static let openManuscriptInEditor = NSNotification.Name("com.imprint.openManuscriptInEditor")

    /// Posted with `userInfo["documentID"]` (UUID string) when a UI
    /// element wants to deep-link into a manuscript — e.g. clicking a
    /// Spotlight result, or a cross-document-search hit. The delegate's
    /// observer (see `applicationDidFinishLaunching`) resolves it via
    /// `ManuscriptStoreAdapter` and pops the editor window.
    ///
    /// Previously declared in the now-retired `ProjectBrowserView`;
    /// rehomed here as part of the Phase F2 cleanup.
    static let openDocumentByID = NSNotification.Name("com.imprint.openDocumentByID")
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

    /// File → New Typst/LaTeX Manuscript handler. Creates an empty
    /// manuscript in the unified store and opens an editor window
    /// for it. Replaces the old `NSDocumentController.shared.newDocument`
    /// path that was DocumentGroup-bound.
    private func createNewManuscript(format: ManuscriptFormat) {
        do {
            let id = try ManuscriptStoreAdapter.shared.createManuscript(
                title: format == .latex ? "Untitled.tex" : "Untitled",
                format: format
            )
            openWindow(id: "manuscript-editor", value: id)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't create manuscript"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// File → Import to Manuscript Library… handler. Opens an
    /// NSOpenPanel for .tex / .imprint files, runs the importer, and
    /// pops a manuscript-editor window for each successful import.
    ///
    /// Errors are surfaced through `NSAlert` because this is a
    /// user-driven flow — silent failure here would be confusing.
    private func handleImportToLibrary() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Import into Manuscript Library"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "tex") ?? .plainText,
            UTType(filenameExtension: "ltx") ?? .plainText,
            UTType(filenameExtension: "imprint") ?? .package,
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true       // .imprint bundles are dirs
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK else { return }
        Task { @MainActor in
            for url in panel.urls {
                do {
                    let result = try ManuscriptImporter.importDocument(at: url)
                    openWindow(id: "manuscript-editor", value: result.manuscriptID)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Import failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
        #endif
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
        // Project browser window. This is the always-present scene
        // (no UTI bindings), so the app-wide commands attach here —
        // they survive the eventual retirement of `DocumentGroup`
        // for the macOS path (Phase 4b of
        // /Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md).
        // Project browser window (post-Phase-4b cleanup). Hosts the
        // ManuscriptLibraryView directly — the legacy CD-backed
        // `ProjectBrowserView` is retired now that the unified store
        // holds all manuscripts. The scene id "project-browser" is
        // preserved so external integrations (URL scheme, openWindow
        // callers) keep working without a transition step.
        WindowGroup("imprint", id: "project-browser") {
            ManuscriptLibraryView()
                .withAppearance()
                .onReceive(
                    NotificationCenter.default.publisher(for: .openManuscriptInEditor)
                ) { notification in
                    // Posted by ImprintAppDelegate.application(_:open:)
                    // after a successful Finder open + import. The
                    // delegate can't call openWindow itself (no
                    // SwiftUI environment), so it asks us to do it.
                    guard
                        let id = notification.userInfo?["manuscriptID"] as? UUID
                    else { return }
                    openWindow(id: "manuscript-editor", value: id)
                }
                // Spotlight result continuation. Previously lived on
                // the (now-retired) DocumentGroup scene. The handler
                // posts `.openDocument` with the document UUID; the
                // app delegate observes that and either opens the
                // legacy doc URL (if DocumentRegistry still knows it)
                // or opens the manuscript-store editor window
                // (preferred — set up by Phase 4a's dual-read paths).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    _ = SpotlightDeepLinkHandler.handle(activity, currentApp: .imprint) { uuid, _ in
                        NotificationCenter.default.post(
                            name: .openDocument,
                            object: nil,
                            userInfo: ["documentID": uuid.uuidString]
                        )
                    }
                }
        }
        .defaultSize(width: 800, height: 600)
        .commands { sharedCommands }

        #if os(macOS)
        // The dedicated "manuscript-library" scene was retired in the
        // Phase F2 cleanup — `project-browser` (above) now hosts the
        // library directly. The "Open Manuscript Library" menu command
        // points at `project-browser` so the keystroke still works.

        // Phase 2 + 4b: editor window for a manuscript in the unified
        // store. Opened from the library list or after a successful
        // import via `openWindow(id: "manuscript-editor", value: manuscriptID)`.
        //
        // The editor reuses the rich `ContentView` via a bridged
        // `ImprintDocument` (loaded from `ManuscriptStoreAdapter`,
        // body edits debounced back). This keeps every editor feature
        // — syntax highlighting, citation insert, plots panel, AI
        // assistant — working in the manuscript-keyed path, which
        // unblocks the eventual full retirement of `DocumentGroup`.
        WindowGroup("Manuscript Editor", id: "manuscript-editor", for: UUID.self) { $manuscriptID in
            if let id = manuscriptID {
                ManuscriptEditorView(manuscriptID: id)
                    .environment(appState)
                    .withAppearance()
            } else {
                Text("No manuscript selected")
                    .foregroundStyle(.secondary)
            }
        }
        .defaultSize(width: 900, height: 600)
        #endif

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

        // DocumentGroup-based editor retired in Phase 4b. File opens
        // go through `ImprintAppDelegate.application(_:open:)` →
        // `ManuscriptImporter` → `manuscript-editor` WindowGroup
        // (above). The imprint:// URL scheme is also handled by the
        // delegate. Spotlight continuation is on `project-browser`
        // (above). DocumentRegistry stays as a value cache for any
        // remaining legacy callers but is no longer populated by an
        // active editor scene — the dual-read fallbacks added in
        // Phase 4a route those through the manuscript store.

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

    // MARK: - App-wide commands
    //
    // Lifted out of the (eventually retiring) `DocumentGroup` scene so
    // they survive when that scene is gated off on macOS — see Phase 4b
    // of /Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md.
    // Attached to the project-browser `WindowGroup` above, which is the
    // always-present scene.
    @CommandsBuilder
    private var sharedCommands: some Commands {
        // File menu additions — augment the standard "New" command
        // (which creates a Typst .imprint document) with a sibling
        // "New LaTeX Document" that creates a .tex-format buffer.
        CommandGroup(replacing: .newItem) {
            // Phase 4b: replaces the old NSDocumentController-driven
            // File > New with adapter-backed manuscript creation.
            // Both formats create a fresh `manuscript` item in the
            // unified store and pop the editor window for it.
            Button("New Typst Manuscript") {
                createNewManuscript(format: .typst)
            }
            .keyboardShortcut("N", modifiers: [.command])

            Button("New LaTeX Manuscript") {
                createNewManuscript(format: .latex)
            }
            .keyboardShortcut("N", modifiers: [.command, .option])

            Divider()

            Button("Open Manuscript Library") {
                openWindow(id: "project-browser")
            }
            .keyboardShortcut("L", modifiers: [.command, .shift])

            Button("Import to Manuscript Library…") {
                handleImportToLibrary()
            }
            .keyboardShortcut("I", modifiers: [.command, .shift])
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

            Button("Show Plots Panel") {
                NotificationCenter.default.post(name: .toggleVeuszPlotsPanel, object: nil)
            }
            .keyboardShortcut("P", modifiers: [.command, .option])
        }

        CommandGroup(after: .pasteboard) {
            Button("Insert Veusz Plot…") {
                NotificationCenter.default.post(name: .presentVeuszPlotPicker, object: nil)
            }
            .keyboardShortcut("I", modifiers: [.command, .shift])
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

    /// Whether the Veusz plots inspector panel is visible
    var showingVeuszPlots = false

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
    static let toggleVeuszPlotsPanel = Notification.Name("toggleVeuszPlotsPanel")
    static let presentVeuszPlotPicker = Notification.Name("presentVeuszPlotPicker")
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
