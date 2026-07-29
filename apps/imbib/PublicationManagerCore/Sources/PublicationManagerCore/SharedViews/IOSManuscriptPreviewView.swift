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
import MarkdownUI

public struct IOSManuscriptPreviewView: View {

    /// The manuscript's format — the ONLY input that selects the surface.
    let format: DocumentFormat
    /// The live editor buffer (used by formats that render without compiling).
    let source: String
    /// Latest compiled artifact, for `.compiledPDF` formats.
    let pdfData: Data?
    let isCompiling: Bool

    public init(
        format: DocumentFormat,
        source: String,
        pdfData: Data?,
        isCompiling: Bool
    ) {
        self.format = format
        self.source = source
        self.pdfData = pdfData
        self.isCompiling = isCompiling
    }

    public var body: some View {
        switch format.previewKind {
        case .compiledPDF:
            IOSPDFPreviewView(pdfData: pdfData, isCompiling: isCompiling)
        case .renderedMarkdown:
            IOSMarkdownPreviewView(source: source)
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

/// Live Markdown render of the editor buffer — the iOS twin of the chassis's
/// (macOS-only) `MarkdownPreviewTab`. No compile step, no artifact: the source
/// is the input, so it re-renders as the user types.
public struct IOSMarkdownPreviewView: View {
    let source: String

    public init(source: String) {
        self.source = source
    }

    public var body: some View {
        ScrollView {
            Markdown(source)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
    }
}
#endif
