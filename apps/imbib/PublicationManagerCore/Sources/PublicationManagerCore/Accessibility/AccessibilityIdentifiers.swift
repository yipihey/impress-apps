import Foundation
import SwiftUI

/// Centralized accessibility identifiers for UI testing and VoiceOver support.
/// Pattern: `{module}.{view}.{section}.{element}`
public enum AccessibilityID {

    // MARK: - Sidebar

    public enum Sidebar {
        public static let inbox = "sidebar.inbox"
        public static let allPapers = "sidebar.allPapers"
        public static let recentlyAdded = "sidebar.recentlyAdded"
        public static let recentlyRead = "sidebar.recentlyRead"
        public static let unread = "sidebar.unread"
        public static let flagged = "sidebar.flagged"
        public static let trash = "sidebar.trash"
        public static let newLibraryButton = "sidebar.newLibraryButton"
        public static let newFolderButton = "sidebar.newFolderButton"
        public static let newSmartCollectionButton = "sidebar.newSmartCollectionButton"
        public static let settingsButton = "sidebar.settingsButton"
        public static let searchField = "sidebar.searchField"
        public static let refreshButton = "sidebar.refreshButton"

        public static func libraryRow(_ id: UUID) -> String { "sidebar.library.\(id.uuidString)" }
        public static func libraryRow(_ id: String) -> String { "sidebar.library.\(id)" }
        public static func folderRow(_ id: UUID) -> String { "sidebar.folder.\(id.uuidString)" }
        public static func smartCollectionRow(_ id: UUID) -> String { "sidebar.smartCollection.\(id.uuidString)" }
        public static func sourceRow(_ id: String) -> String { "sidebar.source.\(id)" }
        public static func feedRow(_ id: UUID) -> String { "sidebar.feed.\(id.uuidString)" }
    }

    // MARK: - List View

    public enum List {
        public static let searchField = "list.searchField"
        public static let sortButton = "list.sortButton"
        public static let filterButton = "list.filterButton"
        public static let selectAllButton = "list.selectAllButton"
        public static let deleteButton = "list.deleteButton"
        public static let emptyStateView = "list.emptyStateView"

        public static func publicationRow(_ citeKey: String) -> String { "list.publication.\(citeKey)" }
        public static func publicationToggleRead(_ citeKey: String) -> String { "list.publication.\(citeKey).toggleRead" }
        public static func publicationToggleFlagged(_ citeKey: String) -> String { "list.publication.\(citeKey).toggleFlagged" }
        public static func publicationPDFButton(_ citeKey: String) -> String { "list.publication.\(citeKey).pdfButton" }
    }

    // MARK: - Detail View

    public enum Detail {
        public enum Tabs {
            public static let info = "detail.tabs.info"
            public static let pdf = "detail.tabs.pdf"
            public static let notes = "detail.tabs.notes"
            public static let bibtex = "detail.tabs.bibtex"
            public static let references = "detail.tabs.references"
            public static let annotations = "detail.tabs.annotations"
        }

        public enum Info {
            public static let titleField = "detail.info.titleField"
            public static let authorsField = "detail.info.authorsField"
            public static let authorsExpand = "detail.info.authorsExpand"
            public static let yearField = "detail.info.yearField"
            public static let journalField = "detail.info.journalField"
            public static let abstractField = "detail.info.abstractField"
            public static let doiField = "detail.info.doiField"
            public static let doiCopyButton = "detail.info.doiCopyButton"
            public static let doiOpenButton = "detail.info.doiOpenButton"
            public static let arxivField = "detail.info.arxivField"
            public static let arxivOpenButton = "detail.info.arxivOpenButton"
            public static let citationCount = "detail.info.citationCount"
            public static let addToLibraryButton = "detail.info.addToLibraryButton"
            public static let openPDFButton = "detail.info.openPDFButton"
            public static let downloadPDFButton = "detail.info.downloadPDFButton"
            public static let keywordsField = "detail.info.keywordsField"
        }

        public enum PDF {
            public static let viewer = "detail.pdf.viewer"
            public static let zoomInButton = "detail.pdf.zoomInButton"
            public static let zoomOutButton = "detail.pdf.zoomOutButton"
            public static let zoomFitButton = "detail.pdf.zoomFitButton"
            public static let pageField = "detail.pdf.pageField"
            public static let previousPageButton = "detail.pdf.previousPageButton"
            public static let nextPageButton = "detail.pdf.nextPageButton"
            public static let searchField = "detail.pdf.searchField"
            public static let thumbnailSidebar = "detail.pdf.thumbnailSidebar"
            public static let annotationToolbar = "detail.pdf.annotationToolbar"
            public static let highlightButton = "detail.pdf.highlightButton"
            public static let underlineButton = "detail.pdf.underlineButton"
            public static let strikethroughButton = "detail.pdf.strikethroughButton"
            public static let noteButton = "detail.pdf.noteButton"
            public static let downloadButton = "detail.pdf.downloadButton"
            public static let noPDFView = "detail.pdf.noPDFView"
            public static let findPDFButton = "detail.pdf.findPDFButton"
        }

        public enum Notes {
            public static let editor = "detail.notes.editor"
            public static let saveButton = "detail.notes.saveButton"
            public static let clearButton = "detail.notes.clearButton"
            public static let formatBoldButton = "detail.notes.formatBoldButton"
            public static let formatItalicButton = "detail.notes.formatItalicButton"
            public static let formatListButton = "detail.notes.formatListButton"
        }

        public enum BibTeX {
            public static let editor = "detail.bibtex.editor"
            public static let copyButton = "detail.bibtex.copyButton"
            public static let saveButton = "detail.bibtex.saveButton"
            public static let resetButton = "detail.bibtex.resetButton"
            public static let validateButton = "detail.bibtex.validateButton"
            public static let validationStatus = "detail.bibtex.validationStatus"
        }

        public enum References {
            public static let list = "detail.references.list"
            public static let refreshButton = "detail.references.refreshButton"
            public static let loadingIndicator = "detail.references.loadingIndicator"
            public static func referenceRow(_ index: Int) -> String { "detail.references.row.\(index)" }
        }
    }

    // MARK: - Settings

    public enum Settings {
        public static let tabView = "settings.tabView"
        public static let closeButton = "settings.closeButton"
        public static let doneButton = "settings.doneButton"

        public enum Tabs {
            public static let general = "settings.tabs.general"
            public static let appearance = "settings.tabs.appearance"
            public static let viewing = "settings.tabs.viewing"
            public static let pdf = "settings.tabs.pdf"
            public static let notes = "settings.tabs.notes"
            public static let sources = "settings.tabs.sources"
            public static let enrichment = "settings.tabs.enrichment"
            public static let inbox = "settings.tabs.inbox"
            public static let importExport = "settings.tabs.importExport"
            public static let recommendations = "settings.tabs.recommendations"
            public static let sync = "settings.tabs.sync"
            public static let shortcuts = "settings.tabs.shortcuts"
            public static let advanced = "settings.tabs.advanced"
        }

        public enum General {
            public static let libraryLocationField = "settings.general.libraryLocationField"
            public static let chooseLocationButton = "settings.general.chooseLocationButton"
            public static let defaultLibraryPicker = "settings.general.defaultLibraryPicker"
            public static let autoImportToggle = "settings.general.autoImportToggle"
            public static let launchAtLoginToggle = "settings.general.launchAtLoginToggle"
            public static let checkUpdatesToggle = "settings.general.checkUpdatesToggle"
        }

        public enum Appearance {
            public static let themeGrid = "settings.appearance.themeGrid"
            public static let themePicker = "settings.appearance.themePicker"
            public static let accentColorPicker = "settings.appearance.accentColorPicker"
            public static let fontSizeStepper = "settings.appearance.fontSizeStepper"
            public static let compactModeToggle = "settings.appearance.compactModeToggle"
            public static let showIconsToggle = "settings.appearance.showIconsToggle"
            public static let sidebarWidthSlider = "settings.appearance.sidebarWidthSlider"
        }

        public enum Viewing {
            public static let doubleClickPicker = "settings.viewing.doubleClickPicker"
            public static let defaultTabPicker = "settings.viewing.defaultTabPicker"
            public static let showPreviewToggle = "settings.viewing.showPreviewToggle"
            public static let previewDelay = "settings.viewing.previewDelay"
            public static let autoMarkReadToggle = "settings.viewing.autoMarkReadToggle"
        }

        public enum PDF {
            public static let pdfFolderField = "settings.pdf.pdfFolderField"
            public static let chooseFolderButton = "settings.pdf.chooseFolderButton"
            public static let filenameFormatPicker = "settings.pdf.filenameFormatPicker"
            public static let autoDownloadToggle = "settings.pdf.autoDownloadToggle"
            public static let openExternalToggle = "settings.pdf.openExternalToggle"
            public static let defaultZoomPicker = "settings.pdf.defaultZoomPicker"
            public static let showThumbnailsToggle = "settings.pdf.showThumbnailsToggle"
        }

        public enum Notes {
            public static let defaultFormatPicker = "settings.notes.defaultFormatPicker"
            public static let autoSaveToggle = "settings.notes.autoSaveToggle"
            public static let autoSaveInterval = "settings.notes.autoSaveInterval"
            public static let fontPicker = "settings.notes.fontPicker"
            public static let fontSizePicker = "settings.notes.fontSizePicker"
            public static let spellCheckToggle = "settings.notes.spellCheckToggle"
            public static let highlightColorPicker = "settings.notes.highlightColorPicker"
        }

        public enum Sources {
            public static let sourcesList = "settings.sources.sourcesList"
            public static let enableAllButton = "settings.sources.enableAllButton"
            public static let disableAllButton = "settings.sources.disableAllButton"

            public static func sourceRow(_ id: String) -> String { "settings.sources.\(id)" }
            public static func sourceToggle(_ id: String) -> String { "settings.sources.\(id).toggle" }
            public static func apiKeyField(_ id: String) -> String { "settings.sources.\(id).apiKeyField" }
            public static func apiKeyVisibilityToggle(_ id: String) -> String { "settings.sources.\(id).apiKeyVisibilityToggle" }
            public static func testConnectionButton(_ id: String) -> String { "settings.sources.\(id).testConnectionButton" }
        }

        public enum Inbox {
            public static let enableInboxToggle = "settings.inbox.enableInboxToggle"
            public static let refreshIntervalPicker = "settings.inbox.refreshIntervalPicker"
            public static let maxItemsStepper = "settings.inbox.maxItemsStepper"
            public static let autoArchiveToggle = "settings.inbox.autoArchiveToggle"
            public static let archiveAfterDaysPicker = "settings.inbox.archiveAfterDaysPicker"
            public static let feedsList = "settings.inbox.feedsList"
            public static let addFeedButton = "settings.inbox.addFeedButton"

            public static func feedRow(_ id: UUID) -> String { "settings.inbox.feed.\(id.uuidString)" }
            public static func feedDeleteButton(_ id: UUID) -> String { "settings.inbox.feed.\(id.uuidString).delete" }
        }

        public enum ImportExport {
            public static let importBibTeXButton = "settings.importExport.importBibTeXButton"
            public static let importRISButton = "settings.importExport.importRISButton"
            public static let exportBibTeXButton = "settings.importExport.exportBibTeXButton"
            public static let exportRISButton = "settings.importExport.exportRISButton"
            public static let exportCSVButton = "settings.importExport.exportCSVButton"
            public static let includeAbstractsToggle = "settings.importExport.includeAbstractsToggle"
            public static let includeNotesToggle = "settings.importExport.includeNotesToggle"
            public static let exportFormatPicker = "settings.importExport.exportFormatPicker"
        }

        public enum Recommendations {
            public static let enableToggle = "settings.recommendations.enableToggle"
            public static let algorithmPicker = "settings.recommendations.algorithmPicker"
            public static let maxRecommendationsStepper = "settings.recommendations.maxRecommendationsStepper"
            public static let includeArxivToggle = "settings.recommendations.includeArxivToggle"
            public static let includeSemanticScholarToggle = "settings.recommendations.includeSemanticScholarToggle"
            public static let refreshButton = "settings.recommendations.refreshButton"
        }

        public enum Shortcuts {
            public static let shortcutsList = "settings.shortcuts.shortcutsList"
            public static let resetToDefaultsButton = "settings.shortcuts.resetToDefaultsButton"
            public static let searchField = "settings.shortcuts.searchField"

            public static func shortcutRow(_ id: String) -> String { "settings.shortcuts.\(id)" }
            public static func shortcutRecorder(_ id: String) -> String { "settings.shortcuts.\(id).recorder" }
        }

        public enum Advanced {
            public static let debugModeToggle = "settings.advanced.debugModeToggle"
            public static let clearCacheButton = "settings.advanced.clearCacheButton"
            public static let resetSettingsButton = "settings.advanced.resetSettingsButton"
            public static let exportLogsButton = "settings.advanced.exportLogsButton"
            public static let databasePathField = "settings.advanced.databasePathField"
            public static let showConsoleToggle = "settings.advanced.showConsoleToggle"
        }
    }

    // MARK: - Search

    public enum Search {
        public static let searchField = "search.searchField"
        public static let searchButton = "search.searchButton"
        public static let clearButton = "search.clearButton"
        public static let resultsList = "search.resultsList"
        public static let sourcePicker = "search.sourcePicker"
        public static let advancedToggle = "search.advancedToggle"
        public static let loadingIndicator = "search.loadingIndicator"

        public static func resultRow(_ index: Int) -> String { "search.result.\(index)" }

        public enum ArXiv {
            public static let titleField = "search.arxiv.titleField"
            public static let authorField = "search.arxiv.authorField"
            public static let abstractField = "search.arxiv.abstractField"
            public static let categoryPicker = "search.arxiv.categoryPicker"
            public static let categoryBrowser = "search.arxiv.categoryBrowser"
            public static let dateFromPicker = "search.arxiv.dateFromPicker"
            public static let dateToPicker = "search.arxiv.dateToPicker"
            public static let maxResultsStepper = "search.arxiv.maxResultsStepper"
            public static let sortByPicker = "search.arxiv.sortByPicker"
        }

        public enum ADS {
            public static let queryField = "search.ads.queryField"
            public static let authorField = "search.ads.authorField"
            public static let titleField = "search.ads.titleField"
            public static let abstractField = "search.ads.abstractField"
            public static let yearField = "search.ads.yearField"
            public static let yearFromField = "search.ads.yearFromField"
            public static let yearToField = "search.ads.yearToField"
            public static let bibcodeField = "search.ads.bibcodeField"
            public static let doiField = "search.ads.doiField"
            public static let orcidField = "search.ads.orcidField"
            public static let databasePicker = "search.ads.databasePicker"
            public static let sortByPicker = "search.ads.sortByPicker"
        }

        public enum WoS {
            public static let queryField = "search.wos.queryField"
            public static let authorField = "search.wos.authorField"
            public static let titleField = "search.wos.titleField"
            public static let topicField = "search.wos.topicField"
            public static let yearField = "search.wos.yearField"
            public static let doiField = "search.wos.doiField"
            public static let sourceField = "search.wos.sourceField"
            public static let organizationField = "search.wos.organizationField"
            public static let fundingField = "search.wos.fundingField"
        }

        public enum Feed {
            public static let nameField = "search.feed.nameField"
            public static let queryField = "search.feed.queryField"
            public static let categoryPicker = "search.feed.categoryPicker"
            public static let refreshIntervalPicker = "search.feed.refreshIntervalPicker"
            public static let saveButton = "search.feed.saveButton"
            public static let cancelButton = "search.feed.cancelButton"
        }
    }

    // MARK: - Import/Export

    public enum Import {
        public static let fileDropZone = "import.fileDropZone"
        public static let previewList = "import.previewList"
        public static let selectAllButton = "import.selectAllButton"
        public static let deselectAllButton = "import.deselectAllButton"
        public static let importButton = "import.importButton"
        public static let cancelButton = "import.cancelButton"
        public static let libraryPicker = "import.libraryPicker"
        public static let duplicateHandlingPicker = "import.duplicateHandlingPicker"
        public static let progressIndicator = "import.progressIndicator"

        public static func previewRow(_ index: Int) -> String { "import.preview.\(index)" }
        public static func previewCheckbox(_ index: Int) -> String { "import.preview.\(index).checkbox" }
    }

    public enum Export {
        public static let formatPicker = "export.formatPicker"
        public static let destinationField = "export.destinationField"
        public static let chooseDestinationButton = "export.chooseDestinationButton"
        public static let includeAbstractsToggle = "export.includeAbstractsToggle"
        public static let includeNotesToggle = "export.includeNotesToggle"
        public static let includePDFsToggle = "export.includePDFsToggle"
        public static let exportButton = "export.exportButton"
        public static let cancelButton = "export.cancelButton"
        public static let progressIndicator = "export.progressIndicator"
    }

    // MARK: - Dialogs

    public enum Dialog {
        public enum Conflict {
            public static let localOption = "dialog.conflict.localOption"
            public static let remoteOption = "dialog.conflict.remoteOption"
            public static let mergeOption = "dialog.conflict.mergeOption"
            public static let applyButton = "dialog.conflict.applyButton"
            public static let cancelButton = "dialog.conflict.cancelButton"
            public static let applyToAllToggle = "dialog.conflict.applyToAllToggle"
            public static let diffView = "dialog.conflict.diffView"
        }

        public enum Credential {
            public static let serviceLabel = "dialog.credential.serviceLabel"
            public static let apiKeyField = "dialog.credential.apiKeyField"
            public static let showPasswordToggle = "dialog.credential.showPasswordToggle"
            public static let saveButton = "dialog.credential.saveButton"
            public static let cancelButton = "dialog.credential.cancelButton"
            public static let helpButton = "dialog.credential.helpButton"
        }

        public enum Drop {
            public static let previewList = "dialog.drop.previewList"
            public static let libraryPicker = "dialog.drop.libraryPicker"
            public static let importButton = "dialog.drop.importButton"
            public static let cancelButton = "dialog.drop.cancelButton"
        }

        public enum SmartCollection {
            public static let nameField = "dialog.smartCollection.nameField"
            public static let predicateEditor = "dialog.smartCollection.predicateEditor"
            public static let addRuleButton = "dialog.smartCollection.addRuleButton"
            public static let removeRuleButton = "dialog.smartCollection.removeRuleButton"
            public static let matchAllToggle = "dialog.smartCollection.matchAllToggle"
            public static let saveButton = "dialog.smartCollection.saveButton"
            public static let cancelButton = "dialog.smartCollection.cancelButton"

            public static func ruleRow(_ index: Int) -> String { "dialog.smartCollection.rule.\(index)" }
            public static func ruleFieldPicker(_ index: Int) -> String { "dialog.smartCollection.rule.\(index).fieldPicker" }
            public static func ruleOperatorPicker(_ index: Int) -> String { "dialog.smartCollection.rule.\(index).operatorPicker" }
            public static func ruleValueField(_ index: Int) -> String { "dialog.smartCollection.rule.\(index).valueField" }
        }

        public enum Library {
            public static let nameField = "dialog.library.nameField"
            public static let locationField = "dialog.library.locationField"
            public static let chooseLocationButton = "dialog.library.chooseLocationButton"
            public static let colorPicker = "dialog.library.colorPicker"
            public static let iconPicker = "dialog.library.iconPicker"
            public static let createButton = "dialog.library.createButton"
            public static let cancelButton = "dialog.library.cancelButton"
        }
    }

    // MARK: - Console

    public enum Console {
        public static let logList = "console.logList"
        public static let searchField = "console.searchField"
        public static let levelFilter = "console.levelFilter"
        public static let clearButton = "console.clearButton"
        public static let exportButton = "console.exportButton"
        public static let autoScrollToggle = "console.autoScrollToggle"
    }

    // MARK: - PDF Browser

    public enum PDFBrowser {
        public static let urlField = "pdfBrowser.urlField"
        public static let backButton = "pdfBrowser.backButton"
        public static let forwardButton = "pdfBrowser.forwardButton"
        public static let refreshButton = "pdfBrowser.refreshButton"
        public static let stopButton = "pdfBrowser.stopButton"
        public static let downloadButton = "pdfBrowser.downloadButton"
        public static let webView = "pdfBrowser.webView"
        public static let statusBar = "pdfBrowser.statusBar"
        public static let progressIndicator = "pdfBrowser.progressIndicator"
    }

    // MARK: - Toolbar

    public enum Toolbar {
        public static let addButton = "toolbar.addButton"
        public static let removeButton = "toolbar.removeButton"
        public static let searchButton = "toolbar.searchButton"
        public static let sortMenu = "toolbar.sortMenu"
        public static let viewModeButton = "toolbar.viewModeButton"
        public static let shareButton = "toolbar.shareButton"
        public static let syncButton = "toolbar.syncButton"
        public static let settingsButton = "toolbar.settingsButton"
    }

    // MARK: - Help

    public enum Help {
        // Main views
        public static let window = "help.window"
        public static let sidebar = "help.sidebar"
        public static let documentView = "help.documentView"

        // Search
        public static let searchField = "help.searchField"
        public static let searchPalette = "help.searchPalette"
        public static let searchResults = "help.searchResults"

        /// Search result row identifier
        public static func searchResult(_ index: Int) -> String {
            "help.searchResult.\(index)"
        }

        // Sidebar
        /// Category section identifier
        public static func categorySection(_ category: HelpCategory) -> String {
            "help.category.\(category.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"
        }

        /// Sidebar document row identifier
        public static func sidebarDocument(_ id: String) -> String {
            "help.sidebar.document.\(id)"
        }

        // Document
        /// Document content identifier
        public static func documentContent(_ id: String) -> String {
            "help.document.\(id)"
        }

        public static let documentTitle = "help.document.title"
        public static let documentBody = "help.document.body"

        // Navigation
        public static let backButton = "help.navigation.back"
        public static let homeButton = "help.navigation.home"
    }
}

// MARK: - View Extension

extension View {
    /// Add an accessibility identifier for UI testing.
    ///
    /// Convenience wrapper that also adds the identifier as an accessibility hint
    /// for debugging purposes.
    ///
    /// - Parameter identifier: The accessibility identifier string
    /// - Returns: Modified view with accessibility identifier
    public func testID(_ identifier: String) -> some View {
        self
            .accessibilityIdentifier(identifier)
    }

    /// Add accessibility identifier for a sidebar library row.
    public func sidebarLibraryID(_ libraryID: UUID) -> some View {
        self.testID(AccessibilityID.Sidebar.libraryRow(libraryID))
    }

    /// Add accessibility identifier for a sidebar collection row.
    public func sidebarCollectionID(_ collectionID: UUID) -> some View {
        self.testID(AccessibilityID.Sidebar.folderRow(collectionID))
    }

    /// Add accessibility identifier for a publication row.
    public func publicationRowID(_ citeKey: String) -> some View {
        self.testID(AccessibilityID.List.publicationRow(citeKey))
    }

    /// Add accessibility identifier for a search result.
    public func searchResultID(_ index: Int) -> some View {
        self.testID(AccessibilityID.Search.resultRow(index))
    }
}
