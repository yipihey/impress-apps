//
//  RecordKindDescriptorTests.swift
//  PublicationManagerCoreTests
//
//  Stage 1 (ADR-0021) regression oracle: the record-kind descriptors must
//  reproduce the legacy DetailTab.ItemKind behavior EXACTLY (frozen in
//  docs/chassis-capability-matrix.md "Record-kind descriptor contract")
//  before any legacy path is deleted.
//

import UniformTypeIdentifiers
import XCTest
@testable import PublicationManagerCore

#if os(macOS)
final class RecordKindDescriptorTests: XCTestCase {

    // MARK: - Frozen legacy behavior (verbatim from pre-Stage-1 DetailTab)
    //
    // ItemKind was deleted in S1-WP7b; these literals ARE the frozen
    // contract now, and the descriptors must keep reproducing them.

    private enum FrozenKind {
        case publication(editable: Bool)
        case manuscript(previewKind: DocumentFormat.PreviewKind)

        var context: RecordTabContext {
            switch self {
            case .publication(let editable):
                return RecordTabContext(isEditable: editable)
            case .manuscript(let previewKind):
                return RecordTabContext(previewKind: previewKind)
            }
        }

        var descriptor: RecordKindDescriptor {
            switch self {
            case .publication: return PublicationRecordKind.descriptor
            case .manuscript: return ManuscriptRecordKind.descriptor
            }
        }
    }

    private func legacyAvailable(for kind: FrozenKind) -> [DetailTab] {
        switch kind {
        case .publication(let editable):
            return editable ? [.info, .pdf, .notes, .bibtex] : [.info, .pdf, .bibtex]
        case .manuscript(let previewKind):
            switch previewKind {
            case .compiledPDF, .renderedMarkdown: return [.info, .source, .pdf]
            case .none: return [.info, .source]
            }
        }
    }

    private func legacyCoerced(_ tab: DetailTab, for kind: FrozenKind) -> DetailTab {
        let valid = legacyAvailable(for: kind)
        if valid.contains(tab) { return tab }
        switch tab {
        case .bibtex:
            if case .manuscript = kind { return .source }
            return .info
        case .source: return valid.contains(.bibtex) ? .bibtex : .info
        default: return .info
        }
    }

    private var allKinds: [FrozenKind] {
        [
            .publication(editable: true),
            .publication(editable: false),
            .manuscript(previewKind: .compiledPDF),
            .manuscript(previewKind: .renderedMarkdown),
            .manuscript(previewKind: .none),
        ]
    }

    func testDescriptorsReproduceLegacyAvailability() {
        for kind in allKinds {
            XCTAssertEqual(
                kind.descriptor.availableTabs(for: kind.context),
                legacyAvailable(for: kind),
                "availability drifted for \(kind)"
            )
        }
    }

    func testDescriptorsReproduceLegacyCoercion() {
        for kind in allKinds {
            for tab in DetailTab.allCases {
                XCTAssertEqual(
                    kind.descriptor.coercedTab(tab, for: kind.context),
                    legacyCoerced(tab, for: kind),
                    "coercion drifted for \(tab) in \(kind)"
                )
            }
        }
    }

    // MARK: - Registry & contract sanity

    func testRegistryLookupBySchemaRef() {
        let registry = RecordKindRegistry([
            PublicationRecordKind.descriptor,
            ManuscriptRecordKind.descriptor,
            ArtifactRecordKind.descriptor,
        ])
        XCTAssertEqual(registry.descriptor(forSchemaRef: "manuscript")?.id, .manuscript)
        XCTAssertEqual(
            registry.descriptor(forSchemaRef: "imbib/bibliography-entry")?.id, .publication)
        XCTAssertNil(registry.descriptor(forSchemaRef: "no-such-schema"))
        XCTAssertEqual(registry[.artifact]?.displayName, "Artifact")
    }

    func testManuscriptStatusesMatchSwiftEnumPlusConventions() {
        let declared = Set(ManuscriptRecordKind.descriptor.triage.statusValues)
        let fromEnum = Set(JournalManuscriptStatus.allCases.map(\.rawValue))
        XCTAssertEqual(
            declared, fromEnum,
            "descriptor statuses must track JournalManuscriptStatus"
        )
    }

    func testManuscriptCreationTracksDocumentFormats() {
        let labels = ManuscriptRecordKind.descriptor.creation.compactMap(\.formatValue)
        XCTAssertEqual(labels, DocumentFormat.allCases.map(\.rawValue))
    }

    // MARK: - Collection capability (ADR-0022 D3 / WP G2)

    /// The two kinds with sidebar folders declare a binding; everything else
    /// declares none. A kind that grows folders must ALSO get a
    /// `CollectionStoreAdapter` binding — that pairing is the next test.
    func testOnlyFolderCapableKindsDeclareACollectionBinding() {
        XCTAssertEqual(
            ManuscriptRecordKind.descriptor.collection?.bindingID,
            CollectionBindingID.manuscript
        )
        XCTAssertEqual(
            FigureRecordKind.descriptor.collection?.bindingID,
            CollectionBindingID.figure
        )
        // ADR-0022 C2: publications joined the declared bindings. Their
        // capability is the one that exercises all three optional axes, so it
        // is pinned in full rather than merely asserted non-nil.
        let publication = try! XCTUnwrap(PublicationRecordKind.descriptor.collection)
        XCTAssertEqual(publication.bindingID, CollectionBindingID.publication)
        XCTAssertEqual(
            publication.organizePolicy, .unlessSmart,
            "smart collections offer Delete only — the per-row predicate (axis 2)")
        XCTAssertEqual(
            publication.container?.noun, "Library",
            "publication collections are per-library (axis 1)")
        XCTAssertEqual(
            publication.tiers.map(\.id),
            [CollectionTierID.libraries, CollectionTierID.inbox, CollectionTierID.exploration],
            "the three tiers the same binding appears in (axis 4)")
        XCTAssertEqual(
            publication.deleteContainerTitle, "Delete",
            "imbib's frozen menu says a bare 'Delete', not 'Delete Collection'")
        XCTAssertEqual(publication.newSubContainerTitle, "New Subcollection")

        for descriptor in [
            ArtifactRecordKind.descriptor,
            MessageRecordKind.descriptor,
            TaskRecordKind.descriptor,
            AgentRunRecordKind.descriptor,
        ] {
            XCTAssertNil(
                descriptor.collection,
                "\(descriptor.displayName) has no sidebar folders yet (message/agent "
                    + "folders are a later work package — ADR-0022 D2/G2)"
            )
        }
    }

    /// ADR-0022 C2 axis 1: exactly ONE kind is container-scoped, and only that
    /// kind's containers are excluded from section-level folder hosting.
    ///
    /// This is the interlock behind the third gate in
    /// `ImbibSidebarViewModel.folderCapability(ofSection:)`. `.inbox`,
    /// `.libraries` and `.exploration` are all `.primary` sections bound to
    /// `.publication`, so without that gate declaring this capability would
    /// have handed three section headers a "New Collection" item, folder drop
    /// acceptance and `reorderFolders` — none of which imbib has ever done.
    func testOnlyPublicationsAreContainerScoped() {
        XCTAssertNotNil(PublicationRecordKind.descriptor.collection?.container)
        XCTAssertNil(
            ManuscriptRecordKind.descriptor.collection?.container,
            "manuscript folders are global and genuinely section-rooted")
        XCTAssertNil(
            FigureRecordKind.descriptor.collection?.container,
            "figure folders are global and genuinely section-rooted")
    }

    /// The tier table is the matrix rows, in code. Pinned so a tier cannot
    /// drift from the behaviour it claims (ADR-0022 C2 axis 4).
    func testPublicationTiersMatchTheFrozenMatrixRows() throws {
        let capability = try XCTUnwrap(PublicationRecordKind.descriptor.collection)
        // Matrix `libraryCollection`: ✅ Rename / Subcoll / Delete.
        let libraries = try XCTUnwrap(capability.tier(CollectionTierID.libraries))
        XCTAssertTrue(libraries.allowsRename)
        XCTAssertTrue(libraries.allowsSubcontainers)
        // Matrix `inboxCollection`: rename ✅, delete ✅.
        let inbox = try XCTUnwrap(capability.tier(CollectionTierID.inbox))
        XCTAssertTrue(inbox.allowsRename)
        // Matrix `explorationCollection`: "✅ Delete" ONLY — named by the
        // search that produced it.
        let exploration = try XCTUnwrap(capability.tier(CollectionTierID.exploration))
        XCTAssertFalse(exploration.allowsRename)
        XCTAssertFalse(exploration.allowsSubcontainers)
        XCTAssertFalse(
            capability.allowsOrganize(isSmart: false, tier: exploration),
            "an exploration collection offers neither rename nor sub-collections")
    }

    /// Axis 2 evaluated where it belongs: on the ROW, from the kernel's flag.
    func testSmartRowsLoseTheOrganiseVerbsAndOtherKindsDoNot() throws {
        let publication = try XCTUnwrap(PublicationRecordKind.descriptor.collection)
        XCTAssertTrue(publication.allowsOrganize(isSmart: false))
        XCTAssertFalse(
            publication.allowsOrganize(isSmart: true),
            "a smart publication collection is defined by its query — Delete only")

        // Manuscript/figure schemas have no smart rows; their menus are
        // unchanged whatever a stray flag might say.
        for descriptor in [ManuscriptRecordKind.descriptor, FigureRecordKind.descriptor] {
            let capability = try XCTUnwrap(descriptor.collection)
            XCTAssertEqual(capability.organizePolicy, .always)
            XCTAssertTrue(capability.allowsOrganize(isSmart: true))
        }
    }

    /// Every declared binding id must resolve to a kernel binding, and every
    /// organisable kind must declare the pasteboard type its rows drag —
    /// otherwise records could never be filed into its folders.
    func testDeclaredBindingsResolveAndCarryADragType() {
        for descriptor in BuiltinRecordKinds.collectionCapable {
            let capability = try! XCTUnwrap(descriptor.collection)
            XCTAssertTrue(
                CollectionBindingID.all.contains(capability.bindingID),
                "\(descriptor.displayName) declares unknown binding "
                    + "'\(capability.bindingID)'"
            )
            XCTAssertNotNil(
                CollectionStoreAdapter.binding(for: capability.bindingID),
                "\(descriptor.displayName)'s binding has no SharedCollectionBinding"
            )
            // A kind whose rows are filed by the GENERIC record-drop path must
            // declare the pasteboard type those rows drag, or records could
            // never be filed into its containers.
            //
            // Publications are the documented exception (ADR-0022 C2): their
            // rows are dropped by `handlePublicationDrop` on imbib's own
            // `UTType.publicationID`, because filing a publication carries
            // library-membership semantics and feeds the publication-only
            // multi-select union — see the C2 matrix note. `dragUTTypeIdentifier`
            // is therefore deliberately nil, which is exactly what keeps
            // `handleRecordDrop` from claiming that path.
            if capability.canOrganize, capability.container == nil {
                XCTAssertNotNil(
                    capability.dragUTTypeIdentifier,
                    "\(descriptor.displayName) folders accept drops but the kind "
                        + "declares no drag UTType"
                )
            }
        }
    }

    /// The drag UTTypes are spelled out in the descriptors (the RecordKind
    /// folder must not import view types), so pin them to the exported ones.
    func testCollectionDragTypesMatchTheExportedUTTypes() {
        XCTAssertEqual(
            ManuscriptRecordKind.descriptor.collection?.dragUTTypeIdentifier,
            UTType.manuscriptID.identifier
        )
        XCTAssertEqual(
            FigureRecordKind.descriptor.collection?.dragUTTypeIdentifier,
            UTType.figureID.identifier
        )
    }

    /// Binding ids are the Rust enum's variant names — a rename on either
    /// side must break here rather than at runtime.
    func testBindingIDsCoverTheKernelEnum() {
        XCTAssertEqual(
            CollectionBindingID.all,
            ["publication", "manuscript", "figure", "generic"]
        )
        for bindingID in CollectionBindingID.all {
            XCTAssertNotNil(CollectionStoreAdapter.binding(for: bindingID))
        }
        XCTAssertNil(CollectionStoreAdapter.binding(for: "mail-folder"))
    }

    /// Kind-intrinsic lookups must NOT go through a shell registry: imbib's
    /// preset omits the figure kind but shows the Figures section, so a
    /// shell-scoped lookup would silently make its folders read-only.
    func testBuiltinRegistryCoversKindsMissingFromTheImbibShell() {
        XCTAssertNil(
            AppShellConfiguration.imbib.recordKinds[.figure],
            "precondition: the imbib preset does not register the figure kind"
        )
        XCTAssertEqual(
            BuiltinRecordKinds.registry[.figure]?.collection?.bindingID,
            CollectionBindingID.figure
        )
        XCTAssertEqual(
            BuiltinRecordKinds.registry.descriptor(
                forCollectionBinding: CollectionBindingID.manuscript)?.id,
            .manuscript
        )
    }

    func testStableViewIDsAreDeterministicAndDistinct() {
        let a = ManuscriptListScope.all.stableViewID
        let b = ManuscriptListScope.all.stableViewID
        XCTAssertEqual(a, b, "same scope must produce the same id across evaluations")
        XCTAssertNotEqual(
            ManuscriptListScope.status(.draft).stableViewID,
            ManuscriptListScope.status(.submitted).stableViewID
        )
        XCTAssertNotEqual(
            ManuscriptListScope.flagged(nil).stableViewID,
            ManuscriptListScope.flagged(.red).stableViewID
        )
    }
}
#endif
