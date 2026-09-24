#if os(macOS)
//
//  ChassisViewKindsTests.swift
//  PublicationManagerCoreTests
//
//  Plan wave 6, W6. The layout host moved to `packages/ImpressLayout`, whose
//  registry holds only `placeholder`, `surface` and `console` (its own
//  `ViewKindRegistryTests` pin that). This is the chassis' half: after
//  `ChassisViewKinds.registerIfNeeded()` — what `ChassisRootView.init` runs
//  before any pane renders — every view kind `impress_layout::ViewKindId`
//  names resolves to itself (`plot` and `console` included: they were the
//  two "unregistered" rows of the capability matrix), `source` is the one
//  session-bearing kind (⌘Z routing depends on it, ADR-0031 D7), and an
//  unknown kind still falls back to the placeholder (ADR-0031 D4).
//

import SwiftUI
import XCTest

@testable import PublicationManagerCore

@MainActor
final class ChassisViewKindsTests: XCTestCase {

    override func setUp() async throws {
        ChassisViewKinds.registerIfNeeded()
    }

    /// Every constant in `crates/impress-layout/src/ids.rs`'s `ViewKindId`,
    /// plus the kit's `surface` (ADR-0033) and imbib's two extra tabs.
    private let vocabulary: [ViewKindID] = [
        .outline, .list, .info, .pdf, .notes, .bibtex, .source, .plot, .console, .legacy,
        .placeholder, .surface,
    ]

    func testEveryViewKindResolvesToItselfOnceTheChassisRegisters() {
        let registry = ViewKindRegistry.builtin
        for kind in vocabulary {
            XCTAssertEqual(
                registry.resolvedKind(for: kind), kind,
                "\(kind.rawValue) has no factory — it would render as a placeholder")
        }
        XCTAssertEqual(registry.registeredKinds, Set(vocabulary))
    }

    func testTheChassisRegistersTheDomainKindsAndOverridesSurface() {
        XCTAssertEqual(
            Set(ChassisViewKinds.kinds),
            [.outline, .list, .info, .surface, .legacy, .pdf, .notes, .bibtex, .source, .plot])
    }

    /// `console` is the kit's (ImpressLogging's `ConsoleView` needs nothing
    /// the chassis has), so the chassis does not re-register it; `plot` is
    /// the chassis' (it reads the figure store).
    func testConsoleIsTheKitsAndPlotIsTheChassis() {
        XCTAssertTrue(ViewKindID.kitBuiltins.contains(.console))
        XCTAssertFalse(ChassisViewKinds.kinds.contains(.console))
        XCTAssertFalse(ViewKindID.kitBuiltins.contains(.plot))
        XCTAssertTrue(ChassisViewKinds.kinds.contains(.plot))
    }

    func testAnUnknownKindStillFallsBackToThePlaceholder() {
        XCTAssertEqual(ViewKindRegistry.builtin.resolvedKind(for: ViewKindID("holodeck")), .placeholder)
    }

    func testOnlyEditorKindsAreSessionBearing() {
        let registry = ViewKindRegistry.builtin
        XCTAssertTrue(registry.isSessionBearing(.source))
        for kind in vocabulary where kind != .source {
            XCTAssertFalse(
                registry.isSessionBearing(kind),
                "\(kind.rawValue) claims a session it does not have")
        }
    }

    /// Registering twice is harmless: `ChassisRootView.init` runs once per
    /// window, and a second window must not change the registry.
    func testRegistrationIsIdempotent() {
        let before = ViewKindRegistry.builtin.registeredKinds
        ChassisViewKinds.registerIfNeeded()
        XCTAssertEqual(ViewKindRegistry.builtin.registeredKinds, before)
    }

    /// A private registry gets the same kinds — the path a host that keeps
    /// its own registry (a test, a second shell) takes.
    func testRegisteringIntoAFreshRegistry() {
        let registry = ViewKindRegistry()
        ChassisViewKinds.registerIfNeeded(into: registry)
        XCTAssertEqual(registry.registeredKinds, Set(ChassisViewKinds.kinds))
        // A fresh registry has no kit kinds, so `console` is a placeholder
        // there and `placeholder` resolves by fallback, not by factory.
        XCTAssertEqual(registry.resolvedKind(for: .placeholder), .placeholder)
        XCTAssertEqual(registry.resolvedKind(for: .console), .placeholder)
        XCTAssertEqual(registry.resolvedKind(for: .plot), .plot)
    }
}
#endif
