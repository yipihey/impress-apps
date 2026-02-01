//
//  AnnotationConverterTests.swift
//  PublicationManagerCoreTests
//
//  Tests for converting reMarkable annotations to PDF/imbib format.
//  ADR-019: reMarkable Tablet Integration
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class AnnotationConverterTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(configuration: .preview)
        context = persistenceController.viewContext
    }

    override func tearDown() {
        context = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - ConversionResult Tests

    func testConversionResult_initialization() {
        let highlights = [
            AnnotationConverter.HighlightAnnotation(
                pageNumber: 0,
                bounds: CGRect(x: 10, y: 20, width: 100, height: 20),
                color: "#FFFF00"
            )
        ]

        let inkStrokes = [
            AnnotationConverter.InkAnnotation(
                pageNumber: 1,
                bounds: CGRect(x: 50, y: 100, width: 200, height: 150),
                color: "#000000",
                strokeData: Data()
            )
        ]

        let result = AnnotationConverter.ConversionResult(
            highlights: highlights,
            inkStrokes: inkStrokes,
            renderedImage: nil
        )

        XCTAssertEqual(result.highlights.count, 1)
        XCTAssertEqual(result.inkStrokes.count, 1)
        XCTAssertNil(result.renderedImage)
    }

    // MARK: - HighlightAnnotation Tests

    func testHighlightAnnotation_properties() {
        let highlight = AnnotationConverter.HighlightAnnotation(
            pageNumber: 5,
            bounds: CGRect(x: 100, y: 200, width: 300, height: 25),
            color: "#FFFF00"
        )

        XCTAssertEqual(highlight.pageNumber, 5)
        XCTAssertEqual(highlight.bounds.origin.x, 100)
        XCTAssertEqual(highlight.bounds.origin.y, 200)
        XCTAssertEqual(highlight.bounds.size.width, 300)
        XCTAssertEqual(highlight.bounds.size.height, 25)
        XCTAssertEqual(highlight.color, "#FFFF00")
    }

    // MARK: - InkAnnotation Tests

    func testInkAnnotation_properties() {
        let strokeData = Data([0x01, 0x02, 0x03, 0x04])
        let ink = AnnotationConverter.InkAnnotation(
            pageNumber: 3,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            color: "#000000",
            strokeData: strokeData
        )

        XCTAssertEqual(ink.pageNumber, 3)
        XCTAssertEqual(ink.color, "#000000")
        XCTAssertEqual(ink.strokeData, strokeData)
    }

    // MARK: - RawAnnotation Conversion Tests

    func testConvertToImbibAnnotation_highlight() throws {
        // Create a CDLinkedFile for the annotation
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = "test.pdf"
        linkedFile.filename = "test.pdf"

        let raw = RemarkableRawAnnotation(
            id: "raw-1",
            pageNumber: 2,
            type: .highlight,
            bounds: CGRect(x: 10, y: 20, width: 100, height: 15),
            color: "#FFFF00"
        )

        let annotation = AnnotationConverter.convertToImbibAnnotation(
            raw: raw,
            linkedFile: linkedFile,
            context: context
        )

        XCTAssertNotNil(annotation)
        XCTAssertEqual(annotation?.pageNumber, 2)
        XCTAssertEqual(annotation?.annotationType, "highlight")
        XCTAssertEqual(annotation?.author, "reMarkable")
        XCTAssertEqual(annotation?.linkedFile, linkedFile)
    }

    func testConvertToImbibAnnotation_ink() throws {
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = "test.pdf"
        linkedFile.filename = "test.pdf"

        let raw = RemarkableRawAnnotation(
            id: "raw-2",
            pageNumber: 5,
            type: .ink,
            strokeData: Data([0x01, 0x02]),
            bounds: CGRect(x: 50, y: 100, width: 200, height: 150),
            color: "#000000"
        )

        let annotation = AnnotationConverter.convertToImbibAnnotation(
            raw: raw,
            linkedFile: linkedFile,
            context: context
        )

        XCTAssertNotNil(annotation)
        XCTAssertEqual(annotation?.pageNumber, 5)
        XCTAssertEqual(annotation?.annotationType, "ink")
    }

    func testConvertToImbibAnnotation_text() throws {
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = "test.pdf"
        linkedFile.filename = "test.pdf"

        let raw = RemarkableRawAnnotation(
            id: "raw-3",
            pageNumber: 1,
            type: .text,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            color: nil,
            ocrText: "Sample text"
        )

        let annotation = AnnotationConverter.convertToImbibAnnotation(
            raw: raw,
            linkedFile: linkedFile,
            context: context
        )

        XCTAssertNotNil(annotation)
        XCTAssertEqual(annotation?.annotationType, "note")
    }

    // MARK: - Coordinate Scaling Tests

    func testConvert_scalesCoordinatesToPDFSize() {
        // This would require creating a real RMFile with strokes
        // For now, just verify the constants are correct
        XCTAssertGreaterThan(RMPageDimensions.width, 0)
        XCTAssertGreaterThan(RMPageDimensions.height, 0)
    }
}
