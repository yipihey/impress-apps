import CoreGraphics
import Foundation
import Vision

/// Stateless, on-device OCR adapter over Apple's Vision framework.
public struct AppleVisionOCR: Sendable {
    public let configuration: AppleVisionOCRConfiguration

    public init(configuration: AppleVisionOCRConfiguration = .init()) {
        self.configuration = configuration
    }

    public func recognize(_ image: CGImage, pageIndex: Int = 0) async throws -> OCRPageResult {
        do {
            switch configuration.mode {
            case .text:
                return try await recognizeText(image, pageIndex: pageIndex)
            case .document:
                return try await recognizeDocument(image, pageIndex: pageIndex)
            }
        } catch let error as ImpressOCRError {
            throw error
        } catch {
            throw ImpressOCRError.recognitionFailed(error.localizedDescription)
        }
    }

    private func recognizeText(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        var request = RecognizeTextRequest(.revision3)
        request.recognitionLevel = configuration.recognitionLevel == .accurate ? .accurate : .fast
        request.recognitionLanguages = configuration.recognitionLanguages.map {
            Locale.Language(identifier: $0)
        }
        request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        request.customWords = configuration.customWords
        request.minimumTextHeightFraction = configuration.minimumTextHeightFraction
        let recognized = try await request.perform(on: image)
        let observations = recognized.map(observation)
        let text = OCRTextUtilities.normalize(observations.map(\.text).joined(separator: "\n"))
        return OCRPageResult(
            pageIndex: pageIndex,
            text: text,
            observations: observations,
            structure: nil
        )
    }

    private func recognizeDocument(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        var request = RecognizeDocumentsRequest(.revision1)
        var options = request.textRecognitionOptions
        options.recognitionLanguages = configuration.recognitionLanguages.map {
            Locale.Language(identifier: $0)
        }
        options.automaticallyDetectLanguage = configuration.automaticallyDetectsLanguage
        options.useLanguageCorrection = configuration.usesLanguageCorrection
        options.customWords = configuration.customWords
        options.minimumTextHeightFraction = configuration.minimumTextHeightFraction
        options.maximumCandidateCount = 1
        request.textRecognitionOptions = options
        var barcodeOptions = request.barcodeDetectionOptions
        barcodeOptions.enabled = false
        request.barcodeDetectionOptions = barcodeOptions

        let documents = try await request.perform(on: image)
        let lines = documents.flatMap { $0.document.text.lines }
        let observations = lines.map(observation)
        let transcript = documents.map { $0.document.text.transcript }.joined(separator: "\n\n")
        let structure = OCRDocumentStructure(
            paragraphCount: documents.reduce(0) { $0 + $1.document.paragraphs.count },
            tableCount: documents.reduce(0) { $0 + $1.document.tables.count },
            listCount: documents.reduce(0) { $0 + $1.document.lists.count }
        )
        return OCRPageResult(
            pageIndex: pageIndex,
            text: OCRTextUtilities.normalize(transcript),
            observations: observations,
            structure: structure
        )
    }

    private func observation(_ source: RecognizedTextObservation) -> OCRTextObservation {
        let points = [source.topLeft, source.topRight, source.bottomRight, source.bottomLeft]
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        // Vision can return harmless floating-point spill just outside the
        // normalized unit square. Clamp it before serializing provenance.
        let minX = min(1, max(0, xs.min() ?? 0))
        let maxX = min(1, max(0, xs.max() ?? 0))
        let minY = min(1, max(0, ys.min() ?? 0))
        let maxY = min(1, max(0, ys.max() ?? 0))
        return OCRTextObservation(
            text: source.transcript,
            confidence: source.confidence,
            boundingBox: OCRNormalizedBox(
                x: Double(minX),
                y: Double(minY),
                width: Double(maxX - minX),
                height: Double(maxY - minY)
            )
        )
    }
}
