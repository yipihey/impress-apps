//
//  RMFileParserTests.swift
//  PublicationManagerCoreTests
//
//  Tests for parsing reMarkable .rm binary annotation files.
//  ADR-019: reMarkable Tablet Integration
//

import XCTest
@testable import PublicationManagerCore

final class RMFileParserTests: XCTestCase {

    // MARK: - Invalid Data Tests

    func testParse_emptyData_throwsError() {
        let data = Data()

        XCTAssertThrowsError(try RMFileParser.parse(data))
    }

    func testParse_invalidHeader_throwsError() {
        let data = Data("Invalid header content\n".utf8)

        XCTAssertThrowsError(try RMFileParser.parse(data)) { error in
            XCTAssertTrue(error is RMParseError)
        }
    }

    func testParse_noVersionNumber_throwsError() {
        let data = Data("reMarkable .lines file\n".utf8)

        XCTAssertThrowsError(try RMFileParser.parse(data))
    }

    func testParse_randomData_throwsError() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])

        XCTAssertThrowsError(try RMFileParser.parse(data))
    }

    // MARK: - RMParseError Tests

    func testRMParseError_invalidHeader_description() {
        let error = RMParseError.invalidHeader

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("header") ?? false)
    }

    func testRMParseError_unexpectedEOF_description() {
        let error = RMParseError.unexpectedEOF

        XCTAssertNotNil(error.errorDescription)
    }

    func testRMParseError_invalidData_description() {
        let error = RMParseError.invalidData("test reason")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("test reason") ?? false)
    }

    func testRMParseError_unsupportedVersion_description() {
        let error = RMParseError.unsupportedVersion(99)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("99") ?? false)
    }

    // MARK: - RMLayer Tests

    func testRMLayer_initialization() {
        let layer = RMLayer(name: "Layer 1", strokes: [])

        XCTAssertEqual(layer.name, "Layer 1")
        XCTAssertTrue(layer.strokes.isEmpty)
    }

    // MARK: - RMStroke Tests

    func testRMStroke_PenType_allCases() {
        // Verify pen types are defined
        XCTAssertEqual(RMStroke.PenType.ballpoint.rawValue, 2)
        XCTAssertEqual(RMStroke.PenType.highlighter.rawValue, 5)
        XCTAssertEqual(RMStroke.PenType.eraser.rawValue, 6)
    }

    func testRMStroke_PenType_displayNames() {
        XCTAssertEqual(RMStroke.PenType.ballpoint.displayName, "Ballpoint")
        XCTAssertEqual(RMStroke.PenType.highlighter.displayName, "Highlighter")
        XCTAssertEqual(RMStroke.PenType.eraser.displayName, "Eraser")
    }

    func testRMStroke_StrokeColor_hexColors() {
        XCTAssertEqual(RMStroke.StrokeColor.black.hexColor, "#000000")
        XCTAssertEqual(RMStroke.StrokeColor.yellow.hexColor, "#FFFF00")
        XCTAssertEqual(RMStroke.StrokeColor.blue.hexColor, "#3366FF")
    }

    func testRMStroke_StrokeColor_cgColors() {
        XCTAssertNotNil(RMStroke.StrokeColor.black.cgColor)
        XCTAssertNotNil(RMStroke.StrokeColor.yellow.cgColor)
        XCTAssertNotNil(RMStroke.StrokeColor.red.cgColor)
    }

    // MARK: - RMPoint Tests

    func testRMPoint_initialization() {
        let point = RMPoint(x: 100, y: 200, pressure: 0.5, tiltX: 0.1, tiltY: 0.2)

        XCTAssertEqual(point.x, 100)
        XCTAssertEqual(point.y, 200)
        XCTAssertEqual(point.pressure, 0.5)
        XCTAssertEqual(point.tiltX, 0.1)
        XCTAssertEqual(point.tiltY, 0.2)
    }

    func testRMPoint_cgPoint() {
        let point = RMPoint(x: 150.5, y: 250.75, pressure: 1.0, tiltX: 0, tiltY: 0)

        let cgPoint = point.cgPoint
        XCTAssertEqual(cgPoint.x, 150.5, accuracy: 0.01)
        XCTAssertEqual(cgPoint.y, 250.75, accuracy: 0.01)
    }

    // MARK: - RMPageDimensions Tests

    func testRMPageDimensions_arePositive() {
        XCTAssertGreaterThan(RMPageDimensions.width, 0)
        XCTAssertGreaterThan(RMPageDimensions.height, 0)
    }

    func testRMPageDimensions_aspectRatio() {
        // reMarkable has portrait aspect ratio
        XCTAssertLessThan(RMPageDimensions.width, RMPageDimensions.height)
    }
}
