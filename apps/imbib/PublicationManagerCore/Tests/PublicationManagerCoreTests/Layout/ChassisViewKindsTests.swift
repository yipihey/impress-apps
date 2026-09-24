#if os(macOS)
//
//  ChassisViewKindsTests.swift
//  PublicationManagerCoreTests
//
//  Plan wave 6, W6. The layout host moved to `packages/ImpressLayout`, whose
//  registry holds only `placeholder` and `surface` (its own
//  `ViewKindRegistryTests` pin that). This is the chassis' half: after
//  `ChassisViewKinds.registerIfNeeded()` — what `ChassisRootView.init` runs
//  before any pane renders — every view kind of the L8 vocabulary resolves to
//  itself, `source` is the one session-bearing kind (⌘Z routing depends on
//  it, ADR-0031 D7), and an unknown kind still falls back to the placeholder
//  (ADR-0031 D4).
//

import SwiftUI
import XCTest

@testable import PublicationManagerCore

@MainActor
final class ChassisViewKindsTests: XCTestCase {

    override func setUp() async throws {
        ChassisViewKinds.registerIfNeeded()
    }

    private let vocabulary: [ViewKindID] = [
        .outline, .list, .info, .pdf, .notes, .bibtex, .source, .legacy, .placeholder, .surface,
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
            [.outline, .list, .info, .surface, .legacy, .pdf, .notes, .bibtex, .source])
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
        XCTAssertEqual(registry.resolvedKind(for: .placeholder), .placeholder)
    }
}
#endif
