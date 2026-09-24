#if os(macOS)
//
//  ViewKindRegistryTests.swift
//  ImpressLayoutTests
//
//  ADR-0031 L6; plan wave 6, W6. Three properties:
//
//  1. the kit's registry holds EXACTLY `placeholder`, `surface` and
//     `console` — every other view kind is a host's to register
//     (PublicationManagerCore's side
//     of this is `ChassisViewKindsTests`), and a kit that quietly grew a
//     domain factory would no longer be a kit;
//  2. every kind the kit registers resolves to itself;
//  3. an unknown kind resolves to `placeholder` and does NOT throw or return
//     nil. ADR-0031 D4: "a pane whose view kind the platform cannot render
//     becomes a placeholder that keeps its spec", which is what lets a layout
//     built on a richer build survive a round trip through this one.
//
//  `resolvedKind(for:)` is a pure lookup, so neither property needs a view, a
//  store or the FFI.
//

import SwiftUI
import XCTest

@testable import ImpressLayout

final class ViewKindRegistryTests: XCTestCase {

    /// Nothing in this test process registers anything, so the shared
    /// registry is the kit's own.
    func testTheKitRegistersOnlyPlaceholderSurfaceAndConsole() {
        XCTAssertEqual(
            ViewKindRegistry.builtin.registeredKinds, [.placeholder, .surface, .console])
        XCTAssertEqual(Set(ViewKindID.kitBuiltins), [.placeholder, .surface, .console])
    }

    /// A kind the host has not registered — `list` here — renders the
    /// placeholder, which is what makes a bare kit draw a tree at all.
    func testAHostKindTheKitDoesNotRegisterIsAPlaceholder() {
        let registry = ViewKindRegistry.builtin
        for kind: ViewKindID in [
            .outline, .list, .info, .pdf, .notes, .bibtex, .source, .plot, .legacy,
        ] {
            XCTAssertEqual(registry.resolvedKind(for: kind), .placeholder, kind.rawValue)
        }
    }

    func testEveryKitKindResolvesToItself() {
        let registry = ViewKindRegistry.builtin
        for kind in ViewKindID.kitBuiltins {
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
        XCTAssertEqual(ViewKindID.legacy.rawValue, "legacy")
        XCTAssertEqual(ViewKindID.placeholder.rawValue, "placeholder")
        XCTAssertEqual(ViewKindID.surface.rawValue, "surface")
        XCTAssertEqual(ViewKindID.source.rawValue, "source")
        // `crates/impress-layout/src/ids.rs`: `ViewKindId::PLOT` / `CONSOLE`.
        XCTAssertEqual(ViewKindID.plot.rawValue, "plot")
        XCTAssertEqual(ViewKindID.console.rawValue, "console")
    }

    /// ⌘Z routing asks this registry (ADR-0031 D7). The kit's three kinds own
    /// no editor; `source` becomes session-bearing only when a host registers
    /// it so.
    func testTheKitsKindsAreNotSessionBearing() {
        let registry = ViewKindRegistry.builtin
        XCTAssertFalse(registry.isSessionBearing(.placeholder))
        XCTAssertFalse(registry.isSessionBearing(.surface))
        XCTAssertFalse(registry.isSessionBearing(.console))
        XCTAssertFalse(registry.isSessionBearing(.source))
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
