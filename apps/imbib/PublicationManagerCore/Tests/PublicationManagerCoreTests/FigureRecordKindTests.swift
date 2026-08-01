//
//  FigureRecordKindTests.swift
//  PublicationManagerCoreTests
//
//  Stage 2-B (ADR-0021): the figure record kind's descriptor contract —
//  View-tab gating on artifact presence, scope identity determinism, and the
//  implore shell preset — mirroring RecordKindDescriptorTests.
//

import SwiftUI
import XCTest
import ImpressRustCore
@testable import PublicationManagerCore

#if os(macOS)
final class FigureRecordKindTests: XCTestCase {

    // MARK: - Descriptor tab gating

    /// Figures encode "has a CAS artifact" through previewKind (see the
    /// comment in BuiltinRecordKinds.FigureRecordKind): `.compiledPDF` when
    /// the payload carries a data_hash, `.none` otherwise.
    func testViewTabGatedOnArtifactPresence() {
        let withData = RecordTabContext(previewKind: .compiledPDF)
        let withoutData = RecordTabContext(previewKind: DocumentFormat.PreviewKind.none)
        let unresolved = RecordTabContext()   // nil previewKind = hidden (safe default)

        XCTAssertEqual(
            FigureRecordKind.descriptor.availableTabs(for: withData),
            [.info, .pdf])
        XCTAssertEqual(
            FigureRecordKind.descriptor.availableTabs(for: withoutData),
            [.info])
        XCTAssertEqual(
            FigureRecordKind.descriptor.availableTabs(for: unresolved),
            [.info])
    }

    func testCoercionLandsOnInfoWhenViewUnavailable() {
        let withoutData = RecordTabContext(previewKind: DocumentFormat.PreviewKind.none)
        for tab in DetailTab.allCases {
            let coerced = FigureRecordKind.descriptor.coercedTab(tab, for: withoutData)
            XCTAssertEqual(coerced, .info, "\(tab) must coerce to info without an artifact")
        }
        let withData = RecordTabContext(previewKind: .compiledPDF)
        XCTAssertEqual(FigureRecordKind.descriptor.coercedTab(.pdf, for: withData), .pdf)
        XCTAssertEqual(FigureRecordKind.descriptor.coercedTab(.bibtex, for: withData), .info)
    }

    // MARK: - Triage contract (frozen in docs/chassis-capability-matrix.md)

    func testTriageCapabilitiesMatchContract() {
        let triage = FigureRecordKind.descriptor.triage
        XCTAssertTrue(triage.canStar)
        XCTAssertTrue(triage.canFlag)
        XCTAssertTrue(triage.canTag)
        XCTAssertEqual(triage.dismissal, .none, "figures have no status field today")
        XCTAssertNil(triage.archiveStatus)
        XCTAssertEqual(triage.deletion, .confirmHard)
        XCTAssertEqual(triage.statuses, [])
        XCTAssertTrue(FigureRecordKind.descriptor.creation.isEmpty,
                      "figures are created by the canvas/generators, not `n`")
        XCTAssertEqual(FigureRecordKind.descriptor.defaultOpenBehavior, .window(id: "canvas"))
    }

    func testRegistryLookupBySchemaRef() {
        let registry = AppShellConfiguration.implore.recordKinds
        XCTAssertEqual(registry.descriptor(forSchemaRef: "figure")?.id, .figure)
        XCTAssertEqual(registry[.figure]?.displayName, "Figure")
    }

    // MARK: - Scope identity

    func testScopeStableViewIDsAreDeterministicAndDistinct() {
        let a = FigureListScope.all.stableViewID
        let b = FigureListScope.all.stableViewID
        XCTAssertEqual(a, b, "same scope must produce the same id across evaluations")
        XCTAssertNotEqual(
            FigureListScope.all.stableViewID,
            FigureListScope.unfiled.stableViewID)
        XCTAssertNotEqual(
            FigureListScope.flagged(nil).stableViewID,
            FigureListScope.flagged(.red).stableViewID)
        let folderID = UUID()
        XCTAssertEqual(
            FigureListScope.folder(folderID).stableViewID,
            FigureListScope.folder(folderID).stableViewID)
        XCTAssertNotEqual(
            FigureListScope.folder(folderID).stableViewID,
            FigureListScope.folder(UUID()).stableViewID)
    }

    func testScopeKeysAreNamespacedAgainstManuscripts() {
        // Figure and manuscript scopes must never collide in persisted keys.
        XCTAssertNotEqual(
            FigureListScope.all.scopeKey,
            ManuscriptListScope.all.scopeKey)
        XCTAssertNotEqual(
            FigureListScope.flagged(.red).stableViewID,
            ManuscriptListScope.flagged(.red).stableViewID)
    }

    // MARK: - Row model

    @MainActor
    func testFigureRowDataMapsSharedItemRow() {
        let id = UUID()
        let row = SharedItemRow(
            id: id.uuidString.lowercased(),
            schemaRef: "figure",
            payloadJson: #"{"title":"Power spectrum","caption":"z=6","format":"png","data_hash":"abc123","script_hash":"def456"}"#,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_100_000,
            parentId: "folder-1",
            isRead: false,
            isStarred: true,
            tags: ["projects/reionization"],
            flagColor: "red")
        guard let data = FigureRowData(from: row) else {
            return XCTFail("row should map")
        }
        XCTAssertEqual(data.id, id)
        XCTAssertEqual(data.title, "Power spectrum")
        XCTAssertEqual(data.caption, "z=6")
        XCTAssertEqual(data.format, "png")
        XCTAssertEqual(data.dataHash, "abc123")
        XCTAssertEqual(data.scriptHash, "def456")
        XCTAssertEqual(data.parentIDString, "folder-1")
        XCTAssertTrue(data.isStarred)
        XCTAssertEqual(data.flag?.color, .red)
        XCTAssertEqual(data.tagDisplays.map(\.leaf), ["reionization"])
        // MailStyleItem projections
        XCTAssertEqual(data.headerText, "PNG")
        XCTAssertEqual(data.titleText, "Power spectrum")
        XCTAssertEqual(data.subtitleText, "Png")
        XCTAssertEqual(data.previewText, "z=6")
        XCTAssertTrue(data.isRead, "figures have no unread semantics")
        XCTAssertTrue(data.hasAttachment, "paperclip = CAS artifact present")
    }

    @MainActor
    func testFigureRowDataDefaults() {
        let row = SharedItemRow(
            id: UUID().uuidString.lowercased(),
            schemaRef: "figure",
            payloadJson: "{}",
            createdMs: 0, modifiedMs: 0,
            parentId: nil, isRead: true, isStarred: false,
            tags: [], flagColor: nil)
        guard let data = FigureRowData(from: row) else {
            return XCTFail("row should map")
        }
        XCTAssertEqual(data.title, "Untitled figure")
        XCTAssertNil(data.flag)
        XCTAssertFalse(data.hasAttachment)
        XCTAssertNil(data.subtitleText)
        XCTAssertEqual(data.headerText, "Figure")
        // Non-UUID store ids don't map (defensive).
        let bad = SharedItemRow(
            id: "not-a-uuid", schemaRef: "figure", payloadJson: "{}",
            createdMs: 0, modifiedMs: 0, parentId: nil,
            isRead: true, isStarred: false, tags: [], flagColor: nil)
        XCTAssertNil(FigureRowData(from: bad))
    }

    // MARK: - implore shell preset

    func testImplorePresetMatchesContract() {
        let c = AppShellConfiguration.implore
        XCTAssertEqual(c.appID, "implore")
        XCTAssertEqual(c.visibleSections, [.figures, .tags], "Flagged is deliberately skipped in v1; Tags is not — every artifact is taggable")
        XCTAssertEqual(c.defaultSection, .figures)
        XCTAssertEqual(c.defaultDetailTab, .info)
        XCTAssertEqual(c.openBehavior(for: .figure), .window(id: "canvas"))
        XCTAssertTrue(c.customSurfaces.isEmpty,
                      "surfaces are registered app-side via withCustomSurfaces")
        XCTAssertFalse(c.permits(.inbox))
        XCTAssertFalse(c.permits(.manuscripts))
        XCTAssertTrue(c.permits(.figures))
    }

    @MainActor
    func testWithCustomSurfacesPreservesShellIdentity() {
        let surface = CustomSurfaceDescriptor(
            id: "generate", title: "Generate", systemImage: "waveform",
            makeView: { AnyView(EmptyView()) })
        let extended = AppShellConfiguration.implore.withCustomSurfaces([surface])
        XCTAssertEqual(extended.appID, "implore")
        XCTAssertEqual(extended.visibleSections, [.figures, .tags])
        XCTAssertEqual(extended.defaultSection, .figures)
        XCTAssertEqual(extended.customSurfaces["generate"]?.title, "Generate")
        XCTAssertNotEqual(extended, .implore, "surface ids participate in equality")
    }
}
#endif
