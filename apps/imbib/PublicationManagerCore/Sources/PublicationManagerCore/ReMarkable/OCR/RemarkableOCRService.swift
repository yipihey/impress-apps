//
//  RemarkableOCRService.swift
//  PublicationManagerCore
//
//  OCR service for recognizing handwritten text from reMarkable annotations.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation
import CoreGraphics
import OSLog

#if canImport(Vision)
import Vision
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableOCR")

// MARK: - OCR Service

/// Service for recognizing handwritten text from reMarkable annotations.
///
/// Uses Apple's Vision framework for text recognition, which works well
/// with the clean strokes from reMarkable's e-ink display.
public actor RemarkableOCRService {

    // MARK: - Singleton

    public static let shared = RemarkableOCRService()

    // MARK: - Configuration

    /// Minimum confidence score to accept OCR results.
    public var minimumConfidence: Float = 0.5

    /// Recognition languages to use.
    public var recognitionLanguages: [String] = ["en-US"]

    /// Whether to use accurate (slower) or fast recognition.
    public var usesAccurateRecognition: Bool = true

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Perform OCR on rendered annotation strokes.
    ///
    /// - Parameter image: Rendered image of the strokes
    /// - Returns: OCR result with text and confidence
    public func recognizeText(from image: CGImage) async throws -> OCRResult {
        #if canImport(Vision)
        return try await performVisionOCR(image: image)
        #else
        throw OCRError.notSupported
        #endif
    }

    /// Perform OCR on an RMFile.
    ///
    /// - Parameters:
    ///   - rmFile: The parsed .rm file
    ///   - scale: Rendering scale for better recognition
    /// - Returns: OCR result with text and confidence
    public func recognizeText(from rmFile: RMFile, scale: CGFloat = 2.0) async throws -> OCRResult {
        // Render the strokes to an image
        guard let image = rmFile.render(scale: scale) else {
            throw OCRError.renderingFailed
        }

        return try await recognizeText(from: image)
    }

    /// Perform OCR on multiple strokes and return combined result.
    ///
    /// - Parameter strokes: Individual strokes to recognize
    /// - Returns: Array of OCR results, one per stroke region
    public func recognizeStrokes(_ strokes: [RMStroke]) async throws -> [StrokeOCRResult] {
        var results: [StrokeOCRResult] = []

        for (index, stroke) in strokes.enumerated() {
            // Skip highlighter strokes (not text)
            guard !stroke.isHighlight && !stroke.isEraser else { continue }

            // Render individual stroke
            guard let image = RMStrokeRenderer.render(
                stroke: stroke,
                options: .init(scale: 2.0)
            ) else { continue }

            do {
                let ocrResult = try await recognizeText(from: image)
                if ocrResult.confidence >= minimumConfidence {
                    results.append(StrokeOCRResult(
                        strokeIndex: index,
                        bounds: stroke.bounds,
                        text: ocrResult.text,
                        confidence: ocrResult.confidence
                    ))
                }
            } catch {
                logger.debug("OCR failed for stroke \(index): \(error)")
            }
        }

        return results
    }

    // MARK: - Vision OCR

    #if canImport(Vision)
    private func performVisionOCR(image: CGImage) async throws -> OCRResult {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRResult(text: "", confidence: 0, observations: []))
                    return
                }

                // Combine all recognized text
                var allText: [String] = []
                var totalConfidence: Float = 0
                var observationResults: [TextObservation] = []

                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }

                    allText.append(topCandidate.string)
                    totalConfidence += topCandidate.confidence

                    observationResults.append(TextObservation(
                        text: topCandidate.string,
                        confidence: topCandidate.confidence,
                        boundingBox: observation.boundingBox
                    ))
                }

                let averageConfidence = observations.isEmpty ? 0 : totalConfidence / Float(observations.count)
                let combinedText = allText.joined(separator: "\n")

                continuation.resume(returning: OCRResult(
                    text: combinedText,
                    confidence: averageConfidence,
                    observations: observationResults
                ))
            }

            // Configure recognition
            request.recognitionLevel = usesAccurateRecognition ? .accurate : .fast
            request.recognitionLanguages = recognitionLanguages
            request.usesLanguageCorrection = true

            // Perform request
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
            }
        }
    }
    #endif
}

// MARK: - OCR Result Types

/// Result of OCR recognition.
public struct OCRResult: Sendable {
    /// Recognized text.
    public let text: String

    /// Overall confidence score (0-1).
    public let confidence: Float

    /// Individual text observations with positions.
    public let observations: [TextObservation]

    /// Whether the result is likely valid (meets minimum confidence).
    public var isValid: Bool {
        confidence >= 0.5 && !text.isEmpty
    }
}

/// A single text observation from OCR.
public struct TextObservation: Sendable {
    /// Recognized text.
    public let text: String

    /// Confidence score (0-1).
    public let confidence: Float

    /// Bounding box in normalized coordinates (0-1).
    public let boundingBox: CGRect
}

/// OCR result for a single stroke.
public struct StrokeOCRResult: Sendable {
    /// Index of the stroke in the layer.
    public let strokeIndex: Int

    /// Bounds of the stroke in device coordinates.
    public let bounds: CGRect

    /// Recognized text.
    public let text: String

    /// Confidence score.
    public let confidence: Float
}

// MARK: - OCR Errors

/// Errors that can occur during OCR.
public enum OCRError: LocalizedError, Sendable {
    case notSupported
    case renderingFailed
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSupported:
            return "OCR is not supported on this platform."
        case .renderingFailed:
            return "Failed to render strokes for OCR."
        case .recognitionFailed(let reason):
            return "OCR recognition failed: \(reason)"
        }
    }
}

// MARK: - Batch Processing

public extension RemarkableOCRService {

    /// Process all pages of a document for OCR.
    ///
    /// - Parameter pages: Array of page annotations
    /// - Returns: Dictionary mapping page number to OCR results
    func processDocument(_ pages: [PageAnnotations]) async -> [Int: OCRResult] {
        var results: [Int: OCRResult] = [:]

        for page in pages {
            guard page.hasStrokes else { continue }

            do {
                let result = try await recognizeText(from: page.rmFile)
                if result.isValid {
                    results[page.pageNumber] = result
                }
            } catch {
                logger.warning("OCR failed for page \(page.pageNumber): \(error)")
            }
        }

        return results
    }
}
