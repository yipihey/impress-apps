//
//  ShippedSectionBindingsTests.swift
//  PublicationManagerCoreTests
//
//  Plan wave 6 W5 moved the shipped presets' `sectionBindings` into Rust
//  (`impress_layout_service::section_bindings`). These are the literal tables
//  the six presets carried before the move, so the move is proven to change
//  nothing any shell reads.
//

import XCTest

@testable import PublicationManagerCore

final class ShippedSectionBindingsTests: XCTestCase {

    func testTheShippedPresetsReadExactlyTheTablesTheyUsedToCarry() {
        XCTAssertEqual(
            AppShellConfiguration.imbib.sectionBindings,
            [.flagged: .publication, .tags: .publication, .dismissed: .publication])
        XCTAssertEqual(
            AppShellConfiguration.imprint.sectionBindings,
            [.flagged: .manuscript, .tags: .manuscript, .dismissed: .manuscript])
        XCTAssertEqual(AppShellConfiguration.implore.sectionBindings, [.tags: .figure])
        XCTAssertEqual(AppShellConfiguration.impart.sectionBindings, [.tags: .message])
        XCTAssertEqual(AppShellConfiguration.impel.sectionBindings, [.tags: .task])
        XCTAssertEqual(
            AppShellConfiguration.impress.sectionBindings,
            [
                .inbox: .publication,
                .libraries: .publication,
                .sharedWithMe: .publication,
                .scixLibraries: .publication,
                .search: .publication,
                .exploration: .publication,
                .flagged: .publication,
                .tags: .publication,
                .citedInManuscripts: .publication,
                .artifacts: .artifact,
                .manuscripts: .manuscript,
                .figures: .figure,
                .mail: .message,
                .agents: .task,
                .dismissed: .publication,
            ])
    }

    /// `manuscripts` is the case name Rust spells; its raw value is `journal`.
    /// Decoding by raw value would silently drop impress's manuscript binding.
    func testSectionsAreMatchedByCaseNameNotRawValue() {
        XCTAssertEqual(SidebarSectionType.manuscripts.rawValue == "manuscripts", false)
        XCTAssertEqual(ShippedSectionBindings.of("impress")[.manuscripts], .manuscript)
    }

    func testAnAppRustShipsNothingForBindsNothing() {
        XCTAssertEqual(ShippedSectionBindings.of("no-such-app"), [:])
    }
}
