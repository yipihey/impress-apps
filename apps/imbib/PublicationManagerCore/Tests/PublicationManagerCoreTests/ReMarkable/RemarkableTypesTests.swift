//
//  RemarkableTypesTests.swift
//  PublicationManagerCoreTests
//
//  Tests for reMarkable data types and structures.
//  ADR-019: reMarkable Tablet Integration
//

import XCTest
@testable import PublicationManagerCore

final class RemarkableTypesTests: XCTestCase {

    // MARK: - RemarkableDocumentInfo Tests

    func testDocumentInfo_initialization() {
        let info = RemarkableDocumentInfo(
            id: "doc-123",
            name: "Test Document",
            parentFolderID: "folder-1",
            lastModified: Date(),
            version: 5,
            pageCount: 10,
            hasAnnotations: true
        )

        XCTAssertEqual(info.id, "doc-123")
        XCTAssertEqual(info.name, "Test Document")
        XCTAssertEqual(info.parentFolderID, "folder-1")
        XCTAssertEqual(info.version, 5)
        XCTAssertEqual(info.pageCount, 10)
        XCTAssertTrue(info.hasAnnotations)
    }

    func testDocumentInfo_defaultValues() {
        let info = RemarkableDocumentInfo(
            id: "doc-123",
            name: "Test",
            parentFolderID: nil,
            lastModified: Date(),
            version: 1
        )

        XCTAssertEqual(info.pageCount, 0)
        XCTAssertFalse(info.hasAnnotations)
        XCTAssertNil(info.parentFolderID)
    }

    func testDocumentInfo_identifiable() {
        let info = RemarkableDocumentInfo(
            id: "unique-id",
            name: "Test",
            parentFolderID: nil,
            lastModified: Date(),
            version: 1
        )

        XCTAssertEqual(info.id, "unique-id")
    }

    // MARK: - RemarkableFolderInfo Tests

    func testFolderInfo_initialization() {
        let info = RemarkableFolderInfo(
            id: "folder-1",
            name: "Papers",
            parentFolderID: nil,
            documentCount: 5
        )

        XCTAssertEqual(info.id, "folder-1")
        XCTAssertEqual(info.name, "Papers")
        XCTAssertNil(info.parentFolderID)
        XCTAssertEqual(info.documentCount, 5)
    }

    func testFolderInfo_nestedFolder() {
        let info = RemarkableFolderInfo(
            id: "sub-folder",
            name: "Subfolder",
            parentFolderID: "parent-folder",
            documentCount: 3
        )

        XCTAssertEqual(info.parentFolderID, "parent-folder")
    }

    // MARK: - RemarkableRawAnnotation Tests

    func testRawAnnotation_highlightType() {
        let annotation = RemarkableRawAnnotation(
            id: "ann-1",
            pageNumber: 0,
            type: .highlight,
            bounds: CGRect(x: 10, y: 20, width: 100, height: 20),
            color: "#FFFF00"
        )

        XCTAssertEqual(annotation.type, .highlight)
        XCTAssertEqual(annotation.pageNumber, 0)
        XCTAssertEqual(annotation.color, "#FFFF00")
    }

    func testRawAnnotation_inkType() {
        let strokeData = Data([0x01, 0x02, 0x03])
        let annotation = RemarkableRawAnnotation(
            id: "ann-2",
            pageNumber: 5,
            type: .ink,
            strokeData: strokeData,
            bounds: CGRect(x: 50, y: 100, width: 200, height: 150),
            color: "#000000"
        )

        XCTAssertEqual(annotation.type, .ink)
        XCTAssertEqual(annotation.strokeData, strokeData)
    }

    func testRawAnnotation_textType() {
        let annotation = RemarkableRawAnnotation(
            id: "ann-3",
            pageNumber: 2,
            type: .text,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            color: nil,
            ocrText: "Sample OCR text"
        )

        XCTAssertEqual(annotation.type, .text)
        XCTAssertEqual(annotation.ocrText, "Sample OCR text")
    }

    func testRawAnnotation_bounds() {
        let rect = CGRect(x: 100, y: 200, width: 300, height: 50)
        let annotation = RemarkableRawAnnotation(
            id: "ann-4",
            pageNumber: 0,
            type: .highlight,
            bounds: rect,
            color: nil
        )

        XCTAssertEqual(annotation.bounds.origin.x, 100)
        XCTAssertEqual(annotation.bounds.origin.y, 200)
        XCTAssertEqual(annotation.bounds.size.width, 300)
        XCTAssertEqual(annotation.bounds.size.height, 50)
    }

    // MARK: - RemarkableDocumentBundle Tests

    func testDocumentBundle_initialization() {
        let docInfo = RemarkableDocumentInfo(
            id: "doc-1",
            name: "Test",
            parentFolderID: nil,
            lastModified: Date(),
            version: 1
        )

        let pdfData = Data("PDF content".utf8)
        let annotations = [
            RemarkableRawAnnotation(
                id: "ann-1",
                pageNumber: 0,
                type: .highlight,
                bounds: .zero,
                color: nil
            )
        ]

        let bundle = RemarkableDocumentBundle(
            documentInfo: docInfo,
            pdfData: pdfData,
            annotations: annotations,
            metadata: ["key": "value"]
        )

        XCTAssertEqual(bundle.documentInfo.id, "doc-1")
        XCTAssertEqual(bundle.pdfData, pdfData)
        XCTAssertEqual(bundle.annotations.count, 1)
        XCTAssertEqual(bundle.metadata["key"], "value")
    }

    // MARK: - RemarkableDeviceInfo Tests

    func testDeviceInfo_initialization() {
        let info = RemarkableDeviceInfo(
            deviceID: "RM100-123",
            deviceName: "My reMarkable",
            storageUsed: 1024 * 1024 * 500,
            storageTotal: 1024 * 1024 * 1024 * 8
        )

        XCTAssertEqual(info.deviceID, "RM100-123")
        XCTAssertEqual(info.deviceName, "My reMarkable")
        XCTAssertEqual(info.storageUsed, 524288000)
        XCTAssertEqual(info.storageTotal, 8589934592)
    }

    func testDeviceInfo_optionalStorage() {
        let info = RemarkableDeviceInfo(
            deviceID: "RM100-456",
            deviceName: "reMarkable 2"
        )

        XCTAssertNil(info.storageUsed)
        XCTAssertNil(info.storageTotal)
    }

    // MARK: - RemarkableError Tests

    func testRemarkableError_descriptions() {
        let errors: [RemarkableError] = [
            .notAuthenticated,
            .authTimeout,
            .authFailed("Test failure"),
            .notConfigured("Missing config"),
            .noBackendConfigured,
            .backendNotFound("cloud"),
            .backendUnavailable("local"),
            .noPDFAvailable,
            .localFolderNotConfigured,
            .localFolderNotFound("/path"),
            .localFolderNotAccessible,
            .documentNotFound("doc-123")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Missing description for \(error)")
        }
    }

    // MARK: - ConflictResolution Tests

    func testConflictResolution_allCases() {
        let cases = ConflictResolution.allCases

        XCTAssertTrue(cases.contains(.preferLocal))
        XCTAssertTrue(cases.contains(.preferRemarkable))
        XCTAssertTrue(cases.contains(.keepBoth))
    }
}
