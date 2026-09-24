#if os(macOS)
// Chassis file — macOS-only.
//
//  ManuscriptPreviewContent.swift
//  PublicationManagerCore
//
//  A manuscript's preview: the compiled artifact for Typst/LaTeX, the live
//  MarkdownUI render for Markdown, and the honest states in between (no LaTeX
//  engine here, the latest compile failed, nothing compiled yet).
//
//  Moved verbatim out of `ManuscriptDetailPane`'s Preview tab (plan wave 6,
//  W4 pass B) so the layout tree's `pdf` pane over manuscripts shows the same
//  view rather than a second one. What differed between the two hosts is one
//  thing — what "show the source" means — and it is the `onShowSource`
//  closure: the detail pane switches to its Source tab, the tree focuses the
//  pane that edits the manuscript.
//

import SwiftUI

struct ManuscriptPreviewContent: View {

    /// The manuscript's live session, or nil while it resolves.
    let session: ManuscriptEditorSession?
    /// Bring the source into view. Called BEFORE the caret moves on an
    /// inverse-sync click: the editor has to be in the hierarchy to scroll.
    let onShowSource: () -> Void

    private var previewKind: DocumentFormat.PreviewKind {
        session?.format.previewKind ?? .compiledPDF
    }

    var body: some View {
        // The Preview tab: compiled artifact for Typst/LaTeX, live
        // MarkdownUI render for Markdown (no compile step).
        if previewKind == .renderedMarkdown, let session {
            MarkdownPreviewTab(session: session)
        } else if let session, session.latexPreviewUnavailable {
            ManuscriptLaTeXImprintPrompt(session: session)
        } else if let data = session?.vm.pdfData {
            // A click both jumps the caret AND shows the source so the jump
            // is visible.
            ManuscriptPDFPreview(
                data: data,
                // Entering the preview lands on the region matching the caret
                // instead of page 1.
                cursorOffset: session?.cursorPosition,
                sourceMapEntries: session?.vm.sourceMapEntries ?? [],
                onInverseSync: { page, x, y in
                    guard let session else { return }
                    Task {
                        if let offset = await ManuscriptInverseSync.resolveOffset(
                            session: session, page: page, x: x, y: y) {
                            // Show the source FIRST, then move the caret: the
                            // editor has to exist before it can scroll to the
                            // offset. Setting cursorPosition while the editor
                            // is not in the hierarchy loses the jump.
                            onShowSource()
                            session.cursorPosition = offset
                        }
                    }
                })
                // A stale PDF must not impersonate the current manuscript:
                // when the LATEST compile failed, say so on the preview
                // itself, with the error one copy-click away.
                .overlay(alignment: .bottom) {
                    if let session, let error = session.vm.compilationError {
                        ManuscriptCompileErrorBanner(
                            errorText: error,
                            diagnostics: session.vm.compilationDiagnostics
                        )
                    }
                }
        } else if let session, let error = session.vm.compilationError {
            // A failed compile used to fall through to the "Nothing
            // compiled yet" placeholder — the user was left staring at an
            // empty state while the error sat unshown on the controller.
            ManuscriptCompileErrorCard(
                errorText: error,
                diagnostics: session.vm.compilationDiagnostics,
                onOpenSource: onShowSource
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.richtext").font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Nothing compiled yet")
                    .foregroundStyle(.secondary)
                Text("Edit in the Source tab to compile a preview.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
