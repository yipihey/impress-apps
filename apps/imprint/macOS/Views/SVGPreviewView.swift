import SwiftUI
import AppKit
import ImprintCore

/// SVG preview panel — renders each page as an SVG image for faster updates
/// on multi-page documents. Used as an alternative to PDFPreviewView in split-view mode.
struct SVGPreviewView: View {
    let svgPages: [String]
    let isCompiling: Bool
    let sourceMapEntries: [SourceMapEntry]
    let cursorPosition: Int

    var body: some View {
        ZStack {
            if !svgPages.isEmpty {
                SVGScrollView(
                    svgPages: svgPages,
                    sourceMapEntries: sourceMapEntries,
                    cursorPosition: cursorPosition
                )
                .accessibilityIdentifier("svgPreview.document")
            } else {
                emptyState
            }

            if isCompiling {
                compilingOverlay
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("svgPreview.container")
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

// MARK: - SVG Scroll View (NSViewRepresentable)

/// NSScrollView wrapper that displays SVG pages vertically with lazy image creation.
struct SVGScrollView: NSViewRepresentable {
    let svgPages: [String]
    let sourceMapEntries: [SourceMapEntry]
    let cursorPosition: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.autohidesScrollers = true

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        context.coordinator.scrollView = scrollView
        context.coordinator.documentView = documentView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator

        // Only rebuild page views if content changed
        let newHash = svgPages.hashValue
        guard newHash != coordinator.lastContentHash else {
            // Content unchanged — just scroll to cursor if needed
            scrollToCursorIfNeeded(coordinator: coordinator)
            return
        }
        coordinator.lastContentHash = newHash

        guard let documentView = coordinator.documentView else { return }

        // Remove old page views
        for subview in documentView.subviews {
            subview.removeFromSuperview()
        }
        coordinator.pageViews.removeAll()
        coordinator.pageYOffsets.removeAll()

        let pageGap: CGFloat = 12
        let pageShadowInset: CGFloat = 8
        var yOffset: CGFloat = pageGap

        for (index, svgString) in svgPages.enumerated() {
            guard let svgData = svgString.data(using: .utf8),
                  let image = NSImage(data: svgData) else {
                continue
            }

            let imageView = NSImageView()
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyDown
            imageView.setAccessibilityIdentifier("svgPreview.page.\(index)")

            // Size the image view to match the SVG's natural aspect ratio
            let imageSize = image.size
            let availableWidth = max(scrollView.contentSize.width - 2 * pageShadowInset, 200)
            let scale = availableWidth / imageSize.width
            let scaledHeight = imageSize.height * scale

            imageView.frame = NSRect(
                x: pageShadowInset,
                y: yOffset,
                width: availableWidth,
                height: scaledHeight
            )

            // Light page shadow for visual separation
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.white.cgColor
            imageView.layer?.shadowColor = NSColor.black.cgColor
            imageView.layer?.shadowOffset = CGSize(width: 0, height: -1)
            imageView.layer?.shadowRadius = 3
            imageView.layer?.shadowOpacity = 0.15

            documentView.addSubview(imageView)
            coordinator.pageViews.append(imageView)
            coordinator.pageYOffsets.append(yOffset)

            yOffset += scaledHeight + pageGap
        }

        // Size the document view to contain all pages
        let totalWidth = max(scrollView.contentSize.width, 200)
        documentView.frame = NSRect(x: 0, y: 0, width: totalWidth, height: yOffset)

        scrollToCursorIfNeeded(coordinator: coordinator)
    }

    private func scrollToCursorIfNeeded(coordinator: Coordinator) {
        guard cursorPosition != coordinator.lastScrolledCursor else { return }
        guard !sourceMapEntries.isEmpty else { return }
        guard let scrollView = coordinator.scrollView else { return }

        guard let renderRegion = SourceMapUtils.sourceToRender(
            entries: sourceMapEntries,
            sourceOffset: cursorPosition
        ) else { return }

        let pageIndex = renderRegion.page
        guard pageIndex < coordinator.pageYOffsets.count else { return }
        guard pageIndex < coordinator.pageViews.count else { return }

        let pageView = coordinator.pageViews[pageIndex]
        let pageYOffset = coordinator.pageYOffsets[pageIndex]

        // Scale the y coordinate to the view's coordinate space
        guard let image = (pageView as? NSImageView)?.image else { return }
        let scaleY = pageView.frame.height / image.size.height
        let targetY = pageYOffset + renderRegion.center.y * scaleY

        let visibleRect = NSRect(
            x: 0,
            y: targetY - 50,
            width: scrollView.contentSize.width,
            height: 100
        )

        scrollView.documentView?.scrollToVisible(visibleRect)
        coordinator.lastScrolledCursor = cursorPosition
    }

    class Coordinator {
        var scrollView: NSScrollView?
        var documentView: FlippedView?
        var pageViews: [NSView] = []
        var pageYOffsets: [CGFloat] = []
        var lastContentHash: Int = 0
        var lastScrolledCursor: Int = -1
    }
}

/// An NSView with flipped coordinate system (origin at top-left)
/// so page layout flows top-to-bottom like a document viewer.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

#Preview {
    SVGPreviewView(svgPages: [], isCompiling: false, sourceMapEntries: [], cursorPosition: 0)
        .frame(width: 400, height: 600)
}
