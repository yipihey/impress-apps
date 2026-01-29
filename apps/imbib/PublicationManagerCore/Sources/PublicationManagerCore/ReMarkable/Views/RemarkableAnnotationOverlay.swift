//
//  RemarkableAnnotationOverlay.swift
//  PublicationManagerCore
//
//  Overlay view for displaying reMarkable annotations on PDF pages.
//  ADR-019: reMarkable Tablet Integration
//

import SwiftUI
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableOverlay")

// MARK: - Annotation Overlay View

/// Overlay that renders reMarkable annotations on top of a PDF page.
///
/// This view is designed to be overlaid on top of a PDFView or similar,
/// matching the page dimensions exactly.
public struct RemarkableAnnotationOverlay: View {
    let annotations: [PageAnnotations]
    let pageNumber: Int
    let pageSize: CGSize
    let showHighlights: Bool
    let showInk: Bool
    let opacity: Double

    @State private var renderedImage: CGImage?
    @State private var highlightRects: [HighlightRect] = []

    public init(
        annotations: [PageAnnotations],
        pageNumber: Int,
        pageSize: CGSize,
        showHighlights: Bool = true,
        showInk: Bool = true,
        opacity: Double = 0.8
    ) {
        self.annotations = annotations
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.showHighlights = showHighlights
        self.showInk = showInk
        self.opacity = opacity
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Highlight underlays
                if showHighlights {
                    ForEach(highlightRects) { rect in
                        highlightView(for: rect, in: geometry.size)
                    }
                }

                // Ink overlay
                if showInk, let image = renderedImage {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(opacity)
                }
            }
        }
        .task {
            await renderAnnotations()
        }
    }

    private func highlightView(for rect: HighlightRect, in size: CGSize) -> some View {
        // Scale from reMarkable coordinates to view coordinates
        let scaleX = size.width / pageSize.width
        let scaleY = size.height / pageSize.height

        let scaledRect = CGRect(
            x: rect.bounds.origin.x * scaleX,
            y: rect.bounds.origin.y * scaleY,
            width: rect.bounds.width * scaleX,
            height: rect.bounds.height * scaleY
        )

        return Rectangle()
            .fill(rect.color.opacity(0.3))
            .frame(width: scaledRect.width, height: scaledRect.height)
            .position(x: scaledRect.midX, y: scaledRect.midY)
    }

    private func renderAnnotations() async {
        guard let pageAnnotations = annotations.first(where: { $0.pageNumber == pageNumber }) else {
            return
        }

        // Extract highlights
        var highlights: [HighlightRect] = []
        for layer in pageAnnotations.rmFile.layers {
            for stroke in layer.strokes {
                if stroke.isHighlight {
                    highlights.append(HighlightRect(
                        id: UUID(),
                        bounds: stroke.bounds,
                        color: stroke.color.swiftUIColor
                    ))
                }
            }
        }
        highlightRects = highlights

        // Render ink strokes
        if showInk {
            let options = RMStrokeRenderer.RenderOptions(
                scale: 2.0,
                backgroundColor: nil  // Transparent
            )

            renderedImage = RMStrokeRenderer.render(pageAnnotations.rmFile, options: options)
        }
    }
}

// MARK: - Highlight Rect

private struct HighlightRect: Identifiable {
    let id: UUID
    let bounds: CGRect
    let color: Color
}

// MARK: - Color Extension

extension RMStroke.StrokeColor {
    var swiftUIColor: Color {
        switch self {
        case .black:
            return .black
        case .grey:
            return .gray
        case .white:
            return .white
        case .yellow:
            return .yellow
        case .green:
            return .green
        case .pink:
            return .pink
        case .blue:
            return .blue
        case .red:
            return .red
        case .greyOverlap:
            return .gray.opacity(0.5)
        }
    }
}

// MARK: - Annotation Preview Card

/// A card view showing a preview of annotations on a page.
public struct RemarkableAnnotationPreviewCard: View {
    let annotations: PageAnnotations
    let pageSize: CGSize

    @State private var previewImage: CGImage?

    public init(annotations: PageAnnotations, pageSize: CGSize = CGSize(width: 200, height: 280)) {
        self.annotations = annotations
        self.pageSize = pageSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Preview image
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
                    .shadow(radius: 2)

                if let image = previewImage {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView()
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)

            // Info
            HStack {
                Text("Page \(annotations.pageNumber + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(annotations.strokeCount) strokes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await renderPreview()
        }
    }

    private func renderPreview() async {
        let whiteColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let options = RMStrokeRenderer.RenderOptions(
            scale: 1.0,
            backgroundColor: whiteColor
        )

        previewImage = RMStrokeRenderer.render(annotations.rmFile, options: options)
    }
}

// MARK: - Annotation List View

/// A list showing all pages with annotations.
public struct RemarkableAnnotationListView: View {
    let annotations: [PageAnnotations]
    let onPageSelected: (Int) -> Void

    public init(annotations: [PageAnnotations], onPageSelected: @escaping (Int) -> Void) {
        self.annotations = annotations
        self.onPageSelected = onPageSelected
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)
            ], spacing: 16) {
                ForEach(annotations, id: \.pageNumber) { pageAnnotation in
                    Button {
                        onPageSelected(pageAnnotation.pageNumber)
                    } label: {
                        RemarkableAnnotationPreviewCard(annotations: pageAnnotation)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

// MARK: - Annotation Summary View

/// Summary view showing annotation statistics.
public struct RemarkableAnnotationSummaryView: View {
    let annotations: [PageAnnotations]

    public init(annotations: [PageAnnotations]) {
        self.annotations = annotations
    }

    private var totalStrokes: Int {
        annotations.reduce(0) { $0 + $1.strokeCount }
    }

    private var highlightCount: Int {
        annotations.reduce(0) { count, page in
            count + page.rmFile.layers.reduce(0) { layerCount, layer in
                layerCount + layer.strokes.filter { $0.isHighlight }.count
            }
        }
    }

    private var inkCount: Int {
        annotations.reduce(0) { count, page in
            count + page.rmFile.layers.reduce(0) { layerCount, layer in
                layerCount + layer.strokes.filter { !$0.isHighlight && !$0.isEraser }.count
            }
        }
    }

    public var body: some View {
        GroupBox("Annotations") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Pages with annotations") {
                    Text("\(annotations.count)")
                }

                LabeledContent("Total strokes") {
                    Text("\(totalStrokes)")
                }

                LabeledContent("Highlights") {
                    Text("\(highlightCount)")
                }

                LabeledContent("Handwritten notes") {
                    Text("\(inkCount)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Interactive Overlay Controller

/// Controller for managing annotation overlay visibility and options.
@MainActor
@Observable
public final class RemarkableOverlayController {
    public var showOverlay = true
    public var showHighlights = true
    public var showInk = true
    public var opacity: Double = 0.8

    public var annotations: [PageAnnotations] = []
    public var currentPage = 0

    public init() {}

    /// Load annotations for a document.
    public func loadAnnotations(documentID: String) async {
        do {
            let downloader = RemarkableDocumentDownloader.shared

            // This would need the actual document data
            // For now, just a placeholder
            logger.debug("Would load annotations for document: \(documentID)")

        } catch {
            logger.error("Failed to load annotations: \(error)")
        }
    }

    /// Get annotations for the current page.
    public var currentPageAnnotations: PageAnnotations? {
        annotations.first { $0.pageNumber == currentPage }
    }

    /// Toggle overlay visibility.
    public func toggleOverlay() {
        showOverlay.toggle()
    }

    /// Toggle highlights.
    public func toggleHighlights() {
        showHighlights.toggle()
    }

    /// Toggle ink strokes.
    public func toggleInk() {
        showInk.toggle()
    }
}
