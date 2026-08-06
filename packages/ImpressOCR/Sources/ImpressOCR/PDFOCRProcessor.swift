import CoreGraphics
import Foundation
@preconcurrency import PDFKit

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct PDFOCRConfiguration: Codable, Equatable, Sendable {
    public var dpi: Int
    public var maximumConcurrentPages: Int
    public var vision: AppleVisionOCRConfiguration

    public init(
        dpi: Int = 220,
        maximumConcurrentPages: Int = 1,
        vision: AppleVisionOCRConfiguration = .init()
    ) {
        self.dpi = dpi
        self.maximumConcurrentPages = maximumConcurrentPages
        self.vision = vision
    }
}

/// Batch scanned-PDF adapter. Rendering is bounded and page-local; OCR can run
/// concurrently without retaining the entire manual as images.
public struct PDFOCRProcessor: Sendable {
    private struct RenderedPage: @unchecked Sendable {
        let index: Int
        let image: CGImage
    }

    public let configuration: PDFOCRConfiguration

    public init(configuration: PDFOCRConfiguration = .init()) {
        self.configuration = configuration
    }

    public static func pageCount(for url: URL) throws -> Int {
        guard let document = PDFDocument(url: url) else {
            throw ImpressOCRError.invalidPDF(url.path)
        }
        return document.pageCount
    }

    public func process(
        pdf url: URL,
        pages: [Int]? = nil,
        onProgress: (@Sendable (_ completed: Int, _ total: Int, _ page: OCRPageResult) -> Void)? = nil
    ) async throws -> [OCRPageResult] {
        guard let document = PDFDocument(url: url) else {
            throw ImpressOCRError.invalidPDF(url.path)
        }
        let selected = try validatedPages(pages, pageCount: document.pageCount)
        let batchSize = max(1, configuration.maximumConcurrentPages)
        let engine = AppleVisionOCR(configuration: configuration.vision)
        var results: [OCRPageResult] = []
        results.reserveCapacity(selected.count)

        for batchStart in stride(from: 0, to: selected.count, by: batchSize) {
            let batchEnd = min(selected.count, batchStart + batchSize)
            let rendered = try selected[batchStart..<batchEnd].map {
                RenderedPage(index: $0, image: try render(document: document, pageIndex: $0))
            }
            let batchResults = try await withThrowingTaskGroup(of: OCRPageResult.self) { group in
                for page in rendered {
                    group.addTask {
                        try await engine.recognize(page.image, pageIndex: page.index)
                    }
                }
                var recognized: [OCRPageResult] = []
                for try await page in group {
                    recognized.append(page)
                }
                return recognized.sorted { $0.pageIndex < $1.pageIndex }
            }
            for page in batchResults {
                results.append(page)
                onProgress?(results.count, selected.count, page)
            }
        }
        return results
    }

    private func validatedPages(_ pages: [Int]?, pageCount: Int) throws -> [Int] {
        let selected = pages ?? Array(0..<pageCount)
        for page in selected where page < 0 || page >= pageCount {
            throw ImpressOCRError.invalidPage(page)
        }
        return Array(Set(selected)).sorted()
    }

    private func render(document: PDFDocument, pageIndex: Int) throws -> CGImage {
        guard let page = document.page(at: pageIndex) else {
            throw ImpressOCRError.invalidPage(pageIndex)
        }
        let bounds = page.bounds(for: .cropBox)
        let scale = CGFloat(configuration.dpi) / 72
        let size = CGSize(
            width: max(1, ceil(bounds.width * scale)),
            height: max(1, ceil(bounds.height * scale))
        )
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        #if os(macOS)
        var proposed = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw ImpressOCRError.renderingFailed(pageIndex)
        }
        return image
        #elseif canImport(UIKit)
        guard let image = thumbnail.cgImage else {
            throw ImpressOCRError.renderingFailed(pageIndex)
        }
        return image
        #else
        throw ImpressOCRError.renderingFailed(pageIndex)
        #endif
    }
}
