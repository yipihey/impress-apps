//
//  ImprintNotifications.swift
//  imprint
//
//  App-wide Notification.Name constants. Pure Foundation — lives in Shared
//  (outside ImprintApp.swift's #if os(macOS)) because cross-platform code
//  like ImprintDocument posts these on both platforms.
//

import Foundation

extension Notification.Name {
    static let insertCitation = Notification.Name("insertCitation")
    static let compileDocument = Notification.Name("compileDocument")
    static let formatBold = Notification.Name("formatBold")
    static let formatItalic = Notification.Name("formatItalic")
    static let insertHeading = Notification.Name("insertHeading")
    static let printPDF = Notification.Name("printPDF")
    static let exportPDF = Notification.Name("exportPDF")
    static let exportLatex = Notification.Name("exportLatex")
    static let exportBibliography = Notification.Name("exportBibliography")
    static let showVersionHistory = Notification.Name("showVersionHistory")
    static let shareDocument = Notification.Name("shareDocument")
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
    static let toggleAIAssistant = Notification.Name("toggleAIAssistant")
    static let toggleCommentsSidebar = Notification.Name("toggleCommentsSidebar")
    static let toggleVeuszPlotsPanel = Notification.Name("toggleVeuszPlotsPanel")
    static let presentVeuszPlotPicker = Notification.Name("presentVeuszPlotPicker")
    static let addCommentAtSelection = Notification.Name("addCommentAtSelection")
    static let showAIContextMenu = Notification.Name("showAIContextMenu")
    /// Run a specific AI author-task on a source range (from a cell bracket or
    /// text selection). userInfo: ["actionId": String, "range": NSValue(range:)].
    static let runInlineAITask = Notification.Name("imprint.runInlineAITask")
    static let showSymbolPalette = Notification.Name("showSymbolPalette")
    static let formatDocument = Notification.Name("formatDocument")

    // Git
    static let gitCommit = Notification.Name("gitCommit")
    static let gitPush = Notification.Name("gitPush")
    static let gitPull = Notification.Name("gitPull")
    static let gitLink = Notification.Name("gitLink")
    static let gitCreateRepo = Notification.Name("gitCreateRepo")
    static let gitHistory = Notification.Name("gitHistory")

    // Document lifecycle
    static let imprintDocumentDidSave = Notification.Name("imprintDocumentDidSave")
}
