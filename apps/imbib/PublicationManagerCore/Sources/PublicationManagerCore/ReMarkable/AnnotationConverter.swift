//
//  AnnotationConverter.swift
//  PublicationManagerCore
//
//  Converts between reMarkable annotations and PDF/imbib annotations.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation
import CoreGraphics
import OSLog

#if canImport(PDFKit)
import PDFKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "annotationConverter")

// MARK: - Annotation Converter

/// Converts between reMarkable strokes and PDF annotations.
///
/// Handles:
/// - Converting highlighter strokes to PDF highlight annotations
/// - Converting ink strokes to PDF ink annotations
/// - Scaling coordinates between reMarkable and PDF page sizes
public struct AnnotationConverter {

    // MARK: - Conversion Result

    /// Result of converting reMarkable strokes to annotations.
    public struct ConversionResult: Sendable {
        /// Highlights extracted from strokes.
        public let highlights: [HighlightAnnotation]

        /// Ink strokes preserved for display.
        public let inkStrokes: [InkAnnotation]

        /// Rendered image of handwritten content (for inline display).
        public let renderedImage: Data?
    }

    /// A highlight annotation.
    public struct HighlightAnnotation: Sendable {
        public let pageNumber: Int
        public let bounds: CGRect
        public let color: String
    }

    /// An ink annotation (handwritten).
    public struct InkAnnotation: Sendable {
        public let pageNumber: Int
        public let bounds: CGRect
        public let color: String
        public let strokeData: Data
    }

    // MARK: - Public API

    /// Convert parsed .rm file strokes to annotations.
    ///
    /// - Parameters:
    ///   - rmFile: Parsed .rm file
    ///   - pageNumber: PDF page number (0-indexed)
    ///   - pdfPageSize: Size of the PDF page for coordinate scaling
    /// - Returns: Converted annotations
    public static func convert(
        rmFile: RMFile,
        pageNumber: Int,
        pdfPageSize: CGSize
    ) -> ConversionResult {
        var highlights: [HighlightAnnotation] = []
        var inkStrokes: [InkAnnotation] = []

        // Calculate scale factor
        let scaleX = pdfPageSize.width / RMPageDimensions.width
        let scaleY = pdfPageSize.height / RMPageDimensions.height

        for layer in rmFile.layers {
            for stroke in layer.strokes {
                // Skip eraser strokes
                if stroke.isEraser { continue }

                // Scale bounds to PDF coordinates
                let scaledBounds = CGRect(
                    x: stroke.bounds.origin.x * scaleX,
                    y: pdfPageSize.height - (stroke.bounds.origin.y + stroke.bounds.height) * scaleY,  // Flip Y
                    width: stroke.bounds.width * scaleX,
                    height: stroke.bounds.height * scaleY
                )

                if stroke.isHighlight {
                    // Convert highlighter to highlight annotation
                    highlights.append(HighlightAnnotation(
                        pageNumber: pageNumber,
                        bounds: scaledBounds,
                        color: stroke.color.hexColor
                    ))
                } else {
                    // Preserve ink strokes
                    if let strokeData = encodeStroke(stroke) {
                        inkStrokes.append(InkAnnotation(
                            pageNumber: pageNumber,
                            bounds: scaledBounds,
                            color: stroke.color.hexColor,
                            strokeData: strokeData
                        ))
                    }
                }
            }
        }

        // Render ink strokes to image if present
        var renderedImage: Data? = nil
        if !inkStrokes.isEmpty {
            renderedImage = rmFile.renderToPNG(scale: 2.0)
        }

        logger.debug("Converted \(highlights.count) highlights, \(inkStrokes.count) ink strokes")

        return ConversionResult(
            highlights: highlights,
            inkStrokes: inkStrokes,
            renderedImage: renderedImage
        )
    }

    /// Convert reMarkable raw annotation to imbib AnnotationModel via RustStoreAdapter.
    ///
    /// - Parameters:
    ///   - raw: Raw annotation from reMarkable
    ///   - linkedFileId: The linked file ID
    /// - Returns: Created AnnotationModel, or nil if conversion failed
    @MainActor
    public static func convertToImbibAnnotation(
        raw: RemarkableRawAnnotation,
        linkedFileId: UUID
    ) -> AnnotationModel? {
        let store = RustStoreAdapter.shared

        // Map reMarkable type to imbib annotation type
        let annotationType: String
        switch raw.type {
        case .highlight:
            annotationType = "highlight"
        case .ink:
            annotationType = "ink"
        case .text:
            annotationType = "note"
        }

        // Serialize CGRect to JSON string
        let boundsRect = raw.bounds
        let boundsString = "{\"x\":\(boundsRect.origin.x),\"y\":\(boundsRect.origin.y),\"width\":\(boundsRect.width),\"height\":\(boundsRect.height)}"

        return store.createAnnotation(
            linkedFileId: linkedFileId,
            annotationType: annotationType,
            pageNumber: Int64(raw.pageNumber),
            boundsJson: boundsString,
            color: raw.color,
            contents: nil,
            selectedText: nil
        )
    }

    #if canImport(PDFKit)
    /// Create PDFKit annotation from highlight data.
    ///
    /// - Parameters:
    ///   - highlight: Highlight annotation data
    ///   - page: PDF page to add annotation to
    /// - Returns: Created PDFAnnotation
    public static func createPDFHighlight(
        from highlight: HighlightAnnotation,
        on page: PDFPage
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: highlight.bounds,
            forType: .highlight,
            withProperties: nil
        )

        // Set color from hex
        if let color = colorFromHex(highlight.color) {
            annotation.color = color
        }

        return annotation
    }

    /// Create PDFKit ink annotation from stroke data.
    ///
    /// - Parameters:
    ///   - ink: Ink annotation data
    ///   - page: PDF page to add annotation to
    /// - Returns: Created PDFAnnotation
    public static func createPDFInk(
        from ink: InkAnnotation,
        on page: PDFPage
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: ink.bounds,
            forType: .ink,
            withProperties: nil
        )

        // Decode stroke paths and add to annotation
        if let paths = decodeStrokePaths(ink.strokeData, in: ink.bounds) {
            for path in paths {
                annotation.add(path)
            }
        }

        // Set color from hex
        if let color = colorFromHex(ink.color) {
            annotation.color = color
        }

        return annotation
    }
    #endif

    // MARK: - Private Helpers

    /// Encode stroke data for storage.
    private static func encodeStroke(_ stroke: RMStroke) -> Data? {
        // Encode as JSON for simplicity
        // In production, might use a more compact format
        let encoder = JSONEncoder()
        let strokeData = StrokeData(
            pen: stroke.pen.rawValue,
            color: stroke.color.rawValue,
            width: stroke.width,
            points: stroke.points.map { PointData(x: $0.x, y: $0.y, pressure: $0.pressure) }
        )
        return try? encoder.encode(strokeData)
    }

    /// Decode stroke paths from stored data.
    private static func decodeStrokePaths(_ data: Data, in bounds: CGRect) -> [RMBezierPath]? {
        let decoder = JSONDecoder()
        guard let strokeData = try? decoder.decode(StrokeData.self, from: data) else {
            return nil
        }

        guard strokeData.points.count >= 2 else { return nil }

        let path = RMBezierPath()
        let firstPoint = strokeData.points[0]
        path.move(to: CGPoint(x: CGFloat(firstPoint.x), y: CGFloat(firstPoint.y)))

        for point in strokeData.points.dropFirst() {
            #if canImport(AppKit)
            path.line(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
            #else
            path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
            #endif
        }

        return [path]
    }

    #if canImport(AppKit)
    /// Convert hex color to NSColor.
    private static func colorFromHex(_ hex: String) -> NSColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgb & 0x0000FF) / 255.0

        return NSColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
    #elseif canImport(UIKit)
    /// Convert hex color to UIColor.
    private static func colorFromHex(_ hex: String) -> UIColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgb & 0x0000FF) / 255.0

        return UIColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
    #endif
}

// MARK: - Encoding Types

private struct StrokeData: Codable {
    let pen: Int
    let color: Int
    let width: Float
    let points: [PointData]
}

private struct PointData: Codable {
    let x: Float
    let y: Float
    let pressure: Float
}

// MARK: - Platform Aliases

#if canImport(AppKit)
import AppKit
private typealias RMRMPlatformColor = NSColor
private typealias RMBezierPath = NSBezierPath
#elseif canImport(UIKit)
import UIKit
private typealias RMRMPlatformColor = UIColor
private typealias RMBezierPath = UIBezierPath
#endif
