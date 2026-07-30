//
//  RecordRouteTests.swift
//  PublicationManagerCoreTests
//
//  Stage 3 of the declarative chassis: the per-kind macOS routing collapsed
//  into ONE `RecordRoute` (kind + `RecordSidebarScope`) and ONE generic
//  folder node (`ImbibSidebarNodeType.recordFolder`).
//
//  Two kinds of assertion here, and the second is the unusual one:
//
//  1. ROUND TRIP — a kind + scope survives the trip out to a route and back
//     into the kind's own parallel list scope (`RecordRouteScope`). This is the
//     hinge the collapse rests on: if it loses information, a sidebar row
//     silently shows the wrong records, which is precisely the class of bug the
//     capability matrix exists to catch.
//
//  2. STRUCTURAL — the collapsed files no longer DECLARE per-kind route enums
//     or per-kind folder node cases. ADR-0021's litmus re-run (step 6) named
//     the navigation enums as the one place the "zero chassis edits" gate did
//     not hold, and the only honest way to keep that fixed is to assert the
//     absence of the shape that used to grow. Grepping source text in a test is
//     crude; a compiler cannot express "and no future kind adds a case here",
//     and the alternative is a comment nobody runs.
//

import XCTest
@testable import PublicationManagerCore

final class RecordRouteTests: XCTestCase {

    // MARK: - Route identity

    /// Routes are SELECTION STATE (`ImbibSidebarViewModel.tabToNodeID` keys a
    /// dictionary on the tab carrying them), so equality and hashing must be
    /// value semantics over kind + scope.
    func testRouteEqualityAndHashingAreValueSemanticsOverKindAndScope() {
        let folderID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        XCTAssertEqual(RecordRoute.all(.figure), RecordRoute(kind: .figure, scope: .all(.figure)))
        XCTAssertEqual(
            RecordRoute.folder(.manuscript, folderID),
            RecordRoute.folder(.manuscript, folderID))
        XCTAssertNotEqual(RecordRoute.all(.figure), RecordRoute.all(.message))
        XCTAssertNotEqual(
            RecordRoute.status(.task, "queued"), RecordRoute.status(.task, "running"))

        // Tasks and runs are two KINDS sharing one section view — the route
        // must keep them apart even though both are "all of the kind".
        XCTAssertNotEqual(RecordRoute.all(.task), RecordRoute.all(.agentRun))

        let set: Set<RecordRoute> = [
            .all(.figure), .all(.figure), .all(.message), .folder(.manuscript, folderID),
        ]
        XCTAssertEqual(set.count, 3)

        // Tabs carrying routes stay usable as dictionary keys.
        var tabToNode: [ImbibTab: Int] = [:]
        tabToNode[.record(.all(.figure))] = 1
        tabToNode[.record(.all(.figure))] = 2
        XCTAssertEqual(tabToNode.count, 1)
        XCTAssertEqual(tabToNode[.record(.all(.figure))], 2)
    }

    /// `stableID` is the scope's canonical key — the same string `stableViewID`
    /// derives from, so two different routes cannot share a SwiftUI identity.
    func testRouteStableIDIsTheScopeKeyAndIsDistinctPerRoute() {
        XCTAssertEqual(RecordRoute.all(.figure).stableID, "figure.all")
        XCTAssertEqual(RecordRoute.status(.task, "queued").stableID, "task.status.queued")

        let ids = [
            RecordRoute.all(.manuscript), .status(.manuscript, "draft"),
            .flagged(.manuscript, nil), .flagged(.manuscript, "red"),
            .all(.task), .all(.agentRun),
        ].map(\.stableID)
        XCTAssertEqual(Set(ids).count, ids.count, "stableID must separate every route")
    }

    // MARK: - Round trip: kind + scope in, kind's own list scope out

    func testManuscriptRouteRoundTrip() {
        let folderID = UUID()
        XCTAssertEqual(ManuscriptListScope(routeScope: RecordRoute.all(.manuscript).scope), .all)
        XCTAssertEqual(
            ManuscriptListScope(
                routeScope: RecordRoute.status(
                    .manuscript, JournalManuscriptStatus.draft.rawValue).scope),
            .status(.draft))
        XCTAssertEqual(
            ManuscriptListScope(routeScope: RecordRoute.folder(.manuscript, folderID).scope),
            .folder(folderID))
        XCTAssertEqual(
            ManuscriptListScope(routeScope: RecordRoute.flagged(.manuscript, "red").scope),
            .flagged(.red))
        XCTAssertEqual(
            ManuscriptListScope(routeScope: RecordRoute.flagged(.manuscript, nil).scope),
            .flagged(nil))
        // Unknown flag colour degrades to "any flag", never to no rows — the
        // legacy `colorRaw.flatMap { FlagColor(rawValue:) }` behaviour.
        XCTAssertEqual(
            ManuscriptListScope(routeScope: RecordRoute.flagged(.manuscript, "chartreuse").scope),
            .flagged(nil))
        // An undeclared status is honest nil (empty state), not a silent `.all`.
        XCTAssertNil(
            ManuscriptListScope(routeScope: RecordRoute.status(.manuscript, "nonesuch").scope))
    }

    func testFigureRouteRoundTripIncludingTheUnfiledHostScope() {
        let folderID = UUID()
        XCTAssertEqual(FigureListScope(routeScope: RecordRoute.all(.figure).scope), .all)
        XCTAssertEqual(
            FigureListScope(routeScope: RecordRoute.folder(.figure, folderID).scope),
            .folder(folderID))
        XCTAssertEqual(
            FigureListScope(routeScope: RecordRoute.flagged(.figure, "gray").scope),
            .flagged(.gray))
        // "Unfiled" has no chassis scope case — it rides RecordSidebarScope's
        // declared host escape hatch, and the key is spelled ONCE.
        XCTAssertEqual(
            FigureListScope(routeScope: FigureListScope.unfiledRouteScope), .unfiled)
    }

    func testMessageRouteRoundTripIncludingTheAccountHostScope() {
        let folderID = UUID()
        let accountID = UUID()
        XCTAssertEqual(MessageListScope(routeScope: RecordRoute.all(.message).scope), .allInboxes)
        XCTAssertEqual(
            MessageListScope(routeScope: RecordRoute.folder(.message, folderID).scope),
            .folder(folderID))
        // Accounts own FOLDERS, not records, so `.folder` would be the wrong
        // word: host escape hatch, round-tripped through the key in both
        // directions (and case-insensitively — store ids are lowercase).
        let accountScope = MessageListScope.accountRouteScope(accountID)
        XCTAssertEqual(MessageListScope(routeScope: accountScope), .account(accountID))
        XCTAssertEqual(MessageListScope.accountID(fromRouteScope: accountScope), accountID)
        XCTAssertNil(MessageListScope.accountID(fromRouteScope: .all(.message)))
    }

    func testAgentRouteRoundTripKeepsTasksAndRunsApart() {
        XCTAssertEqual(AgentListScope(routeScope: RecordRoute.all(.task).scope), .tasks)
        XCTAssertEqual(AgentListScope(routeScope: RecordRoute.all(.agentRun).scope), .runs)
        XCTAssertEqual(
            AgentListScope(routeScope: RecordRoute.status(.task, "waiting_review").scope),
            .tasksByState("waiting_review"))
    }

    /// A scope naming a different kind must not translate — this is what keeps
    /// `RecordSectionContext.scope(as:)` honest, and it is the only guard
    /// against one kind's viewer rendering another kind's rows.
    func testScopesRejectOtherKindsScopes() {
        XCTAssertNil(FigureListScope(routeScope: RecordRoute.all(.message).scope))
        XCTAssertNil(MessageListScope(routeScope: RecordRoute.all(.figure).scope))
        XCTAssertNil(ManuscriptListScope(routeScope: RecordRoute.all(.figure).scope))
        XCTAssertNil(AgentListScope(routeScope: RecordRoute.all(.figure).scope))
        XCTAssertNil(FigureListScope(routeScope: .section(.figures, .figure)))
    }

    // MARK: - Folder binding lookups (Part 2)

    /// The generic folder node carries its kernel BINDING, so both directions
    /// of binding ↔ kind have to be resolvable from the descriptors.
    func testCollectionBindingResolvesBackToItsKindAndCapability() {
        XCTAssertEqual(
            BuiltinRecordKinds.kind(forCollectionBindingID: CollectionBindingID.manuscript),
            .manuscript)
        XCTAssertEqual(
            BuiltinRecordKinds.kind(forCollectionBindingID: CollectionBindingID.figure), .figure)
        XCTAssertEqual(
            BuiltinRecordKinds.collectionCapability(
                forBindingID: CollectionBindingID.figure)?.bindingID,
            CollectionBindingID.figure)

        // Publications' collections are NOT a kernel folder binding the sidebar
        // drives (see the note in ImbibSidebarViewModel): the publication
        // descriptor declares no `collection`, so this must stay nil rather
        // than half-converge.
        XCTAssertNil(
            BuiltinRecordKinds.kind(forCollectionBindingID: CollectionBindingID.publication))
        XCTAssertNil(BuiltinRecordKinds.kind(forCollectionBindingID: "nonesuch"))
    }

    // MARK: - Structural: adding a kind needs no chassis enum edit

    func testChassisRouteFileDeclaresNoPerKindRouteEnums() throws {
        let source = try chassisSource("Chassis/TabSidebar/TabSidebarTypes.swift")
        for banned in [
            "enum ImbibJournalRoute", "enum FigureRoute", "enum MailRoute", "enum AgentRoute",
        ] {
            XCTAssertFalse(
                source.contains(banned),
                "\(banned) is back: the four parallel per-kind route enums were collapsed into "
                    + "RecordRoute, and a fifth means adding a record kind costs a chassis enum "
                    + "edit again (ADR-0021 litmus step 6)")
        }
        // The wrapper cases those enums hung off must not return either.
        for banned in ["case journal(", "case figures(", "case mail(", "case agents("] {
            XCTAssertFalse(source.contains(banned), "per-kind content-route wrapper case: \(banned)")
        }
        XCTAssertTrue(source.contains("struct RecordRoute"), "the generic route must live here")
    }

    func testSidebarNodeTypeHasOneFolderCaseForEveryKind() throws {
        let source = try chassisSource("Chassis/TabSidebar/ImbibSidebarNode.swift")
        XCTAssertTrue(
            source.contains("case recordFolder(bindingID: String, folderID: String)"),
            "the generic folder node case is the contract")
        for banned in ["case manuscriptFolder", "case figureFolder"] {
            XCTAssertFalse(
                source.contains(banned),
                "\(banned) is back: folder nodes carry their kernel binding so the seven sites "
                    + "that handle them stay total over CollectionCapability (ADR-0022 D3/G2)")
        }
    }

    func testSidebarViewModelHasNoFolderMigrationGate() throws {
        // The identifier still appears in the comment that records WHY it went;
        // what must not come back is the declaration or a read of it.
        let source = try chassisSource("Chassis/TabSidebar/ImbibSidebarViewModel.swift")
        for banned in ["let migratedFolderBindings", "Self.migratedFolderBindings"] {
            XCTAssertFalse(
                source.contains(banned),
                "the G2 strangler gate is retired — folderNode is total over "
                    + "CollectionCapability, so a newly declared capability is live rather than "
                    + "silently read-only (\(banned))")
        }
    }

    // MARK: - Helpers

    /// Chassis source text, resolved relative to this test file so the check
    /// travels with the package rather than depending on a working directory.
    private func chassisSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PublicationManagerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PublicationManagerCore
        let url = root
            .appendingPathComponent("Sources/PublicationManagerCore")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
