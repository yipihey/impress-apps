# imbib Development Changelog

Detailed session-by-session development history. For quick reference during development, see [CLAUDE.md](CLAUDE.md).

## 2026-01-28 - iCloud Data Safety Strategy

Comprehensive data protection for CloudKit sync operations.

### Schema Version Management
- **SchemaVersion.swift**: Explicit versioning with compatibility checks
  - Version registry (v1.0 → v1.2 current)
  - Compatibility checker for CloudKit sync
  - Display strings and migration info

### Safe Migration Infrastructure
- **SafeMigrationService.swift**: Migration wrapper with pre/post validation
  - Automatic backup before migrations
  - State capture and validation
  - Rollback capability on failure
  - CloudKit sync coordination

### Sync Health Monitoring
- **SyncHealthMonitor.swift**: Observable health tracking
  - Real-time sync status updates
  - Pending upload/download counts
  - Unresolved conflict tracking
  - Actionable issue detection

- **SyncHealthView.swift**: User-facing health dashboard
  - Status overview with icons
  - Issue list with resolution actions
  - Pre-update backup prompts

### Library Backup Service
- **LibraryBackupService.swift**: Comprehensive export
  - Full BibTeX export with all metadata
  - PDF files with preserved structure
  - Notes as JSON
  - Settings backup
  - Manifest with checksums for verification

### CloudKit Feature Flags
- **CloudKitSyncSettingsStore.swift**: Extended with:
  - SyncFeatureFlags for gating risky changes
  - Emergency rollback capability
  - Graceful degradation options

### Test Infrastructure
- **SchemaMigrationTests.swift**: Version and migration tests
- **CloudKitSyncSimulatorTests.swift**: Multi-device simulation
- **CorruptionRecoveryTests.swift**: Recovery scenario tests
- **SyncStressTests.swift**: Load and stress tests

### Documentation
- **icloud-pitfalls.md**: Developer guide for CloudKit
  - Known limitations and dangerous operations
  - Safe practices and testing procedures
  - Recovery procedures

- **data-recovery-guide.md**: User support documentation
  - Troubleshooting sync issues
  - Export and backup instructions
  - Emergency recovery steps

### Modified Files
- PersistenceController.swift: Schema version recording
- SettingsView.swift: Added Sync Health and Backup sections

## 2026-01-28 - iOS Keyboard & Apple Pencil Support

Extended hardware keyboard and Apple Pencil support to imbib iOS app.

### Keyboard Shortcuts (iPad)
- **Notes Editor**: IOSNotesEditorView.swift
  - Cmd+S: Save notes immediately
  - Cmd+B: Bold (wraps selection with `**`)
  - Cmd+I: Italic (wraps selection with `*`)
  - Cmd+Z: Undo
  - Cmd+Shift+Z: Redo
- **BibTeX Editor**: IOSBibTeXEditorView.swift
  - Cmd+S: Save and validate BibTeX
  - Cmd+A: Select all text
  - Cmd+C: Copy (selection or all)
  - Cmd+N: Insert field template
  - Cmd+Z/Cmd+Shift+Z: Undo/redo

### Apple Pencil Scribble Support
- **IOSScribbleSupport.swift**: Scribble configuration and scratch-to-delete gesture
- UITextView wrappers configured for automatic Scribble support
- Write anywhere to insert text, scratch to delete, circle to select

### PencilKit PDF Annotations
- **IOSSketchAnnotationView.swift**: Full PencilKit drawing canvas
- Draw tool added to AnnotationToolbar (iOS only)
- Export sketches as PNG stamp annotations on PDFs
- Full pressure sensitivity and palm rejection
- Undo/redo support with tool picker integration

### Voice Dictation
- **IOSDictationService.swift**: Speech recognition service
- Auto-punctuation for natural speech
- Voice commands adapted for imbib:
  - "new paragraph", "new line", "bold", "italic"
  - "save note", "next paper", "previous paper"
  - "show pdf", "show notes", "show bibtex"
  - "undo", "stop dictation"
- Waveform visualization overlay
- Floating dictation button component

### Modified Files
- IOSNotesTab.swift: Uses IOSNotesEditorView for keyboard support
- IOSBibTeXEditorSheet.swift: Uses IOSBibTeXEditorView for keyboard support
- AnnotationToolbar.swift: Added sketch tool with iOS conditional
- AnnotationService.swift: Added ink/stamp annotation methods

### Documentation Updated
- docs/features.md: Added iOS keyboard/Pencil section
- docs/keyboard-shortcuts.md: Added iOS shortcuts and voice commands
- imbib/Resources/HelpDocs/features.md: Updated in-app help

## 2026-01-19 (Session 21)
- Enhanced Import Preview with Library Picker
  - Library destination picker: import to existing library or create new
  - Duplicate detection during import via DOI, arXiv ID, bibcode matching
  - Duplicate handling options: skip duplicates or replace existing entries
  - Pre-selected library support when files dropped on specific library
- BibTeX/RIS Drag-and-Drop Improvements
  - Drop .bib/.ris files onto library rows to import with that library pre-selected
  - Sidebar-wide drop zone for creating new library from dropped files
  - New notification: `.importBibTeXToLibrary` with fileURL and library in userInfo
  - New `ImportError.noLibrarySelected` case for validation
- Smart Search Duplicate Prevention
  - `createExplorationSearch()` checks for existing search with same query
  - Returns existing search instead of creating duplicate
  - Updates name if user renamed the existing search
- Collection Filtering Fix
  - `flattenedExplorationCollections()` now excludes smart search result collections
  - Smart search results shown as search rows, not duplicate collections
  - Applied to both macOS (SidebarView) and iOS (IOSSidebarView)
- ContentView Refactoring
  - Extracted notification handlers into ViewModifier structs
  - `NavigationHandlersModifier`, `ImportExportHandlersModifier`, `StateChangeHandlersModifier`
  - `ImportPreviewData` struct for cleaner sheet binding
  - `mainContent` extracted from body for reduced complexity
- Files: ImportPreviewView.swift, SidebarView.swift, IOSSidebarView.swift,
  ContentView.swift, Notifications.swift, SmartSearchProvider.swift, LibraryViewModel.swift

## 2026-01-16 (Session 20)
- PDF Auto-Download Improvements
  - Fixed `resolveForAutoDownload()` to respect user's priority setting (preprint vs publisher)
  - Gateway URLs (ADS link_gateway) now used as absolute last resort only
  - Added `resolveGatewayURL()` method separated from main resolution flow
  - ArXiv now uses direct PDF URLs (`https://arxiv.org/pdf/{id}.pdf`) instead of abstract pages
- ArXiv BrowserURLProvider
  - Added `BrowserURLProvider` conformance to ArXivSource for direct PDF URLs
  - Registered ArXiv provider with highest priority (20) in both macOS and iOS apps
  - ADS provider also updated to prefer direct PDFs over gateway URLs
- PDF Resolution Priority (for auto-download):
  - Publisher priority: OpenAlex OA → Direct publisher PDF → ADS scan → DOI resolver → (fallback to arXiv) → gateway
  - Preprint priority: Direct arXiv PDF → preprint links → (fallback to publisher) → gateway
- Sidebar Multi-Selection for Searches
  - Added Option+Click to toggle individual search in multi-selection
  - Added Shift+Click for range selection of searches
  - Context menu shows "Delete N Searches" for batch delete
  - Visual feedback with accent color background for selected items
- New Tests (97 tests added):
  - PDFURLResolverTests: 15 new tests for auto-download, gateway deprioritization
  - PDFDownloadIntegrationTests: 18 tests for network mocking scenarios
  - PDFValidationTests: 22 tests for PDF magic byte validation
  - IdentifierExtractorTests: 36 tests for arXiv/DOI/bibcode extraction
- Files: PDFURLResolver.swift, ArXivSource.swift, ADSSource.swift, SidebarView.swift,
  imbibApp.swift (macOS + iOS), PDFURLResolverTests.swift, PDFDownloadIntegrationTests.swift,
  PDFValidationTests.swift, IdentifierExtractorTests.swift
- All tests passing

## 2026-01-16 (Session 19)
- ADR-018: AI Assistant Integration - Phase 1 & 2
  - Core automation layer with rich data returns (not just notifications)
  - Designed for MCP server, enhanced AppIntents, and REST API support
- New Automation Types (`Automation/AutomationTypes.swift`):
  - `PaperIdentifier`: Flexible lookup by citeKey, DOI, arXiv, bibcode, UUID, PMID, etc.
  - `SearchFilters`: Year range, authors, read status, PDF status, collections
  - `PaperResult`: Complete serializable paper representation
  - `CollectionResult`, `LibraryResult`: Collection/library representations
  - `AddPapersResult`, `ExportResult`, `DownloadResult`: Operation results
  - `SearchOperationResult`: Search results with metadata
  - `AutomationOperationError`: Domain-specific error types
- AutomationOperations Protocol (`Automation/AutomationOperations.swift`):
  - `searchLibrary()`, `searchExternal()`: Search with rich returns
  - `getPaper()`, `getPapers()`: Lookup by identifier
  - `addPapers()`: Add papers from DOI/arXiv/bibcode with PDF download
  - `deletePapers()`, `markAsRead()`, `markAsUnread()`, `toggleReadStatus()`, `toggleStar()`
  - `listCollections()`, `createCollection()`, `addToCollection()`, `removeFromCollection()`
  - `listLibraries()`, `getDefaultLibrary()`, `getInboxLibrary()`
  - `exportBibTeX()`, `exportRIS()`: Export with content returned
  - `downloadPDFs()`, `checkPDFStatus()`: PDF operations
  - `listSources()`: Available search sources
- AutomationService Actor (`Automation/AutomationService.swift`):
  - Implements AutomationOperations protocol
  - Calls PublicationRepository and SourceManager directly
  - Authorization check via AutomationSettingsStore
  - Singleton pattern: `AutomationService.shared`
- Enhanced AppIntents with Entity Support:
  - `PaperEntity.swift`: AppEntity for papers with EntityQuery support
  - `CollectionEntity.swift`: AppEntity for collections, LibraryEntity for libraries
  - `AddPapersIntent.swift`: New intents for adding papers by identifier
    - AddPapersIntent (batch), AddPaperByDOIIntent, AddPaperByArXivIntent, AddPaperByBibcodeIntent
    - DownloadPDFsIntent, GetPaperIntent
  - Updated `SearchIntents.swift` to return `[PaperEntity]` data
    - SearchPapersIntent now returns actual results
    - New SearchLibraryIntent, SearchExternalIntent
  - Updated `ImbibShortcuts.swift` with new shortcuts
- Key Design Decision:
  - AutomationService **bypasses** URLSchemeHandler for data returns
  - URLSchemeHandler still used for UI navigation notifications
  - Enables MCP/Shortcuts to work with actual data, not just success/failure
- Added 22 new tests (AutomationTypesTests)
- Files: Automation/AutomationTypes.swift, Automation/AutomationOperations.swift,
  Automation/AutomationService.swift, AppIntents/PaperEntity.swift,
  AppIntents/CollectionEntity.swift, AppIntents/AddPapersIntent.swift
- Build succeeds, all automation tests passing (46 tests)

## 2026-01-16 (Session 18)
- iOS Siri Shortcuts / AppIntents Integration
  - AppIntents framework for Siri voice commands and Shortcuts app automation
  - Wraps existing URLSchemeHandler automation infrastructure
  - Respects automation enable/disable setting
- AppIntents Module (`AppIntents/`):
  - `ImbibShortcuts.swift`: AppShortcutsProvider with 5 pre-configured shortcuts
  - `SearchIntents.swift`: SearchPapersIntent, SearchCategoryIntent, ShowSearchIntent
  - `NavigationIntents.swift`: ShowInboxIntent, ShowLibraryIntent, ShowPDFTabIntent, etc.
  - `PaperIntents.swift`: ToggleReadStatusIntent, MarkAllReadIntent, CopyBibTeXIntent, etc.
  - `InboxIntents.swift`: ArchiveInboxItemIntent, DismissInboxItemIntent, ToggleStarIntent
  - `AppActionIntents.swift`: RefreshDataIntent, ExportLibraryIntent, ToggleSidebarIntent
- Key Components:
  - `AutomationIntent` protocol: Executes via URLSchemeHandler.execute()
  - `IntentError`: automationDisabled, executionFailed, invalidParameter, paperNotFound
  - `SearchSourceOption`: AppEnum for search source selection
  - `ExportFormatOption`: AppEnum for export format selection
- iOS App Integration:
  - Added Siri entitlement (`com.apple.developer.siri`) to iOS entitlements
  - Added `.onOpenURL` handler for URL scheme automation
  - Linked ImbibShortcuts provider for Shortcuts app discovery
- Siri Phrases:
  - "Search imbib for {query}"
  - "Show my imbib inbox"
  - "Mark all papers as read in imbib"
  - "Refresh imbib"
- Added 54 new tests (AppIntentsTests, AppIntentsIntegrationTests)
- Files: AppIntents/*.swift, imbib-iOS/imbibApp.swift, imbib-iOS.entitlements
- All tests passing

## 2026-01-09 (Session 17)
- Automation API for AI Agents & External Programs
  - URL scheme support (`imbib://...`) for external control
  - Disabled by default for security (toggle in Settings > General)
  - Logging option for debugging automation requests
- URL Scheme Infrastructure:
  - Registered `imbib://` scheme in project.yml for macOS and iOS
  - `URLSchemeHandler`: Actor that parses and executes URL commands
  - `URLCommandParser`: Parses 30+ command types into `AutomationCommand` enums
  - `AutomationSettingsStore`: Persists enable/logging preferences
  - `AutomationResult`: JSON-serializable result type for command responses
  - `AutomationURLBuilder`: Helper for constructing URLs programmatically
- Command Categories:
  - `imbib://search?query=...` - Search online sources
  - `imbib://navigate/<target>` - Navigate to library/search/inbox/tabs
  - `imbib://focus/<target>` - Focus sidebar/list/detail/search
  - `imbib://paper/<citeKey>/<action>` - Paper actions (open, toggle-read, delete, etc.)
  - `imbib://selected/<action>` - Actions on selected papers
  - `imbib://inbox/<action>` - Inbox triage (archive, dismiss, star, etc.)
  - `imbib://pdf/<action>` - PDF viewer (go-to-page, zoom, etc.)
  - `imbib://app/<action>` - App actions (refresh, toggle-sidebar, etc.)
  - `imbib://import`, `imbib://export` - Import/export operations
- CLI Tool (`imbib-cli`):
  - Separate Swift Package using swift-argument-parser
  - Full command-line interface for all automation features
  - Subcommands: search, navigate, focus, paper, selected, inbox, pdf, app, import, export, raw
  - Uses `NSWorkspace.shared.open(url)` to trigger URL schemes
- Settings Integration:
  - Added Automation section to GeneralSettingsTab
  - "Enable automation API" toggle
  - "Log automation requests" toggle
- Added 57 new tests (URLCommandParserTests, AutomationSettingsTests)
- Files: project.yml, imbibApp.swift, SettingsView.swift,
  Automation/URLSchemeHandler.swift, Automation/URLCommandParser.swift,
  Automation/AutomationSettings.swift, imbib-cli/

## 2026-01-06 (Session 12-15)

### Session 15: General File Attachment System
- Extends imbib to accept any file type via drag-and-drop (code, .tar.gz, images, data files)
- Files stored in Papers/ directory alongside PDFs
- Virtual tag-based grouping (CDAttachmentTag entity)
- All attachments exported as Bdsk-File-* fields (BibDesk compatible)
- Data Model Extensions: CDLinkedFile (displayName, fileSize, mimeType), CDAttachmentTag
- AttachmentManager (generalized PDFManager) with MIME type detection
- FileDropHandler, FileTypeIcon component (60+ extensions mapped to SF Symbols)
- Enhanced Info Tab attachments section with drop zone
- All 774 tests passing

### Session 14: PDF Browser Improvements
- Removed library proxy from browser URLs (proxy prefix breaks ADS gateway)
- Browser uses natural web authentication via WKWebView cookie persistence
- Improved ADS browser URL priority (DOI resolver → ADS abstract page)
- App Transport Security fix (NSAllowsArbitraryLoadsInWebContent)
- Text selection/copy/paste in browser, auto-close after PDF save

### Session 13: Interactive PDF Browser
- Web browser window for PDFs requiring auth, CAPTCHAs, or multi-step access
- Auto-detect PDFs via %PDF magic bytes (WKDownloadDelegate)
- Manual capture button, persistent sessions (cookies survive)
- PDFBrowser module: PDFBrowserViewModel, PDFBrowserSession, PDFDownloadInterceptor
- BrowserURLProvider protocol + registry for source-specific URLs
- ADS BrowserURLProvider conformance (bibcode → link_gateway URL)
- All 773 tests passing

### Session 12: Multi-library and Multi-collection Support
- Publications can belong to multiple libraries AND multiple collections
- Schema: Changed publication-to-library from many-to-one to many-to-many
- New helper methods: addToLibrary(), removeFromLibrary(), addToCollection(), etc.
- Context menu: "Add to Library", "Add to Collection" with "All Publications" option
- Drag-and-drop improvements, inline collection rename
- All 743 tests passing

## 2026-01-05 (Session 8-11)

### Session 11: Info Tab and Enrichment
- Rebranded "Metadata" tab to "Info" tab (email mental model)
- Email-style layout: From/Year/Subject header, Identifiers (FlowLayout), Abstract, Attachments, Record Info
- Delete button for attachments, auto-retry for corrupt PDFs
- Wired up OpenAlex enrichment for PDF URLs (EnrichmentCoordinator)
- All 743 tests passing

### Session 10: Unified Publication List Views
- Created PublicationListView shared component (all three list views use identical code)
- ListViewStateStore for persisting selection, sort order, filters per view
- Fixed ADS year extraction bug ("Author_NoYear_Title.pdf")
- Fixed deletion crash when deleting selected sidebar items
- Restored Cmd-A select all, fixed clipboard commands breaking text editing
- Fixed bulk deletion crash
- All 743 tests passing

### Session 9: Multi-library Sidebar
- Each library as disclosure group with publications, smart searches, collections
- Core Data relationship updates (owningLibrary, library relationships)
- SidebarSection enum refactored for library-specific views
- ReadingPositionStore for PDF reading position tracking
- All 741 tests passing

### Session 8: ADR-016 Unified Paper Model
- All papers are now CDPublication entities (no more OnlinePaper)
- Search results auto-import to Last Search collection
- Deduplication via DOI, arXiv ID, bibcode, Semantic Scholar ID, OpenAlex ID
- Simplified SessionCache, PDFURLResolver, UnifiedDetailView
- All 741 tests passing

## 2026-01-04 (Session 1-7)

### Session 7: Unified Detail View
- Merged PaperDetailView and PublicationDetailView into UnifiedDetailView
- Protocol-based approach (any PaperRepresentable)
- Four tabs: Info, BibTeX, PDF, Notes
- Full Add PDF functionality with fileImporter
- All 756 tests passing

### Session 6: PDF Settings (ADR-015)
- PDFSettingsStore (priority, proxy URL, proxy enabled)
- PDFURLResolver with preprint/publisher priority
- Library proxy support with common presets
- PDFSettingsTab UI
- 53 new tests

### Session 5: RIS Integration (ADR-013 Phase 2-4)
- LibraryViewModel and PublicationRepository RIS methods
- RIS import to file picker/drag-drop handlers
- fetchRIS in CrossrefSource and ADSSource
- ImportPreviewView for BibTeX/RIS file preview
- All 370 tests passing, ADR-013 complete

### Session 4: RIS Format Support (ADR-013 Phase 1)
- RIS module: RISTypes, RISParser, RISExporter, RISBibTeXConverter
- 50+ reference types, 65+ tags
- Bidirectional RIS ↔ BibTeX conversion
- 103 new tests

### Session 3: Phase 2 Features
- LibraryManager, CDLibrary, CDSmartSearch
- SmartSearchProvider, SmartSearchRepository
- PDFManager for PDF import and auto-filing
- Cross-platform PDFViewer using PDFKit
- BibTeXEditor with syntax highlighting
- Smart collections with predicate builder
- Export templates (BibTeX, RIS, Plain Text, Markdown, HTML, CSV)
- All 267 tests passing

### Session 2: Unified Experience (ADR-012)
- PaperRepresentable and PaperProvider protocols
- LocalPaper, OnlinePaper wrappers
- SessionCache actor
- Console window for debugging (ADR-011)
- All 147 tests passing

### Session 1: Foundation
- Initial documentation and architecture decisions (ADR-001 through ADR-010)
- SourcePlugin protocol with all built-in sources
- Core Data model and repository pattern
- Basic SwiftUI views
