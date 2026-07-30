//
//  ImpelChassisFlipTests.swift
//  impelTests
//
//  Stage 4c: the chassis window is impel's only window. `impel://navigate/...`
//  used to set a `DashboardTab` that only the deleted classic `ContentView`
//  observed — so with the chassis as default it navigated NOTHING, silently.
//  That is the failure mode these tests exist for: the replacement is
//  string-keyed (surface ids), and a URL pointing at an unregistered id is
//  indistinguishable from a URL that worked.
//

import PublicationManagerCore
import XCTest
@testable import ImpelCore
@testable import impel

final class ImpelChassisFlipTests: XCTestCase {

    private var surfaces: CustomSurfaceRegistry {
        ImpelChassisRoot.shellConfiguration.customSurfaces
    }

    /// Every `impel://navigate/{section}` target resolves to a REGISTERED surface.
    func testEveryURLSectionResolvesToARegisteredSurface() {
        for (section, surfaceID) in ImpelChassisRoot.surfaceIDsByURLSection {
            XCTAssertNotNil(
                surfaces[surfaceID],
                "impel://navigate/\(section) targets surface '\(surfaceID)', which no descriptor registers")
        }
    }

    /// The URL vocabulary is exactly the one the classic `DashboardTab` switch
    /// accepted, so no deep link that worked before the flip stops working.
    /// `agents` maps to the ROSTER surface (`AgentListView` + personas) rather
    /// than the chassis Agents section, because the section's Runs child lists
    /// `agent-run@1.0.0` provenance rows, not the live agent roster.
    func testURLVocabularyMatchesTheClassicDashboardTabs() {
        XCTAssertEqual(
            Set(ImpelChassisRoot.surfaceIDsByURLSection.keys),
            ["dashboard", "threads", "agents", "escalations", "suggestions", "counsel"])
        XCTAssertEqual(ImpelChassisRoot.surfaceIDsByURLSection["agents"], "roster")
    }

    /// The six surfaces the classic sidebar's sections mapped to are all
    /// registered. Threads and Roster are the two Stage 4c additions: the chassis
    /// Agents SECTION reads the same `task@1.0.0` rows, but as tasks — it has no
    /// surface for `ImpelClient.state.agents` or `.personas` at all, and personas
    /// own the counsel model picker and system-prompt editor.
    func testClassicSidebarSurfacesAreAllRegistered() {
        for id in ["dashboard", "threads", "roster", "escalations", "suggestions", "counsel"] {
            XCTAssertNotNil(surfaces[id], "surface '\(id)' is not registered")
        }
    }

    /// The shell is still the Agents facet — the flip added surfaces, it did not
    /// widen impel's sidebar.
    func testShellIsStillTheAgentsFacet() {
        let configuration = ImpelChassisRoot.shellConfiguration
        XCTAssertEqual(configuration.appID, "impel")
        XCTAssertEqual(configuration.visibleSections, [.agents])
        XCTAssertEqual(configuration.defaultSection, .agents)
    }

    /// The kernel-owned gaps stay gaps: Stage 4c wired keyboard, undo and
    /// navigation, not task mutation.
    func testTaskLifecycleStaysKernelOwned() {
        let descriptor = TaskRecordKind.descriptor
        XCTAssertTrue(descriptor.creation.isEmpty, "tasks are scheduled by impel-taskd/counsel")
        XCTAssertEqual(descriptor.triage.dismissal, .none)
        XCTAssertEqual(descriptor.triage.deletion, .none)
        XCTAssertEqual(descriptor.lifecycle?.isKernelOwned, true)
    }
}
