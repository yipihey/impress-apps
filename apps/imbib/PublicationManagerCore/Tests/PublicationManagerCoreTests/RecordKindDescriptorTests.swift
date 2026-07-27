//
//  RecordKindDescriptorTests.swift
//  PublicationManagerCoreTests
//
//  Stage 1 (ADR-0021) regression oracle: the record-kind descriptors must
//  reproduce the legacy DetailTab.ItemKind behavior EXACTLY (frozen in
//  docs/chassis-capability-matrix.md "Record-kind descriptor contract")
//  before any legacy path is deleted.
//

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
        let declared = Set(ManuscriptRecordKind.descriptor.triage.statuses)
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
