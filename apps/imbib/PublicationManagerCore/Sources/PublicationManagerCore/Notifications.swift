//
//  Notifications.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation

// MARK: - Command Dispatch Architecture
//
// imbib uses a notification-based command system for app-wide actions. This pattern
// provides clean separation between input sources (keyboard, menu, URL scheme, Siri)
// and action handlers (views, view models).
//
// ## Design Rationale
//
// The notification pattern was chosen over Combine publishers or direct method calls for:
// 1. **Decoupling**: Input sources don't need references to action handlers
// 2. **Multi-platform**: Same notifications work on macOS and iOS with different UI
// 3. **Multiple entry points**: Keyboard, menu, URL scheme, and Siri all post identical notifications
// 4. **SwiftUI compatibility**: Works naturally with `.onReceive()` view modifiers
//
// ## Dispatch Flow
//
// ```
// ┌─────────────────┐    ┌──────────────────┐    ┌───────────────────┐
// │  Input Source   │───▶│  NotificationCenter │───▶│  View / Handler   │
// │                 │    │                   │    │                   │
// │ • Keyboard      │    │  post(name:)      │    │ .onReceive()      │
// │ • Menu command  │    │                   │    │ ViewModifier      │
// │ • URL scheme    │    │                   │    │                   │
// │ • Siri/Shortcut │    │                   │    │                   │
// └─────────────────┘    └──────────────────┘    └───────────────────┘
// ```
//
// ## Example Flow: "Show Library" Command
//
// 1. User presses ⌘1 (keyboard) or selects View → Show Library (menu)
// 2. AppCommands posts: `NotificationCenter.default.post(name: .showLibrary)`
// 3. ContentView receives via: `.onReceive(NotificationCenter.default.publisher(for: .showLibrary))`
// 4. ContentView updates state: `selectedSection = .library`
//
// ## Notification Categories
//
// - **Navigation**: Switch between views (Library, Search, Inbox, tabs)
// - **Paper Actions**: Read status, keep/dismiss, move to collection
// - **Clipboard**: Copy/cut/paste publications
// - **PDF Viewer**: Zoom, page navigation, go to page
// - **Window Management**: Detach tabs, flip window positions
// - **Search**: Focus search, toggle filters
//
// ## userInfo Conventions
//
// Some notifications pass data via userInfo dictionary:
// - `["collection": CDCollection]` - Target collection for move/add
// - `["library": CDLibrary]` - Target library for import
// - `["fileURL": URL]` - File to import
// - `["category": String]` - arXiv category to search
// - `["documentID": String]` - Help document to show
//
// ## Related Files
//
// - `imbibApp.swift`: AppCommands posts notifications from menu items
// - `ContentView.swift`: Main receiver with `.onReceive()` modifiers
// - `KeyboardShortcutsSettings.swift`: Maps key bindings to notifications
// - `URLSchemeHandler.swift`: Translates URL schemes to notifications

// MARK: - App Notification Names

/// Centralized notification names used by both macOS and iOS apps.
///
/// These notifications implement a command dispatch pattern where input sources
/// (keyboard shortcuts, menu items, URL schemes) post notifications, and views
/// or view models receive and handle them via `.onReceive()` modifiers.
///
/// See the architecture documentation above for the dispatch flow.
public extension Notification.Name {

    // MARK: - File Operations

    /// Import BibTeX file (shows file picker)
    static let importBibTeX = Notification.Name("importBibTeX")

    /// Import BibTeX file to specific library (from drag-and-drop)
    /// userInfo: ["fileURL": URL, "library": CDLibrary]
    static let importBibTeXToLibrary = Notification.Name("importBibTeXToLibrary")

    /// Export library to BibTeX
    static let exportBibTeX = Notification.Name("exportBibTeX")

    // MARK: - Navigation

    /// Show library view
    static let showLibrary = Notification.Name("showLibrary")

    /// Show search view
    static let showSearch = Notification.Name("showSearch")

    // MARK: - Publication Actions

    /// Toggle read/unread status of selected publications
    static let toggleReadStatus = Notification.Name("toggleReadStatus")

    /// Read status changed (for UI updates)
    static let readStatusDidChange = Notification.Name("readStatusDidChange")

    /// Library content changed (papers added/removed from library or collection)
    /// Used to refresh sidebar publication counts
    static let libraryContentDidChange = Notification.Name("libraryContentDidChange")

    // MARK: - Clipboard Operations

    /// Copy selected publications to clipboard
    static let copyPublications = Notification.Name("copyPublications")

    /// Cut selected publications to clipboard
    static let cutPublications = Notification.Name("cutPublications")

    /// Paste publications from clipboard
    static let pastePublications = Notification.Name("pastePublications")

    /// Select all publications in current view
    static let selectAllPublications = Notification.Name("selectAllPublications")

    // MARK: - Inbox Triage Actions

    /// Save selected inbox items to default library (S key)
    static let inboxSave = Notification.Name("inboxSave")

    /// Save and star selected inbox items (Shift+S)
    static let inboxSaveAndStar = Notification.Name("inboxSaveAndStar")

    /// Dismiss selected inbox items (D key)
    static let inboxDismiss = Notification.Name("inboxDismiss")

    /// Toggle star/flag on selected inbox items (T key)
    static let inboxToggleStar = Notification.Name("inboxToggleStar")

    /// Posted when a triage action (keep/dismiss) starts - iOS uses this to lock sidebar
    static let triageActionStarted = Notification.Name("triageActionStarted")

    /// Posted when a triage action completes - iOS uses this to unlock sidebar after delay
    static let triageActionCompleted = Notification.Name("triageActionCompleted")

    // MARK: - Category Search

    /// Search for papers in a specific arXiv category (userInfo["category"] = String)
    static let searchCategory = Notification.Name("searchCategory")

    // MARK: - Keyboard Navigation

    /// Navigate to next paper in list (↓ key)
    static let navigateNextPaper = Notification.Name("navigateNextPaper")

    /// Navigate to previous paper in list (↑ key)
    static let navigatePreviousPaper = Notification.Name("navigatePreviousPaper")

    /// Navigate to first paper in list (⌘↑)
    static let navigateFirstPaper = Notification.Name("navigateFirstPaper")

    /// Navigate to last paper in list (⌘↓)
    static let navigateLastPaper = Notification.Name("navigateLastPaper")

    /// Navigate to next unread paper (⌥↓)
    static let navigateNextUnread = Notification.Name("navigateNextUnread")

    /// Navigate to previous unread paper (⌥↑)
    static let navigatePreviousUnread = Notification.Name("navigatePreviousUnread")

    /// Open selected paper / show detail (Return key)
    static let openSelectedPaper = Notification.Name("openSelectedPaper")

    // MARK: - View Switching

    /// Show inbox view (⌘3)
    static let showInbox = Notification.Name("showInbox")

    /// Show PDF tab in detail view (⌘4)
    static let showPDFTab = Notification.Name("showPDFTab")

    /// Show BibTeX tab in detail view (⌘5)
    static let showBibTeXTab = Notification.Name("showBibTeXTab")

    /// Show Notes tab in detail view (⌘6 or ⌘R)
    static let showNotesTab = Notification.Name("showNotesTab")

    /// Show Info tab in detail view
    static let showInfoTab = Notification.Name("showInfoTab")

    /// Cycle to previous detail tab (h key in vim mode)
    static let showPreviousDetailTab = Notification.Name("showPreviousDetailTab")

    /// Cycle to next detail tab (l key in vim mode)
    static let showNextDetailTab = Notification.Name("showNextDetailTab")

    /// Toggle detail pane visibility (⌘0)
    static let toggleDetailPane = Notification.Name("toggleDetailPane")

    /// Toggle sidebar visibility (⌃⌘S)
    static let toggleSidebar = Notification.Name("toggleSidebar")

    /// Focus sidebar (⌥⌘1)
    static let focusSidebar = Notification.Name("focusSidebar")

    /// Focus list view (⌥⌘2)
    static let focusList = Notification.Name("focusList")

    /// Focus detail view (⌥⌘3)
    static let focusDetail = Notification.Name("focusDetail")

    /// Scroll list view to current selection (used by global search navigation)
    static let scrollToSelection = Notification.Name("scrollToSelection")

    // MARK: - Paper Actions

    /// Open references/citations for selected paper (⇧⌘R)
    static let openReferences = Notification.Name("openReferences")

    /// Mark all visible papers as read (⌥⌘U)
    static let markAllAsRead = Notification.Name("markAllAsRead")

    /// Delete selected papers (⌘Delete)
    static let deleteSelectedPapers = Notification.Name("deleteSelectedPapers")

    /// Save selected papers to library (⌃⌘S)
    static let saveToLibrary = Notification.Name("saveToLibrary")

    /// Posted when a publication is saved to a library (for auto-removal from Inbox)
    static let publicationSavedToLibrary = Notification.Name("publicationSavedToLibrary")

    /// Dismiss selected papers from inbox (⇧⌘J)
    static let dismissFromInbox = Notification.Name("dismissFromInbox")

    /// Move selected papers to collection (⌃⌘M)
    static let moveToCollection = Notification.Name("moveToCollection")

    /// Add selected papers to collection (⌘L)
    static let addToCollection = Notification.Name("addToCollection")

    /// Remove selected papers from current collection (⇧⌘L)
    static let removeFromCollection = Notification.Name("removeFromCollection")

    /// Share selected papers (⇧⌘F)
    static let sharePapers = Notification.Name("sharePapers")

    // MARK: - Search Actions

    /// Focus search field (⌘F)
    static let focusSearch = Notification.Name("focusSearch")

    /// Posted when the Last Search collection is updated with new search results.
    ///
    /// Views displaying the Last Search collection (via UnifiedPublicationListWrapper)
    /// should observe this notification to refresh their list.
    static let lastSearchUpdated = Notification.Name("lastSearchUpdated")

    /// Toggle unread filter (⌘\\)
    static let toggleUnreadFilter = Notification.Name("toggleUnreadFilter")

    /// Toggle PDF filter - papers with attachments (⇧⌘\\)
    static let togglePDFFilter = Notification.Name("togglePDFFilter")

    // MARK: - Clipboard Extensions

    /// Copy as formatted citation (⇧⌘C)
    static let copyAsCitation = Notification.Name("copyAsCitation")

    /// Copy DOI or URL (⌥⌘C)
    static let copyIdentifier = Notification.Name("copyIdentifier")

    // MARK: - PDF Viewer

    /// Go to specific page in PDF (⌘G)
    static let pdfGoToPage = Notification.Name("pdfGoToPage")

    /// PDF page down (Space)
    static let pdfPageDown = Notification.Name("pdfPageDown")

    /// PDF page up (Shift+Space)
    static let pdfPageUp = Notification.Name("pdfPageUp")

    /// PDF scroll half page down (j key in vim mode)
    static let pdfScrollHalfPageDown = Notification.Name("pdfScrollHalfPageDown")

    /// PDF scroll half page up (k key in vim mode)
    static let pdfScrollHalfPageUp = Notification.Name("pdfScrollHalfPageUp")

    /// PDF zoom in (⌘+)
    static let pdfZoomIn = Notification.Name("pdfZoomIn")

    /// PDF zoom out (⌘-)
    static let pdfZoomOut = Notification.Name("pdfZoomOut")

    /// PDF actual size (⌘0 in PDF context)
    static let pdfActualSize = Notification.Name("pdfActualSize")

    /// PDF fit to window (⌘9)
    static let pdfFitToWindow = Notification.Name("pdfFitToWindow")

    // MARK: - App Actions

    /// Refresh/sync data (⇧⌘N)
    static let refreshData = Notification.Name("refreshData")

    /// Show keyboard shortcuts window (⌘/)
    static let showKeyboardShortcuts = Notification.Name("showKeyboardShortcuts")

    // MARK: - Exploration Navigation

    /// Navigate to a collection in the sidebar (userInfo["collection"] = CDCollection)
    static let navigateToCollection = Notification.Name("navigateToCollection")

    /// Exploration library changed (collection added/removed)
    static let explorationLibraryDidChange = Notification.Name("explorationLibraryDidChange")

    /// Navigate back in history (⌘[)
    static let navigateBack = Notification.Name("navigateBack")

    /// Navigate forward in history (⌘])
    static let navigateForward = Notification.Name("navigateForward")

    /// Navigate to a smart search in the sidebar (object = UUID of smart search)
    static let navigateToSmartSearch = Notification.Name("navigateToSmartSearch")

    // MARK: - Search Form Navigation

    /// Reset search form view to show input form instead of results
    /// Posted when user clicks a search form in sidebar (even if already selected)
    static let resetSearchFormView = Notification.Name("resetSearchFormView")

    /// Navigate to Search section (object = optional library UUID to create search for)
    static let navigateToSearchSection = Notification.Name("navigateToSearchSection")

    /// Open arXiv search interface with a category pre-filled
    /// userInfo["category"] = the category query (e.g., "cat:astro-ph")
    static let openArxivSearchWithCategory = Notification.Name("openArxivSearchWithCategory")

    /// Pre-fill arXiv category in the feed form
    /// userInfo["category"] = the category query (e.g., "cat:astro-ph")
    static let prefillArxivCategory = Notification.Name("prefillArxivCategory")

    /// Edit a smart search by navigating to Search section with its query
    /// Object = UUID of the smart search to edit
    static let editSmartSearch = Notification.Name("editSmartSearch")

    // MARK: - Inbox Triage Extensions

    /// Mark inbox item as read (R key - single key when in inbox)
    static let inboxMarkRead = Notification.Name("inboxMarkRead")

    /// Mark inbox item as unread (U key - single key when in inbox)
    static let inboxMarkUnread = Notification.Name("inboxMarkUnread")

    /// Navigate next (J key - vim style)
    static let inboxNextItem = Notification.Name("inboxNextItem")

    /// Navigate previous (K key - vim style)
    static let inboxPreviousItem = Notification.Name("inboxPreviousItem")

    /// Open inbox item (O key - vim style)
    static let inboxOpenItem = Notification.Name("inboxOpenItem")

    // MARK: - Explore Actions (Context Menu)

    /// Explore references for a publication (object = CDPublication)
    static let exploreReferences = Notification.Name("exploreReferences")

    /// Explore citations for a publication (object = CDPublication)
    static let exploreCitations = Notification.Name("exploreCitations")

    /// Explore similar papers for a publication (object = CDPublication)
    static let exploreSimilar = Notification.Name("exploreSimilar")

    // MARK: - Window Management (Dual Monitor Support)

    /// Detach PDF tab to separate window (⌥⇧⌘M)
    static let detachPDFTab = Notification.Name("detachPDFTab")

    /// Detach Notes tab to separate window (⌥⇧⌘N)
    static let detachNotesTab = Notification.Name("detachNotesTab")

    /// Detach BibTeX tab to separate window
    static let detachBibTeXTab = Notification.Name("detachBibTeXTab")

    /// Detach Info tab to separate window
    static let detachInfoTab = Notification.Name("detachInfoTab")

    /// Flip/swap window positions between displays (⌥⇧⌘F)
    static let flipWindowPositions = Notification.Name("flipWindowPositions")

    /// Close all detached windows for current publication (⌥⇧⌘W)
    static let closeDetachedWindows = Notification.Name("closeDetachedWindows")

    // MARK: - Text Size Control

    /// Increase text size throughout the app (⇧⌘=)
    static let increaseFontSize = Notification.Name("increaseFontSize")

    /// Decrease text size throughout the app (⇧⌘-)
    static let decreaseFontSize = Notification.Name("decreaseFontSize")

    // MARK: - Command Palette

    /// Show the command palette (⇧⌘P)
    static let showCommandPalette = Notification.Name("showCommandPalette")

    // MARK: - Help

    /// Show the help browser window (⌘?)
    static let showHelp = Notification.Name("showHelp")

    /// Show the help search palette (⇧⌘?)
    static let showHelpSearchPalette = Notification.Name("showHelpSearchPalette")

    /// Navigate to a specific help document (userInfo["documentID"] = String)
    static let showHelpDocument = Notification.Name("showHelpDocument")

    // MARK: - Persistence Notifications

    /// Posted when the persistent store fails to load.
    ///
    /// This notification indicates a critical error during app startup. The app should
    /// display an error UI and offer recovery options (retry, contact support).
    ///
    /// userInfo:
    /// - `error`: The `Error` that caused the failure
    ///
    /// Example handling:
    /// ```swift
    /// .onReceive(NotificationCenter.default.publisher(for: .persistentStoreLoadFailed)) { notification in
    ///     if let error = notification.userInfo?["error"] as? Error {
    ///         showDatabaseErrorView(error: error)
    ///     }
    /// }
    /// ```
    static let persistentStoreLoadFailed = Notification.Name("persistentStoreLoadFailed")

    /// Posted when CloudKit sync fails and the app falls back to local-only storage.
    ///
    /// This allows the app to continue operating without CloudKit sync. The user should
    /// be informed that their data won't sync across devices until the issue is resolved.
    ///
    /// userInfo:
    /// - `originalError`: The CloudKit `Error` that triggered the fallback
    ///
    /// Example handling:
    /// ```swift
    /// .onReceive(NotificationCenter.default.publisher(for: .persistentStoreFellBackToLocal)) { notification in
    ///     showCloudKitUnavailableBanner()
    /// }
    /// ```
    static let persistentStoreFellBackToLocal = Notification.Name("persistentStoreFellBackToLocal")

    /// Posted when a database health check completes.
    ///
    /// userInfo:
    /// - `report`: `DatabaseHealthReport` with health status and any detected issues
    ///
    /// Subscribe to this notification if you want to display health status in the UI
    /// or log health metrics for debugging.
    static let databaseHealthCheckCompleted = Notification.Name("databaseHealthCheckCompleted")

    // MARK: - Enrichment Notifications

    /// Posted when a publication's enrichment data is updated.
    ///
    /// userInfo:
    /// - `publicationID`: UUID of the enriched publication
    ///
    /// Views displaying publication details can observe this to refresh when
    /// citation counts, references, or other enrichment data becomes available.
    static let publicationEnrichmentDidComplete = Notification.Name("publicationEnrichmentDidComplete")

    // MARK: - Detail View Tab Navigation

    /// Posted when the detail view tab changes (iOS)
    ///
    /// userInfo:
    /// - `tab`: The new IOSDetailTab rawValue (String)
    static let detailTabDidChange = Notification.Name("detailTabDidChange")

    /// Posted when a PDF search is requested from the global search palette
    ///
    /// userInfo:
    /// - `query`: The search query string
    static let pdfSearchRequested = Notification.Name("pdfSearchRequested")

    // MARK: - imprint Integration

    /// Show PDF annotations for a paper (from imprint deep link)
    ///
    /// userInfo:
    /// - `citeKey`: The cite key of the paper
    ///
    /// This is triggered when imprint requests to view annotations via URL scheme:
    /// `imbib://paper/{citeKey}/annotations`
    static let showAnnotations = Notification.Name("showAnnotations")

    /// Open a paper in imprint (launch imprint with linked document)
    ///
    /// userInfo:
    /// - `citeKey`: The cite key of the manuscript
    ///
    /// This is triggered via URL scheme or context menu:
    /// `imbib://paper/{citeKey}/open-in-imprint`
    static let openInImprint = Notification.Name("openInImprint")

    /// Posted when a compiled PDF is detected from imprint
    ///
    /// userInfo:
    /// - `documentUUID`: UUID of the imprint document
    /// - `pdfURL`: URL of the compiled PDF
    static let compiledPDFDetected = Notification.Name("compiledPDFDetected")

    // MARK: - Unified Import/Export

    /// Show the unified export dialog
    ///
    /// userInfo (optional):
    /// - `library`: CDLibrary to export (if from context menu)
    /// - `publications`: [CDPublication] to export (if selection export)
    ///
    /// This notification triggers the UnifiedExportView sheet.
    static let showUnifiedExport = Notification.Name("showUnifiedExport")

    /// Show the unified import dialog
    ///
    /// userInfo (optional):
    /// - `library`: CDLibrary to import into (if from context menu)
    ///
    /// This notification triggers the UnifiedImportView file picker and preview.
    static let showUnifiedImport = Notification.Name("showUnifiedImport")

    // MARK: - E-Ink Device Integration

    /// Send selected papers to E-Ink device (reMarkable, Supernote, Kindle Scribe)
    ///
    /// userInfo (optional):
    /// - `publications`: [CDPublication] to send (if not provided, uses current selection)
    ///
    /// This notification triggers the E-Ink sync process for the specified papers.
    static let sendToEInkDevice = Notification.Name("sendToEInkDevice")

    /// Sync annotations from E-Ink device
    ///
    /// Triggers a sync to pull annotations from the active E-Ink device.
    static let syncEInkAnnotations = Notification.Name("syncEInkAnnotations")

    /// Open E-Ink device settings
    ///
    /// Opens the Settings window and navigates to the E-Ink tab.
    static let showEInkSettings = Notification.Name("showEInkSettings")

    // MARK: - Settings Navigation

    /// Open Inbox settings panel
    ///
    /// Opens the Settings window and navigates to the Inbox tab.
    /// Used by sidebar retention labels.
    static let showInboxSettings = Notification.Name("showInboxSettings")

    /// Open Exploration settings panel
    ///
    /// Opens the Settings window and navigates to the Advanced tab (Exploration section).
    /// Used by sidebar retention labels.
    static let showExplorationSettings = Notification.Name("showExplorationSettings")

    // MARK: - Vim-Style Pane Focus Navigation

    /// Cycle pane focus to the left (h key)
    ///
    /// Cycles through panes: sidebar ← list ← info ← pdf ← notes ← bibtex (wrapping)
    static let cycleFocusLeft = Notification.Name("cycleFocusLeft")

    /// Cycle pane focus to the right (l key)
    ///
    /// Cycles through panes: sidebar → list → info → pdf → notes → bibtex (wrapping)
    static let cycleFocusRight = Notification.Name("cycleFocusRight")

    // MARK: - Detail Tab Scrolling (Vim-style)

    /// Scroll detail tab content down by half page (j key in detail tabs)
    static let scrollDetailDown = Notification.Name("scrollDetailDown")

    /// Scroll detail tab content up by half page (k key in detail tabs)
    static let scrollDetailUp = Notification.Name("scrollDetailUp")
}
