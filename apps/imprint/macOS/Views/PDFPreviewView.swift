import SwiftUI
import PDFKit
import ImprintCore

/// PDF preview panel for the rendered document with cursor synchronization
struct PDFPreviewView: View {
    let pdfData: Data?
    let isCompiling: Bool
    let sourceMapEntries: [SourceMapEntry]
    let cursorPosition: Int

    @State private var pdfView: PDFView?
    @State private var lastScrolledPosition: Int = -1

    var body: some View {
        ZStack {
            if let pdfData = pdfData {
                SyncablePDFKitView(
                    data: pdfData,
                    pdfView: $pdfView
                )
                .accessibilityIdentifier("pdfPreview.document")
            } else {
                emptyState
            }

            if isCompiling {
                compilingOverlay
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("pdfPreview.container")
        .onChange(of: cursorPosition) { _, newPosition in
            scrollToCursor(newPosition)
        }
    }

    /// Scroll the PDF to show the current cursor position
    private func scrollToCursor(_ position: Int) {
        // Avoid redundant scrolling
        guard position != lastScrolledPosition else { return }
        guard !sourceMapEntries.isEmpty else { return }
        guard let pdfView = pdfView else { return }
        guard let document = pdfView.document else { return }

        // Look up the render position for this cursor
        guard let renderRegion = SourceMapUtils.sourceToRender(entries: sourceMapEntries, sourceOffset: position) else {
            return
        }

        // Get the PDF page
        guard renderRegion.page < document.pageCount,
              let page = document.page(at: renderRegion.page) else {
            return
        }

        // Convert to PDF coordinates (PDF uses bottom-left origin)
        let pageBounds = page.bounds(for: .mediaBox)
        let pdfPoint = CGPoint(
            x: renderRegion.center.x,
            y: pageBounds.height - renderRegion.center.y // Flip Y coordinate
        )

        // Scroll to the position
        pdfView.go(to: CGRect(x: pdfPoint.x - 50, y: pdfPoint.y - 50, width: 100, height: 100), on: page)

        lastScrolledPosition = position
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Preview")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Start typing to auto-compile, or press Cmd+B")
                .font(.subheadline)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private var compilingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text("Compiling...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// NSViewRepresentable wrapper for PDFKit with view binding for scroll control
struct SyncablePDFKitView: NSViewRepresentable {
    let data: Data
    @Binding var pdfView: PDFView?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.setAccessibilityIdentifier("pdfPreview.document")

        // Store reference for scroll control
        DispatchQueue.main.async {
            pdfView = view
        }

        return view
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if let document = PDFDocument(data: data) {
            // Only update document if it changed (avoid resetting scroll position)
            if pdfView.document?.dataRepresentation() != data {
                pdfView.document = document
            }
        }
    }
}

/// Basic PDFKitView for simple use cases (no sync)
struct PDFKitView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.setAccessibilityIdentifier("pdfPreview.document")
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
    }
}

#Preview {
    PDFPreviewView(pdfData: nil, isCompiling: false, sourceMapEntries: [], cursorPosition: 0)
        .frame(width: 400, height: 600)
}
