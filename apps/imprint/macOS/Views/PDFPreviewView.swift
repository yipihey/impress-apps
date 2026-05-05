import SwiftUI
import PDFKit
import ImpressLogging
import ImprintCore

/// PDF preview panel for the rendered document with cursor synchronization.
/// Supports SyncTeX click-to-source (inverse sync) in LaTeX mode and
/// forward sync highlighting.
struct PDFPreviewView: View {
    let pdfData: Data?
    let isCompiling: Bool
    let sourceMapEntries: [SourceMapEntry]
    let cursorPosition: Int
    /// Called when the user clicks on the PDF in LaTeX mode (inverse sync).
    var onInverseSync: ((String, Int, Int) -> Void)?
    /// SyncTeX highlight position (from forward sync).
    var syncTeXHighlight: SyncTeXPosition?

    @State private var pdfView: PDFView?
    @State private var lastScrolledPosition: Int = -1
    @State private var lastSyncTeXHighlight: SyncTeXPosition?

    var body: some View {
        ZStack {
            if let pdfData = pdfData {
                SyncablePDFKitView(
                    data: pdfData,
                    pdfView: $pdfView,
                    onClickPosition: { page, x, y in
                        // Inverse SyncTeX: PDF click → source
                        Task {
                            if let loc = await SyncTeXService.shared.inverseSync(page: page, x: x, y: y) {
                                await MainActor.run {
                                    onInverseSync?(loc.file, loc.line, loc.column)
                                }
                            }
                        }
                    }
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
        .onChange(of: syncTeXHighlight) { _, highlight in
            if let highlight = highlight {
                logInfo("PDF onChange syncTeX: page=\(highlight.page), pdfView=\(pdfView != nil)", category: "synctex")
                scrollToSyncTeX(highlight)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("com.imprint.scrollToSyncTeX"))) { notification in
            if let highlight = notification.object as? SyncTeXPositionBox {
                logInfo("PDF notification syncTeX: page=\(highlight.position.page), pdfView=\(pdfView != nil)", category: "synctex")
                scrollToSyncTeX(highlight.position)
            }
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

    /// Scroll the PDF to a SyncTeX-resolved position (LaTeX forward sync).
    private func scrollToSyncTeX(_ position: SyncTeXPosition) {
        guard let pdfView = pdfView else { return }
        guard let document = pdfView.document else { return }

        // SyncTeX pages are 1-indexed
        let pageIndex = position.page - 1
        guard pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }

        let pageBounds = page.bounds(for: .mediaBox)
        // SyncTeX y is from top; PDF coordinates are from bottom
        let pdfY = pageBounds.height - position.y
        let rect = CGRect(
            x: max(0, position.x - 50),
            y: pdfY - position.height / 2,
            width: max(position.width, 100),
            height: max(position.height, 50)
        )

        pdfView.go(to: rect, on: page)
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
/// and click-to-source support.
struct SyncablePDFKitView: NSViewRepresentable {
    let data: Data
    @Binding var pdfView: PDFView?
    /// Callback when user clicks on PDF: (page 1-indexed, x in points, y in points).
    var onClickPosition: ((Int, Double, Double) -> Void)?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.setAccessibilityIdentifier("pdfPreview.document")

        // Add click gesture for SyncTeX inverse sync
        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        view.addGestureRecognizer(clickGesture)

        // Store reference for scroll control
        DispatchQueue.main.async {
            pdfView = view
        }

        return view
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onClickPosition = onClickPosition
        // Only replace the document when data actually changes (avoid re-parsing on every SwiftUI state change)
        guard context.coordinator.lastDataCount != data.count || context.coordinator.lastDataPrefix != data.prefix(64) else { return }
        context.coordinator.lastDataCount = data.count
        context.coordinator.lastDataPrefix = data.prefix(64)
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onClickPosition: onClickPosition)
    }

    class Coordinator: NSObject {
        var onClickPosition: ((Int, Double, Double) -> Void)?
        var lastDataCount: Int = -1
        var lastDataPrefix: Data = Data()

        init(onClickPosition: ((Int, Double, Double) -> Void)?) {
            self.onClickPosition = onClickPosition
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = gesture.view as? PDFView else { return }
            let locationInView = gesture.location(in: pdfView)

            // Convert view point to PDF page coordinates
            guard let page = pdfView.page(for: locationInView, nearest: true) else { return }
            let pagePoint = pdfView.convert(locationInView, to: page)
            let pageBounds = page.bounds(for: .mediaBox)

            // Get 1-indexed page number
            guard let pageIndex = pdfView.document?.index(for: page) else { return }
            let pageNumber = pageIndex + 1

            // PDF coordinates: origin at bottom-left. Convert Y to top-origin.
            let x = Double(pagePoint.x)
            let y = Double(pageBounds.height - pagePoint.y)

            onClickPosition?(pageNumber, x, y)
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
        guard context.coordinator.lastDataCount != data.count || context.coordinator.lastDataPrefix != data.prefix(64) else { return }
        context.coordinator.lastDataCount = data.count
        context.coordinator.lastDataPrefix = data.prefix(64)
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var lastDataCount: Int = -1
        var lastDataPrefix: Data = Data()
    }
}

#Preview {
    PDFPreviewView(pdfData: nil, isCompiling: false, sourceMapEntries: [], cursorPosition: 0)
        .frame(width: 400, height: 600)
}
