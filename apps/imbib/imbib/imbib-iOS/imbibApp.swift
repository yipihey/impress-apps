//
//  imbibApp.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import CoreData
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

    // MARK: - Initialization

    init() {
        appLogger.info("imbib iOS app initializing...")

        // Use shared credential manager singleton for persistence
        let credentialManager = CredentialManager.shared
        let sourceManager = SourceManager(credentialManager: credentialManager)
        let repository = PublicationRepository()
        let deduplicationService = DeduplicationService()

        appLogger.info("Created shared dependencies")

        // Initialize LibraryManager first
        _libraryManager = State(initialValue: LibraryManager())

        appLogger.info("LibraryManager initialized")

        // Initialize ViewModels
        _libraryViewModel = State(initialValue: LibraryViewModel(repository: repository))
        _searchViewModel = State(initialValue: SearchViewModel(
            sourceManager: sourceManager,
            deduplicationService: deduplicationService,
            repository: repository
        ))
        _settingsViewModel = State(initialValue: SettingsViewModel(
            sourceManager: sourceManager,
            credentialManager: credentialManager
        ))

        appLogger.info("ViewModels initialized")

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

            // Deduplicate feeds first (CloudKit sync can create duplicates)
            // This runs async to ensure Core Data is fully initialized
            await MainActor.run {
                let duplicatesRemoved = FeedDeduplicationService.shared.deduplicateFeeds(
                    in: PersistenceController.shared.viewContext
                )
                if duplicatesRemoved > 0 {
                    appLogger.info("Feed deduplication: removed \(duplicatesRemoved) duplicate(s)")
                }
            }

            await sourceManager.registerBuiltInSources()
            appLogger.info("Built-in sources registered")

            // Register browser URL providers for interactive PDF downloads
            // Higher priority = tried first. ArXiv has highest priority (direct PDF, always free)
            await BrowserURLProviderRegistry.shared.register(ArXivSource.self, priority: 20)
            await BrowserURLProviderRegistry.shared.register(ADSSource.self, priority: 10)
            appLogger.info("BrowserURLProviders registered")

            // Configure staggered smart search refresh service (before InboxCoordinator)
            await SmartSearchRefreshService.shared.configure(
                sourceManager: sourceManager,
                repository: repository
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

// Note: Notification.Name extensions are now defined in PublicationManagerCore/Notifications.swift
// Note: ShareExtensionError is now defined in PublicationManagerCore/SharedExtension/ShareExtensionError.swift

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
        appLogger.info("Auto-building embedding index for search...")

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
            appLogger.info("Auto-built embedding index with \(count) publications from \(libraries.count) libraries")
        }
    } else if !embeddingAvailable {
        appLogger.debug("Embedding service not available, skipping auto-index")
    } else {
        appLogger.debug("Embedding index already built, skipping auto-index")
    }
}
