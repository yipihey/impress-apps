//
//  ChassisCrossPlatformContractTests.swift
//  PublicationManagerCoreTests
//
//  The iOS foundation pass de-gated the DECLARATIVE half of the chassis
//  (ADR-0021 descriptors + presets, ADR-0022 kind lookup / mixed-kind row)
//  so iOS reads the contract instead of re-encoding it as literals.
//
//  Two kinds of assertion live here, and the second is the important one:
//
//  1. Behavioural — the descriptors and shell presets resolve, and the
//     manuscript kind still declares the exact status lifecycle imprint's
//     iOS adapter now reads from it.
//
//  2. STRUCTURAL — the contract files must not carry an `#if os(macOS)`
//     gate. A macOS-only test cannot prove "compiles on iOS"; what it CAN
//     prove is that nobody re-gated the files, which is the failure mode
//     (the gates were historical comments, and a future chassis change could
//     copy the header verbatim into a new contract file). The imprint-iOS
//     build is the compile-level gate; this is the guard that keeps it
//     honest between builds.
//
//  Deliberately NOT `#if os(macOS)`-gated itself: it is a test about the
//  cross-platform contract.
//

import XCTest
@testable import PublicationManagerCore

final class ChassisCrossPlatformContractTests: XCTestCase {

    // MARK: - 1. Behavioural: the contract resolves off macOS-only code

    func testBuiltinDescriptorsResolveWithoutPlatformGating() {
        XCTAssertFalse(BuiltinRecordKinds.all.isEmpty)
        for descriptor in BuiltinRecordKinds.all {
            XCTAssertEqual(
                BuiltinRecordKinds.registry[descriptor.id]?.id,
                descriptor.id,
                "registry lookup must return the same descriptor for \(descriptor.id.rawValue)")
            XCTAssertFalse(
                descriptor.schemaRefs.isEmpty,
                "\(descriptor.id.rawValue) declares no schema ref")
            XCTAssertFalse(descriptor.displayName.isEmpty)
        }
    }

    func testEveryShellPresetResolvesWithoutPlatformGating() {
        let presets: [AppShellConfiguration] = [
            .imbib, .imprint, .implore, .impart, .impel, .impress,
        ]
        for preset in presets {
            XCTAssertFalse(preset.appID.isEmpty)
            XCTAssertTrue(
                preset.permits(preset.defaultSection),
                "\(preset.appID) must permit the section it lands on")
            for (section, kind) in preset.sectionBindings {
                XCTAssertNotNil(
                    preset.recordKinds[kind],
                    "\(preset.appID) binds \(section.rawValue) to unregistered kind "
                        + kind.rawValue)
            }
        }
    }

    func testSchemaRefLookupResolvesBothSpellingsCrossPlatform() {
        let registry = BuiltinRecordKinds.registry
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "manuscript"), .manuscript)
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "manuscript@1.2.0"), .manuscript)
        // Version tolerance is base-name equality, never `hasPrefix`.
        XCTAssertNil(registry.kind(forStoreSchemaRef: "manuscript-collection"))
    }

    func testKindTaggedRowIsAvailableCrossPlatform() {
        let row = KindTaggedRow(
            id: UUID(), kind: .manuscript, headerText: "h", titleText: "t", date: .distantPast)
        XCTAssertEqual(row.kind, .manuscript)
        XCTAssertEqual(row.titleText, "t")
    }

    // MARK: - Manuscript status lifecycle (what iOS now READS)

    func testManuscriptDescriptorDeclaresTheReservedStatusLifecycle() {
        let triage = ManuscriptRecordKind.descriptor.triage
        guard case .statusChange(let dismissed, let restoreTo) = triage.dismissal else {
            return XCTFail("manuscript dismissal must be .statusChange")
        }
        // docs/status-lifecycle.md reserves these two values chassis-wide.
        XCTAssertEqual(dismissed, "dismissed")
        XCTAssertEqual(restoreTo, "draft")
        XCTAssertEqual(triage.archiveStatus, "archived")
        XCTAssertEqual(triage.deletion, .confirmHard)
        XCTAssertTrue(triage.statusValues.contains("dismissed"))
        XCTAssertTrue(triage.statusValues.contains("archived"))
        XCTAssertTrue(triage.statusValues.contains("draft"))
    }

    func testManuscriptDescriptorDeclaresItsCollectionBinding() {
        let capability = ManuscriptRecordKind.descriptor.collection
        XCTAssertEqual(capability?.bindingID, CollectionBindingID.manuscript)
        XCTAssertEqual(capability?.canOrganize, true)
    }

    // MARK: - 2. Structural: the gate must not come back

    /// Files whose content is pure DATA/logic. They compile on every platform
    /// and MUST NOT be wrapped in `#if os(macOS)`; imprint-iOS links them.
    private static let crossPlatformContractFiles = [
        "Chassis/RecordKind/RecordKindDescriptor.swift",
        "Chassis/RecordKind/BuiltinRecordKinds.swift",
        "Chassis/RecordKind/RecordScopeKey.swift",
        "Chassis/RecordKind/KindTaggedRow.swift",
        "Chassis/AppShellConfiguration.swift",
        "Chassis/CustomSurface.swift",
        "Chassis/Shared/SchemaRefKindLookup.swift",
        "Chassis/Shared/RecordTriage.swift",
        // The iOS sidebar's DATA half (shape of the sidebar, folder tree,
        // organise verbs, triage row modifier). The renderer that consumes
        // them, `RecordSidebar/RecordSidebarView.swift`, is iOS-gated — the
        // same data/view split the descriptors use.
        "Chassis/Shared/RecordSidebar/RecordSidebarModel.swift",
        "Chassis/Shared/RecordSidebar/RecordSidebarBuilder.swift",
        "Chassis/Shared/RecordSidebar/RecordCollectionActions.swift",
        "Chassis/Shared/RecordSidebar/RecordTriageListRow.swift",
        "Files/SidebarSectionOrderStore.swift",
        "SharedViews/DetailTab.swift",

        // MARK: Stage 2a — the declarative chassis goes cross-platform
        //
        // None of these ever imported AppKit; the gate was the historical
        // GUI-meld Phase 1 header copied verbatim. Where a genuinely
        // macOS-only symbol lived in one, it was SPLIT out (see the gated
        // companions below) rather than the contract being re-gated.

        // Record-kind machinery: the registry itself (iOS previously had NO
        // registry type at all), the row-struct initializers, and the four
        // per-kind list scopes.
        "Chassis/RecordKind/RecordViewerRegistry.swift",
        "Chassis/RecordKind/KindTaggedRow+RowData.swift",
        "Chassis/RecordKind/RecordScopeKey+ListScopes.swift",
        "Chassis/RecordKind/AnyRecordListWrapper.swift",

        // Route / focus vocabulary.
        "Chassis/TabSidebar/TabSidebarTypes.swift",
        "Chassis/TabSidebar/FocusedPane.swift",
        "Chassis/Manuscripts/FocusedManuscript.swift",
        "Chassis/Shared/FindCoordinator.swift",

        // Row snapshots — pure value types over store rows.
        "Chassis/Manuscripts/ManuscriptRowData.swift",
        "Chassis/Messages/MessageRowData.swift",
        "Chassis/Figures/FigureRowData.swift",
        "Chassis/Agents/AgentRowData.swift",

        // Store readers. While these were gated iOS could not read mail,
        // figures, tasks or agent runs from the shared store AT ALL.
        "Chassis/Messages/MailStoreReader.swift",
        "Chassis/Figures/FigureStoreReader.swift",
        "Chassis/Agents/AgentStoreReader.swift",
        "Chassis/Services/JournalEventBridge.swift",

        // Plain-SwiftUI sections and sheets.
        "Chassis/Shared/RelatedItemsSection.swift",
        "Chassis/Detail/Tabs/CitedInManuscriptsSection.swift",
        "Chassis/Detail/JournalManuscriptsListView.swift",
        "Chassis/Detail/SubmissionsInboxView.swift",
        "Chassis/Manuscripts/ManuscriptVersionsSection.swift",
        "Chassis/Manuscripts/ManuscriptHistorySection.swift",
        "Chassis/Manuscripts/MarkdownPreviewTab.swift",
        "Chassis/SciX/SciXLibraryListView.swift",
        "Chassis/SciX/SciXLibraryInfoSheet.swift",
        "Chassis/SciX/SciXEditLibrarySheet.swift",

        // The editor lifecycle seam. Buffer + cursor + debounced CAS save +
        // conflict resolution + the session LRU; the AppKit lives in the
        // editor VIEWS that consume a session, never here.
        "Manuscript/Editor/ManuscriptEditorSession.swift",

        // MARK: Stage 6 phase 1 — the shared settings surface
        //
        // Settings were authored per app AND per platform, with no shared
        // frame; imprint-iOS shipped none at all, because "which panes does
        // this app have" existed only as a macOS `TabView` body. These three
        // are the declarative half — descriptor, registry, preset. The two
        // RENDERERS are gated, one per platform (see the companion test).
        "Chassis/Settings/SettingsSectionDescriptor.swift",
        "Chassis/Settings/SettingsSectionRegistry.swift",
        "Chassis/Settings/AppSettingsConfiguration.swift",

        // MARK: Stage 5b — the publication detail pane's shared halves
        //
        // The five bespoke iOS detail tabs read these instead of re-encoding
        // them: the identifier URL templates, the Flag & Tags section, the
        // Explore row's rules + runner, the `note` field's format + debounced
        // writer, the multi-PDF switcher, "where is this PDF", and the shell
        // behaviour (auto-mark-read / Recent dwell / live refresh). The four
        // macOS CHROMES that consume them stay gated — see
        // `PublicationDetailSharedSurfaceTests`, which also owns the
        // behavioural oracle for each file.
        "Chassis/Detail/Shared/PublicationIdentifierLink.swift",
        "Chassis/Detail/Shared/PublicationFlagAndTagsSection.swift",
        "Chassis/Detail/Shared/PublicationExploration.swift",
        "Chassis/Detail/Shared/PublicationNotesDocument.swift",
        "Chassis/Detail/Shared/PublicationPDFSwitcher.swift",
        "Chassis/Detail/Shared/PublicationPDFAvailability.swift",
        "Chassis/Detail/Shared/PublicationDetailLifecycle.swift",
        // Collapsed outright: ONE BibTeX tab, both platforms.
        "Chassis/Detail/Tabs/BibTeXTab.swift",

        // MARK: Stage 5c — impart-iOS joins the chassis
        //
        // The mail sidebar's account/folder TREE (role order, the six folder
        // glyphs, the All-Inboxes fan-out) was inside the macOS-gated
        // `ImbibSidebarViewModel.mailChildren()`, and it needed
        // `MailStoreReader`'s INTERNAL payload decoders — so impart-iOS could
        // not have reproduced it even by copying. Now both sidebars map this
        // one snapshot onto their own node type.
        "Chassis/Messages/MailSidebarSnapshot.swift",
        // The message detail pane, collapsed outright: it was gated by the
        // GUI-meld Phase 1 header plus an `import AppKit` nothing used. Its
        // body is plain SwiftUI over cross-platform chassis types, so
        // impart-iOS renders THIS pane rather than an app-side clone — the
        // Stage-5b lesson from imbib's publication detail, applied before the
        // second copy exists rather than after.
        "Chassis/Messages/MessageDetailPane.swift",
    ]

    func testContractFilesAreNotWrappedInAMacOSGate() throws {
        for relativePath in Self.crossPlatformContractFiles {
            let url = Self.sourcesRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            let firstCode = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? ""
            XCTAssertFalse(
                firstCode.hasPrefix("#if os(macOS)"),
                """
                \(relativePath) is wrapped in `#if os(macOS)`. It is a chassis \
                CONTRACT file: iOS reads it (imprint's ManuscriptStoreAdapter \
                sources its status strings and collection binding from the \
                descriptors). If a genuinely macOS-only symbol landed in it, \
                SPLIT the file — data here, AppKit views in a gated companion \
                — rather than re-gating the contract.
                """)
        }
    }

    /// The AppKit-linking pieces that were split OUT stay gated — the split
    /// is only worth anything if the macOS half really is separate.
    func testSplitOutPlatformFilesStayGated() throws {
        let gated = [
            // The builtin viewer factories: each constructs an AppKit-adjacent
            // chassis section view. The REGISTRY above is cross-platform.
            "Chassis/RecordKind/RecordViewerRegistry+Builtin.swift",
            // The markdown preview's `ManuscriptEditorSession` entry point.
            "Chassis/Manuscripts/MarkdownPreviewTab+Session.swift",
            // Stage 6 phase 1: the macOS settings RENDERER (tabbed
            // `TabView`). Its iOS twin has its own gate, asserted in
            // `SettingsSurfaceContractTests.testRenderersStayPlatformGated`
            // along with this one — the declaration they both read is in the
            // cross-platform list above.
            "Chassis/Settings/MacSettingsSceneContent.swift",
        ]
        for relativePath in gated {
            let url = Self.sourcesRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(
                text.hasPrefix("#if os(macOS)"),
                "\(relativePath) must stay macOS-gated")
        }
    }

    /// `<package>/Sources/PublicationManagerCore`, derived from this test's
    /// own path so the test is location-independent.
    private static let sourcesRoot: URL = {
        URL(fileURLWithPath: #filePath)          // …/Tests/PublicationManagerCoreTests/<this>
            .deletingLastPathComponent()          // …/Tests/PublicationManagerCoreTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/PublicationManagerCore
            .appendingPathComponent("Sources/PublicationManagerCore")
    }()
}
