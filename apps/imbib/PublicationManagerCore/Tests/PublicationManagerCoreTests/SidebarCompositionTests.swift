//
//  SidebarCompositionTests.swift
//  PublicationManagerCoreTests
//
//  impress's sidebar is the five sibling presets rendered as groups (I3). The
//  data half of that is `SidebarComposition` + `RecordSidebarBuilder.groups`,
//  which is pure value code — so the interesting half, including the exact
//  regression the user reported, is testable here in `swift test` rather than
//  only in a simulator screenshot.
//
//  The user's report, verbatim: "It's quite hit and miss with impress …
//  Imprint has its own collections for manuscripts. Impart has its own for
//  messages and all have flagged pubs, manuscripts or messages." The last
//  clause is `testEachGroupsFlaggedSectionListsThatAppsOwnKind` — under the FLAT
//  preset there was exactly one Flagged section bound to `.publication`, so
//  flagged manuscripts had no row in impress at all.
//

import ImpressKit
import XCTest
@testable import PublicationManagerCore

@MainActor
final class SidebarCompositionTests: XCTestCase {

    // MARK: - Helpers

    private func dataSource(
        folders: [RecordFolder] = [],
        available: @escaping (SidebarSectionType) -> Bool = { _ in true }
    ) -> RecordSidebarDataSource {
        RecordSidebarDataSource(
            folders: { _ in folders },
            folderCounts: { _, ids in ids.map { _ in 1 } },
            count: { _ in nil },
            sectionIsAvailable: available)
    }

    private func groups(
        host: AppShellConfiguration = .impress,
        dataSource source: RecordSidebarDataSource? = nil
    ) -> [RecordSidebarGroupModel] {
        RecordSidebarBuilder.groups(
            composition: .impress,
            host: host,
            dataSource: source ?? dataSource())
    }

    // MARK: - The composition IS the five presets

    /// Every group carries the app's SHIPPING preset by identity. This is the
    /// whole claim: impress's sidebar is not a description of the other five,
    /// it is the same values they run on.
    func testEveryGroupCarriesItsAppsShippingPresetUnmodified() {
        let expected: [(String, AppShellConfiguration)] = [
            ("imbib", .imbib),
            ("imprint", .imprint),
            ("implore", .implore),
            ("impel", .impel),
            ("impart", .impart),
        ]
        XCTAssertEqual(SidebarComposition.impress.groups.count, expected.count)
        for (id, preset) in expected {
            guard let group = SidebarComposition.impress[id] else {
                return XCTFail("no \(id) group")
            }
            XCTAssertEqual(
                group.configuration, preset,
                "\(id)'s group must BE its preset, not a copy that can drift from it")
        }
    }

    /// Order, titles and glyphs are lookups into `SiblingApp.descriptors` — the
    /// one table — never literals here.
    func testOrderTitlesAndGlyphsComeFromTheSiblingTable() {
        let composed = SidebarComposition.impress
        // impress itself contributes no group: it owns no domain.
        let expectedOrder = SiblingApp.descriptors.map(\.id)
            .filter { $0 != .impress }
            .map(\.rawValue)
        XCTAssertEqual(composed.appIDs, expectedOrder)
        XCTAssertEqual(composed.appIDs, ["imbib", "imprint", "implore", "impel", "impart"])

        for group in composed.groups {
            guard let app = SiblingApp(rawValue: group.id) else {
                return XCTFail("group id \(group.id) is not a SiblingApp")
            }
            XCTAssertEqual(group.title, app.displayName)
            XCTAssertEqual(group.systemImage, app.systemImage)
            XCTAssertFalse(group.systemImage.isEmpty)
        }
    }

    /// The composed shell is not a group of itself.
    func testTheComposedShellIsNotOneOfItsOwnGroups() {
        XCTAssertNil(SidebarComposition.impress["impress"])
        XCTAssertNil(SidebarComposition.preset(for: .impress))
    }

    // MARK: - Each group is that app's sidebar, verbatim

    /// A group's sections are EXACTLY what the app's own shell renders. Proven
    /// by building both ways and comparing, so this cannot drift into a
    /// hand-maintained list of what each app "has".
    func testEachGroupsSectionsAreExactlyWhatThatAppsOwnShellBuilds() {
        let source = dataSource()
        for group in SidebarComposition.impress.groups {
            let standalone = RecordSidebarBuilder.sections(
                configuration: group.configuration, dataSource: source)
            let composed = groups(dataSource: source)[groupID: group.id]?.sections ?? []
            XCTAssertEqual(
                composed.map(\.section), standalone.map(\.section),
                "\(group.id)'s group must render \(group.id)'s sidebar")
            XCTAssertEqual(
                composed.map(\.kind), standalone.map(\.kind),
                "\(group.id)'s per-section kind bindings must survive composition")
        }
    }

    /// The user's own inventory of what each app owns.
    func testTheGroupsCarryTheSectionsTheUserNamed() {
        let built = groups()
        // "Libraries and collections and the Inbox is for imbib."
        let imbib = built[groupID: "imbib"]
        XCTAssertNotNil(imbib?.section(.inbox))
        XCTAssertNotNil(imbib?.section(.libraries))
        // "Imprint has its own collections for manuscripts."
        let imprint = built[groupID: "imprint"]
        XCTAssertNotNil(imprint?.section(.manuscripts))
        XCTAssertEqual(imprint?.section(.manuscripts)?.kind, .manuscript)
        XCTAssertNil(imprint?.section(.libraries), "Libraries is imbib's, not imprint's")
        // "Impart has its own for messages."
        let impart = built[groupID: "impart"]
        XCTAssertEqual(impart?.sections.map(\.section), [.mail])
        XCTAssertEqual(impart?.section(.mail)?.kind, .message)
        // implore / impel round out the five.
        XCTAssertEqual(built[groupID: "implore"]?.sections.map(\.section), [.figures])
        XCTAssertEqual(built[groupID: "impel"]?.sections.map(\.section), [.agents])
    }

    // MARK: - THE regression: per-group Flagged

    /// "all have flagged pubs, manuscripts or messages."
    ///
    /// A group's Flagged section binds the kind ITS preset binds. This is what
    /// the flat union could not express — `sectionBindings` maps a section to
    /// ONE kind, so flat impress's single `.flagged` was `.publication` and
    /// flagged manuscripts were unreachable.
    func testEachGroupsFlaggedSectionListsThatAppsOwnKind() {
        let built = groups()

        guard let imbibFlagged = built[groupID: "imbib"]?.section(.flagged),
              let imprintFlagged = built[groupID: "imprint"]?.section(.flagged)
        else { return XCTFail("both imbib and imprint declare a Flagged section") }

        XCTAssertEqual(imbibFlagged.kind, .publication)
        XCTAssertEqual(imprintFlagged.kind, .manuscript)

        // Down to the ROW: what a tap actually selects.
        XCTAssertEqual(
            imbibFlagged.nodes.map(\.scope),
            FlagColor.allCases.map { RecordSidebarScope.flagged(.publication, $0.rawValue) })
        XCTAssertEqual(
            imprintFlagged.nodes.map(\.scope),
            FlagColor.allCases.map { RecordSidebarScope.flagged(.manuscript, $0.rawValue) })

        // And the routing those scopes reach: the imprint group's red flag row
        // resolves to a MANUSCRIPT list, the imbib group's to a publication one.
        XCTAssertEqual(
            ManuscriptListScope(routeScope: imprintFlagged.nodes[0].scope), .flagged(.red))
        XCTAssertNil(
            ManuscriptListScope(routeScope: imbibFlagged.nodes[0].scope),
            "a publication flag scope must not resolve to a manuscript list")
    }

    /// The same split for Dismissed, whose two groups differ in SEMANTICS as
    /// well as kind: publications dismiss by library move, manuscripts by
    /// status change, and each group gets its own kind's answer.
    func testEachGroupsDismissedSectionUsesItsOwnKindsDismissalSemantics() {
        let built = groups()
        XCTAssertEqual(
            built[groupID: "imbib"]?.section(.dismissed)?.nodes.first?.scope,
            .section(.dismissed, .publication))
        XCTAssertEqual(
            built[groupID: "imprint"]?.section(.dismissed)?.nodes.first?.scope,
            .status(.manuscript, "dismissed"))
    }

    /// Duplication across groups is the DESIGN, not a leak: two apps genuinely
    /// declare Cited in Manuscripts, so it renders under both. The renderer
    /// namespaces the rows by group precisely because the scope does not.
    func testASectionTwoAppsDeclareRendersInBothGroups() {
        let built = groups()
        XCTAssertNotNil(built[groupID: "imbib"]?.section(.citedInManuscripts))
        XCTAssertNotNil(built[groupID: "imprint"]?.section(.citedInManuscripts))
        XCTAssertEqual(
            built[groupID: "imbib"]?.section(.citedInManuscripts)?.nodes.first?.scope,
            built[groupID: "imprint"]?.section(.citedInManuscripts)?.nodes.first?.scope,
            "same scope in both groups — two doors, one destination")
    }

    // MARK: - Host gates

    /// The HOST's `presentableKinds` narrows every group, once. impress-iOS
    /// has no artifact pane, so imbib's Artifacts section leaves the imbib
    /// group — by KIND, with no section name anywhere in the gate.
    func testHostPresentableKindsNarrowEveryGroup() {
        let iOSKinds: Set<RecordKindID> = [.message, .figure, .task, .publication, .manuscript]
        let built = groups(host: AppShellConfiguration.impress.presenting(iOSKinds))
        XCTAssertNil(
            built[groupID: "imbib"]?.section(.artifacts),
            ".artifacts binds .artifact, which this host cannot present")
        XCTAssertNotNil(built[groupID: "imbib"]?.section(.libraries))
        XCTAssertNotNil(built[groupID: "imprint"]?.section(.manuscripts))

        // And a host that narrows nothing keeps it.
        XCTAssertNotNil(groups()[groupID: "imbib"]?.section(.artifacts))
    }

    /// The host's CONTENT gate applies inside every group, exactly as it does
    /// in the flat sidebar.
    func testHostContentGateAppliesWithinEveryGroup() {
        let built = groups(dataSource: dataSource(available: { $0 != .flagged }))
        XCTAssertNil(built[groupID: "imbib"]?.section(.flagged))
        XCTAssertNil(built[groupID: "imprint"]?.section(.flagged))
        XCTAssertNotNil(built[groupID: "imbib"]?.section(.inbox))
    }

    /// A group whose every section gates away is KEPT, with no sections. The
    /// user asked to collate the five sidebars; an app with nothing in it right
    /// now is a fact about the store, not a reason to hide the app.
    func testAGroupWithNoSurvivingSectionsIsKeptRatherThanDropped() {
        let built = groups(dataSource: dataSource(available: { $0 != .agents }))
        guard let impel = built[groupID: "impel"] else {
            return XCTFail("the impel group must still be present")
        }
        XCTAssertTrue(impel.sections.isEmpty)
        XCTAssertEqual(impel.title, "impel")
        XCTAssertEqual(built.count, 5, "no group is ever dropped")
    }

    // MARK: - The flat preset is untouched

    /// `.impress` stays exactly what the parity tests freeze. The composition
    /// is a NEW value beside it, not an edit to it — macOS still runs the flat
    /// preset, and `AppShellConfigurationParityTests` is still the oracle.
    func testTheFlatImpressPresetIsUnchangedByTheComposition() {
        XCTAssertEqual(
            AppShellConfiguration.impress.visibleSections, Set(SidebarSectionType.allCases))
        XCTAssertEqual(AppShellConfiguration.impress.sectionBindings[.flagged], .publication)
        XCTAssertNil(AppShellConfiguration.impress.presentableKinds)
        // And the flat build still produces the flat sidebar.
        let flat = RecordSidebarBuilder.sections(
            configuration: .impress, dataSource: dataSource())
        XCTAssertEqual(
            flat.filter { $0.section == .flagged }.count, 1,
            "the flat sidebar has exactly ONE Flagged section — which is the limitation "
                + "the composition exists to lift, and the reason it is a separate value")
    }

    /// Composing changes nothing for a shell that does not compose. The five
    /// sibling apps pass a single preset and get byte-identical sections.
    func testSiblingShellsAreUnaffectedByTheCompositionExisting() {
        let source = dataSource()
        for preset in [
            AppShellConfiguration.imbib, .imprint, .implore, .impel, .impart,
        ] {
            let sections = RecordSidebarBuilder.sections(
                configuration: preset, dataSource: source)
            XCTAssertFalse(
                sections.isEmpty, "\(preset.appID) still builds its own flat sidebar")
            XCTAssertNil(
                preset.presentableKinds,
                "\(preset.appID)'s preset must not have acquired a host narrowing")
        }
    }

    // MARK: - Only impress composes

    /// The three sibling iOS shells pass a single preset, and must keep doing
    /// so. A behavioural test cannot prove this — PMC's bundle cannot link an
    /// app target — so it is asserted on the SOURCE, the same instrument
    /// `ChassisCrossPlatformContractTests` uses for "nobody re-gated this file".
    ///
    /// It matters because grouping changes every accessibility identifier in a
    /// sidebar (`sidebar.node.<app>.<scope>` instead of `sidebar.node.<scope>`).
    /// A sibling that quietly adopted the composed init would break its own UI
    /// suite for a reason no one would look for in this chassis.
    func testOnlyImpressUsesTheComposedSidebarInit() throws {
        let hosts = [
            "apps/imbib/imbib/imbib-iOS/Views/IOSSidebarHost.swift",
            "apps/imprint/imprint-iOS/Views/IOSManuscriptLibraryView.swift",
            "apps/impart/impart-iOS/Views/IOSMailHostView.swift",
        ]
        for host in hosts {
            let source = try ChassisSourceRoots.repoText(of: host)
            XCTAssertTrue(
                source.contains("RecordSidebarView("),
                "\(host) should still render the chassis sidebar")
            XCTAssertFalse(
                source.contains("composition:"),
                "\(host) must keep passing ONE preset: grouping renames every row identifier "
                    + "its UI suite matches on, and this app has no groups to show")
        }
        let impress = try ChassisSourceRoots.repoText(
            of: "apps/impress/impress-iOS/Views/IOSImpressHostView.swift")
        XCTAssertTrue(
            impress.contains("composition: .impress"),
            "impress-iOS is the one shell that composes")
    }

    // MARK: - Persistence keys

    /// The two collapsible levels get distinct keys, and a section key carries
    /// its group — otherwise collapsing imbib's Flagged would collapse
    /// imprint's, which is the exact confusion the composition removes.
    func testCompositionKeysDistinguishGroupsAndPerGroupSections() {
        XCTAssertNotEqual(
            SidebarCompositionKey.section("imbib", .flagged),
            SidebarCompositionKey.section("imprint", .flagged))
        XCTAssertNotEqual(
            SidebarCompositionKey.group("imbib"),
            SidebarCompositionKey.section("imbib", .flagged))
        XCTAssertEqual(SidebarCompositionKey.group("imbib").rawValue, "group:imbib")
        XCTAssertEqual(
            SidebarCompositionKey.section("imprint", .flagged).rawValue,
            "section:imprint:flagged")
        // Round-trips through the persisted representation.
        let keys: Set<SidebarCompositionKey> = [
            .group("impel"), .section("imbib", .libraries),
        ]
        let data = try? JSONEncoder().encode(keys)
        XCTAssertNotNil(data)
        XCTAssertEqual(
            data.flatMap { try? JSONDecoder().decode(Set<SidebarCompositionKey>.self, from: $0) },
            keys)
    }
}
