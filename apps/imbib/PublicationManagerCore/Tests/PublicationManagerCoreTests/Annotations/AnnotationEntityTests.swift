//
//  AnnotationEntityTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-16.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class AnnotationEntityTests: XCTestCase {

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

    // MARK: - Annotation Type Tests

    func testAnnotationType_allCases() {
        let types = CDAnnotation.AnnotationType.allCases

        XCTAssertEqual(types.count, 6)
        XCTAssertTrue(types.contains(.highlight))
        XCTAssertTrue(types.contains(.underline))
        XCTAssertTrue(types.contains(.strikethrough))
        XCTAssertTrue(types.contains(.note))
        XCTAssertTrue(types.contains(.freeText))
        XCTAssertTrue(types.contains(.ink))
    }

    func testAnnotationType_icons() {
        XCTAssertEqual(CDAnnotation.AnnotationType.highlight.icon, "highlighter")
        XCTAssertEqual(CDAnnotation.AnnotationType.underline.icon, "underline")
        XCTAssertEqual(CDAnnotation.AnnotationType.strikethrough.icon, "strikethrough")
        XCTAssertEqual(CDAnnotation.AnnotationType.note.icon, "note.text")
        XCTAssertEqual(CDAnnotation.AnnotationType.freeText.icon, "textformat")
        XCTAssertEqual(CDAnnotation.AnnotationType.ink.icon, "pencil.tip")
    }

    func testAnnotationType_displayNames() {
        XCTAssertEqual(CDAnnotation.AnnotationType.highlight.displayName, "Highlight")
        XCTAssertEqual(CDAnnotation.AnnotationType.underline.displayName, "Underline")
        XCTAssertEqual(CDAnnotation.AnnotationType.strikethrough.displayName, "Strikethrough")
        XCTAssertEqual(CDAnnotation.AnnotationType.note.displayName, "Note")
        XCTAssertEqual(CDAnnotation.AnnotationType.freeText.displayName, "Free Text")
        XCTAssertEqual(CDAnnotation.AnnotationType.ink.displayName, "Ink")
    }

    // MARK: - Bounds Tests

    func testAnnotationBounds_encode_decode() {
        let rect = CGRect(x: 100, y: 200, width: 300, height: 50)
        let bounds = CDAnnotation.Bounds(rect: rect)

        XCTAssertEqual(bounds.x, 100)
        XCTAssertEqual(bounds.y, 200)
        XCTAssertEqual(bounds.width, 300)
        XCTAssertEqual(bounds.height, 50)

        let cgRect = bounds.cgRect
        XCTAssertEqual(cgRect, rect)
    }

    func testAnnotation_bounds_property() {
        let annotation = CDAnnotation(context: context)
        annotation.id = UUID()
        annotation.annotationType = "highlight"
        annotation.pageNumber = 0
        annotation.dateCreated = Date()
        annotation.dateModified = Date()

        let rect = CGRect(x: 50, y: 100, width: 200, height: 30)
        annotation.bounds = rect

        XCTAssertEqual(annotation.bounds.origin.x, rect.origin.x)
        XCTAssertEqual(annotation.bounds.origin.y, rect.origin.y)
        XCTAssertEqual(annotation.bounds.width, rect.width)
        XCTAssertEqual(annotation.bounds.height, rect.height)
    }

    // MARK: - CDAnnotation Entity Tests

    func testAnnotation_create() {
        let annotation = CDAnnotation(context: context)
        annotation.id = UUID()
        annotation.annotationType = CDAnnotation.AnnotationType.highlight.rawValue
        annotation.pageNumber = 5
        annotation.boundsJSON = "{\"x\":0,\"y\":0,\"width\":100,\"height\":20}"
        annotation.color = "#FFFF00"
        annotation.contents = "Test note"
        annotation.selectedText = "Selected text"
        annotation.author = "Test Device"
        annotation.dateCreated = Date()
        annotation.dateModified = Date()

        XCTAssertNotNil(annotation.id)
        XCTAssertEqual(annotation.annotationType, "highlight")
        XCTAssertEqual(annotation.pageNumber, 5)
        XCTAssertEqual(annotation.color, "#FFFF00")
        XCTAssertEqual(annotation.contents, "Test note")
        XCTAssertEqual(annotation.selectedText, "Selected text")
        XCTAssertEqual(annotation.author, "Test Device")
    }

    func testAnnotation_typeEnum() {
        let annotation = CDAnnotation(context: context)
        annotation.id = UUID()
        annotation.annotationType = "highlight"
        annotation.pageNumber = 0
        annotation.boundsJSON = "{\"x\":0,\"y\":0,\"width\":100,\"height\":20}"
        annotation.dateCreated = Date()
        annotation.dateModified = Date()

        XCTAssertEqual(annotation.typeEnum, .highlight)

        annotation.annotationType = "underline"
        XCTAssertEqual(annotation.typeEnum, .underline)

        annotation.annotationType = "unknown"
        XCTAssertNil(annotation.typeEnum)
    }

    func testAnnotation_previewText() {
        let annotation = CDAnnotation(context: context)
        annotation.id = UUID()
        annotation.annotationType = "highlight"
        annotation.pageNumber = 0
        annotation.boundsJSON = "{\"x\":0,\"y\":0,\"width\":100,\"height\":20}"
        annotation.dateCreated = Date()
        annotation.dateModified = Date()

        // No content
        XCTAssertEqual(annotation.previewText, "Highlight")

        // With contents
        annotation.contents = "This is a note"
        XCTAssertEqual(annotation.previewText, "This is a note")

        // With selected text (no contents)
        annotation.contents = nil
        annotation.selectedText = "Selected text here"
        XCTAssertEqual(annotation.previewText, "Selected text here")
    }

    func testAnnotation_hasContent() {
        let annotation = CDAnnotation(context: context)
        annotation.id = UUID()
        annotation.annotationType = "highlight"
        annotation.pageNumber = 0
        annotation.boundsJSON = "{\"x\":0,\"y\":0,\"width\":100,\"height\":20}"
        annotation.dateCreated = Date()
        annotation.dateModified = Date()

        XCTAssertFalse(annotation.hasContent)

        annotation.contents = "Some content"
        XCTAssertTrue(annotation.hasContent)

        annotation.contents = nil
        annotation.selectedText = "Some selected text"
        XCTAssertTrue(annotation.hasContent)
    }

    // MARK: - CDLinkedFile Annotation Helpers Tests

    func testLinkedFile_annotationHelpers() {
        // Create linked file
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = "Papers/test.pdf"
        linkedFile.filename = "test.pdf"
        linkedFile.dateAdded = Date()

        XCTAssertEqual(linkedFile.annotationCount, 0)
        XCTAssertFalse(linkedFile.hasAnnotations)

        // Add annotations
        let annotation1 = CDAnnotation(context: context)
        annotation1.id = UUID()
        annotation1.annotationType = "highlight"
        annotation1.pageNumber = 1
        annotation1.boundsJSON = "{\"x\":0,\"y\":100,\"width\":100,\"height\":20}"
        annotation1.dateCreated = Date()
        annotation1.dateModified = Date()
        annotation1.linkedFile = linkedFile

        let annotation2 = CDAnnotation(context: context)
        annotation2.id = UUID()
        annotation2.annotationType = "note"
        annotation2.pageNumber = 0
        annotation2.boundsJSON = "{\"x\":0,\"y\":200,\"width\":24,\"height\":24}"
        annotation2.dateCreated = Date()
        annotation2.dateModified = Date()
        annotation2.linkedFile = linkedFile

        XCTAssertEqual(linkedFile.annotationCount, 2)
        XCTAssertTrue(linkedFile.hasAnnotations)

        // Test sorted annotations (by page, then by y position)
        let sorted = linkedFile.sortedAnnotations
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted[0].pageNumber, 0)  // Page 0 first
        XCTAssertEqual(sorted[1].pageNumber, 1)  // Page 1 second

        // Test annotations on specific page
        let page0Annotations = linkedFile.annotations(onPage: 0)
        XCTAssertEqual(page0Annotations.count, 1)
        XCTAssertEqual(page0Annotations[0].annotationType, "note")

        let page1Annotations = linkedFile.annotations(onPage: 1)
        XCTAssertEqual(page1Annotations.count, 1)
        XCTAssertEqual(page1Annotations[0].annotationType, "highlight")
    }

    // MARK: - Relationship Tests

    func testAnnotation_linkedFileRelationship() {
        // Create linked file
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = "Papers/test.pdf"
        linkedFile.filename = "test.pdf"
        linkedFile.dateAdded = Date()

        // Create annotation
        let annotation = CDAnnotation(context: context)
        annotation.id = UUID()
        annotation.annotationType = "highlight"
        annotation.pageNumber = 0
        annotation.boundsJSON = "{\"x\":0,\"y\":0,\"width\":100,\"height\":20}"
        annotation.dateCreated = Date()
        annotation.dateModified = Date()
        annotation.linkedFile = linkedFile

        // Verify relationship
        XCTAssertEqual(annotation.linkedFile, linkedFile)
        XCTAssertTrue(linkedFile.annotations?.contains(annotation) ?? false)
    }

    // MARK: - Persistence Tests

    func testAnnotation_saveAndFetch() throws {
        // Create linked file
        let linkedFile = CDLinkedFile(context: context)
        linkedFile.id = UUID()
        linkedFile.relativePath = "Papers/test.pdf"
        linkedFile.filename = "test.pdf"
        linkedFile.dateAdded = Date()

        // Create annotation
        let annotation = CDAnnotation(context: context)
        annotation.id = UUID()
        annotation.annotationType = "highlight"
        annotation.pageNumber = 3
        annotation.boundsJSON = "{\"x\":50,\"y\":100,\"width\":200,\"height\":30}"
        annotation.color = "#00FF00"
        annotation.selectedText = "Test text"
        annotation.dateCreated = Date()
        annotation.dateModified = Date()
        annotation.linkedFile = linkedFile

        // Save
        try context.save()

        // Fetch
        let request = NSFetchRequest<CDAnnotation>(entityName: "Annotation")
        request.predicate = NSPredicate(format: "id == %@", annotation.id as CVarArg)

        let fetched = try context.fetch(request)

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].annotationType, "highlight")
        XCTAssertEqual(fetched[0].pageNumber, 3)
        XCTAssertEqual(fetched[0].color, "#00FF00")
        XCTAssertEqual(fetched[0].selectedText, "Test text")
    }
}
