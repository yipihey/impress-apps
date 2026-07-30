//
//  HostPresentableKindsTests.swift
//  PublicationManagerCoreTests
//
//  `AppShellConfiguration.presentableKinds` — the host capability that
//  replaced imprint-iOS's `section != .citedInManuscripts` literal.
//
//  The two things worth proving: it does what the literal did, and it does
//  NOTHING to any shipping preset (all of which leave it nil).
//

import XCTest
@testable import PublicationManagerCore

@MainActor
final class HostPresentableKindsTests: XCTestCase {

    private func dataSource() -> RecordSidebarDataSource {
        RecordSidebarDataSource(
            folders: { _ in [] },
            folderCounts: { _, ids in ids.map { _ in 0 } },
            count: { _ in nil },
            sectionIsAvailable: { _ in true })
    }

    private func sectionIDs(_ configuration: AppShellConfiguration) -> [SidebarSectionType] {
        RecordSidebarBuilder.sections(configuration: configuration, dataSource: dataSource())
            .map(\.section)
    }

    // MARK: - The replacement

    /// imprint-iOS's actual configuration. `.citedInManuscripts` resolves to
    /// `.publication` through the canonical section→kind table, and this host
    /// has no publication surface, so the section disappears — which is exactly
    /// what the hardcoded section name used to accomplish.
    func testHostThatCannotPresentAKindDropsThatKindsSections() {
        let iOSHost = AppShellConfiguration.imprint.presenting([.manuscript])
        let sections = sectionIDs(iOSHost)

        XCTAssertFalse(
            sections.contains(.citedInManuscripts),
            "a host with no publication surface must not offer a section whose rows "
                + "are publications")
        for manuscriptSection in [SidebarSectionType.manuscripts, .flagged, .dismissed] {
            XCTAssertTrue(
                sections.contains(manuscriptSection),
                "manuscript-bound sections must survive: \(manuscriptSection.rawValue)")
        }
    }

    /// The capability is about KINDS, not about section names: the same
    /// declaration drops any future publication-bound section with no further
    /// edit. Demonstrated on the preset that has the most of them.
    func testCapabilityGeneralisesBeyondTheOneSectionItReplaced() {
        let manuscriptsOnly = AppShellConfiguration.impress.presenting([.manuscript])
        let sections = sectionIDs(manuscriptsOnly)

        for publicationSection in [
            SidebarSectionType.inbox, .libraries, .sharedWithMe, .scixLibraries,
            .search, .exploration, .citedInManuscripts,
        ] {
            XCTAssertFalse(
                sections.contains(publicationSection),
                "\(publicationSection.rawValue) is publication-bound and must drop")
        }
        XCTAssertTrue(sections.contains(.manuscripts))
        // Unbound sections are unaffected — they have no kind to be incapable
        // of. `.reviewQueue`'s rows are review-request items with no descriptor.
        XCTAssertTrue(
            sections.contains(.reviewQueue),
            "an UNBOUND section has no kind, so the kind capability cannot hide it")
    }

    // MARK: - No shipping preset changes

    /// The macOS no-change proof at unit level: every shipped preset leaves
    /// `presentableKinds` nil, so `canPresent` is universally true and the
    /// builder behaves exactly as before the field existed.
    func testEveryShippedPresetPresentsEveryKind() {
        let presets: [AppShellConfiguration] = [
            .imbib, .imprint, .implore, .impart, .impel, .impress,
        ]
        for preset in presets {
            XCTAssertNil(
                preset.presentableKinds,
                "\(preset.appID) declares presentableKinds — that is a HOST decision "
                    + "applied with presenting(_:) at the app root, not a preset one: "
                    + "the same preset serves macOS and iOS, which differ")
            for descriptor in preset.recordKinds.descriptors {
                XCTAssertTrue(
                    preset.canPresent(descriptor.id),
                    "\(preset.appID) must present every kind it registers")
            }
        }
    }

    /// `presenting(_:)` must preserve everything else about the preset —
    /// a copy modifier that dropped `sectionBindings` or `openOverrides` would
    /// silently re-home sections or change what double-click does.
    func testPresentingPreservesTheRestOfThePreset() {
        let base = AppShellConfiguration.imprint
        let host = base.presenting([.manuscript])

        XCTAssertEqual(host.appID, base.appID)
        XCTAssertEqual(host.visibleSections, base.visibleSections)
        XCTAssertEqual(host.defaultSection, base.defaultSection)
        XCTAssertEqual(host.defaultDetailTab, base.defaultDetailTab)
        XCTAssertEqual(host.sectionBindings, base.sectionBindings)
        XCTAssertEqual(host.auxiliaryRoutes, base.auxiliaryRoutes)
        XCTAssertEqual(host.openOverrides, base.openOverrides)
        XCTAssertEqual(
            host.recordKinds.descriptors.map(\.id), base.recordKinds.descriptors.map(\.id))
        XCTAssertNotEqual(host, base, "the capability must participate in equality")
    }

    /// It composes with the surfaces modifier in either order — hosts apply
    /// both at their root.
    func testPresentingComposesWithCustomSurfaces() {
        let host = AppShellConfiguration.imprint
            .presenting([.manuscript])
            .withCustomSurfaces([])
        XCTAssertEqual(host.presentableKinds, [.manuscript],
                       "withCustomSurfaces must not drop the kind capability")
    }

    // MARK: - Relationship to the other gates

    /// The four gates are orthogonal and all must pass. In particular the
    /// facet gate is NOT subsumed: implore can present figures, and still must
    /// not surface `.mail` — that is suite policy keyed on appID, not a
    /// statement about implore's rendering ability.
    func testKindCapabilityComplementsRatherThanReplacesTheFacetGate() {
        let implore = AppShellConfiguration.implore
        XCTAssertTrue(implore.canPresent(.figure))
        XCTAssertFalse(
            implore.passesFacetGate(.mail),
            "the facet gate is a separate, appID-keyed policy")
        XCTAssertTrue(
            AppShellConfiguration.impress.passesFacetGate(.mail),
            "and it is a SET, so impress legitimately hosts mail")

        // A host can be capable of a kind whose section the preset still
        // forbids: capability does not grant visibility.
        let host = AppShellConfiguration.imprint.presenting([.manuscript, .figure])
        XCTAssertTrue(host.canPresent(.figure))
        XCTAssertFalse(host.permits(.figures),
                       "presentableKinds never widens what a preset permits")
        XCTAssertFalse(sectionIDs(host).contains(.figures))
    }
}
