//
//  DetachedPDFWindowView.swift
//  imprint
//
//  Content of the detached PDF preview window (scene id "pdf-preview").
//  Observes CompiledPDFStore, so it live-updates on every recompile without
//  any coupling to the editor window's view model. Placement on the second
//  display is handled declaratively by the scene's defaultWindowPlacement.
//

import SwiftUI

struct DetachedPDFWindowView: View {
    let manuscriptID: UUID?

    private var entry: CompiledPDFStore.Entry? {
        guard let manuscriptID else { return nil }
        return CompiledPDFStore.shared.entry(for: manuscriptID)
    }

    var body: some View {
        Group {
            if let entry {
                PDFPreviewView(
                    pdfData: entry.pdfData,
                    isCompiling: entry.isCompiling,
                    sourceMapEntries: [],
                    cursorPosition: 0
                )
            } else {
                ContentUnavailableView(
                    "No Compiled PDF",
                    systemImage: "doc.richtext",
                    description: Text("Open a manuscript and compile it (⌘↩), then use View ▸ Open PDF on Second Display.")
                )
            }
        }
        .navigationTitle(entry.map { "\($0.title) — PDF" } ?? "PDF Preview")
    }
}
