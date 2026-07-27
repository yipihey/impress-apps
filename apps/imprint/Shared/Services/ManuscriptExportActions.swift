#if os(macOS)
//
//  ManuscriptExportActions.swift
//  imprint
//
//  Save-panel + error-alert wrappers around ManuscriptExporter, shared by the
//  standalone editor window's Export menu and the File ▸ Document menu
//  commands (which act on the frontmost window's `focusedManuscriptID`).
//

import AppKit
import PublicationManagerCore
import UniformTypeIdentifiers

@MainActor
enum ManuscriptExportActions {

    static func exportAsBundle(manuscriptID: UUID) {
        let title = manuscriptTitle(manuscriptID)
        let panel = NSSavePanel()
        panel.title = "Export as .imprint Bundle"
        panel.nameFieldStringValue = "\(title).imprint"
        panel.allowedContentTypes = [UTType(filenameExtension: "imprint") ?? .package]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try ManuscriptExporter.exportAsBundle(manuscriptID: manuscriptID, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            presentError(error)
        }
    }

    static func exportAsProject(manuscriptID: UUID) {
        let panel = NSSavePanel()
        panel.title = "Export Standalone Project"
        panel.nameFieldStringValue = manuscriptTitle(manuscriptID)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try ManuscriptExporter.exportAsProject(manuscriptID: manuscriptID, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            presentError(error)
        }
    }

    /// Write the last compiled PDF from the live editor session. No compiled
    /// artifact yet → explanatory alert instead of a silent no-op.
    static func exportPDF(manuscriptID: UUID) {
        guard let data = ManuscriptSessionRegistry.shared
            .session(for: manuscriptID)?.vm.pdfData
        else {
            let alert = NSAlert()
            alert.messageText = "Nothing compiled yet"
            alert.informativeText =
                "Open the manuscript's Source tab to compile a PDF, then export."
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.nameFieldStringValue = "\(manuscriptTitle(manuscriptID)).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try data.write(to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            presentError(error)
        }
    }

    private static func manuscriptTitle(_ id: UUID) -> String {
        ManuscriptStoreAdapter.shared.manuscript(id: id)?.title ?? "manuscript"
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
#endif
