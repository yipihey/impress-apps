//
//  StoreSearchSurfaceTests.swift
//  PublicationManagerCoreTests
//
//  WP G4 (ADR-0022 D6): the testable half of grouped store-wide search —
//  schema-ref → kind for EVERY shipped schema ref, hit → `KindTaggedRow`
//  projection, the mixed-list grouping primitive, and the registration
//  invariant that makes the surface appear in every app without opting in.
//
//  The view itself (debounce, focus, empty states) is not unit-testable;
//  builds plus the three-point "search" trace cover it.
//

import SwiftUI
import XCTest
import ImpressRustCore
@testable import PublicationManagerCore

#if os(macOS)
final class StoreSearchSurfaceTests: XCTestCase {

    // MARK: - schema_ref → RecordKindID

    /// Every ref a shipped descriptor declares must resolve back to that
    /// descriptor — otherwise a whole kind lands in the "unknown" bucket of a
    /// search that already found its rows.
    @MainActor
    func testEveryBuiltinSchemaRefResolvesToItsOwnKind() {
        let registry = BuiltinRecordKinds.registry
        for descriptor in BuiltinRecordKinds.all {
            XCTAssertFalse(
                descriptor.schemaRefs.isEmpty,
                "\(descriptor.id.rawValue) declares no schema refs")
            for ref in descriptor.schemaRefs {
                XCTAssertEqual(
                    registry.kind(forStoreSchemaRef: ref), descriptor.id,
                    "schema ref \(ref) did not resolve to \(descriptor.id.rawValue)")
            }
        }
    }

    /// The store spells the same kind with and without a version suffix
    /// (`manuscript` vs `task@1.0.0`). Both spellings must land on one kind.
    @MainActor
    func testSchemaRefLookupIsVersionSuffixTolerantBothWays() {
        let registry = BuiltinRecordKinds.registry
        for descriptor in BuiltinRecordKinds.all {
            for ref in descriptor.schemaRefs {
                let base = RecordKindSchemaRef.baseName(ref)
                XCTAssertEqual(
                    registry.kind(forStoreSchemaRef: base), descriptor.id,
                    "bare \(base) did not resolve to \(descriptor.id.rawValue)")
                XCTAssertEqual(
                    registry.kind(forStoreSchemaRef: "\(base)@9.9.9"), descriptor.id,
                    "versioned \(base)@9.9.9 did not resolve to \(descriptor.id.rawValue)")
            }
        }
    }

    /// The lookup must be base-name EQUALITY, never a prefix test: the
    /// collection schemas share a prefix with the kinds they organise, and
    /// mislabelling a folder as a figure is the bug this asserts against.
    @MainActor
    func testCollectionAndEnvelopeSchemasResolveToNoKind() {
        let registry = BuiltinRecordKinds.registry
        for ref in [
            "figure-collection", "figure-collection@1.0.0",
            "manuscript-collection", "manuscript-section",
            "imbib/collection", "collection@1.0.0",
            "mail-folder", "mail-account", "review-request@1.0.0",
        ] {
            XCTAssertNil(
                registry.kind(forStoreSchemaRef: ref),
                "\(ref) must not claim a record kind")
        }
    }

    // MARK: - SharedSearchHit → KindTaggedRow

    private func hit(
        id: String = "00000000-0000-0000-0000-0000000000a1",
        schemaRef: String = "manuscript",
        title: String = "Scaling Relations",
        snippet: String = "…scaling relations in cluster cores…",
        rank: Double = -3.5
    ) -> SharedSearchHit {
        SharedSearchHit(
            id: id, schemaRef: schemaRef, title: title, snippet: snippet, rank: rank)
    }

    private func itemRow(
        id: String, schemaRef: String, modifiedMs: Int64,
        isRead: Bool = true, isStarred: Bool = false
    ) -> SharedItemRow {
        SharedItemRow(
            id: id, schemaRef: schemaRef, payloadJson: "{}",
            createdMs: modifiedMs, modifiedMs: modifiedMs, parentId: nil,
            isRead: isRead, isStarred: isStarred, tags: [], flagColor: nil)
    }

    @MainActor
    func testHitMappingPreservesIDKindAndTitle() {
        let h = hit()
        let row = StoreSearchReader.kindTaggedRow(hit: h)
        XCTAssertEqual(row?.id, UUID(uuidString: h.id))
        XCTAssertEqual(row?.kind, .manuscript)
        XCTAssertEqual(row?.titleText, "Scaling Relations")
        XCTAssertEqual(row?.headerText, ManuscriptRecordKind.descriptor.displayName)
        XCTAssertEqual(row?.previewText, "…scaling relations in cluster cores…")
    }

    @MainActor
    func testHitMappingCoversEveryBuiltinKind() {
        for descriptor in BuiltinRecordKinds.all {
            guard let ref = descriptor.schemaRefs.first else { continue }
            let row = StoreSearchReader.kindTaggedRow(hit: hit(schemaRef: ref))
            XCTAssertEqual(
                row?.kind, descriptor.id,
                "hit with schema \(ref) mapped to \(row?.kind.rawValue ?? "nil")")
            XCTAssertEqual(row?.headerText, descriptor.displayName)
        }
    }

    /// The envelope row is where an honest date comes from — `SharedSearchHit`
    /// carries none, and a search result must never invent "now".
    @MainActor
    func testEnvelopeRowSuppliesDateAndReadState() {
        let h = hit(schemaRef: "figure")
        let ms: Int64 = 1_700_000_000_000
        let row = StoreSearchReader.kindTaggedRow(
            hit: h,
            item: itemRow(id: h.id, schemaRef: "figure", modifiedMs: ms,
                          isRead: false, isStarred: true))
        XCTAssertEqual(row?.kind, .figure)
        XCTAssertEqual(
            row?.date.timeIntervalSince1970 ?? 0, Double(ms) / 1000, accuracy: 0.001)
        XCTAssertEqual(row?.isRead, false)
        XCTAssertEqual(row?.isStarred, true)
    }

    @MainActor
    func testMissingEnvelopeRowFallsBackToDistantPastNotNow() {
        let row = StoreSearchReader.kindTaggedRow(hit: hit(), item: nil)
        XCTAssertEqual(row?.date, .distantPast)
    }

    /// The kernel falls back to the title when a match has nothing quotable;
    /// rendering it as the preview line shows the same text twice.
    @MainActor
    func testSnippetEqualToTitleIsNotShownTwice() {
        let row = StoreSearchReader.kindTaggedRow(
            hit: hit(title: "Untitled Draft", snippet: "Untitled Draft"))
        XCTAssertNil(row?.previewText)
    }

    @MainActor
    func testEmptyTitleBecomesUntitledRatherThanABlankRow() {
        let row = StoreSearchReader.kindTaggedRow(hit: hit(title: "  ", snippet: "  "))
        XCTAssertEqual(row?.titleText, "Untitled")
    }

    /// A schema no descriptor claims still renders — tagged with its base
    /// name, so nothing the store matched vanishes from the results.
    @MainActor
    func testUnclaimedSchemaKeepsTheRowTaggedByBaseName() {
        let row = StoreSearchReader.kindTaggedRow(
            hit: hit(schemaRef: "figure-collection@1.0.0", title: "Cluster Plots"))
        XCTAssertEqual(row?.kind, RecordKindID("figure-collection"))
        XCTAssertEqual(row?.titleText, "Cluster Plots")
    }

    @MainActor
    func testHitWithNonUUIDIDIsDropped() {
        XCTAssertNil(StoreSearchReader.kindTaggedRow(hit: hit(id: "not-a-uuid")))
    }

    // MARK: - Grouping (AnyRecordListWrapper)

    private func row(_ kind: RecordKindID, _ title: String) -> KindTaggedRow {
        KindTaggedRow(
            id: UUID(), kind: kind, headerText: kind.rawValue,
            titleText: title, date: .distantPast)
    }

    @MainActor
    func testGroupsBucketByKindInFirstAppearanceOrder() {
        let rows = [
            row(.manuscript, "m1"), row(.publication, "p1"),
            row(.manuscript, "m2"), row(.figure, "f1"), row(.publication, "p2"),
        ]
        let groups = AnyRecordListWrapper.groups(from: rows)
        XCTAssertEqual(groups.map(\.kind), [.manuscript, .publication, .figure])
        XCTAssertEqual(groups[0].rows.map(\.titleText), ["m1", "m2"])
        XCTAssertEqual(groups[1].rows.map(\.titleText), ["p1", "p2"])
        XCTAssertEqual(groups[2].rows.map(\.titleText), ["f1"])
    }

    @MainActor
    func testGroupsOfEmptyRowsIsEmpty() {
        XCTAssertTrue(AnyRecordListWrapper.groups(from: []).isEmpty)
    }

    /// `primaryRow` must follow DISPLAY order, and grouping changes it — the
    /// detail pane would otherwise track a different row than the one the
    /// user sees first.
    @MainActor
    func testDisplayOrderedRowsFollowGroupingNotInputOrder() {
        let rows = [
            row(.manuscript, "m1"), row(.publication, "p1"), row(.manuscript, "m2"),
        ]
        XCTAssertEqual(
            AnyRecordListWrapper.displayOrderedRows(rows, grouped: false).map(\.titleText),
            ["m1", "p1", "m2"])
        XCTAssertEqual(
            AnyRecordListWrapper.displayOrderedRows(rows, grouped: true).map(\.titleText),
            ["m1", "m2", "p1"])

        let selection: Set<UUID> = [rows[1].id, rows[2].id]
        XCTAssertEqual(
            AnyRecordListWrapper.primaryRow(
                in: selection,
                of: AnyRecordListWrapper.displayOrderedRows(rows, grouped: true))?.titleText,
            "m2")
    }

    // MARK: - Registration (present in EVERY shell, no opt-in)

    /// `impress` (ADR-0022 D9) is in this list although it ships no target:
    /// grouped store-wide search is the chassis's own surface, and the shell
    /// that shows everything is the one shell where it would be most absurd to
    /// be missing. Its presence here is one of the seams G8 freezes.
    @MainActor
    func testStoreSearchSurfaceIsRegisteredInEveryPreset() {
        let presets: [AppShellConfiguration] = [
            .imbib, .imprint, .implore, .impart, .impel, .impress,
        ]
        for preset in presets {
            let surface = preset.customSurfaces[StoreSearchSurface.surfaceID]
            XCTAssertNotNil(
                surface, "\(preset.appID) is missing the builtin store-search surface")
            XCTAssertEqual(surface?.title, "Search Everything")
            XCTAssertEqual(surface?.systemImage, "magnifyingglass")
            XCTAssertTrue(
                preset.customSurfaces.surfaces.contains { $0.id == StoreSearchSurface.surfaceID },
                "\(preset.appID) would emit no sidebar node for store-search")
        }
    }

    /// The builtin must not read as an app-registered surface — the preset
    /// parity tests assert emptiness, and that assertion is about the app's
    /// own choices.
    @MainActor
    func testBuiltinIsNotCountedAsAnAppRegisteredSurface() {
        XCTAssertTrue(AppShellConfiguration.imbib.customSurfaces.isEmpty)
        XCTAssertTrue(AppShellConfiguration.imprint.customSurfaces.isEmpty)
        XCTAssertTrue(AppShellConfiguration.imbib.customSurfaces.appSurfaces.isEmpty)
        XCTAssertFalse(AppShellConfiguration.imbib.customSurfaces.surfaces.isEmpty)
    }

    /// App surfaces keep their order; the builtin is appended — imbib/imprint
    /// gain exactly one node and nobody else's move.
    @MainActor
    func testAppSurfacesKeepTheirOrderAndBuiltinComesLast() {
        let extended = AppShellConfiguration.implore.withCustomSurfaces([
            CustomSurfaceDescriptor(
                id: "generate", title: "Generate", systemImage: "waveform",
                makeView: { AnyView(EmptyView()) }),
            CustomSurfaceDescriptor(
                id: "analyze", title: "Analyze", systemImage: "chart.bar",
                makeView: { AnyView(EmptyView()) }),
        ])
        XCTAssertEqual(
            extended.customSurfaces.surfaces.map(\.id),
            ["generate", "analyze", StoreSearchSurface.surfaceID])
    }

    /// An app that registers the same id replaces the builtin rather than
    /// producing two sidebar nodes with one selection id.
    @MainActor
    func testAppRegisteredSurfaceWithBuiltinIDReplacesItExactlyOnce() {
        let overridden = AppShellConfiguration.impel.withCustomSurfaces([
            CustomSurfaceDescriptor(
                id: StoreSearchSurface.surfaceID, title: "Find", systemImage: "eye",
                makeView: { AnyView(EmptyView()) }),
        ])
        XCTAssertEqual(
            overridden.customSurfaces.surfaces.filter {
                $0.id == StoreSearchSurface.surfaceID
            }.count, 1)
        XCTAssertEqual(
            overridden.customSurfaces[StoreSearchSurface.surfaceID]?.title, "Find")
    }

    // MARK: - Live store smoke (skips when the workspace is absent)

    /// End-to-end against the real shared store: the FFI call, the per-hit
    /// envelope lookup and the projection, on whatever rows the machine has.
    /// Asserts only invariants that hold for ANY corpus, so it cannot depend
    /// on the developer's library — and skips entirely on a bare machine
    /// (same shape as `CollectionStoreAdapterTests`).
    func testLiveSearchProducesWellFormedRowsOrSkips() throws {
        let reader = StoreSearchReader.shared
        try XCTSkipUnless(reader.isReady, "no shared workspace on this machine")

        XCTAssertTrue(reader.search(query: "   ").isEmpty, "blank query must not query")
        // Hostile input is data, not FTS5 syntax (search_ops.rs) — it must
        // come back empty-or-fine, never throw.
        _ = reader.search(query: "foo AND (")

        let rows = reader.search(query: "a", limitPerKind: 5)
        for row in rows {
            XCTAssertFalse(row.titleText.isEmpty, "row \(row.id) has no title")
            XCTAssertFalse(row.kind.rawValue.isEmpty, "row \(row.id) has no kind")
        }
        // Per-kind cap is the kernel's promise the surface depends on.
        for group in AnyRecordListWrapper.groups(from: rows) {
            XCTAssertLessThanOrEqual(group.rows.count, 5, "\(group.kind.rawValue) exceeded the cap")
        }
    }

    /// The surface descriptor and the sidebar/route identifiers must agree —
    /// a mismatch shows the "Surface Unavailable" placeholder.
    @MainActor
    func testDescriptorIDMatchesTheSurfaceIdentifier() {
        XCTAssertEqual(StoreSearchSurface.descriptor.id, StoreSearchSurface.surfaceID)
        XCTAssertEqual(StoreSearchSurface.descriptor.title, StoreSearchSurface.surfaceTitle)
        XCTAssertEqual(StoreSearchSurface.surfaceID, "store-search")
    }
}
#endif
