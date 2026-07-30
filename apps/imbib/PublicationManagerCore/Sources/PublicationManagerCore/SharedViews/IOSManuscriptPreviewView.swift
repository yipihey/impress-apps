//
//  IOSManuscriptPreviewView.swift
//  PublicationManagerCore
//
//  THE iOS preview surface for a manuscript. Which surface appears is derived
//  from `DocumentFormat.PreviewKind` — never from a hardcoded "typst → PDF"
//  test at the call site:
//
//      .compiledPDF      → IOSPDFPreviewView (PDFKit, the existing view)
//      .renderedMarkdown → live MarkdownUI render of the buffer (no compile)
//      .none             → an explicit "no preview" state; hosts should not
//                          offer a preview affordance at all (`hasPreview`)
//
//  A new format only has to answer `previewKind` and every iOS host — imprint's
//  iPhone/iPad editor and imbib's manuscript detail — picks it up.
//

#if os(iOS)
import SwiftUI

public struct IOSManuscriptPreviewView: View {

    /// The manuscript's format — the ONLY input that selects the surface.
    let format: DocumentFormat
    /// The live editor buffer (used by formats that render without compiling).
    let source: String
    /// Latest compiled artifact, for `.compiledPDF` formats.
    let pdfData: Data?
    let isCompiling: Bool
    /// Diagnostic from the last compile, so a failure is shown as a failure
    /// rather than as an empty pane.
    let compilationError: String?

    public init(
        format: DocumentFormat,
        source: String,
        pdfData: Data?,
        isCompiling: Bool,
        compilationError: String? = nil
    ) {
        self.format = format
        self.source = source
        self.pdfData = pdfData
        self.isCompiling = isCompiling
        self.compilationError = compilationError
    }

    public var body: some View {
        switch format.previewKind {
        case .compiledPDF:
            IOSPDFPreviewView(
                pdfData: pdfData,
                isCompiling: isCompiling,
                compilationError: compilationError
            )
        case .renderedMarkdown:
            // The chassis's markdown preview, unmodified — the same view macOS
            // shows in its Preview tab. There is no iOS-specific copy.
            MarkdownSourcePreview(source: source)
        case .none:
            ContentUnavailableView(
                "No Preview",
                systemImage: "doc.plaintext",
                description: Text("\(format.displayName) documents have no rendered preview.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        }
    }
}

// `IOSMarkdownPreviewView` used to live here: a copy of the chassis markdown
// preview that differed only in its background colour and 4pt of padding. The
// colour became `Color.platformTextBackground` (ImpressTheme) and the chassis
// view lost its `#if os(macOS)` gate, so the copy was deleted — this file now
// calls `MarkdownSourcePreview` directly. One markdown renderer, two platforms.
#endif
