//
//  imbibApp.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import OSLog
import UserNotifications
import AppIntents

private let appLogger = Logger(subsystem: "com.imbib.app", category: "app")

@main
struct imbibApp: App {

    // MARK: - State

    @State private var libraryManager: LibraryManager
    @State private var libraryViewModel: LibraryViewModel
    @State private var searchViewModel: SearchViewModel
    @State private var settingsViewModel: SettingsViewModel
    @State private var shareExtensionHandler: ShareExtensionHandler?

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        appLogger.info("imbib iOS app initializing...")

        // Use shared credential manager singleton for persistence
        let credentialManager = CredentialManager.shared
        let sourceManager = SourceManager(credentialManager: credentialManager)
        let deduplicationService = DeduplicationService()

        appLogger.info("Created shared dependencies")

        // Initialize LibraryManager first
        _libraryManager = State(initialValue: LibraryManager())

        appLogger.info("LibraryManager initialized")

        // Initialize ViewModels
        _libraryViewModel = State(initialValue: LibraryViewModel())
        _searchViewModel = State(initialValue: SearchViewModel(
            sourceManager: sourceManager,
            deduplicationService: deduplicationService
        ))
        _settingsViewModel = State(initialValue: SettingsViewModel(
            sourceManager: sourceManager,
            credentialManager: credentialManager
        ))

        appLogger.info("ViewModels initialized")

        // Capture libraryManager for use in Task (can't capture self in struct)
        let capturedLibraryManager = libraryManager

        // Register built-in sources and start enrichment
        Task {
            // Register File Provider domain
            do {
                try await FileProviderDomainManager.shared.registerDomain()
                appLogger.info("File Provider domain registered")
            } catch {
                appLogger.error("Failed to register File Provider domain: \(error.localizedDescription)")
            }

            // Initialize full-text search index
            await FullTextSearchService.shared.initialize()
            appLogger.info("Full-text search index initialized")

            await sourceManager.registerBuiltInSources()
            DragDropCoordinator.shared.sourceManager = sourceManager
            appLogger.info("Built-in sources registered")

            // Register browser URL providers for interactive PDF downloads
            // Higher priority = tried first. ArXiv has highest priority (direct PDF, always free)
            await BrowserURLProviderRegistry.shared.register(ArXivSource.self, priority: 20)
            await BrowserURLProviderRegistry.shared.register(ADSSource.self, priority: 10)
            appLogger.info("BrowserURLProviders registered")

            // Configure staggered smart search refresh service (before InboxCoordinator)
            await SmartSearchRefreshService.shared.configure(
                sourceManager: sourceManager
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
            // This ensures global search works without manual setup
            Task {
                try? await Task.sleep(for: .seconds(3))
                await autoPopulateSearchIndexesOnStartup()
            }

            // Cleanup old exploration collections based on retention setting
            await cleanupExplorationCollectionsOnStartup(libraryManager: capturedLibraryManager)
        }

        // Request notification permissions for badge
        requestNotificationPermissions()

        appLogger.info("imbib iOS app initialization complete")
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .withTheme()
                .environment(libraryManager)
                .environment(libraryViewModel)
                .environment(searchViewModel)
                .environment(settingsViewModel)
                .onAppear {
                    setupBadgeObserver()
                    // Initialize share extension handler
                    if shareExtensionHandler == nil {
                        shareExtensionHandler = ShareExtensionHandler(
                            libraryManager: libraryManager,
                            sourceManager: searchViewModel.sourceManager
                        )
                    }
                    // Process any pending shared URLs from share extension
                    Task {
                        await shareExtensionHandler?.handlePendingSharedItems()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: ShareExtensionService.sharedURLReceivedNotification)) { _ in
                    Task {
                        await shareExtensionHandler?.handlePendingSharedItems()
                    }
                }
                .onOpenURL { url in
                    // Handle automation URL scheme requests
                    Task {
                        await URLSchemeHandler.shared.handle(url)
                    }
                }
                // Clear exploration library when going to background if retention is "While App is Open"
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background && SyncedSettingsStore.shared.explorationRetention == .sessionOnly {
                        libraryManager.clearExplorationLibrary()
                        appLogger.info("Cleared exploration library on background (sessionOnly mode)")
                    }
                }
        }
    }

    // MARK: - App Shortcuts

    /// Expose shortcuts provider for Siri and Shortcuts app discovery.
    /// This ensures the intents are linked into the app binary.
    @available(iOS 16.0, *)
    private static let _shortcutsProvider: any AppShortcutsProvider.Type = ImbibShortcuts.self

    // MARK: - Badge Management

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
            if granted {
                appLogger.info("Badge notification permission granted")
            } else if let error = error {
                appLogger.error("Badge permission error: \(error.localizedDescription)")
            }
        }
    }

    private func setupBadgeObserver() {
        // Set initial badge
        updateAppBadge(InboxManager.shared.unreadCount)

        // Observe unread count changes
        NotificationCenter.default.addObserver(
            forName: .inboxUnreadCountChanged,
            object: nil,
            queue: .main
        ) { notification in
            if let count = notification.userInfo?["count"] as? Int {
                updateAppBadge(count)
            }
        }
    }
}

/// Update the app icon badge with unread count
private func updateAppBadge(_ count: Int) {
    UNUserNotificationCenter.current().setBadgeCount(count) { error in
        if let error = error {
            appLogger.error("Failed to set badge: \(error.localizedDescription)")
        }
    }
}

// MARK: - Exploration Cleanup

/// Cleanup old exploration collections based on user's retention setting.
private func cleanupExplorationCollectionsOnStartup(libraryManager: LibraryManager) async {
    let retention = SyncedSettingsStore.shared.explorationRetention
    // Only cleanup if retention is time-based (not forever or sessionOnly)
    // sessionOnly is handled when going to background, forever keeps everything
    if let days = retention.days, days > 0 {
        await MainActor.run {
            libraryManager.cleanupExplorationCollections(olderThanDays: days)
        }
        appLogger.info("Exploration cleanup: retention=\(retention.rawValue)")
    }
}

// MARK: - Auto-populate Search Indexes

/// Auto-populate search indexes if needed on startup.
///
/// Builds the embedding index for semantic search.
/// Called a few seconds after startup to avoid blocking the UI.
private func autoPopulateSearchIndexesOnStartup() async {
    // Only build if embedding service is available and index is not yet built
    let embeddingAvailable = await EmbeddingService.shared.isAvailable
    let hasEmbeddingIndex = await EmbeddingService.shared.hasIndex

    if embeddingAvailable && !hasEmbeddingIndex {
        appLogger.info("Embedding index not yet built — will be built on demand")
    } else if !embeddingAvailable {
        appLogger.debug("Embedding service not available, skipping auto-index")
    } else {
        appLogger.debug("Embedding index already built, skipping auto-index")
    }
}
