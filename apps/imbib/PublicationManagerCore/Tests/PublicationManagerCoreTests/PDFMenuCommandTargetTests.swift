//
//  PDFMenuCommandTargetTests.swift
//  PublicationManagerCoreTests
//
//  Annotate ▸ Highlight / Underline / Strikethrough and Go ▸ Go to Page post
//  no file id and (for ⌘G) no page. These pin what the PDF view does with
//  such a post.
//

import XCTest
@testable import PublicationManagerCore

final class PDFMenuCommandTargetTests: XCTestCase {

    private let shown = UUID()
    private let other = UUID()

    private func post(_ userInfo: [String: Any]? = nil) -> Notification {
        Notification(name: .highlightSelection, object: nil, userInfo: userInfo)
    }

    /// The menu's post (no id) persists under the file the view shows — the
    /// id that was missing, which left the annotation unstored.
    func testAMenuPostWithNoIdTakesTheDisplayedFile() {
        XCTAssertTrue(AnnotationCommandTarget.applies(post(), displayed: shown))
        XCTAssertEqual(AnnotationCommandTarget.fileID(post(), displayed: shown), shown)
        // The color submenu's post carries only a color.
        XCTAssertEqual(AnnotationCommandTarget.fileID(post(["color": "green"]), displayed: shown), shown)
    }

    func testAPostNamingAnotherFileIsNotForThisView() {
        let aimed = post([AnnotationCommandTarget.linkedFileIDKey: other])
        XCTAssertFalse(AnnotationCommandTarget.applies(aimed, displayed: shown))
        XCTAssertTrue(AnnotationCommandTarget.applies(post([AnnotationCommandTarget.linkedFileIDKey: shown]), displayed: shown))
    }

    /// A viewer with no linked file (opened from a URL) still draws; there is
    /// no row to store it under.
    func testAViewWithNoLinkedFileHasNothingToStoreUnder() {
        XCTAssertTrue(AnnotationCommandTarget.applies(post(), displayed: nil))
        XCTAssertNil(AnnotationCommandTarget.fileID(post(), displayed: nil))
    }

    func testGoToPageInputClampsAndRejectsNonNumbers() {
        XCTAssertEqual(GoToPageInput.page(from: "7", totalPages: 12), 7)
        XCTAssertEqual(GoToPageInput.page(from: " 3 \n", totalPages: 12), 3)
        XCTAssertEqual(GoToPageInput.page(from: "40", totalPages: 12), 12)
        XCTAssertEqual(GoToPageInput.page(from: "0", totalPages: 12), 1)
        XCTAssertNil(GoToPageInput.page(from: "", totalPages: 12))
        XCTAssertNil(GoToPageInput.page(from: "iv", totalPages: 12))
        XCTAssertNil(GoToPageInput.page(from: "3", totalPages: 0))
    }

    /// The observer's source keeps both paths: a posted page navigates, and a
    /// post without one raises the prompt instead of returning.
    func testTheGoToPageObserverPromptsWhenNoPageIsGiven() throws {
        let source = try MenuNotificationObserverTests.source(
            of: "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/SharedViews/PDFViewer.swift")
        let command = try MenuNotificationObserverTests.source(
            of: "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/SharedViews/GoToPageSheet.swift")
        XCTAssertTrue(source.contains(".modifier(GoToPageCommand("))
        XCTAssertTrue(command.contains("showPrompt = true"))
        XCTAssertTrue(command.contains("GoToPageSheet("))
    }
}
