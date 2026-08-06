import CoreGraphics
import Foundation

public enum OCRRecognitionMode: String, Codable, Sendable {
    /// Accurate line-oriented recognition with confidence and geometry.
    case text
    /// macOS/iOS 26 structured recognition for paragraphs, tables, and lists.
    case document
}

public enum OCRRecognitionLevel: String, Codable, Sendable {
    case accurate
    case fast
}

public struct AppleVisionOCRConfiguration: Codable, Equatable, Sendable {
    public var mode: OCRRecognitionMode
    public var recognitionLevel: OCRRecognitionLevel
    public var recognitionLanguages: [String]
    public var automaticallyDetectsLanguage: Bool
    public var usesLanguageCorrection: Bool
    public var customWords: [String]
    public var minimumTextHeightFraction: Float

    public init(
        mode: OCRRecognitionMode = .text,
        recognitionLevel: OCRRecognitionLevel = .accurate,
        recognitionLanguages: [String] = ["en-US"],
        automaticallyDetectsLanguage: Bool = false,
        usesLanguageCorrection: Bool = true,
        customWords: [String] = [],
        minimumTextHeightFraction: Float = 0
    ) {
        self.mode = mode
        self.recognitionLevel = recognitionLevel
        self.recognitionLanguages = recognitionLanguages
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords
        self.minimumTextHeightFraction = minimumTextHeightFraction
    }

    /// Stable, human-readable extraction settings recorded in Impress.
    public var profileIdentity: String {
        let languages = recognitionLanguages.joined(separator: ",")
        let words = customWords.sorted().joined(separator: ",")
        return [
            "mode=\(mode.rawValue)",
            "level=\(recognitionLevel.rawValue)",
            "languages=\(languages)",
            "automatic-language=\(automaticallyDetectsLanguage)",
            "language-correction=\(usesLanguageCorrection)",
            "minimum-text-height=\(minimumTextHeightFraction)",
            "custom-words=\(words)",
        ].joined(separator: ";")
    }
}

/// Rectangle in Vision's normalized, lower-left-origin coordinate system.
public struct OCRNormalizedBox: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct OCRTextObservation: Codable, Equatable, Sendable {
    public let text: String
    /// Normalized confidence between zero and one.
    public let confidence: Float
    public let boundingBox: OCRNormalizedBox

    public init(text: String, confidence: Float, boundingBox: OCRNormalizedBox) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct OCRDocumentStructure: Codable, Equatable, Sendable {
    public let paragraphCount: Int
    public let tableCount: Int
    public let listCount: Int

    public init(paragraphCount: Int, tableCount: Int, listCount: Int) {
        self.paragraphCount = paragraphCount
        self.tableCount = tableCount
        self.listCount = listCount
    }
}

public struct OCRPageResult: Codable, Equatable, Sendable {
    /// Zero-based page index.
    public let pageIndex: Int
    public let text: String
    public let observations: [OCRTextObservation]
    public let structure: OCRDocumentStructure?

    public init(
        pageIndex: Int,
        text: String,
        observations: [OCRTextObservation],
        structure: OCRDocumentStructure?
    ) {
        self.pageIndex = pageIndex
        self.text = text
        self.observations = observations
        self.structure = structure
    }

    public var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Mean line confidence on the same 0–100 scale as the portable index.
    public var meanConfidence: Double {
        guard !observations.isEmpty else { return 0 }
        return observations.reduce(0) { $0 + Double($1.confidence) * 100 }
            / Double(observations.count)
    }

    public var medianConfidence: Double {
        let sorted = observations.map { Double($0.confidence) * 100 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    public var lowConfidenceFraction: Double {
        guard !observations.isEmpty else { return 0 }
        let low = observations.count { $0.confidence < 0.6 }
        return Double(low) / Double(observations.count)
    }

    public var sectionHint: String {
        OCRTextUtilities.sectionHint(text)
    }
}

public enum OCRTextUtilities {
    public static func normalize(_ text: String) -> String {
        var lines = text
            .replacingOccurrences(of: "\u{000c}", with: "")
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        var normalized: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 2 {
                    normalized.append("")
                }
            } else {
                blankRun = 0
                normalized.append(line)
            }
        }
        return normalized.isEmpty ? "" : normalized.joined(separator: "\n") + "\n"
    }

    public static func sectionHint(_ text: String) -> String {
        var candidates: [String] = []
        for rawLine in text.components(separatedBy: .newlines).prefix(30) {
            let line = rawLine
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -|_"))
            guard (3...100).contains(line.count) else { continue }
            guard line.filter(\.isLetter).count >= 3 else { continue }
            candidates.append(line)
            if candidates.count == 3 { break }
        }
        return candidates.joined(separator: " | ")
    }
}

public enum ImpressOCRError: LocalizedError, Sendable {
    case invalidPDF(String)
    case invalidPage(Int)
    case renderingFailed(Int)
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPDF(let path):
            return "Could not open PDF: \(path)"
        case .invalidPage(let page):
            return "PDF page \(page + 1) does not exist."
        case .renderingFailed(let page):
            return "Could not render PDF page \(page + 1)."
        case .recognitionFailed(let message):
            return "Vision OCR failed: \(message)"
        }
    }
}
