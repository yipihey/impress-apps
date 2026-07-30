//
//  RecordKindPresentationTests.swift
//  PublicationManagerCoreTests
//
//  The descriptor's PRESENTATION declarations — `symbolName`,
//  `pluralDisplayName`, `CollectionCapability.folderSymbolName` /
//  `containerNoun` — and the empty-state table.
//
//  Each of these replaced a `switch` or a literal that had to be edited per
//  kind. The tests freeze what those produced, so "the descriptor answers now"
//  is a refactor rather than a redesign.
//

import XCTest
@testable import PublicationManagerCore

final class RecordKindPresentationTests: XCTestCase {

    // MARK: - Symbols

    /// Every kind declares a symbol, and none of them is the unknown glyph.
    ///
    /// This is the assertion that closes the ADR-0021 litmus's "one-line
    /// exception": adding a kind used to require a `case` in
    /// `RecordKindIconography.symbolName(for:)`, and forgetting it showed the
    /// honest-but-wrong `questionmark.square.dashed`. The symbol is now part of
    /// the declaration, so forgetting it fails here instead of shipping.
    func testEveryKindDeclaresItsOwnSymbol() {
        for descriptor in BuiltinRecordKinds.all {
            XCTAssertFalse(
                descriptor.symbolName.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(descriptor.id.rawValue) declares no symbol")
            XCTAssertNotEqual(
                descriptor.symbolName, RecordKindDescriptor.unknownSymbolName,
                "\(descriptor.id.rawValue) left symbolName at the unknown-kind default")
        }
    }

    /// The symbols the retired seven-arm switch produced, frozen. A row in
    /// grouped search or the Related section must look the same after the
    /// switch's removal as before it.
    func testKindSymbolsReproduceTheFormerSwitch() {
        let frozen: [(RecordKindID, String)] = [
            (.publication, "doc.text"),
            (.manuscript, "doc.richtext"),
            (.figure, "photo"),
            (.message, "envelope"),
            (.task, "checklist"),
            (.agentRun, "bolt"),
            (.artifact, "archivebox"),
        ]
        for (kind, symbol) in frozen {
            XCTAssertEqual(
                RecordKindIconography.symbolName(for: kind), symbol,
                "symbol for \(kind.rawValue)")
        }
    }

    /// The unknown paths still degrade honestly rather than picking a wrong
    /// glyph — the property the switch's `default` arm provided.
    func testUnknownKindsAndSchemaRefsGetTheUnknownGlyph() {
        XCTAssertEqual(
            RecordKindIconography.symbolName(for: nil),
            RecordKindDescriptor.unknownSymbolName)
        XCTAssertEqual(
            RecordKindIconography.symbolName(for: RecordKindID("audio-recording")),
            RecordKindDescriptor.unknownSymbolName,
            "a kind no build registers is unknown, not mislabelled")
        XCTAssertEqual(
            RecordKindIconography.symbolName(forStoreSchemaRef: "collection"),
            RecordKindDescriptor.unknownSymbolName,
            "a collection row is not a record kind")
    }

    /// Artifacts were the live casualty of the wrong descriptor ref: every
    /// `impress/artifact/*` row resolved to no kind at all, so grouped search
    /// and the Related section showed them as "unknown". Now they resolve.
    func testArtifactRowsResolveToTheArtifactKind() {
        for medium in [
            "code", "dataset", "general", "media", "note", "poster", "presentation",
            "webpage",
        ] {
            let ref = "impress/artifact/\(medium)"
            XCTAssertEqual(
                BuiltinRecordKinds.registry.kind(forStoreSchemaRef: ref), .artifact,
                "\(ref) must resolve to the artifact kind")
            XCTAssertEqual(
                RecordKindIconography.symbolName(forStoreSchemaRef: ref), "archivebox")
        }
        XCTAssertNil(
            BuiltinRecordKinds.registry.descriptor(forSchemaRef: "artifact"),
            "the bare 'artifact' ref never existed in any registry and must not "
                + "resolve — keeping it would re-legalise the bug")
    }

    // MARK: - Plurals

    /// The sidebar's "All …" row used `displayName + \"s\"`. Every shipped kind
    /// happens to pluralise that way, which is exactly why the latent bug was
    /// invisible; the declaration is now explicit and checked.
    func testPluralNamesAreDeclaredAndNonEmpty() {
        for descriptor in BuiltinRecordKinds.all {
            XCTAssertFalse(
                descriptor.pluralDisplayName.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(descriptor.id.rawValue) declares no plural")
            XCTAssertNotEqual(
                descriptor.pluralDisplayName, descriptor.displayName,
                "\(descriptor.id.rawValue): a plural equal to the singular is almost "
                    + "certainly a mistake in English")
        }
    }

    func testPluralNamesReproduceTheFormerConcatenation() {
        let frozen: [(RecordKindID, String)] = [
            (.publication, "Publications"),
            (.manuscript, "Manuscripts"),
            (.figure, "Figures"),
            (.message, "Messages"),
            (.task, "Tasks"),
            (.agentRun, "Agent Runs"),
            (.artifact, "Artifacts"),
        ]
        for (kind, plural) in frozen {
            XCTAssertEqual(
                BuiltinRecordKinds.registry[kind]?.pluralDisplayName, plural,
                "plural for \(kind.rawValue) — this string is a sidebar row title")
        }
    }

    // MARK: - Containers

    /// Folder glyph and menu titles are declared, and default to what the
    /// hardcoded versions said.
    func testCollectionCapabilitiesDeclareTheirContainerVocabulary() {
        for descriptor in BuiltinRecordKinds.collectionCapable {
            guard let collection = descriptor.collection else { continue }
            XCTAssertFalse(collection.folderSymbolName.isEmpty)
            XCTAssertFalse(collection.containerNoun.isEmpty)
            // The three AppKit menu titles that used to be inline literals in
            // ImbibSidebarViewModel, frozen for the shipped kinds.
            XCTAssertEqual(collection.newContainerTitle, "New Folder")
            XCTAssertEqual(collection.newSubContainerTitle, "New Subfolder")
            XCTAssertEqual(collection.deleteContainerTitle, "Delete Folder")
            XCTAssertEqual(collection.folderSymbolName, "folder")
        }
    }

    /// A kind whose containers are not called folders gets the right words
    /// without any app-side `if` — the reason the noun is data.
    func testContainerNounDrivesTheMenuTitles() {
        let mailbox = CollectionCapability(
            bindingID: CollectionBindingID.generic,
            containerNoun: "Mailbox")
        XCTAssertEqual(mailbox.newContainerTitle, "New Mailbox")
        XCTAssertEqual(mailbox.newSubContainerTitle, "New Submailbox")
        XCTAssertEqual(mailbox.deleteContainerTitle, "Delete Mailbox")
    }

    // MARK: - Section roles

    /// The role now lives on `SidebarSectionType`, beside `displayName` and
    /// `icon`; the chassis helper forwards. Frozen so the forwarding cannot
    /// change any section's behaviour.
    func testSectionRolesAreUnchangedAndTotal() {
        let frozen: [(SidebarSectionType, RecordSidebarSectionRole)] = [
            (.inbox, .primary), (.libraries, .primary), (.sharedWithMe, .opaque),
            (.scixLibraries, .opaque), (.search, .opaque), (.exploration, .primary),
            (.flagged, .flagged), (.citedInManuscripts, .opaque),
            (.artifacts, .primary), (.manuscripts, .primary), (.figures, .primary),
            (.mail, .primary), (.agents, .primary), (.reviewQueue, .opaque),
            (.dismissed, .dismissed),
        ]
        XCTAssertEqual(
            frozen.count, SidebarSectionType.allCases.count,
            "a section was added — give it a role and freeze it here")
        for (section, role) in frozen {
            XCTAssertEqual(section.role, role, "role of \(section.rawValue)")
            XCTAssertEqual(
                RecordSidebarSectionRole.role(for: section), role,
                "the chassis helper must forward to the section's own declaration")
        }
    }

    // MARK: - Empty states

    /// The relocated copy, verbatim. `SectionContentView` hand-wrote these
    /// inline; the table is a relocation, so the strings are the contract.
    func testEmptyStateCopyIsPreservedVerbatim() {
        XCTAssertEqual(ChassisEmptyState.inboxEmpty.title, "Inbox Empty")
        XCTAssertEqual(ChassisEmptyState.inboxEmpty.systemImage, "tray")
        XCTAssertEqual(
            ChassisEmptyState.inboxEmpty.message, "Add feeds to start discovering papers")

        XCTAssertEqual(ChassisEmptyState.noSidebarSelection.title, "No Selection")
        XCTAssertEqual(ChassisEmptyState.noSidebarSelection.systemImage, "sidebar.left")
        XCTAssertEqual(
            ChassisEmptyState.noSidebarSelection.message, "Select an item from the sidebar")

        XCTAssertEqual(ChassisEmptyState.searchResultsElsewhere.title, "Search Results")
        XCTAssertEqual(
            ChassisEmptyState.searchResultsElsewhere.message,
            "Results appear in the Exploration section of the sidebar.")

        let publication = ChassisEmptyState.noRowSelection(isArtifact: false)
        XCTAssertEqual(publication.title, "No Selection")
        XCTAssertEqual(publication.systemImage, "doc.text")
        XCTAssertEqual(publication.message, "Select a publication to view details")

        let artifact = ChassisEmptyState.noRowSelection(isArtifact: true)
        XCTAssertEqual(artifact.systemImage, "archivebox")
        XCTAssertEqual(artifact.message, "Select an artifact to view details")

        XCTAssertEqual(
            ChassisEmptyState.viewerUnavailable(kind: .figure).message,
            "No registered viewer for \u{201C}figure\u{201D}.")
        XCTAssertEqual(
            ChassisEmptyState.surfaceUnavailable(id: "canvas").message,
            "No registered surface named \u{201C}canvas\u{201D}.")
    }

    /// Every state is fully populated, and ids are unique so a test or a
    /// transition can name one.
    func testEveryEmptyStateIsCompleteAndUniquelyIdentified() {
        var states = ChassisEmptyState.allParameterless
        states.append(.viewerUnavailable(kind: .publication))
        states.append(.surfaceUnavailable(id: "x"))
        states.append(.noRowSelection(isArtifact: false))
        states.append(.noRowSelection(isArtifact: true))

        for state in states {
            XCTAssertFalse(state.id.isEmpty)
            XCTAssertFalse(state.title.isEmpty, "\(state.id) has no title")
            XCTAssertFalse(state.systemImage.isEmpty, "\(state.id) has no glyph")
            XCTAssertFalse(state.message.isEmpty, "\(state.id) has no message")
        }
        let ids = states.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate empty-state ids: \(ids)")
    }

    // MARK: - Publication detail tabs

    /// `DetailTabSpec`/`coercedTab` had view-side consumers for manuscripts,
    /// messages, figures and agent runs — publications, the kind it was
    /// modelled on, still hardcoded `[.info, .pdf, .notes, .bibtex]` in
    /// `DetailView` and four inline `Tab`s in imbib-iOS. Both now read this.
    func testPublicationTabsMatchTheFormerHardcodedArray() {
        let editable = RecordTabContext(isEditable: true)
        XCTAssertEqual(
            PublicationRecordKind.descriptor.availableTabs(for: editable),
            [.info, .pdf, .notes, .bibtex],
            "order is the tab-bar order AND the h/l cycling order")

        // The skip the cycler used to hand-write: a non-library paper has no
        // Notes tab, so it is simply not in the ring.
        let readOnly = RecordTabContext(isEditable: false)
        XCTAssertEqual(
            PublicationRecordKind.descriptor.availableTabs(for: readOnly),
            [.info, .pdf, .bibtex])
        XCTAssertEqual(
            PublicationRecordKind.descriptor.coercedTab(.notes, for: readOnly), .info,
            "a persisted Notes selection on a read-only paper coerces, not crashes")
    }
}
