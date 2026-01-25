//
//  imbibApp.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import CoreData
import PublicationManagerCore
import OSLog
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private let appLogger = Logger(subsystem: "com.imbib.app", category: "app")

// MARK: - App Delegate for URL Scheme Handling

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    private func debugLog(_ message: String) {
        // Use NSLog which works in sandboxed apps and shows in Console.app
        NSLog("[DEBUG] %@", message)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("AppDelegate.applicationDidFinishLaunching called")

        // Clear any corrupted SwiftUI window state on launch
        // This prevents oversized windows from being restored
        sanitizeWindowDefaults()
    }

    /// Remove corrupted SwiftUI window state that could cause oversized windows.
    /// Checks against actual current screen dimensions to catch size mismatches.
    private func sanitizeWindowDefaults() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        // Get the maximum screen dimensions from all connected displays
        let maxScreenHeight = NSScreen.screens.map { $0.frame.height }.max() ?? 1080
        let maxScreenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1920

        // Add some tolerance (10%) for edge cases
        let maxAllowedHeight = maxScreenHeight * 1.1
        let maxAllowedWidth = maxScreenWidth * 1.1

        for key in allKeys {
            // Check for SwiftUI window frame and split view entries
            if key.contains("SwiftUI") && (key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSSplitView")) {
                // Check if it contains oversized dimensions
                if let value = defaults.object(forKey: key) {
                    var shouldDelete = false

                    // For NSWindow Frame strings like "x y width height screenX screenY screenWidth screenHeight"
                    if let frameString = value as? String {
                        let parts = frameString.split(separator: " ").compactMap { Double($0) }
                        if parts.count >= 4 {
                            let width = parts[2]
                            let height = parts[3]
                            // If window is larger than current screen configuration
                            if width > maxAllowedWidth || height > maxAllowedHeight {
                                shouldDelete = true
                                appLogger.info("Removing oversized window frame: \(key.prefix(60))... (\(Int(width))x\(Int(height)) > \(Int(maxAllowedWidth))x\(Int(maxAllowedHeight)))")
                            }
                        }
                    }

                    // For NSSplitView arrays
                    if let frameArray = value as? [String] {
                        for frameString in frameArray {
                            let parts = frameString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            if parts.count >= 4,
                               let width = Double(parts[2]),
                               let height = Double(parts[3]) {
                                // If split view dimension is larger than current screen
                                if width > maxAllowedWidth || height > maxAllowedHeight {
                                    shouldDelete = true
                                    appLogger.info("Removing oversized split view: \(key.prefix(60))... (dim: \(Int(width))x\(Int(height)))")
                                    break
                                }
                            }
                        }
                    }

                    if shouldDelete {
                        defaults.removeObject(forKey: key)
                    }
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        debugLog("AppDelegate.application(open:) called with \(urls.count) URLs")
        for url in urls {
            debugLog("Processing URL: \(url.absoluteString)")
            if url.scheme == "imbib" {
                Task {
                    await URLSchemeHandler.shared.handle(url)
                }
            }
        }
    }
}
#endif

@main
struct imbibApp: App {

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    // MARK: - State

    @State private var libraryManager: LibraryManager
    @State private var libraryViewModel: LibraryViewModel
    @State private var searchViewModel: SearchViewModel
    @State private var settingsViewModel: SettingsViewModel
    @State private var shareExtensionHandler: ShareExtensionHandler?

    /// Development mode: edit the bundled default library set
    private let isEditingDefaultSet: Bool

    // MARK: - Initialization

    /// Dependencies created during app initialization, used for async setup.
    private struct AppDependencies: Sendable {
        let credentialManager: CredentialManager
        let sourceManager: SourceManager
        let repository: PublicationRepository
        let deduplicationService: DeduplicationService
    }

    init() {
        let appStart = CFAbsoluteTimeGetCurrent()

        // Phase 1: Development mode flags (--edit-default-set, --show-welcome-screen, UI testing)
        isEditingDefaultSet = Self.setupDevelopmentModeFlags()
        appLogger.info("imbib app initializing...")

        // Phase 2: Data layer setup (migrations, Core Data, shared services)
        let deps = Self.setupDataLayer()

        // Phase 3: Initialize view models with dependencies
        let (libraryManager, libraryViewModel, searchViewModel, settingsViewModel) = Self.setupViewModels(deps: deps)
        _libraryManager = State(initialValue: libraryManager)
        _libraryViewModel = State(initialValue: libraryViewModel)
        _searchViewModel = State(initialValue: searchViewModel)
        _settingsViewModel = State(initialValue: settingsViewModel)

        // Phase 4: Set up notification observers for extensions
        Self.setupNotificationObservers()

        // Phase 5: Schedule background initialization (async)
        Self.scheduleBackgroundInit(deps: deps)

        appLogger.info("⏱ TOTAL app init: \(Int((CFAbsoluteTimeGetCurrent() - appStart) * 1000))ms")
    }

    // MARK: - Initialization Phases

    /// Phase 1: Set up development mode flags and handle special launch modes.
    /// Returns whether we're in edit-default-set mode.
    private static func setupDevelopmentModeFlags() -> Bool {
        #if os(macOS)
        let editingDefaultSet = CommandLine.arguments.contains("--edit-default-set")
        if editingDefaultSet {
            appLogger.info("Running in edit-default-set mode")
        }

        // Handle --show-welcome-screen flag (shows welcome screen without resetting data)
        if FirstRunManager.shouldShowWelcomeScreen {
            appLogger.info("--show-welcome-screen flag detected, will show welcome screen")
            // Set force flag so ContentView shows the onboarding sheet
            OnboardingManager.forceShowOnboarding = true
        }

        // Handle UI testing mode
        if UITestingConfiguration.isUITesting {
            UITestingConfiguration.logConfiguration()
            // Note: State reset is handled asynchronously in scheduleBackgroundInit
            // to avoid deadlock with @MainActor
        }

        return editingDefaultSet
        #else
        return false
        #endif
    }

    /// Phase 2: Set up the data layer - run migrations, create shared dependencies.
    private static func setupDataLayer() -> AppDependencies {
        var stepStart = CFAbsoluteTimeGetCurrent()

        // Run data migrations (backfill indexed fields, year from rawFields, etc.)
        // Skip migrations in UI testing mode to avoid interference with test data
        if !UITestingEnvironment.isUITesting {
            PersistenceController.shared.runMigrations()
            appLogger.info("⏱ Migrations complete: \(Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000))ms")
        } else {
            appLogger.info("UI testing mode: skipping migrations")
            // Seed test data if requested
            TestDataSeeder.seedIfNeeded(context: PersistenceController.shared.viewContext)
        }

        // Create shared dependencies
        stepStart = CFAbsoluteTimeGetCurrent()
        let credentialManager = CredentialManager.shared
        let sourceManager = SourceManager(credentialManager: credentialManager)
        let repository = PublicationRepository()
        let deduplicationService = DeduplicationService()
        appLogger.info("⏱ Created shared dependencies: \(Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000))ms")

        return AppDependencies(
            credentialManager: credentialManager,
            sourceManager: sourceManager,
            repository: repository,
            deduplicationService: deduplicationService
        )
    }

    /// Phase 3: Initialize view models with dependencies.
    private static func setupViewModels(deps: AppDependencies) -> (
        LibraryManager,
        LibraryViewModel,
        SearchViewModel,
        SettingsViewModel
    ) {
        var stepStart = CFAbsoluteTimeGetCurrent()

        let libraryManager = LibraryManager()
        appLogger.info("⏱ LibraryManager initialized: \(Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000))ms")

        stepStart = CFAbsoluteTimeGetCurrent()
        let libraryViewModel = LibraryViewModel(repository: deps.repository)
        let searchViewModel = SearchViewModel(
            sourceManager: deps.sourceManager,
            deduplicationService: deps.deduplicationService,
            repository: deps.repository
        )
        let settingsViewModel = SettingsViewModel(
            sourceManager: deps.sourceManager,
            credentialManager: deps.credentialManager
        )
        appLogger.info("⏱ ViewModels initialized: \(Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000))ms")

        return (libraryManager, libraryViewModel, searchViewModel, settingsViewModel)
    }

    /// Phase 4: Set up Darwin notification observers for extensions.
    /// Must be done early, before the app might receive notifications.
    private static func setupNotificationObservers() {
        appLogger.info("⏱ Before Darwin notification setup")
        ShareExtensionHandler.setupDarwinNotificationObserver()
        SafariImportHandler.shared.setupNotificationObserver()
        appLogger.info("⏱ After Darwin notification setup")
    }

    /// Phase 5: Schedule background initialization tasks.
    /// Runs asynchronously to avoid blocking app launch.
    private static func scheduleBackgroundInit(deps: AppDependencies) {
        Task {
            // Handle UI testing mode - reset state and seed data
            if UITestingConfiguration.isUITesting {
                if UITestingConfiguration.shouldResetState {
                    appLogger.info("UI Testing: resetting state")
                    try? await FirstRunManager.shared.resetToFirstRun()
                }
                await UITestingConfiguration.seedTestDataIfNeeded()
            }

            // Initialize full-text search index
            await FullTextSearchService.shared.initialize()
            appLogger.info("Full-text search index initialized")

            // Deduplicate feeds (CloudKit sync can create duplicates)
            await MainActor.run {
                let duplicatesRemoved = FeedDeduplicationService.shared.deduplicateFeeds(
                    in: PersistenceController.shared.viewContext
                )
                if duplicatesRemoved > 0 {
                    appLogger.info("Feed deduplication: removed \(duplicatesRemoved) duplicate(s)")
                }
            }

            // Register built-in sources
            await deps.sourceManager.registerBuiltInSources()
            appLogger.info("Built-in sources registered")

            // Register browser URL providers for interactive PDF downloads
            // Higher priority = tried first. ArXiv has highest priority (direct PDF, always free)
            await BrowserURLProviderRegistry.shared.register(ArXivSource.self, priority: 20)
            await BrowserURLProviderRegistry.shared.register(SciXSource.self, priority: 11)
            await BrowserURLProviderRegistry.shared.register(ADSSource.self, priority: 10)
            appLogger.info("BrowserURLProviders registered")

            // Configure staggered smart search refresh service (before InboxCoordinator)
            await SmartSearchRefreshService.shared.configure(
                sourceManager: deps.sourceManager,
                repository: deps.repository
            )
            appLogger.info("SmartSearchRefreshService configured")

            // Start background enrichment coordinator
            await EnrichmentCoordinator.shared.start()
            appLogger.info("EnrichmentCoordinator started")

            // Start Inbox coordinator (scheduling, fetch service)
            await InboxCoordinator.shared.start()
            appLogger.info("InboxCoordinator started")

            // Set up embedding service change observers for reactive index updates (ADR-022)
            await EmbeddingService.shared.setupChangeObservers()
            appLogger.info("EmbeddingService change observers set up")

            // Auto-build search indexes after a short delay (ADR-022)
            // This ensures Cmd+K global search works without manual setup
            try? await Task.sleep(for: .seconds(3))
            await autoPopulateSearchIndexesOnStartup()
        }
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                .withTheme()
                .environment(libraryManager)
                .environment(libraryViewModel)
                .environment(searchViewModel)
                .environment(settingsViewModel)
                .onAppear {
                    ensureMainWindowVisible()
                    // Initialize share extension handler
                    if shareExtensionHandler == nil {
                        shareExtensionHandler = ShareExtensionHandler(
                            libraryManager: libraryManager,
                            sourceManager: searchViewModel.sourceManager
                        )
                    }
                    // Note: App Group access is deferred until the Safari extension is actually used.
                    // This avoids the TCC "access data from other apps" dialog at startup.
                    // When a Darwin notification arrives from the extension, we process imports
                    // and sync data back to the App Group at that time.
                }
                .onReceive(NotificationCenter.default.publisher(for: ShareExtensionService.sharedURLReceivedNotification)) { _ in
                    Task {
                        await shareExtensionHandler?.handlePendingSharedItems()
                    }
                }
                // Font size keyboard shortcut handlers
                .onReceive(NotificationCenter.default.publisher(for: .increaseFontSize)) { _ in
                    Task {
                        await ThemeSettingsStore.shared.increaseFontScale()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .decreaseFontSize)) { _ in
                    Task {
                        await ThemeSettingsStore.shared.decreaseFontScale()
                    }
                }
                #if os(iOS)
                .onOpenURL { url in
                    // Handle automation URL schemes (imbib://...)
                    if url.scheme == "imbib" {
                        Task {
                            await URLSchemeHandler.shared.handle(url)
                        }
                    }
                }
                #endif
        }
        .commands {
            AppCommands()
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(settingsViewModel)
                .environment(libraryManager)
        }

        Window("Console", id: "console") {
            ConsoleView()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .defaultSize(width: 800, height: 400)

        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            KeyboardShortcutsView()
        }
        .keyboardShortcut("/", modifiers: .command)
        .defaultSize(width: 450, height: 700)

        Window("Help", id: "help") {
            HelpWindowView()
        }
        .defaultSize(width: 900, height: 700)
        #endif
    }

    // MARK: - Window Management

    #if os(macOS)
    /// Ensure the main window is visible and frontmost on launch
    private func ensureMainWindowVisible() {
        DispatchQueue.main.async {
            // Find the main window (the one with ContentView)
            if let mainWindow = NSApplication.shared.windows.first(where: { window in
                window.contentView?.subviews.contains(where: { $0.className.contains("ContentView") }) ?? false
                    || window.title.isEmpty || window.title == "imbib"
            }) {
                mainWindow.makeKeyAndOrderFront(nil)
                appLogger.info("Main window made visible and frontmost")
            } else if NSApplication.shared.windows.isEmpty {
                // No windows at all - this shouldn't happen with WindowGroup
                appLogger.warning("No windows found on launch")
            } else {
                // Fallback: make any non-console window visible
                for window in NSApplication.shared.windows {
                    if window.title != "Console" {
                        window.makeKeyAndOrderFront(nil)
                        appLogger.info("Made window '\(window.title)' visible")
                        break
                    }
                }
            }

            // Set up dock badge observer and initial badge
            setupDockBadge()
        }
    }

    /// Set up dock badge for Inbox unread count
    private func setupDockBadge() {
        // Set initial badge
        updateDockBadge(InboxManager.shared.unreadCount)

        // Observe unread count changes
        NotificationCenter.default.addObserver(
            forName: .inboxUnreadCountChanged,
            object: nil,
            queue: .main
        ) { notification in
            if let count = notification.userInfo?["count"] as? Int {
                updateDockBadge(count)
            }
        }
    }
    #endif
}

#if os(macOS)
/// Update the dock badge with unread count
@MainActor
private func updateDockBadge(_ count: Int) {
    if count > 0 {
        NSApp.dockTile.badgeLabel = "\(count)"
    } else {
        NSApp.dockTile.badgeLabel = nil
    }
}
#endif

// MARK: - App Commands

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    /// Check if running in edit-default-set development mode
    private var isEditingDefaultSet: Bool {
        CommandLine.arguments.contains("--edit-default-set")
    }

    var body: some Commands {
        // Development mode: Export default set
        if isEditingDefaultSet {
            CommandGroup(before: .newItem) {
                Button("Export as Default Library Set...") {
                    exportDefaultLibrarySet()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()
            }
        }

        // File menu
        CommandGroup(after: .newItem) {
            Button("Import BibTeX...") {
                NotificationCenter.default.post(name: .importBibTeX, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command])

            Button("Export Library...") {
                NotificationCenter.default.post(name: .exportBibTeX, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        // Edit menu - context-aware pasteboard commands
        // When a text field has focus, use system clipboard; otherwise, use publication clipboard
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                if isTextFieldFocused() {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else {
                    NotificationCenter.default.post(name: .copyPublications, object: nil)
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Copy as Citation") {
                NotificationCenter.default.post(name: .copyAsCitation, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Copy DOI/URL") {
                NotificationCenter.default.post(name: .copyIdentifier, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button("Cut") {
                if isTextFieldFocused() {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                } else {
                    NotificationCenter.default.post(name: .cutPublications, object: nil)
                }
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Paste") {
                if isTextFieldFocused() {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else {
                    NotificationCenter.default.post(name: .pastePublications, object: nil)
                }
            }
            .keyboardShortcut("v", modifiers: .command)

            Divider()

            Button("Select All") {
                if isTextFieldFocused() {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } else {
                    NotificationCenter.default.post(name: .selectAllPublications, object: nil)
                }
            }
            .keyboardShortcut("a", modifiers: .command)

            Divider()

            // Find submenu (⌘F is handled by ContentView for global search)
            Menu("Find") {
                Button("Focus Search") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
            }
        }

        // View menu
        CommandGroup(after: .sidebar) {
            Button("Command Palette...") {
                NotificationCenter.default.post(name: .showCommandPalette, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Show Library") {
                NotificationCenter.default.post(name: .showLibrary, object: nil)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Show Search") {
                NotificationCenter.default.post(name: .showSearch, object: nil)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Show Inbox") {
                NotificationCenter.default.post(name: .showInbox, object: nil)
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button("Show PDF Tab") {
                NotificationCenter.default.post(name: .showPDFTab, object: nil)
            }
            .keyboardShortcut("4", modifiers: .command)

            Button("Show BibTeX Tab") {
                NotificationCenter.default.post(name: .showBibTeXTab, object: nil)
            }
            .keyboardShortcut("5", modifiers: .command)

            Button("Show Notes Tab") {
                NotificationCenter.default.post(name: .showNotesTab, object: nil)
            }
            .keyboardShortcut("6", modifiers: .command)

            Divider()

            Button("Toggle Detail Pane") {
                NotificationCenter.default.post(name: .toggleDetailPane, object: nil)
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Divider()

            Button("Focus Sidebar") {
                NotificationCenter.default.post(name: .focusSidebar, object: nil)
            }
            .keyboardShortcut("1", modifiers: [.command, .option])

            Button("Focus List") {
                NotificationCenter.default.post(name: .focusList, object: nil)
            }
            .keyboardShortcut("2", modifiers: [.command, .option])

            Button("Focus Detail") {
                NotificationCenter.default.post(name: .focusDetail, object: nil)
            }
            .keyboardShortcut("3", modifiers: [.command, .option])

            Divider()

            Button("Show Console") {
                openWindow(id: "console")
            }
            .keyboardShortcut("c", modifiers: [.control, .command])

            Divider()

            Button("Increase Text Size") {
                NotificationCenter.default.post(name: .increaseFontSize, object: nil)
            }
            .keyboardShortcut("=", modifiers: [.command, .shift])

            Button("Decrease Text Size") {
                NotificationCenter.default.post(name: .decreaseFontSize, object: nil)
            }
            .keyboardShortcut("-", modifiers: [.command, .shift])
        }

        // Paper menu (new)
        CommandMenu("Paper") {
            Button("Open PDF") {
                NotificationCenter.default.post(name: .openSelectedPaper, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Open Notes") {
                NotificationCenter.default.post(name: .showNotesTab, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Open References") {
                NotificationCenter.default.post(name: .openReferences, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Toggle Read/Unread") {
                NotificationCenter.default.post(name: .toggleReadStatus, object: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])

            Button("Mark All as Read") {
                NotificationCenter.default.post(name: .markAllAsRead, object: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .option])

            Divider()

            Button("Keep to Library") {
                NotificationCenter.default.post(name: .keepToLibrary, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.control, .command])

            Button("Dismiss from Inbox") {
                NotificationCenter.default.post(name: .dismissFromInbox, object: nil)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Divider()

            Button("Move to Collection...") {
                NotificationCenter.default.post(name: .moveToCollection, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.control, .command])

            Button("Add to Collection...") {
                NotificationCenter.default.post(name: .addToCollection, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Remove from Collection") {
                NotificationCenter.default.post(name: .removeFromCollection, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("Share...") {
                NotificationCenter.default.post(name: .sharePapers, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Delete") {
                NotificationCenter.default.post(name: .deleteSelectedPapers, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }

        // Annotate menu (PDF annotations)
        CommandMenu("Annotate") {
            Button("Highlight Selection") {
                NotificationCenter.default.post(name: .highlightSelection, object: nil)
            }
            .keyboardShortcut("h", modifiers: .control)

            Button("Underline Selection") {
                NotificationCenter.default.post(name: .underlineSelection, object: nil)
            }
            .keyboardShortcut("u", modifiers: .control)

            Button("Strikethrough Selection") {
                NotificationCenter.default.post(name: .strikethroughSelection, object: nil)
            }
            .keyboardShortcut("t", modifiers: .control)

            Divider()

            Button("Add Note at Selection") {
                NotificationCenter.default.post(name: .addNoteAtSelection, object: nil)
            }
            .keyboardShortcut("n", modifiers: .control)

            Divider()

            Menu("Highlight Color") {
                Button("Yellow") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "yellow"]
                    )
                }
                Button("Green") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "green"]
                    )
                }
                Button("Blue") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "blue"]
                    )
                }
                Button("Pink") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "pink"]
                    )
                }
                Button("Purple") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "purple"]
                    )
                }
            }
        }

        // Go menu (new)
        CommandMenu("Go") {
            Button("Back") {
                NotificationCenter.default.post(name: .navigateBack, object: nil)
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Forward") {
                NotificationCenter.default.post(name: .navigateForward, object: nil)
            }
            .keyboardShortcut("]", modifiers: .command)

            Divider()

            Button("Next Paper") {
                NotificationCenter.default.post(name: .navigateNextPaper, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            Button("Previous Paper") {
                NotificationCenter.default.post(name: .navigatePreviousPaper, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button("First Paper") {
                NotificationCenter.default.post(name: .navigateFirstPaper, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Last Paper") {
                NotificationCenter.default.post(name: .navigateLastPaper, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button("Next Unread") {
                NotificationCenter.default.post(name: .navigateNextUnread, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: .option)

            Button("Previous Unread") {
                NotificationCenter.default.post(name: .navigatePreviousUnread, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: .option)

            Divider()

            Button("Go to Page...") {
                NotificationCenter.default.post(name: .pdfGoToPage, object: nil)
            }
            .keyboardShortcut("g", modifiers: .command)
        }

        // Window menu additions
        CommandGroup(after: .windowArrangement) {
            Divider()

            Button("Refresh") {
                NotificationCenter.default.post(name: .refreshData, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Toggle Unread Filter") {
                NotificationCenter.default.post(name: .toggleUnreadFilter, object: nil)
            }
            .keyboardShortcut("\\", modifiers: .command)

            Button("Toggle PDF Filter") {
                NotificationCenter.default.post(name: .togglePDFFilter, object: nil)
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])

            Divider()

            // Dual-monitor / detached window commands
            Button("Detach PDF to Window") {
                NotificationCenter.default.post(name: .detachPDFTab, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift, .option])

            Button("Detach Notes to Window") {
                NotificationCenter.default.post(name: .detachNotesTab, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift, .option])

            if ScreenConfigurationObserver.shared.hasSecondaryScreen {
                Button("Flip Window Positions") {
                    NotificationCenter.default.post(name: .flipWindowPositions, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift, .option])
            }

            Button("Close Detached Windows") {
                NotificationCenter.default.post(name: .closeDetachedWindows, object: nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift, .option])
        }

        // Help menu
        CommandGroup(replacing: .help) {
            Button("imbib Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)

            Button("Search Help...") {
                NotificationCenter.default.post(name: .showHelpSearchPalette, object: nil)
            }
            .keyboardShortcut("?", modifiers: [.command, .shift])

            Divider()

            Button("Keyboard Shortcuts") {
                openWindow(id: "keyboard-shortcuts")
            }
            .keyboardShortcut("/", modifiers: .command)

            Divider()

            Button("Online Documentation") {
                if let url = URL(string: "https://yipihey.github.io/imbib/") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("What's New") {
                if let url = URL(string: "https://github.com/imbib/imbib/releases/latest") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Report an Issue...") {
                if let url = URL(string: "https://github.com/imbib/imbib/issues") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Release Notes") {
                if let url = URL(string: "https://github.com/imbib/imbib/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Check if an editable text field or text view currently has keyboard focus
    private func isTextFieldFocused() -> Bool {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else {
            return false
        }
        // Check if it's an editable NSTextView (TextField, TextEditor, etc.)
        // Non-editable NSTextViews (used by SwiftUI for rendering) should not capture Cmd+A
        if let textView = firstResponder as? NSTextView {
            return textView.isEditable
        }
        return false
    }

    /// Export current libraries as a default library set (development mode)
    private func exportDefaultLibrarySet() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "DefaultLibrarySet.json"
        panel.message = "Export current libraries as the default set for new users"
        panel.prompt = "Export"

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                do {
                    try DefaultLibrarySetManager.shared.exportCurrentAsDefaultSet(to: url)
                    appLogger.info("Exported default library set to: \(url.lastPathComponent)")

                    // Show success alert
                    let alert = NSAlert()
                    alert.messageText = "Export Successful"
                    alert.informativeText = "Default library set exported to \(url.lastPathComponent)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } catch {
                    appLogger.error("Failed to export default library set: \(error.localizedDescription)")

                    // Show error alert
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
        #endif
    }
}

// Note: Notification.Name extensions are now defined in PublicationManagerCore/Notifications.swift

// MARK: - Auto-populate Search Indexes

/// Auto-populate search indexes if needed on startup.
///
/// Builds the embedding index for semantic search (Cmd+K global search).
/// Called a few seconds after startup to avoid blocking the UI.
private func autoPopulateSearchIndexesOnStartup() async {
    // Only build if embedding service is available and index is not yet built
    let embeddingAvailable = await EmbeddingService.shared.isAvailable
    let hasEmbeddingIndex = await EmbeddingService.shared.hasIndex

    if embeddingAvailable && !hasEmbeddingIndex {
        logInfo("Auto-building embedding index for global search...", category: "embedding")

        // Fetch all user libraries from Core Data (excluding system libraries)
        let libraries = await MainActor.run {
            let context = PersistenceController.shared.viewContext
            let request = NSFetchRequest<CDLibrary>(entityName: "Library")
            // Exclude system libraries: Dismissed, Exploration, and any marked as system
            request.predicate = NSPredicate(
                format: "name != %@ AND name != %@ AND isSystemLibrary == NO",
                "Dismissed", "Exploration"
            )
            return (try? context.fetch(request)) ?? []
        }

        if !libraries.isEmpty {
            let count = await EmbeddingService.shared.buildIndex(from: libraries)
            logInfo("Auto-built embedding index with \(count) publications from \(libraries.count) libraries", category: "embedding")
        }
    }
}
