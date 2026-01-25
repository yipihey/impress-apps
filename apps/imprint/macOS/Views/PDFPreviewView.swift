import SwiftUI
import PDFKit

/// PDF preview panel for the rendered document
struct PDFPreviewView: View {
    let pdfData: Data?
    let isCompiling: Bool

    var body: some View {
        ZStack {
            if let pdfData = pdfData {
                PDFKitView(data: pdfData)
            } else {
                emptyState
            }

            if isCompiling {
                compilingOverlay
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Preview")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Press Cmd+B to compile")
                .font(.subheadline)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private var compilingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text("Compiling...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// NSViewRepresentable wrapper for PDFKit
struct PDFKitView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
    }
}

#Preview {
    PDFPreviewView(pdfData: nil, isCompiling: false)
        .frame(width: 400, height: 600)
}
