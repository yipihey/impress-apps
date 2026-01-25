//
//  XCUIElement+Accessibility.swift
//  imbibUITests
//
//  Created by Claude on 2026-01-22.
//

import XCTest

extension XCUIApplication {
    /// Finds an element by its accessibility identifier
    func element(id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Subscript access to elements by accessibility identifier
    subscript(id: String) -> XCUIElement {
        element(id: id)
    }
}

extension XCUIElement {
    /// Waits for the element to exist and returns self for chaining
    @discardableResult
    func waitForExistenceAndReturn(timeout: TimeInterval = 5) -> XCUIElement {
        _ = waitForExistence(timeout: timeout)
        return self
    }

    /// Taps the element after waiting for it to exist
    func tapWhenReady(timeout: TimeInterval = 5) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Element \(identifier) did not appear")
        tap()
    }

    /// Types text into the element after waiting for it to exist
    func typeTextWhenReady(_ text: String, timeout: TimeInterval = 5) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "Element \(identifier) did not appear")
        tap()
        typeText(text)
    }

    /// Clears existing text and types new text
    func clearAndTypeText(_ text: String) {
        tap()
        if let stringValue = value as? String, !stringValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: stringValue.count)
            typeText(deleteString)
        }
        typeText(text)
    }
}

/// Namespace for accessibility identifiers matching PublicationManagerCore
enum AccessibilityID {

    // MARK: - Sidebar

    enum Sidebar {
        static let container = "sidebar.container"
        static let inbox = "sidebar.inbox"
        static let allPapers = "sidebar.allPapers"
        static let allPublications = "sidebar.allPublications"
        static let searchSources = "sidebar.searchSources"
        static let recentlyAdded = "sidebar.recentlyAdded"
        static let recentlyRead = "sidebar.recentlyRead"
        static let unread = "sidebar.unread"
        static let flagged = "sidebar.flagged"
        static let trash = "sidebar.trash"
        static let newLibraryButton = "sidebar.newLibraryButton"
        static let newFolderButton = "sidebar.newFolderButton"
        static let newSmartCollectionButton = "sidebar.newSmartCollectionButton"
        static let settingsButton = "sidebar.settingsButton"
        static let searchField = "sidebar.searchField"
        static let refreshButton = "sidebar.refreshButton"

        static func libraryRow(_ id: String) -> String { "sidebar.library.\(id)" }
        static func library(_ id: String) -> String { "sidebar.library.\(id)" }
        static func folderRow(_ id: String) -> String { "sidebar.folder.\(id)" }
        static func smartCollectionRow(_ id: String) -> String { "sidebar.smartCollection.\(id)" }
        static func collection(_ id: String) -> String { "sidebar.collection.\(id)" }
        static func smartSearch(_ id: String) -> String { "sidebar.smartSearch.\(id)" }
        static func sourceRow(_ id: String) -> String { "sidebar.source.\(id)" }
        static func feedRow(_ id: String) -> String { "sidebar.feed.\(id)" }
    }

    // MARK: - List View

    enum List {
        static let searchField = "list.searchField"
        static let sortButton = "list.sortButton"
        static let filterButton = "list.filterButton"
        static let selectAllButton = "list.selectAllButton"
        static let deleteButton = "list.deleteButton"
        static let emptyStateView = "list.emptyStateView"

        static func publicationRow(_ citeKey: String) -> String { "list.publication.\(citeKey)" }
        static func publicationToggleRead(_ citeKey: String) -> String { "list.publication.\(citeKey).toggleRead" }
        static func publicationToggleFlagged(_ citeKey: String) -> String { "list.publication.\(citeKey).toggleFlagged" }
        static func publicationPDFButton(_ citeKey: String) -> String { "list.publication.\(citeKey).pdfButton" }
    }

    // MARK: - Detail View

    enum Detail {
        static let container = "detail.container"
        static let emptyState = "detail.emptyState"

        enum Tabs {
            static let info = "detail.tabs.info"
            static let pdf = "detail.tabs.pdf"
            static let notes = "detail.tabs.notes"
            static let bibtex = "detail.tabs.bibtex"
            static let references = "detail.tabs.references"
            static let annotations = "detail.tabs.annotations"
        }

        // Alternative naming for Tab (used by some tests)
        enum Tab {
            static let pdf = "detail.tab.pdf"
            static let bibtex = "detail.tab.bibtex"
            static let notes = "detail.tab.notes"
            static let info = "detail.tab.info"
            static let related = "detail.tab.related"
        }

        enum Info {
            static let titleField = "detail.info.titleField"
            static let authorsField = "detail.info.authorsField"
            static let authorsExpand = "detail.info.authorsExpand"
            static let yearField = "detail.info.yearField"
            static let journalField = "detail.info.journalField"
            static let abstractField = "detail.info.abstractField"
            static let doiField = "detail.info.doiField"
            static let doiCopyButton = "detail.info.doiCopyButton"
            static let doiOpenButton = "detail.info.doiOpenButton"
            static let arxivField = "detail.info.arxivField"
            static let arxivOpenButton = "detail.info.arxivOpenButton"
            static let citationCount = "detail.info.citationCount"
            static let addToLibraryButton = "detail.info.addToLibraryButton"
            static let openPDFButton = "detail.info.openPDFButton"
            static let downloadPDFButton = "detail.info.downloadPDFButton"
            static let keywordsField = "detail.info.keywordsField"
        }

        // Alternative naming for Field (used by some tests)
        enum Field {
            static let title = "detail.field.title"
            static let authors = "detail.field.authors"
            static let year = "detail.field.year"
            static let journal = "detail.field.journal"
            static let abstract = "detail.field.abstract"
            static let doi = "detail.field.doi"
            static let citeKey = "detail.field.citeKey"
        }

        // Action buttons
        enum Action {
            static let openPDF = "detail.action.openPDF"
            static let downloadPDF = "detail.action.downloadPDF"
            static let copyDOI = "detail.action.copyDOI"
            static let openURL = "detail.action.openURL"
            static let edit = "detail.action.edit"
            static let delete = "detail.action.delete"
        }

        enum PDF {
            static let viewer = "detail.pdf.viewer"
            static let zoomInButton = "detail.pdf.zoomInButton"
            static let zoomOutButton = "detail.pdf.zoomOutButton"
            static let zoomFitButton = "detail.pdf.zoomFitButton"
            static let pageField = "detail.pdf.pageField"
            static let previousPageButton = "detail.pdf.previousPageButton"
            static let nextPageButton = "detail.pdf.nextPageButton"
            static let searchField = "detail.pdf.searchField"
            static let thumbnailSidebar = "detail.pdf.thumbnailSidebar"
            static let downloadButton = "detail.pdf.downloadButton"
            static let noPDFView = "detail.pdf.noPDFView"
            static let findPDFButton = "detail.pdf.findPDFButton"
        }

        enum Notes {
            static let editor = "detail.notes.editor"
            static let saveButton = "detail.notes.saveButton"
            static let clearButton = "detail.notes.clearButton"
        }

        enum BibTeX {
            static let editor = "detail.bibtex.editor"
            static let copyButton = "detail.bibtex.copyButton"
            static let saveButton = "detail.bibtex.saveButton"
            static let resetButton = "detail.bibtex.resetButton"
            static let validateButton = "detail.bibtex.validateButton"
            static let validationStatus = "detail.bibtex.validationStatus"
        }

        enum References {
            static let list = "detail.references.list"
            static let refreshButton = "detail.references.refreshButton"
            static let loadingIndicator = "detail.references.loadingIndicator"
            static func referenceRow(_ index: Int) -> String { "detail.references.row.\(index)" }
        }
    }

    // MARK: - Settings

    enum Settings {
        static let container = "settings.container"
        static let tabView = "settings.tabView"
        static let closeButton = "settings.closeButton"
        static let doneButton = "settings.doneButton"

        enum Tabs {
            static let general = "settings.tabs.general"
            static let appearance = "settings.tabs.appearance"
            static let viewing = "settings.tabs.viewing"
            static let pdf = "settings.tabs.pdf"
            static let notes = "settings.tabs.notes"
            static let sources = "settings.tabs.sources"
            static let inbox = "settings.tabs.inbox"
            static let importExport = "settings.tabs.importExport"
            static let recommendations = "settings.tabs.recommendations"
            static let shortcuts = "settings.tabs.shortcuts"
            static let advanced = "settings.tabs.advanced"
        }

        // Alternative naming for Tab (used by some tests)
        enum Tab {
            static let general = "settings.tab.general"
            static let sources = "settings.tab.sources"
            static let appearance = "settings.tab.appearance"
            static let shortcuts = "settings.tab.shortcuts"
        }

        enum General {
            static let libraryLocationField = "settings.general.libraryLocationField"
            static let chooseLocationButton = "settings.general.chooseLocationButton"
            static let defaultLibraryPicker = "settings.general.defaultLibraryPicker"
            static let autoImportToggle = "settings.general.autoImportToggle"
            static let launchAtLoginToggle = "settings.general.launchAtLoginToggle"
            static let checkUpdatesToggle = "settings.general.checkUpdatesToggle"
        }

        enum Appearance {
            static let themeGrid = "settings.appearance.themeGrid"
            static let themePicker = "settings.appearance.themePicker"
            static let accentColorPicker = "settings.appearance.accentColorPicker"
            static let fontSizeStepper = "settings.appearance.fontSizeStepper"
            static let compactModeToggle = "settings.appearance.compactModeToggle"
            static let showIconsToggle = "settings.appearance.showIconsToggle"
        }

        enum Sources {
            static let sourcesList = "settings.sources.sourcesList"
            static let enableAllButton = "settings.sources.enableAllButton"
            static let disableAllButton = "settings.sources.disableAllButton"

            static func sourceRow(_ id: String) -> String { "settings.sources.\(id)" }
            static func sourceToggle(_ id: String) -> String { "settings.sources.\(id).toggle" }
            static func apiKeyField(_ id: String) -> String { "settings.sources.\(id).apiKeyField" }
        }

        enum Advanced {
            static let debugModeToggle = "settings.advanced.debugModeToggle"
            static let clearCacheButton = "settings.advanced.clearCacheButton"
            static let resetSettingsButton = "settings.advanced.resetSettingsButton"
            static let exportLogsButton = "settings.advanced.exportLogsButton"
        }
    }

    // MARK: - Search

    enum Search {
        static let searchField = "search.searchField"
        static let searchButton = "search.searchButton"
        static let clearButton = "search.clearButton"
        static let resultsList = "search.resultsList"
        static let sourcePicker = "search.sourcePicker"
        static let advancedToggle = "search.advancedToggle"
        static let loadingIndicator = "search.loadingIndicator"

        static func resultRow(_ index: Int) -> String { "search.result.\(index)" }

        enum ArXiv {
            static let titleField = "search.arxiv.titleField"
            static let authorField = "search.arxiv.authorField"
            static let abstractField = "search.arxiv.abstractField"
            static let categoryPicker = "search.arxiv.categoryPicker"
            static let categoryBrowser = "search.arxiv.categoryBrowser"
            static let dateFromPicker = "search.arxiv.dateFromPicker"
            static let dateToPicker = "search.arxiv.dateToPicker"
            static let maxResultsStepper = "search.arxiv.maxResultsStepper"
            static let sortByPicker = "search.arxiv.sortByPicker"
        }

        enum ADS {
            static let queryField = "search.ads.queryField"
            static let authorField = "search.ads.authorField"
            static let titleField = "search.ads.titleField"
            static let abstractField = "search.ads.abstractField"
            static let yearField = "search.ads.yearField"
            static let yearFromField = "search.ads.yearFromField"
            static let yearToField = "search.ads.yearToField"
            static let bibcodeField = "search.ads.bibcodeField"
            static let doiField = "search.ads.doiField"
        }
    }

    // MARK: - Toolbar

    enum Toolbar {
        static let container = "toolbar.container"
        static let globalSearch = "toolbar.globalSearch"
        static let addButton = "toolbar.addButton"
        static let addPublication = "toolbar.addPublication"
        static let importBibTeX = "toolbar.importBibTeX"
        static let removeButton = "toolbar.removeButton"
        static let searchButton = "toolbar.searchButton"
        static let sortMenu = "toolbar.sortMenu"
        static let filterMenu = "toolbar.filterMenu"
        static let viewModeButton = "toolbar.viewModeButton"
        static let shareButton = "toolbar.shareButton"
        static let syncButton = "toolbar.syncButton"
        static let refresh = "toolbar.refresh"
        static let settingsButton = "toolbar.settingsButton"
        static let toggleSidebar = "toolbar.toggleSidebar"
        static let toggleDetail = "toolbar.toggleDetail"
    }

    // MARK: - Dialog

    enum Dialog {
        enum SmartCollection {
            static let nameField = "dialog.smartCollection.nameField"
            static let predicateEditor = "dialog.smartCollection.predicateEditor"
            static let addRuleButton = "dialog.smartCollection.addRuleButton"
            static let matchAllToggle = "dialog.smartCollection.matchAllToggle"
            static let saveButton = "dialog.smartCollection.saveButton"
            static let cancelButton = "dialog.smartCollection.cancelButton"
        }

        enum Library {
            static let nameField = "dialog.library.nameField"
            static let locationField = "dialog.library.locationField"
            static let chooseLocationButton = "dialog.library.chooseLocationButton"
            static let createButton = "dialog.library.createButton"
            static let cancelButton = "dialog.library.cancelButton"
        }
    }

    // MARK: - Publication List

    enum PublicationList {
        static let container = "publicationList.container"
        static let searchField = "publicationList.searchField"
        static let emptyState = "publicationList.emptyState"

        static func row(_ citeKey: String) -> String {
            "publication.row.\(citeKey)"
        }

        static func rowTitle(_ citeKey: String) -> String {
            "publication.row.\(citeKey).title"
        }

        static func rowAuthors(_ citeKey: String) -> String {
            "publication.row.\(citeKey).authors"
        }
    }

    // MARK: - Global Search

    enum GlobalSearch {
        static let container = "globalSearch.container"
        static let field = "globalSearch.field"
        static let results = "globalSearch.results"
        static let clearButton = "globalSearch.clearButton"
        static let closeButton = "globalSearch.closeButton"

        static func result(_ index: Int) -> String {
            "globalSearch.result.\(index)"
        }
    }

    // MARK: - PDF Viewer

    enum PDFViewer {
        static let container = "pdfViewer.container"
        static let document = "pdfViewer.document"
        static let pageIndicator = "pdfViewer.pageIndicator"
        static let zoomSlider = "pdfViewer.zoomSlider"
        static let searchField = "pdfViewer.searchField"

        enum Annotation {
            static let highlight = "pdfViewer.annotation.highlight"
            static let underline = "pdfViewer.annotation.underline"
            static let strikethrough = "pdfViewer.annotation.strikethrough"
            static let note = "pdfViewer.annotation.note"
            static let colorPicker = "pdfViewer.annotation.colorPicker"
        }
    }

    // MARK: - Sheets & Dialogs

    enum Sheet {
        static let importProgress = "sheet.importProgress"
        static let exportOptions = "sheet.exportOptions"
        static let libraryCreation = "sheet.libraryCreation"
        static let collectionCreation = "sheet.collectionCreation"
        static let smartSearchCreation = "sheet.smartSearchCreation"
        static let triagePicker = "sheet.triagePicker"
    }

    // MARK: - Inbox / Triage

    enum Inbox {
        static let container = "inbox.container"
        static let keepButton = "inbox.keepButton"
        static let dismissButton = "inbox.dismissButton"
        static let starButton = "inbox.starButton"
        static let unreadCount = "inbox.unreadCount"
    }
}
