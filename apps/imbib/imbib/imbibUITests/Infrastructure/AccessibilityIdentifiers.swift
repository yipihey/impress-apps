//
//  AccessibilityIdentifiers.swift
//  imbibUITests
//
//  Centralized accessibility identifiers for UI testing.
//

import Foundation

/// Centralized accessibility identifiers used throughout the app.
///
/// These identifiers are shared between the app (for setting) and
/// UI tests (for querying). Keep this file in sync with identifiers
/// set in the app views.
enum AccessibilityID {

    // MARK: - Sidebar

    enum Sidebar {
        static let container = "sidebar.container"
        static let inbox = "sidebar.inbox"
        static let allPublications = "sidebar.allPublications"
        static let searchSources = "sidebar.searchSources"

        /// Library row: "sidebar.library.{libraryID}"
        static func library(_ id: String) -> String {
            "sidebar.library.\(id)"
        }

        /// Collection row: "sidebar.collection.{collectionID}"
        static func collection(_ id: String) -> String {
            "sidebar.collection.\(id)"
        }

        /// Smart search row: "sidebar.smartSearch.{searchID}"
        static func smartSearch(_ id: String) -> String {
            "sidebar.smartSearch.\(id)"
        }
    }

    // MARK: - Toolbar

    enum Toolbar {
        static let container = "toolbar.container"
        static let globalSearch = "toolbar.globalSearch"
        static let addPublication = "toolbar.addPublication"
        static let importBibTeX = "toolbar.importBibTeX"
        static let refresh = "toolbar.refresh"
        static let toggleSidebar = "toolbar.toggleSidebar"
        static let toggleDetail = "toolbar.toggleDetail"
        static let sortMenu = "toolbar.sortMenu"
        static let filterMenu = "toolbar.filterMenu"
    }

    // MARK: - Publication List

    enum PublicationList {
        static let container = "publicationList.container"
        static let searchField = "publicationList.searchField"
        static let emptyState = "publicationList.emptyState"

        /// Publication row: "publication.row.{citeKey}"
        static func row(_ citeKey: String) -> String {
            "publication.row.\(citeKey)"
        }

        /// Row title: "publication.row.{citeKey}.title"
        static func rowTitle(_ citeKey: String) -> String {
            "publication.row.\(citeKey).title"
        }

        /// Row authors: "publication.row.{citeKey}.authors"
        static func rowAuthors(_ citeKey: String) -> String {
            "publication.row.\(citeKey).authors"
        }
    }

    // MARK: - Detail View

    enum Detail {
        static let container = "detail.container"
        static let emptyState = "detail.emptyState"

        /// Tab buttons
        enum Tab {
            static let pdf = "detail.tab.pdf"
            static let bibtex = "detail.tab.bibtex"
            static let notes = "detail.tab.notes"
            static let info = "detail.tab.info"
            static let related = "detail.tab.related"
        }

        /// Metadata fields
        enum Field {
            static let title = "detail.field.title"
            static let authors = "detail.field.authors"
            static let year = "detail.field.year"
            static let journal = "detail.field.journal"
            static let abstract = "detail.field.abstract"
            static let doi = "detail.field.doi"
            static let citeKey = "detail.field.citeKey"
        }

        /// Action buttons
        enum Action {
            static let openPDF = "detail.action.openPDF"
            static let downloadPDF = "detail.action.downloadPDF"
            static let copyDOI = "detail.action.copyDOI"
            static let openURL = "detail.action.openURL"
            static let edit = "detail.action.edit"
            static let delete = "detail.action.delete"
        }
    }

    // MARK: - Global Search

    enum GlobalSearch {
        static let container = "globalSearch.container"
        static let field = "globalSearch.field"
        static let results = "globalSearch.results"
        static let clearButton = "globalSearch.clearButton"
        static let closeButton = "globalSearch.closeButton"

        /// Result row: "globalSearch.result.{index}"
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

        /// Annotation toolbar
        enum Annotation {
            static let highlight = "pdfViewer.annotation.highlight"
            static let underline = "pdfViewer.annotation.underline"
            static let strikethrough = "pdfViewer.annotation.strikethrough"
            static let note = "pdfViewer.annotation.note"
            static let colorPicker = "pdfViewer.annotation.colorPicker"
        }
    }

    // MARK: - Settings

    enum Settings {
        static let container = "settings.container"

        enum Tab {
            static let general = "settings.tab.general"
            static let sources = "settings.tab.sources"
            static let appearance = "settings.tab.appearance"
            static let shortcuts = "settings.tab.shortcuts"
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
