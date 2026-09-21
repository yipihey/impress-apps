#if os(macOS)
//
//  ViewKindRegistryTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0031 L6. Two properties, both of them about degradation:
//
//  1. every builtin view kind RESOLVES to itself — a kind that silently fell
//     through to the placeholder would look like a rendering bug in one pane
//     and nowhere else;
//  2. an unknown kind resolves to `placeholder` and does NOT throw or return
//     nil. ADR-0031 D4: "a pane whose view kind the platform cannot render
//     becomes a placeholder that keeps its spec", which is what lets a layout
//     built on a richer build survive a round trip through this one.
//
//  `resolvedKind(for:)` is a pure lookup, so neither property needs a view, a
//  store or the FFI.
//

import SwiftUI
import XCTest

@testable import PublicationManagerCore

final class ViewKindRegistryTests: XCTestCase {

    func testEveryBuiltinKindResolvesToItself() {
        let registry = ViewKindRegistry.builtin
        for kind in ViewKindID.builtins {
            XCTAssertEqual(
                registry.resolvedKind(for: kind), kind,
                "\(kind.rawValue) has no factory — it would render as a placeholder")
        }
    }

    func testAnUnknownKindFallsBackToThePlaceholder() {
        let registry = ViewKindRegistry.builtin
        XCTAssertFalse(registry.contains(ViewKindID("holodeck")))
        XCTAssertEqual(registry.resolvedKind(for: ViewKindID("holodeck")), .placeholder)
    }

    /// The names are the wire form: `PaneSpec.view_kind` is matched by string
    /// equality against `impress_layout::ViewKindId`'s constants, so a
    /// renamed case here is a pane that stops rendering.
    func testBuiltinNamesMatchTheRustConstants() {
        XCTAssertEqual(ViewKindID.outline.rawValue, "outline")
        XCTAssertEqual(ViewKindID.list.rawValue, "list")
        XCTAssertEqual(ViewKindID.info.rawValue, "info")
        XCTAssertEqual(ViewKindID.pdf.rawValue, "pdf")
        XCTAssertEqual(ViewKindID.editor.rawValue, "editor")
        XCTAssertEqual(ViewKindID.legacy.rawValue, "legacy")
        XCTAssertEqual(ViewKindID.placeholder.rawValue, "placeholder")
    }

    /// ⌘Z routing depends on this and nothing else (ADR-0031 D7): a
    /// session-bearing pane keeps the chord for its own undo manager.
    func testOnlyEditorKindsAreSessionBearing() {
        let registry = ViewKindRegistry.builtin
        XCTAssertTrue(registry.isSessionBearing(.source))
        XCTAssertTrue(registry.isSessionBearing(.editor))
        for kind: ViewKindID in [.outline, .list, .info, .pdf, .notes, .bibtex, .legacy, .placeholder] {
            XCTAssertFalse(
                registry.isSessionBearing(kind),
                "\(kind.rawValue) claims a session it does not have")
        }
        // An unregistered kind cannot be session-bearing.
        XCTAssertFalse(registry.isSessionBearing(ViewKindID("holodeck")))
    }

    /// A later registration replaces an earlier one, so an app can override a
    /// builtin without editing this package (the `RecordViewerRegistry`
    /// contract, verbatim).
    func testRegistrationReplaces() {
        let registry = ViewKindRegistry([
            ViewKindFactory(kind: .list) { _ in AnyView(EmptyView()) }
        ])
        XCTAssertEqual(registry.registeredKinds, [.list])
        XCTAssertFalse(registry.isSessionBearing(.list))

        registry.register(
            ViewKindFactory(kind: .list, isSessionBearing: true) { _ in AnyView(EmptyView()) })
        XCTAssertEqual(registry.registeredKinds, [.list])
        XCTAssertTrue(registry.isSessionBearing(.list))
    }
}
#endif
