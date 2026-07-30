//
//  PublicationDetailSharedSurfaceTests.swift
//  PublicationManagerCoreTests
//
//  Stage 5b regression oracle: the publication detail pane's shared halves.
//
//  Every assertion here pins something that was written TWICE before this pass
//  and had drifted between the copies. The drifts are the tests: an identifier
//  URL template, the exploration label/help rules, the `note` field's format,
//  the PDF availability classification. A structural test at the end keeps the
//  new cross-platform files from being re-gated, the same guard
//  `ChassisCrossPlatformContractTests` applies to the rest of the contract.
//

import XCTest
@testable import PublicationManagerCore

final class PublicationDetailSharedSurfaceTests: XCTestCase {

    // MARK: - Identifier links (was: three copies of four URL templates)

    func testIdentifierLinksResolveEveryShippedTemplateInOrder() {
        let links = PublicationIdentifierLink.all(
            doi: "10.1086/164143", arxivID: "2401.00001",
            bibcode: "1986ApJ...304...15B", pmid: "12345678")

        XCTAssertEqual(links.map(\.kind), [.doi, .arxiv, .ads, .pubmed])
        XCTAssertEqual(links.map(\.label), ["DOI", "arXiv", "ADS", "PubMed"])
        XCTAssertEqual(
            links.map(\.urlString),
            [
                "https://doi.org/10.1086/164143",
                "https://arxiv.org/abs/2401.00001",
                "https://ui.adsabs.harvard.edu/abs/1986ApJ...304...15B",
                "https://pubmed.ncbi.nlm.nih.gov/12345678",
            ])
        for link in links {
            XCTAssertNotNil(link.url, "\(link.label) must produce a URL")
        }
    }

    /// The iOS More menu had rows for DOI / arXiv / ADS and none for PubMed.
    /// Every kind must be nameable in a menu, or the omission comes back.
    func testEveryIdentifierKindHasAMenuTitleAndHelpText() {
        for kind in PublicationIdentifierLink.Kind.allCases {
            XCTAssertEqual(kind.menuTitle, "Open \(kind.label)")
            XCTAssertFalse(kind.openHelpText.isEmpty)
        }
    }

    func testAbsentAndEmptyIdentifiersProduceNoRow() {
        XCTAssertTrue(
            PublicationIdentifierLink.all(
                doi: nil, arxivID: nil, bibcode: nil, pmid: nil
            ).isEmpty)
        // An empty field used to render "DOI:" linking to `https://doi.org/`.
        XCTAssertTrue(
            PublicationIdentifierLink.all(
                doi: "", arxivID: "   ", bibcode: nil, pmid: nil
            ).isEmpty)
    }

    // MARK: - Exploration (was: macOS's four copies + iOS's count > 0)

    func testExplorationLabelsCarryCountsWhenEnriched() {
        let model = PublicationExplorationModel(
            doi: "10.1/x", arxivID: nil, bibcode: nil,
            referenceCount: 42, citationCount: 7)

        XCTAssertEqual(model.label(for: .references), "References (42)")
        XCTAssertEqual(model.label(for: .citations), "Citations (7)")
        // Uncounted kinds never grow a number.
        XCTAssertEqual(model.label(for: .similar), "Similar")
        XCTAssertEqual(model.label(for: .coReads), "Co-Reads")
        XCTAssertEqual(model.label(for: .wosRelated), "WoS Related")
    }

    func testExplorationAvailabilityDistinguishesNotEnrichedFromUnavailable() {
        let withIdentifiers = PublicationExplorationModel(
            doi: nil, arxivID: "2401.00001", bibcode: nil,
            referenceCount: 0, citationCount: 0)
        XCTAssertEqual(withIdentifiers.availability(of: .references), .notEnriched)
        XCTAssertEqual(
            withIdentifiers.helpText(for: .references),
            "Click to find papers this paper cites")

        let withoutIdentifiers = PublicationExplorationModel(
            doi: nil, arxivID: nil, bibcode: nil,
            referenceCount: 0, citationCount: 0)
        XCTAssertEqual(withoutIdentifiers.availability(of: .citations), .unavailable)
        XCTAssertEqual(
            withoutIdentifiers.helpText(for: .citations),
            "No identifiers available for lookup")

        let enriched = PublicationExplorationModel(
            doi: "10.1/x", arxivID: nil, bibcode: nil,
            referenceCount: 3, citationCount: 5)
        XCTAssertEqual(enriched.helpText(for: .references), "Show 3 referenced papers")
        XCTAssertEqual(enriched.helpText(for: .citations), "Show 5 citing papers")
    }

    /// The un-loaded pane (macOS's `guard let pub … else { .unavailable }`).
    func testExplorationOfAnUnloadedPublicationIsUnavailable() {
        let model = PublicationExplorationModel(publication: nil)
        XCTAssertFalse(model.canExplore)
        for kind in PublicationExplorationKind.allCases {
            XCTAssertEqual(model.availability(of: kind), .unavailable)
        }
    }

    /// WoS co-citation keys on a DOI — iOS's `if pub.doi != nil`, now declared.
    func testWoSRelatedIsOfferedOnlyWithADOI() {
        let withDOI = PublicationExplorationModel(
            doi: "10.1/x", arxivID: nil, bibcode: nil, referenceCount: 0, citationCount: 0)
        XCTAssertEqual(
            withDOI.offeredKinds,
            [.references, .citations, .similar, .coReads, .wosRelated])

        let arxivOnly = PublicationExplorationModel(
            doi: nil, arxivID: "2401.1", bibcode: nil, referenceCount: 0, citationCount: 0)
        XCTAssertEqual(arxivOnly.offeredKinds, [.references, .citations, .similar, .coReads])
        XCTAssertFalse(arxivOnly.offeredKinds.contains(.wosRelated))
    }

    /// macOS renders four buttons; the shared model must not be able to smuggle
    /// a fifth into the frozen pane, so the four it ships stay a prefix of the
    /// declaration order.
    func testMacExplorationRowIsThePrefixOfTheDeclaredOrder() {
        XCTAssertEqual(
            Array(PublicationExplorationKind.allCases.prefix(4)),
            [.references, .citations, .similar, .coReads])
    }

    // MARK: - Notes document (was: macOS parsed the field, iOS did not)

    func testNotesDocumentSplitsFrontMatterFromFreeform() {
        let settings = QuickAnnotationSettings.defaults
        guard let field = settings.fields.first(where: \.isEnabled) else {
            return XCTFail("expected at least one enabled annotation field")
        }
        let raw = """
            ---
            \(field.label): Pioneer in this field
            ---

            Actual reading notes.
            """

        let document = PublicationNotesDocument(rawNote: raw, settings: settings)
        XCTAssertEqual(document.annotations[field.id], "Pioneer in this field")
        XCTAssertEqual(document.freeform, "Actual reading notes.")
        XCTAssertEqual(document.populatedAnnotationIDs, [field.id])
        // The bug: iOS's editor showed the whole thing, front matter included.
        XCTAssertFalse(document.freeform.contains("---"))
        XCTAssertFalse(document.freeform.contains(field.label))
    }

    /// Editing ONLY the freeform half must not lose the annotations. This is
    /// the round trip iOS could not perform: it wrote its raw buffer back.
    func testEditingFreeformPreservesAnnotationsThroughARoundTrip() {
        let settings = QuickAnnotationSettings.defaults
        guard let field = settings.fields.first(where: \.isEnabled) else {
            return XCTFail("expected at least one enabled annotation field")
        }
        let raw = """
            ---
            \(field.label): Pioneer in this field
            ---

            Original notes.
            """

        var document = PublicationNotesDocument(rawNote: raw, settings: settings)
        document.freeform = "Edited on iPhone."

        let serialized = document.serialized(settings: settings)
        let reparsed = PublicationNotesDocument(rawNote: serialized, settings: settings)

        XCTAssertEqual(reparsed.annotations[field.id], "Pioneer in this field")
        XCTAssertEqual(reparsed.freeform, "Edited on iPhone.")
    }

    func testNotesDocumentWithoutFrontMatterIsAllFreeform() {
        let document = PublicationNotesDocument(
            rawNote: "Just notes.", settings: .defaults)
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertEqual(document.freeform, "Just notes.")
        XCTAssertFalse(document.isEmpty)
        XCTAssertTrue(PublicationNotesDocument().isEmpty)
    }

    // MARK: - PDF availability (was: five macOS booleans vs an iOS enum)

    func testPDFAvailabilityClassifiesALocalFile() {
        let file = Self.linkedPDF()
        let publication = Self.publication(linkedFiles: [file])
        XCTAssertEqual(
            PublicationPDFAvailability.resolve(
                publication: publication, libraryID: UUID(), fileExists: { _, _ in true }),
            .localFile(file))
    }

    func testPDFAvailabilityDistinguishesCloudOnlyFromMissing() {
        let cloud = Self.linkedPDF(cloudAvailable: true, materialized: false)
        XCTAssertEqual(
            PublicationPDFAvailability.resolve(
                publication: Self.publication(linkedFiles: [cloud]),
                libraryID: UUID(), fileExists: { _, _ in false }),
            .cloudOnly(cloud))

        let gone = Self.linkedPDF(cloudAvailable: false, materialized: false)
        XCTAssertEqual(
            PublicationPDFAvailability.resolve(
                publication: Self.publication(linkedFiles: [gone]),
                libraryID: UUID(), fileExists: { _, _ in false }),
            .fileMissing(gone))
    }

    func testPDFAvailabilityWithNoFileFallsBackToIdentifiers() {
        XCTAssertEqual(
            PublicationPDFAvailability.resolve(
                publication: Self.publication(fields: ["doi": "10.1/x"]),
                libraryID: nil, fileExists: { _, _ in false }),
            .remoteAvailable)

        XCTAssertEqual(
            PublicationPDFAvailability.resolve(
                publication: Self.publication(),
                libraryID: nil, fileExists: { _, _ in false }),
            .unavailable)

        XCTAssertEqual(
            PublicationPDFAvailability.resolve(
                publication: nil, libraryID: nil, fileExists: { _, _ in true }),
            .unavailable)
    }

    /// macOS's PDF tab has always accepted a bare `eprint`; iOS's did not, so a
    /// paper imported with only that field offered no download on iPhone.
    func testEprintOnlyPaperCountsAsFetchable() {
        XCTAssertTrue(
            PublicationPDFAvailability.hasFetchableIdentifier(
                Self.publication(fields: ["eprint": "2401.00001"])))
        XCTAssertFalse(
            PublicationPDFAvailability.hasFetchableIdentifier(Self.publication()))
    }

    // MARK: - Structural: the shared halves must not get re-gated

    /// The Stage 5b data/logic files. Each is consumed by BOTH detail panes; a
    /// `#if os(macOS)` on any of them silently reverts iOS to its own copy —
    /// which is how the duplication arose in the first place.
    private static let sharedDetailFiles = [
        "Chassis/Detail/Shared/PublicationIdentifierLink.swift",
        "Chassis/Detail/Shared/PublicationFlagAndTagsSection.swift",
        "Chassis/Detail/Shared/PublicationExploration.swift",
        "Chassis/Detail/Shared/PublicationNotesDocument.swift",
        "Chassis/Detail/Shared/PublicationPDFSwitcher.swift",
        "Chassis/Detail/Shared/PublicationPDFAvailability.swift",
        "Chassis/Detail/Shared/PublicationDetailLifecycle.swift",
        // The BibTeX tab itself collapsed: one view, both platforms.
        "Chassis/Detail/Tabs/BibTeXTab.swift",
    ]

    func testSharedDetailFilesAreNotWrappedInAMacOSGate() throws {
        for relativePath in Self.sharedDetailFiles {
            let url = Self.sourcesRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            let firstCode = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? ""
            XCTAssertFalse(
                firstCode.hasPrefix("#if os(macOS)"),
                """
                \(relativePath) is wrapped in `#if os(macOS)`. It is consumed by \
                imbib-iOS's detail pane; re-gating it re-creates the iOS copy \
                this stage deleted. If a macOS-only symbol landed in it, SPLIT \
                the file.
                """)
        }
    }

    /// The chromes that genuinely differ stay where they are: macOS's shell and
    /// its Info/Notes/PDF tabs are AppKit-adjacent (NSPasteboard, NSSavePanel,
    /// NSWorkspace, the PDF browser window controller, HelixNotesTextEditor as
    /// an NSViewRepresentable) and iOS renders its own.
    func testMacOSOnlyDetailChromeStaysGated() throws {
        let gated = [
            "Chassis/Detail/DetailView.swift",
            "Chassis/Detail/Tabs/InfoTab.swift",
            "Chassis/Detail/Tabs/NotesTab.swift",
            "Chassis/Detail/Tabs/PDFTab.swift",
        ]
        for relativePath in gated {
            let url = Self.sourcesRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(
                text.hasPrefix("#if os(macOS)"),
                "\(relativePath) must stay macOS-gated")
        }
    }

    // MARK: - Fixtures

    /// The domain models are built from Rust rows (`init(from:)` is their only
    /// initializer), so the fixtures go through the same boundary the app does.
    private static func linkedPDF(
        cloudAvailable: Bool = false, materialized: Bool = true
    ) -> LinkedFileModel {
        LinkedFileModel(
            from: LinkedFileRow(
                id: "00000000-0000-0000-0000-0000000000AA",
                filename: "Bardeen_1986_Statistics.pdf",
                relativePath: "Papers/Bardeen_1986_Statistics.pdf",
                fileSize: 1024,
                isPdf: true,
                isLocallyMaterialized: materialized,
                pdfCloudAvailable: cloudAvailable,
                dateAdded: 0))
    }

    private static func publication(
        linkedFiles: [LinkedFileModel] = [], fields: [String: String] = [:]
    ) -> PublicationModel {
        PublicationModel(
            from: PublicationDetail(
                id: "00000000-0000-0000-0000-0000000000BB",
                citeKey: "Bardeen1986Statistics",
                entryType: "article",
                fields: fields,
                isRead: false,
                isStarred: false,
                flagColor: nil,
                flagStyle: nil,
                flagLength: nil,
                tags: [],
                authors: [],
                dateAdded: 0,
                dateModified: 0,
                linkedFiles: linkedFiles.map { file in
                    LinkedFileRow(
                        id: file.id.uuidString,
                        filename: file.filename,
                        relativePath: file.relativePath,
                        fileSize: file.fileSize,
                        isPdf: file.isPDF,
                        isLocallyMaterialized: file.isLocallyMaterialized,
                        pdfCloudAvailable: file.pdfCloudAvailable,
                        dateAdded: 0)
                },
                citationCount: 0,
                referenceCount: 0,
                rawBibtex: nil,
                collections: [],
                libraries: []))
    }

    private static let sourcesRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PublicationManagerCore")
    }()
}
