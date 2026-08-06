import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ImpressOCR

@Test
func textUtilitiesNormalizeAndSelectSectionHints() {
    let raw = "  FUEL INJECTION   \n\n\n\nTroubleshooting\nBody text\n"
    let normalized = OCRTextUtilities.normalize(raw)
    #expect(normalized == "  FUEL INJECTION\n\n\nTroubleshooting\nBody text\n")
    #expect(
        OCRTextUtilities.sectionHint(normalized)
            == "FUEL INJECTION | Troubleshooting | Body text"
    )
}

@Test
func confidenceStatisticsUsePortableHundredPointScale() {
    let result = OCRPageResult(
        pageIndex: 2,
        text: "one two",
        observations: [
            .init(
                text: "one",
                confidence: 0.5,
                boundingBox: .init(x: 0, y: 0, width: 0.2, height: 0.1)
            ),
            .init(
                text: "two",
                confidence: 0.9,
                boundingBox: .init(x: 0.3, y: 0, width: 0.2, height: 0.1)
            ),
        ],
        structure: nil
    )
    #expect(abs(result.meanConfidence - 70) < 0.001)
    #expect(abs(result.medianConfidence - 70) < 0.001)
    #expect(result.lowConfidenceFraction == 0.5)
}

@Test
func visionRecognizesSyntheticText() async throws {
    let width = 1400
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: "FUEL INJECTION",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 0, alpha: 1),
            ]
        )
    )
    context.textPosition = CGPoint(x: 50, y: 100)
    CTLineDraw(line, context)
    let image = try #require(context.makeImage())
    let engine = AppleVisionOCR(
        configuration: .init(mode: .text, recognitionLanguages: ["en-US"])
    )
    let result = try await engine.recognize(image)
    #expect(result.text.uppercased().contains("FUEL INJECTION"))
    #expect(result.observations.first?.boundingBox.width ?? 0 > 0)
}
