//
//  ImprintAccessibilityID.swift
//  imprintUITests
//
//  Accessibility identifiers for imprint UI elements.
//

import Foundation

/// Namespace for accessibility identifiers in imprint
enum ImprintAccessibilityID {

    // MARK: - Toolbar

    enum Toolbar {
        static let editModePicker = "toolbar.editModePicker"
        static let compileButton = "toolbar.compileButton"
        static let citationButton = "toolbar.citationButton"
        static let shareButton = "toolbar.shareButton"

        enum Mode {
            static let directPdf = "toolbar.mode.directPdf"
            static let splitView = "toolbar.mode.splitView"
            static let textOnly = "toolbar.mode.textOnly"
        }
    }

    // MARK: - Sidebar

    enum Sidebar {
        static let outline = "sidebar.outline"
    }

    // MARK: - Content

    enum Content {
        static let editorArea = "content.editorArea"
    }

    // MARK: - Source Editor

    enum SourceEditor {
        static let container = "sourceEditor.container"
        static let textView = "sourceEditor.textView"
    }

    // MARK: - PDF Preview

    enum PDFPreview {
        static let container = "pdfPreview.container"
        static let document = "pdfPreview.document"
    }

    // MARK: - Direct PDF

    enum DirectPDF {
        static let container = "directPdf.container"
        static let modeIndicator = "directPdf.modeIndicator"
    }

    // MARK: - Citation Picker

    enum CitationPicker {
        static let container = "citationPicker.container"
        static let searchField = "citationPicker.searchField"
        static let resultsList = "citationPicker.resultsList"
        static let insertButton = "citationPicker.insertButton"
        static let cancelButton = "citationPicker.cancelButton"

        static func resultRow(_ index: Int) -> String {
            "citationPicker.result.\(index)"
        }
    }

    // MARK: - Version History

    enum VersionHistory {
        static let container = "versionHistory.container"
        static let timeline = "versionHistory.timeline"
        static let preview = "versionHistory.preview"
        static let restoreButton = "versionHistory.restoreButton"
        static let compareButton = "versionHistory.compareButton"

        static func snapshotRow(_ index: Int) -> String {
            "versionHistory.snapshot.\(index)"
        }
    }

    // MARK: - Document Outline

    enum Outline {
        static let container = "outline.container"

        static func item(_ lineNumber: Int) -> String {
            "outline.item.\(lineNumber)"
        }
    }

    // MARK: - Settings

    enum Settings {
        static let container = "settings.container"

        enum Tabs {
            static let general = "settings.tabs.general"
            static let editor = "settings.tabs.editor"
            static let export = "settings.tabs.export"
            static let account = "settings.tabs.account"
        }

        enum General {
            static let editModePicker = "settings.general.editModePicker"
            static let autoSaveStepper = "settings.general.autoSaveStepper"
            static let backupToggle = "settings.general.backupToggle"
        }

        enum Editor {
            static let fontFamilyPicker = "settings.editor.fontFamilyPicker"
            static let fontSizeStepper = "settings.editor.fontSizeStepper"
            static let lineNumbersToggle = "settings.editor.lineNumbersToggle"
            static let highlightLineToggle = "settings.editor.highlightLineToggle"
            static let wrapLinesToggle = "settings.editor.wrapLinesToggle"
        }
    }
}
