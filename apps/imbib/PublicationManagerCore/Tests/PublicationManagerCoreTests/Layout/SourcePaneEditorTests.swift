#if os(macOS)
//
//  SourcePaneEditorTests.swift
//  PublicationManagerCoreTests
//
//  W4 pass B (ADR-0031 D6): a `source` pane's editor is MOVED between pane
//  hosts, never rebuilt; it keeps one undo history per manuscript; an
//  external change lands in place; a deleted manuscript leaves nothing.
//  And the external_source predicate the pane gates on.
//

import AppKit
import XCTest

@testable import PublicationManagerCore

@MainActor
final class SourcePaneEditorTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    /// A host with an editor built the way `makeEditor` builds one, reduced
    /// to what the host touches: a scroll view over a `TypstTextView`.
    private func makeHost() -> (TypstEditorHost, TypstTextView) {
        let host = TypstEditorHost(label: "test")
        let scrollView = NSScrollView()
        let textView = TypstTextView()
        textView.allowsUndo = true
        scrollView.documentView = textView
        host.adopt(scrollView)
        return (host, textView)
    }

    /// Register one undoable step on the view's current history.
    private func registerStep(on textView: TypstTextView) {
        let history = textView.documentUndoManager!
        history.groupsByEvent = false
        history.beginUndoGrouping()
        history.registerUndo(withTarget: textView) { _ in }
        history.endUndoGrouping()
    }

    // MARK: Mounting

    func testMountMovesTheSameEditorAndOnlyItsOwnHostMayDetachIt() {
        let (host, textView) = makeHost()
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let second = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))

        host.mount(in: first)
        XCTAssertTrue(host.scrollView?.superview === first)
        XCTAssertEqual(host.scrollView?.frame.size, first.bounds.size)

        // A split: SwiftUI builds the new pane host BEFORE it dismantles the
        // old one. The editor moves; the late teardown must leave it alone.
        host.mount(in: second)
        host.detach(from: first)
        XCTAssertTrue(host.scrollView?.superview === second, "the old host's teardown took it away")
        XCTAssertTrue(host.textView === textView, "it is the same text view, not a new one")
        XCTAssertEqual(host.mounts, 2)

        // The pane really closing: detached, but kept.
        host.detach(from: second)
        XCTAssertNil(host.scrollView?.superview)
        XCTAssertTrue(host.textView === textView)
    }

    // MARK: Documents

    func testEachManuscriptKeepsItsOwnHistory() {
        let (host, textView) = makeHost()
        XCTAssertEqual(host.present(document: a, text: "alpha", in: textView), .switched)
        let historyA = textView.documentUndoManager
        XCTAssertNotNil(historyA)
        XCTAssertTrue(textView.undoManager === historyA, "typing registers on the document's history")
        registerStep(on: textView)

        XCTAssertEqual(host.present(document: b, text: "beta", in: textView), .switched)
        XCTAssertEqual(textView.string, "beta")
        XCTAssertFalse(textView.documentUndoManager === historyA, "B does not inherit A's steps")
        XCTAssertEqual(textView.documentUndoManager?.canUndo, false)

        XCTAssertEqual(host.present(document: a, text: "alpha", in: textView), .switched)
        XCTAssertTrue(textView.documentUndoManager === historyA, "A comes back with its own")
        XCTAssertEqual(textView.documentUndoManager?.canUndo, true)
        XCTAssertEqual(host.present(document: a, text: "alpha", in: textView), .unchanged)
    }

    func testTheViewClaimsUndoOnlyWhenItHasItsOwnHistory() {
        let (host, textView) = makeHost()
        let undo = #selector(TypstTextView.undo(_:))
        XCTAssertFalse(textView.responds(to: undo), "the Source tab's ⌘Z still reaches the window")
        _ = host.present(document: a, text: "alpha", in: textView)
        XCTAssertTrue(textView.responds(to: undo))
    }

    func testAManuscriptChangedWhileAwayLosesItsHistory() {
        let (host, textView) = makeHost()
        _ = host.present(document: a, text: "alpha", in: textView)
        registerStep(on: textView)
        _ = host.present(document: b, text: "beta", in: textView)
        // A was edited elsewhere meanwhile: its steps are ranges into text
        // that is gone.
        _ = host.present(document: a, text: "alpha, merged", in: textView)
        XCTAssertEqual(textView.string, "alpha, merged")
        XCTAssertEqual(textView.documentUndoManager?.canUndo, false)
    }

    func testAnExternalChangeLandsInPlaceAndKeepsTheCaret() {
        let (host, textView) = makeHost()
        _ = host.present(document: a, text: "= Title\n\nmine here", in: textView)
        // The caret after "mine".
        textView.setSelectedRange(NSRange(location: 13, length: 0))
        registerStep(on: textView)

        // A co-author inserted a line ABOVE the caret.
        let merged = "= Title\n\ntheirs\nmine here"
        XCTAssertEqual(host.present(document: a, text: merged, in: textView), .external)
        XCTAssertEqual(textView.string, merged)
        XCTAssertEqual(textView.selectedRange().location, 13 + 7, "the caret moves with its text")
        XCTAssertEqual(textView.documentUndoManager?.canUndo, false, "stale steps are dropped")

        // And an edit BELOW the caret leaves it where it is.
        let appended = merged + "\nlast"
        XCTAssertEqual(host.present(document: a, text: appended, in: textView), .external)
        XCTAssertEqual(textView.selectedRange().location, 20)
    }

    func testForgettingADeletedManuscriptKeepsNothing() {
        let (host, textView) = makeHost()
        _ = host.present(document: a, text: "doomed", in: textView)
        registerStep(on: textView)
        host.forget(document: a)
        XCTAssertNil(host.documentID)
        XCTAssertNil(textView.documentUndoManager)
        XCTAssertEqual(textView.string, "")
        // A stale pass still holding the deleted document's binding is
        // ignored: nothing comes back on screen, no history is made.
        XCTAssertEqual(host.present(document: a, text: "doomed", in: textView), .unchanged)
        XCTAssertEqual(textView.string, "")
        XCTAssertNil(textView.documentUndoManager)

        // Shown again by a fresh session (an undo of the delete): a new,
        // empty history.
        host.remember(document: a)
        XCTAssertEqual(host.present(document: a, text: "doomed", in: textView), .switched)
        XCTAssertEqual(textView.documentUndoManager?.canUndo, false)
    }

    // MARK: The external_source predicate

    func testExternalSourceIsTheOnlyThingThatForbidsASession() {
        XCTAssertTrue(ManuscriptEditorSessionPolicy.allowsEditorSession(externalSource: nil))
        XCTAssertTrue(ManuscriptEditorSessionPolicy.allowsEditorSession(externalSource: NSNull()))
        XCTAssertFalse(
            ManuscriptEditorSessionPolicy.allowsEditorSession(externalSource: #"{"path":"/x.typ"}"#))
        XCTAssertTrue(ManuscriptEditorSessionPolicy.allowsEditorSession(payload: ["title": "t"]))
        XCTAssertFalse(
            ManuscriptEditorSessionPolicy.allowsEditorSession(payload: ["external_source": "{}"]))
        // `import_source` is its opposite and never gates anything.
        XCTAssertTrue(
            ManuscriptEditorSessionPolicy.allowsEditorSession(payload: ["import_source": "{}"]))
    }
}
#endif
