//
//  EInkAnnotationNormalizer.swift
//  PublicationManagerCore
//
//  Protocol and implementations for normalizing device-specific annotations
//  to the unified EInkAnnotation format.
//

import Foundation
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "einkNormalizer")

// MARK: - Normalizer Protocol

/// Protocol for normalizing device-specific annotation data to unified format.
public protocol EInkAnnotationNormalizer: Sendable {
    /// The device type this normalizer handles.
    var deviceType: EInkDeviceType { get }

    /// Normalize raw annotation data to unified EInkAnnotation format.
    ///
    /// - Parameters:
    ///   - data: Raw annotation data in device-native format
    ///   - pageNumber: The page number for these annotations
    ///   - pdfPageSize: The size of the PDF page for coordinate conversion
    /// - Returns: Array of normalized annotations
    func normalize(data: Data, pageNumber: Int, pdfPageSize: CGSize) throws -> [EInkAnnotation]

    /// Normalize all pages of annotations.
    ///
    /// - Parameters:
    ///   - pageData: Dictionary mapping page numbers to raw annotation data
    ///   - pdfPageSizes: Dictionary mapping page numbers to PDF page sizes
    /// - Returns: All normalized annotations
    func normalizeAll(pageData: [Int: Data], pdfPageSizes: [Int: CGSize]) throws -> [EInkAnnotation]
}

// MARK: - Default Implementation

public extension EInkAnnotationNormalizer {
    func normalizeAll(pageData: [Int: Data], pdfPageSizes: [Int: CGSize]) throws -> [EInkAnnotation] {
        var allAnnotations: [EInkAnnotation] = []

        for (pageNumber, data) in pageData {
            let pageSize = pdfPageSizes[pageNumber] ?? CGSize(width: 612, height: 792) // Letter size default
            let annotations = try normalize(data: data, pageNumber: pageNumber, pdfPageSize: pageSize)
            allAnnotations.append(contentsOf: annotations)
        }

        return allAnnotations.sorted { $0.pageNumber < $1.pageNumber }
    }
}

// MARK: - reMarkable Normalizer

/// Normalizes reMarkable .rm file annotations to unified format.
/// Reuses the existing RMFileParser for binary parsing.
public struct RemarkableAnnotationNormalizer: EInkAnnotationNormalizer {
    public let deviceType: EInkDeviceType = .remarkable

    public init() {}

    public func normalize(data: Data, pageNumber: Int, pdfPageSize: CGSize) throws -> [EInkAnnotation] {
        // Parse the .rm file using existing parser
        let rmFile: RMFile
        do {
            rmFile = try RMFileParser.parse(data)
        } catch {
            logger.error("Failed to parse .rm file: \(error.localizedDescription)")
            throw EInkError.parseFailed("Invalid .rm file format: \(error.localizedDescription)")
        }

        guard !rmFile.isEmpty else {
            return []
        }

        // Calculate scale factors for coordinate conversion
        let scaleX = pdfPageSize.width / RMPageDimensions.width
        let scaleY = pdfPageSize.height / RMPageDimensions.height

        var annotations: [EInkAnnotation] = []

        for (layerIndex, layer) in rmFile.layers.enumerated() {
            for (strokeIndex, stroke) in layer.strokes.enumerated() {
                // Skip eraser strokes for now (they're for deletion, not display)
                if stroke.isEraser {
                    continue
                }

                // Determine annotation type
                let annotationType: EInkAnnotationType = stroke.isHighlight ? .highlight : .ink

                // Calculate bounds in PDF coordinates
                let rmBounds = stroke.bounds
                let pdfBounds = EInkAnnotationBounds(
                    x: Double(rmBounds.origin.x * scaleX),
                    y: Double(rmBounds.origin.y * scaleY),
                    width: Double(rmBounds.size.width * scaleX),
                    height: Double(rmBounds.size.height * scaleY)
                )

                // Convert color using the existing hexColor property
                let color = EInkAnnotationColor(hexString: stroke.color.hexColor)

                // Serialize stroke points for potential re-rendering
                let strokeData = serializeStrokePoints(stroke.points, scaleX: scaleX, scaleY: scaleY)

                let annotation = EInkAnnotation(
                    id: "rm-\(pageNumber)-\(layerIndex)-\(strokeIndex)",
                    sourceDevice: .remarkable,
                    pageNumber: pageNumber,
                    annotationType: annotationType,
                    bounds: pdfBounds,
                    color: color,
                    strokeData: strokeData,
                    ocrText: nil,
                    dateCreated: Date(),
                    metadata: [
                        "layer": layer.name,
                        "penType": stroke.pen.displayName,
                        "rmVersion": String(rmFile.version)
                    ]
                )

                annotations.append(annotation)
            }
        }

        logger.debug("Normalized \(annotations.count) annotations from page \(pageNumber)")
        return annotations
    }

    /// Serialize stroke points to Data for storage/re-rendering.
    private func serializeStrokePoints(_ points: [RMPoint], scaleX: CGFloat, scaleY: CGFloat) -> Data {
        // Create a simple binary format: count (Int32), then [x, y, pressure] floats
        var data = Data()

        // Point count
        var count = Int32(points.count)
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        // Points
        for point in points {
            var x = Float(CGFloat(point.x) * scaleX)
            var y = Float(CGFloat(point.y) * scaleY)
            var pressure = point.pressure

            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &pressure) { data.append(contentsOf: $0) }
        }

        return data
    }
}

// MARK: - Supernote Normalizer

/// Normalizes Supernote .note/.mark file annotations to unified format.
/// Currently a stub - full implementation requires Supernote format documentation.
public struct SupernoteAnnotationNormalizer: EInkAnnotationNormalizer {
    public let deviceType: EInkDeviceType = .supernote

    public init() {}

    public func normalize(data: Data, pageNumber: Int, pdfPageSize: CGSize) throws -> [EInkAnnotation] {
        // Supernote uses .note files with a different binary format
        // This is a stub implementation pending format documentation

        logger.warning("Supernote annotation parsing not yet implemented")

        // For now, return empty array
        // Future implementation will parse Supernote's proprietary format
        return []
    }
}

// MARK: - Kindle Scribe Normalizer

/// Normalizes Kindle Scribe annotations from exported PDFs.
/// Kindle Scribe embeds annotations directly in PDF files.
public struct KindleScribeAnnotationNormalizer: EInkAnnotationNormalizer {
    public let deviceType: EInkDeviceType = .kindleScribe

    public init() {}

    public func normalize(data: Data, pageNumber: Int, pdfPageSize: CGSize) throws -> [EInkAnnotation] {
        // Kindle Scribe embeds annotations in the PDF itself
        // Extraction requires PDF annotation parsing
        // This is a stub implementation

        logger.warning("Kindle Scribe annotation extraction not yet implemented")

        // Future implementation will use PDFKit to extract annotations
        // from the exported PDF file
        return []
    }
}

// MARK: - Normalizer Factory

/// Factory for creating the appropriate normalizer for a device type.
public enum EInkAnnotationNormalizerFactory {
    /// Create a normalizer for the given device type.
    public static func normalizer(for deviceType: EInkDeviceType) -> any EInkAnnotationNormalizer {
        switch deviceType {
        case .remarkable:
            return RemarkableAnnotationNormalizer()
        case .supernote:
            return SupernoteAnnotationNormalizer()
        case .kindleScribe:
            return KindleScribeAnnotationNormalizer()
        }
    }
}
