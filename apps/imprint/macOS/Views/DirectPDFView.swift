import SwiftUI
import PDFKit
import ImprintCore

/// Direct PDF manipulation view (Mode A)
///
/// In this mode, users click on the rendered PDF to position their cursor,
/// and edits appear at the corresponding source location via the source map.
struct DirectPDFView: View {
    @Binding var document: ImprintDocument
    let pdfData: Data?
    let sourceMapEntries: [SourceMapEntry]
    @Binding var cursorPosition: Int

    @State private var hoveredPosition: CGPoint?
    @State private var lastClickInfo: String = ""

    var body: some View {
        if let pdfData = pdfData {
            DirectPDFKitView(
                data: pdfData,
                onClickPosition: handleClick,
                onHoverPosition: { hoveredPosition = $0 }
            )
            .overlay(alignment: .topTrailing) {
                modeIndicator
                    .accessibilityIdentifier("directPdf.modeIndicator")
            }
            .overlay(alignment: .bottomLeading) {
                if !lastClickInfo.isEmpty {
                    Text(lastClickInfo)
                        .font(.caption)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                        .accessibilityIdentifier("directPdf.clickInfo")
                }
            }
            .accessibilityIdentifier("directPdf.container")
        } else {
            emptyState
        }
    }

    private var modeIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "cursorarrow.click.2")
            Text("Direct Edit")
            if !sourceMapEntries.isEmpty {
                Text("(\(sourceMapEntries.count) regions)")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Compile to enable Direct PDF editing")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Press Cmd+B to compile the document")
                .font(.subheadline)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private func handleClick(at point: CGPoint, page: Int) {
        // Use source map to convert PDF position to source position
        let result = SourceMapUtils.lookup(
            entries: sourceMapEntries,
            page: page,
            x: Double(point.x),
            y: Double(point.y)
        )

        if result.found {
            // Move cursor to the source position
            cursorPosition = result.sourceOffset
            lastClickInfo = "Cursor → \(result.sourceOffset) (\(result.contentType.rawValue))"
            print("[DirectPDF] Click at (\(point.x), \(point.y)) page \(page) → source offset \(result.sourceOffset)")

            // Post notification to switch to split view and focus editor
            NotificationCenter.default.post(name: .directPdfCursorMoved, object: nil, userInfo: [
                "sourceOffset": result.sourceOffset,
                "contentType": result.contentType.rawValue
            ])
        } else {
            lastClickInfo = "No match at (\(Int(point.x)), \(Int(point.y)))"
            print("[DirectPDF] Click at (\(point.x), \(point.y)) page \(page) → no match in source map")
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let directPdfCursorMoved = Notification.Name("directPdfCursorMoved")
}

/// NSViewRepresentable for clickable PDF viewing
struct DirectPDFKitView: NSViewRepresentable {
    let data: Data
    let onClickPosition: (CGPoint, Int) -> Void
    let onHoverPosition: (CGPoint?) -> Void

    func makeNSView(context: Context) -> PDFView {
        let pdfView = ClickablePDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.onClickPosition = onClickPosition
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
    }
}

/// Custom PDFView subclass that captures clicks
class ClickablePDFView: PDFView {
    var onClickPosition: ((CGPoint, Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)

        // Convert to PDF coordinates
        if let page = page(for: locationInView, nearest: true) {
            let locationInPage = convert(locationInView, to: page)
            let pageIndex = document?.index(for: page) ?? 0
            onClickPosition?(locationInPage, pageIndex)
        }

        super.mouseDown(with: event)
    }
}

#Preview {
    DirectPDFView(
        document: .constant(ImprintDocument()),
        pdfData: nil,
        sourceMapEntries: [],
        cursorPosition: .constant(0)
    )
    .frame(width: 600, height: 800)
}
