//
//  AppShellConfigurationParityTests.swift
//  PublicationManagerCoreTests
//
//  S1-WP2 regression oracle: the v2 declarative fields must derive EXACTLY
//  the frozen Boolean truth table in docs/chassis-capability-matrix.md
//  ("Frozen shell-preset truth table"). If a preset edit changes a derived
//  value, that is a deliberate behavior change and the matrix must move too.
//

import XCTest
@testable import PublicationManagerCore

#if os(macOS)
final class AppShellConfigurationParityTests: XCTestCase {

    func testImbibPresetMatchesFrozenTruthTable() {
        let c = AppShellConfiguration.imbib
        XCTAssertTrue(c.auxiliaryRoutes.contains(.submissionsInbox))
        XCTAssertNotEqual(c.recordKind(for: .flagged), .manuscript)
        XCTAssertNotEqual(c.recordKind(for: .dismissed), .manuscript)
        XCTAssertEqual(c.openBehavior(for: .manuscript), .appHandoff)
        XCTAssertEqual(c.defaultSection, .inbox)
        XCTAssertEqual(c.defaultDetailTab, .info)
    }

    /// Publications-only purification: imbib's `visibleSections` is EXPLICIT.
    /// It used to be `nil` ("no restriction"), which opted imbib into every
    /// section the chassis ever grows. Purity is the policy now (ADR-0022 D9):
    /// imbib is the bibliography facet; manuscripts belong to imprint,
    /// figures to implore, mail to impart, tasks/runs to impel, and `impress`
    /// will unify them. A future section must opt IN here, deliberately.
    func testImbibPermitsOnlyPublicationSections() {
        let c = AppShellConfiguration.imbib
        XCTAssertEqual(
            c.visibleSections,
            [
                .inbox, .libraries, .sharedWithMe, .scixLibraries, .search,
                .exploration, .flagged, .citedInManuscripts, .artifacts,
                .reviewQueue, .dismissed,
            ],
            "imbib surfaces publication-centric sections only"
        )

        // Other kinds' surfaces are NOT permitted — their chassis code stays
        // (imprint/implore/impart/impel run on it), only imbib's surfacing is
        // withdrawn.
        XCTAssertFalse(c.permits(.manuscripts), "manuscripts are imprint's facet")
        XCTAssertFalse(c.permits(.figures), "figures are implore's facet")
        XCTAssertFalse(c.permits(.mail), "mail is impart's facet")
        XCTAssertFalse(c.permits(.agents), "agents are impel's facet")

        // Kept deliberately: "Cited in Manuscripts" lists PUBLICATIONS ("All
        // Cited Papers") and is imbib's half of the imprint bridge; Search is
        // imbib-only (see testOnlyImbibPermitsSearchSection); Dismissed is
        // publication-bound here and is where the dismiss gesture lands.
        XCTAssertTrue(c.permits(.citedInManuscripts))
        XCTAssertTrue(c.permits(.search))
        XCTAssertTrue(c.permits(.dismissed))
        XCTAssertNotEqual(c.recordKind(for: .dismissed), .manuscript)

        // The Submissions inbox route is retained but currently unreachable —
        // it hung off the Manuscripts section. See the matrix's Known gaps.
        XCTAssertTrue(c.auxiliaryRoutes.contains(.submissionsInbox))
        XCTAssertFalse(c.permits(.manuscripts))
    }

    /// No preset leaves `visibleSections` nil any more: an unlisted section
    /// must be invisible everywhere until a preset opts in. `impress` is in
    /// this list on purpose — it wants EVERY section, and it still says so
    /// explicitly rather than opting in by omission (ADR-0022 D9). `nil` stays
    /// supported for test shells only.
    func testNoShippingPresetPermitsEverything() {
        for c in [
            AppShellConfiguration.imbib, .imprint, .implore, .impart, .impel,
            .impress,
        ] {
            XCTAssertNotNil(c.visibleSections, "\(c.appID) must be explicit")
        }
    }

    func testImprintPresetMatchesFrozenTruthTable() {
        let c = AppShellConfiguration.imprint
        XCTAssertFalse(c.auxiliaryRoutes.contains(.submissionsInbox))
        XCTAssertEqual(c.recordKind(for: .flagged), .manuscript)
        XCTAssertEqual(c.recordKind(for: .dismissed), .manuscript)
        XCTAssertEqual(c.openBehavior(for: .manuscript), .window(id: "manuscript-editor"))
        XCTAssertEqual(
            c.visibleSections,
            [.manuscripts, .citedInManuscripts, .flagged, .dismissed]
        )
        XCTAssertEqual(c.defaultSection, .manuscripts)
        XCTAssertEqual(c.defaultDetailTab, .source)
    }

    /// Stage 2-B: the Figures section must never surface in imbib or imprint.
    /// BOTH are now excluded by visibleSections (imbib's set became explicit
    /// with the publications-only purification); the sidebar's pragmatic
    /// appID gate in `shouldShowSection(.figures)` remains as belt-and-braces
    /// for any shell that leaves visibleSections nil.
    func testFiguresSectionHiddenOutsideImplore() {
        XCTAssertFalse(AppShellConfiguration.imprint.permits(.figures))
        XCTAssertFalse(AppShellConfiguration.imbib.permits(.figures))
        XCTAssertNotEqual(AppShellConfiguration.imbib.appID, "implore")
        XCTAssertNotEqual(AppShellConfiguration.imprint.appID, "implore")
        XCTAssertEqual(AppShellConfiguration.implore.appID, "implore")
    }

    /// Only imbib may boot the external-search credential path: the ADS/SciX
    /// keychain items are ACL'd to imbib's code signature, so any sibling
    /// shell that permits `.search` would stall its launch on a SecurityAgent
    /// password prompt (TabContentView gates the credential read on this).
    ///
    /// `impress` is deliberately NOT in this list: it permits `.search` by
    /// design and therefore inherits a signing requirement — see
    /// `testImpressPermitsSearchWhichImpliesTheKeychainRequirement`. It ships
    /// no target, so it stalls no launch today.
    func testOnlyImbibPermitsSearchSection() {
        XCTAssertTrue(AppShellConfiguration.imbib.permits(.search))
        XCTAssertFalse(AppShellConfiguration.imprint.permits(.search))
        XCTAssertFalse(AppShellConfiguration.implore.permits(.search))
        XCTAssertFalse(AppShellConfiguration.impart.permits(.search))
        XCTAssertFalse(AppShellConfiguration.impel.permits(.search))
    }

    // MARK: - impress (ADR-0022 D9): proven, not shipped
    //
    // No app target ships `AppShellConfiguration.impress`. These tests ARE its
    // reason to exist: they freeze the seams the future app stands on, so a
    // chassis change that would quietly make impress impossible fails here
    // instead of surfacing a year from now.

    /// The frozen impress truth table.
    func testImpressPresetMatchesFrozenTruthTable() {
        let c = AppShellConfiguration.impress
        XCTAssertEqual(c.appID, "impress")
        XCTAssertEqual(c.defaultSection, .inbox)
        XCTAssertEqual(c.defaultDetailTab, .info)

        // The Submissions inbox's designated future home — it is unreachable
        // in imbib since the publications-only purification (matrix Known
        // gaps) and this preset is where it lands.
        XCTAssertTrue(c.auxiliaryRoutes.contains(.submissionsInbox))

        // Every kind the chassis ships, not a subset.
        XCTAssertEqual(
            Set(c.recordKinds.descriptors.map(\.id)),
            Set(BuiltinRecordKinds.all.map(\.id)),
            "impress must know every builtin record kind")

        // Bindings, frozen.
        XCTAssertEqual(c.recordKind(for: .manuscripts), .manuscript)
        XCTAssertEqual(c.recordKind(for: .figures), .figure)
        XCTAssertEqual(c.recordKind(for: .mail), .message)
        XCTAssertEqual(c.recordKind(for: .agents), .task)
        XCTAssertEqual(c.recordKind(for: .artifacts), .artifact)
        XCTAssertEqual(c.recordKind(for: .inbox), .publication)
        // The two cross-kind sections stay publication-bound: a single
        // RecordKindID cannot express "flagged records of every kind", and
        // `.publication` reproduces imbib's routing while keeping imprint's
        // manuscript-only path (`== .manuscript`) off. Mixed-kind Flagged is a
        // follow-up over AnyRecordListWrapper, not a preset edit.
        XCTAssertEqual(c.recordKind(for: .flagged), .publication)
        XCTAssertEqual(c.recordKind(for: .dismissed), .publication)
        XCTAssertNotEqual(c.recordKind(for: .flagged), .manuscript)
        XCTAssertNotEqual(c.recordKind(for: .dismissed), .manuscript)

        // Builtin surfaces are not the preset's choice, so it registers none
        // of its own (the store-search builtin still arrives — see
        // StoreSearchSurfaceTests).
        XCTAssertTrue(c.customSurfaces.appSurfaces.isEmpty)
    }

    /// EXPLICIT means explicit: impress lists every section rather than using
    /// `nil`. When the enum grows, this fails until someone decides whether
    /// the unifying shell wants the new section — which is the entire point of
    /// retiring `nil`.
    func testImpressPermitsEverySection() {
        let c = AppShellConfiguration.impress
        XCTAssertNotNil(c.visibleSections)
        XCTAssertEqual(
            c.visibleSections, Set(SidebarSectionType.allCases),
            "impress must list every section explicitly; nil is retired")
        for section in SidebarSectionType.allCases {
            XCTAssertTrue(c.permits(section), "impress must permit .\(section.rawValue)")
        }
        // The four kind sections the siblings own, spelled out — these are the
        // ones a regression would silently drop.
        XCTAssertTrue(c.permits(.manuscripts))
        XCTAssertTrue(c.permits(.figures))
        XCTAssertTrue(c.permits(.mail))
        XCTAssertTrue(c.permits(.agents))
    }

    /// Every permitted section that lists records names its kind. `.reviewQueue`
    /// is the one deliberate exception: its rows are `review-request@1.0.0`
    /// items, which have no `RecordKindDescriptor` — binding it to a kind it
    /// does not list would be a lie a future reader trusts.
    func testImpressBindsEverySectionThatListsRecords() {
        let c = AppShellConfiguration.impress
        for section in SidebarSectionType.allCases where section != .reviewQueue {
            XCTAssertNotNil(
                c.recordKind(for: section),
                "impress has no sectionBinding for .\(section.rawValue)")
        }
        XCTAssertNil(
            c.recordKind(for: .reviewQueue),
            "review requests are not a record kind; bind this when a descriptor lands")
    }

    /// No record kind is homeless in impress — except `agent-run`, which
    /// shares the Agents section with `task` by design (one `AgentSectionView`,
    /// the scope decides which schema it lists), so it can never be a
    /// `sectionBindings` VALUE.
    func testImpressGivesEveryRecordKindASection() {
        let c = AppShellConfiguration.impress
        let bound = Set(c.sectionBindings.values)
        XCTAssertEqual(
            bound.union([.agentRun]),
            Set(BuiltinRecordKinds.all.map(\.id)),
            "a record kind with no section in impress is a kind impress cannot show")
        XCTAssertFalse(
            bound.contains(.agentRun),
            "runs are a child of the Agents section, not a section of their own")
    }

    /// The pragmatic app-ID gates (`shouldShowSection` for figures/mail/agents)
    /// must permit BOTH the owning app and impress. They were `appID ==` tests,
    /// which would have let impress permit these sections in its preset and
    /// still never show them — visibility is the intersection of the two.
    func testFacetGatesPermitTheOwnerAndImpress() {
        for (section, owner) in [
            (SidebarSectionType.figures, "implore"),
            (.mail, "impart"),
            (.agents, "impel"),
        ] {
            XCTAssertEqual(
                AppShellConfiguration.facetOwnerAppIDs(for: section),
                [owner, "impress"],
                ".\(section.rawValue) must be owned by \(owner) AND impress")
        }
        // No gate on the non-facet sections.
        XCTAssertNil(AppShellConfiguration.facetOwnerAppIDs(for: .inbox))
        XCTAssertNil(AppShellConfiguration.facetOwnerAppIDs(for: .manuscripts))

        // impress permits AND passes the gate — both halves, for all three.
        let impress = AppShellConfiguration.impress
        for section in [SidebarSectionType.figures, .mail, .agents] {
            XCTAssertTrue(impress.permits(section))
            XCTAssertTrue(impress.passesFacetGate(section))
        }
        // The owners still pass their own gate and no other.
        XCTAssertTrue(AppShellConfiguration.implore.passesFacetGate(.figures))
        XCTAssertFalse(AppShellConfiguration.implore.passesFacetGate(.mail))
        XCTAssertTrue(AppShellConfiguration.impart.passesFacetGate(.mail))
        XCTAssertTrue(AppShellConfiguration.impel.passesFacetGate(.agents))

        // imbib is unaffected: it fails the gate AND, more importantly, is
        // excluded by visibleSections — the purification is what hides these,
        // the gate is belt-and-braces.
        for section in [SidebarSectionType.figures, .mail, .agents] {
            XCTAssertFalse(AppShellConfiguration.imbib.permits(section))
            XCTAssertFalse(AppShellConfiguration.imbib.passesFacetGate(section))
            XCTAssertFalse(AppShellConfiguration.imprint.permits(section))
        }
    }

    /// impress embeds every viewer, so it overrides NOTHING — each kind uses
    /// its descriptor default.
    ///
    /// The one value that reads oddly is deliberate: manuscripts resolve to
    /// `.appHandoff` (hand off to imprint), which is correct *today* because
    /// there is no impress target to open anything. When impress ships this
    /// becomes `.detailPane` — a decision to make at ship time, asserted here
    /// as-is so the change is conscious rather than incidental.
    func testImpressUsesDescriptorOpenDefaults() {
        let c = AppShellConfiguration.impress
        XCTAssertTrue(c.openOverrides.isEmpty, "impress embeds; it does not override")
        XCTAssertEqual(c.openBehavior(for: .manuscript), .appHandoff)
        XCTAssertEqual(c.openBehavior(for: .figure), .window(id: "canvas"))
        XCTAssertEqual(c.openBehavior(for: .publication), .detailPane)
        XCTAssertEqual(c.openBehavior(for: .message), .detailPane)
        XCTAssertEqual(c.openBehavior(for: .task), .detailPane)
        XCTAssertEqual(c.openBehavior(for: .agentRun), .detailPane)
    }

    /// impress permits `.search`, so `TabContentView`'s boot task WOULD read
    /// the ADS/SciX keychain items in it. Those items are ACL'd to imbib's code
    /// signature: a differently-signed shell reading them pops a SecurityAgent
    /// prompt and blocks the cooperative-pool thread (the bug that hung
    /// impart's `/api/logs`). Before an impress target exists, either it ships
    /// with imbib's keychain access group or the credential read moves behind
    /// a reachability check. Asserted here so the requirement is discovered by
    /// a test, not by a hang.
    func testImpressPermitsSearchWhichImpliesTheKeychainRequirement() {
        XCTAssertTrue(AppShellConfiguration.impress.permits(.search))
        XCTAssertEqual(AppShellConfiguration.impress.recordKind(for: .search), .publication)
    }

    func testOpenBehaviorFallsBackToDescriptorDefault() {
        // A shell with no override uses the descriptor's default.
        let bare = AppShellConfiguration(
            appID: "test",
            visibleSections: nil,
            defaultSection: .inbox,
            defaultDetailTab: .info
        )
        XCTAssertEqual(bare.openBehavior(for: .manuscript), .appHandoff)
        XCTAssertEqual(bare.openBehavior(for: .publication), .detailPane)
        XCTAssertEqual(bare.openBehavior(for: RecordKindID("unknown")), .detailPane)
    }
}
#endif
