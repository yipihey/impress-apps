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
        static let inbox = "sidebar.inbox"
        static let allPapers = "sidebar.allPapers"
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
        static func folderRow(_ id: String) -> String { "sidebar.folder.\(id)" }
        static func smartCollectionRow(_ id: String) -> String { "sidebar.smartCollection.\(id)" }
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
        enum Tabs {
            static let info = "detail.tabs.info"
            static let pdf = "detail.tabs.pdf"
            static let notes = "detail.tabs.notes"
            static let bibtex = "detail.tabs.bibtex"
            static let references = "detail.tabs.references"
            static let annotations = "detail.tabs.annotations"
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
        static let addButton = "toolbar.addButton"
        static let removeButton = "toolbar.removeButton"
        static let searchButton = "toolbar.searchButton"
        static let sortMenu = "toolbar.sortMenu"
        static let viewModeButton = "toolbar.viewModeButton"
        static let shareButton = "toolbar.shareButton"
        static let syncButton = "toolbar.syncButton"
        static let settingsButton = "toolbar.settingsButton"
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
}
