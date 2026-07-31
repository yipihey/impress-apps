//
//  FileDiscoveryCapabilityParityTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D1: "Watchable file types are declared, not coded." The declaration
//  is `RecordKindDescriptor.fileDiscovery`; this file is the referee that keeps
//  it honest against the three authorities it claims to follow.
//
//  Why this suite has to exist at all. Before ADR-0023, the answer to "which
//  file extensions are a bibliography?" lived in TWENTY-THREE independent
//  inline literals across the tree — `["bib", "bibtex", "ris"]` in imbib's
//  sidebar drop handler, the same array again in `DragDropCoordinator`,
//  `case "bib", "bibtex":` in four separate import switches, `.bib`-only open
//  panels next to `.bib`+`.ris` ones — plus one named-but-unused Swift enum
//  (`BibFileFormat`) that no call site consults. Twenty-four spellings of one
//  fact drift; the only question is when you notice. A watched folder is the
//  place you would not notice, because a scope that matches nothing looks
//  exactly like a folder with no files in it (ADR-0023 D6's whole worry, and
//  the schema-ref bug class in a different disguise).
//
//  So each declaration is pinned to the ONE place that owns it:
//
//  | Kind | Authority | How it is checked |
//  |---|---|---|
//  | manuscript | `impress_core::manuscript_format::MANUSCRIPT_FORMAT_GRAMMAR` | READ AT RUNTIME through `DocumentFormatGrammar` (the FFI cache). Nothing is restated, so nothing can drift — and the Rust SOURCE is scraped too, which additionally catches a stale xcframework. |
//  | publication | `impress_core::bibliography_format::BIBLIOGRAPHY_FORMAT_GRAMMAR` | Pinned. That table is not on the FFI surface, so the declaration is a literal and this test scrapes the Rust source it must equal. |
//  | figure, message | the same tables' absence — no Rust table owns `.vsz`/`.mbox`/`.eml` | Frozen literals, plus UTI parity against the plists that declare them. |
//  | every UTI | `apps/chassis-utis.yml` + the per-app `project.yml` document types | Scraped. A UTI no app declares resolves to nothing at runtime. |
//
//  Scraping repo files from a Swift test is the house pattern here, not an
//  improvisation: `ChassisUTIDeclarationTests` greps `apps/chassis-utis.yml`
//  the same way, and `Golden/Stage7ParityTests` reads Rust fixtures by
//  `#filePath` walk-up. It is also deliberately NOT an FFI check for the
//  bibliography table: putting that table on the UniFFI surface would tie this
//  gate to an xcframework rebuild, and a parity test that can only run after a
//  binary regenerates is a parity test people learn to skip.
//

import UniformTypeIdentifiers
import XCTest

@testable import PublicationManagerCore

final class FileDiscoveryCapabilityParityTests: XCTestCase {

    // MARK: - ADR-0023 D3: the ingest units

    /// The ingest map in ADR-0023, transcribed. `entries` is imbib and only
    /// imbib: it is the unit that means "open this file and fan it out", and it
    /// requires dedup machinery behind it. Everything else is
    /// reference-in-place.
    func testIngestUnitsMatchTheADRIngestMap() {
        XCTAssertEqual(
            PublicationRecordKind.descriptor.fileDiscovery?.ingestUnit, .entries,
            "a .bib/.ris is a CONTAINER — it fans out to entries, deduped by identifier")
        for descriptor in [
            ManuscriptRecordKind.descriptor,
            FigureRecordKind.descriptor,
            MessageRecordKind.descriptor,
        ] {
            XCTAssertEqual(
                descriptor.fileDiscovery?.ingestUnit, .file,
                "\(descriptor.id.rawValue) ingests reference-in-place (ADR-0023 D4)")
        }
    }

    /// The four kinds ADR-0023's v1 ingest map names, and no others. A kind
    /// that acquires a capability without an ADR row is a watched folder nobody
    /// designed.
    func testExactlyTheFourV1KindsAreFileDiscoverable() {
        XCTAssertEqual(
            Set(BuiltinRecordKinds.fileDiscoveryKindScopes),
            ["publication", "manuscript", "figure", "message"])
        for descriptor in [TaskRecordKind.descriptor, AgentRunRecordKind.descriptor] {
            XCTAssertNil(
                descriptor.fileDiscovery,
                "\(descriptor.id.rawValue) is a record OF work, not a file on disk")
        }
        XCTAssertNil(
            ArtifactRecordKind.descriptor.fileDiscovery,
            "the artifact domain is eight media schemas — a phase-2 question, not a v1 row")
    }

    /// The `kind_scope` a `watched-folder@1.0.0` row carries is a bare string
    /// on the Rust side, so this is where a caller learns which strings mean
    /// anything — and it must be the RECORD KIND id, because that is what
    /// resolves a capability.
    func testKindScopeVocabularyResolvesBackToCapabilities() {
        for scope in BuiltinRecordKinds.fileDiscoveryKindScopes {
            XCTAssertNotNil(
                BuiltinRecordKinds.fileDiscovery(forKindScope: scope),
                "a watched folder scoped to '\(scope)' must resolve a capability")
        }
        XCTAssertNil(
            BuiltinRecordKinds.fileDiscovery(forKindScope: "task"),
            "an unwatchable kind resolves nothing — honestly, not by crashing")
    }

    // MARK: - Manuscripts: the authority is READ, not copied

    /// The declaration must still be the runtime read. If someone "simplifies"
    /// it into a literal list, this fails the moment Rust's table and the
    /// literal differ — which is the whole reason the derivation is worth
    /// keeping.
    func testManuscriptExtensionsAreTheLiveRustGrammarTable() {
        let declared = ManuscriptRecordKind.descriptor.fileDiscovery?.fileExtensions ?? []
        let fromGrammar = DocumentFormatGrammar.allRows.flatMap(\.extensions)
        XCTAssertFalse(fromGrammar.isEmpty, "the FFI grammar table came back empty")
        XCTAssertEqual(
            declared, fromGrammar,
            """
            ManuscriptRecordKind's watched extensions are supposed to BE the Rust \
            manuscript_format table, read through DocumentFormatGrammar — not a copy \
            of it. They differ, which means the derivation was replaced by literals.
            """)
        // And one type spec per format, keyed by the format id.
        XCTAssertEqual(
            ManuscriptRecordKind.descriptor.fileDiscovery?.types.map(\.id),
            DocumentFormat.allCases.map(\.rawValue))
    }

    /// The FFI table must equal the Rust SOURCE. This is the check the runtime
    /// derivation cannot make for itself: a stale `ImbibCore.xcframework` gives
    /// a perfectly self-consistent Swift build reading last month's table.
    func testTheFFIGrammarTableEqualsTheRustSource() throws {
        let source = try Self.rustSource("crates/impress-core/src/manuscript_format.rs")
        let fromSource = Self.extensionArrays(in: source)
        XCTAssertEqual(
            fromSource.count, DocumentFormat.allCases.count,
            """
            Expected one `extensions: &[…]` row per manuscript format in \
            manuscript_format.rs, found \(fromSource.count). Either a format was \
            added/removed, or the table was restructured and this scrape needs \
            updating — do not delete the assertion, it is the stale-xcframework alarm.
            """)
        XCTAssertEqual(
            DocumentFormatGrammar.allRows.flatMap(\.extensions), fromSource.flatMap { $0 },
            """
            The manuscript grammar reaching Swift over the FFI is not what \
            crates/impress-core/src/manuscript_format.rs says. The usual cause is a \
            stale ImbibCore.xcframework — rebuild it. If the Rust table genuinely \
            changed, this passes again after the rebuild with no Swift edit, which \
            is the point of reading the table instead of copying it.
            """)
    }

    // MARK: - Publications: the table ADR-0023 had to create

    func testPublicationExtensionsAreTheRustBibliographyTable() throws {
        let source = try Self.rustSource("crates/impress-core/src/bibliography_format.rs")
        let fromSource = Self.extensionArrays(in: source)
        XCTAssertEqual(
            fromSource.count, 2,
            "expected the bibtex and ris rows in bibliography_format.rs, found \(fromSource.count)")

        let capability = try XCTUnwrap(PublicationRecordKind.descriptor.fileDiscovery)
        XCTAssertEqual(
            capability.types.map(\.fileExtensions), fromSource,
            """
            PublicationRecordKind's watched extensions have drifted from \
            impress_core::bibliography_format::BIBLIOGRAPHY_FORMAT_GRAMMAR, which is \
            the authority. The Rust table wins: change the declaration to match it. \
            (It is a literal here rather than an FFI read only because that table is \
            not on the UniFFI surface — see this file's header.)
            """)
        XCTAssertEqual(capability.fileExtensions, ["bib", "bibtex", "ris"])
        XCTAssertEqual(capability.types.map(\.id), ["bibtex", "ris"])
    }

    func testPublicationUTIsAreTheRustBibliographyTable() throws {
        let source = try Self.rustSource("crates/impress-core/src/bibliography_format.rs")
        let capability = try XCTUnwrap(PublicationRecordKind.descriptor.fileDiscovery)
        XCTAssertEqual(
            capability.utiIdentifiers, Self.declaredUTIs(in: source),
            "the capability's UTIs must be the Rust table's `uti: Some(…)` column")
        XCTAssertEqual(capability.utiIdentifiers, ["com.impress.bibtex-entry"])
    }

    /// `.ris` has no UTI anywhere in the suite, and the declaration says so
    /// rather than inventing one. This is not a nit: a discovery query built
    /// from a UTI-only clause would match zero RIS files, forever, and look
    /// exactly like "the folder has no RIS files in it".
    func testRISHasNoUTIAndTheCapabilitySaysSo() throws {
        let capability = try XCTUnwrap(PublicationRecordKind.descriptor.fileDiscovery)
        XCTAssertNil(capability.type(forExtension: "ris")?.utiIdentifier)
        XCTAssertTrue(
            capability.requiresFilenameFallback,
            "a watched .bib/.ris folder MUST match on filename as well as type")
    }

    // MARK: - UTIs must be declared somewhere real

    /// Every UTI any capability names has to be declared by an app that ships,
    /// or it resolves to nothing at runtime and the scope silently narrows.
    func testEveryDeclaredUTIIsClaimedByAnAppWithItsExtension() throws {
        let claims: [(uti: String, file: String, `extension`: String)] = [
            // imbib exports it with `public.filename-extension: [bib]` — the
            // only .bib claim in the suite (see ChassisUTIDeclarationTests for
            // why it is per-app rather than in the shared template).
            ("com.impress.bibtex-entry", "apps/imbib/imbib/project.yml", "bib"),
            // imprint IMPORTS Veusz's own type. Correct for a file the suite
            // reads but does not own.
            ("org.veusz.document", "apps/imprint/project.yml", "vsz"),
            // imprint's LaTeX Source document type.
            ("org.tug.tex", "apps/imprint/project.yml", "tex"),
        ]
        let allDeclared = Set(
            BuiltinRecordKinds.fileDiscoverable.flatMap { $0.fileDiscovery?.utiIdentifiers ?? [] })
        XCTAssertEqual(
            allDeclared, Set(claims.map(\.uti)),
            """
            A capability names a UTI this test does not know about (or has stopped \
            naming one it does). Every entry needs a real declaration site: add the \
            claim here alongside the project.yml that makes it, or the type resolves \
            to nothing at runtime and the watched folder quietly matches less than it \
            claims to.
            """)

        for claim in claims {
            let text = try Self.repoFile(claim.file)
            XCTAssertTrue(
                text.contains(claim.uti),
                "\(claim.uti) is declared by no entry in \(claim.file)")
            XCTAssertTrue(
                text.contains(claim.extension),
                "\(claim.file) must claim .\(claim.extension) for \(claim.uti)")
        }
    }

    /// The chassis template declares drag-payload types, not document types —
    /// none of it claims a filename extension (that is its stated rule). So no
    /// discovery UTI should be coming from there, and if one starts to, the
    /// claim table above is where it must be recorded.
    func testDiscoveryUTIsAreNotChassisDragTypes() throws {
        let template = try Self.repoFile("apps/chassis-utis.yml")
        for descriptor in BuiltinRecordKinds.fileDiscoverable {
            for uti in descriptor.fileDiscovery?.utiIdentifiers ?? [] {
                XCTAssertFalse(
                    template.contains("UTTypeIdentifier: \(uti)"),
                    """
                    \(uti) is a chassis drag-payload type (apps/chassis-utis.yml), \
                    which claims no filename extension by design. It cannot identify \
                    a file on disk, so a discovery scope built from it matches nothing.
                    """)
            }
        }
    }

    // MARK: - Cross-kind invariants

    /// One extension, one kind. A `.bib` that also read as a manuscript would
    /// be ingested twice, by two apps, under two units — and `descriptor(for
    /// FileExtension:)` returning "the first match" would silently pick one.
    func testNoExtensionIsClaimedByTwoKinds() {
        var owner: [String: String] = [:]
        for descriptor in BuiltinRecordKinds.fileDiscoverable {
            for ext in descriptor.fileDiscovery?.fileExtensions ?? [] {
                XCTAssertNil(
                    owner[ext],
                    ".\(ext) is claimed by both \(owner[ext] ?? "?") and \(descriptor.id.rawValue)")
                owner[ext] = descriptor.id.rawValue
            }
        }
        XCTAssertEqual(BuiltinRecordKinds.registry.descriptor(forFileExtension: "BIB")?.id, .publication)
        XCTAssertEqual(BuiltinRecordKinds.registry.descriptor(forFileExtension: "typ")?.id, .manuscript)
        XCTAssertEqual(BuiltinRecordKinds.registry.descriptor(forFileExtension: "vsz")?.id, .figure)
        XCTAssertEqual(BuiltinRecordKinds.registry.descriptor(forFileExtension: "mbox")?.id, .message)
        XCTAssertNil(BuiltinRecordKinds.registry.descriptor(forFileExtension: "pdf"))
    }

    /// Extensions are bare and lowercase everywhere, because matching
    /// lowercases its input and a stored `".BIB"` would match nothing.
    func testEveryExtensionIsBareAndLowercase() {
        for descriptor in BuiltinRecordKinds.fileDiscoverable {
            for ext in descriptor.fileDiscovery?.fileExtensions ?? [] {
                XCTAssertEqual(ext, ext.lowercased(), "\(ext) is not lowercase")
                XCTAssertFalse(ext.hasPrefix("."), "\(ext) carries a leading dot")
                XCTAssertFalse(ext.isEmpty)
            }
            for spec in descriptor.fileDiscovery?.types ?? [] {
                XCTAssertFalse(
                    spec.fileExtensions.isEmpty,
                    "\(descriptor.id.rawValue)/\(spec.id) declares a type with no extensions")
            }
        }
    }

    func testMatchingIsCaseInsensitiveAndFileNameAware() throws {
        let publications = try XCTUnwrap(PublicationRecordKind.descriptor.fileDiscovery)
        XCTAssertTrue(publications.matches(fileExtension: "BIB"))
        XCTAssertTrue(publications.matches(fileName: "Zotero Export.RIS"))
        XCTAssertTrue(publications.matches(fileName: "/Users/x/refs.bib"))
        XCTAssertFalse(publications.matches(fileName: "refs"), "no extension is not a match")
        XCTAssertFalse(publications.matches(fileName: "refs."), "an empty extension is not a match")
        XCTAssertFalse(publications.matches(fileName: "bib"), "the NAME 'bib' is not a .bib file")
        XCTAssertFalse(
            publications.matches(fileExtension: "pdf"),
            "a PDF ATTACHES to a publication (ADR-0023 W5); it never becomes one")
    }

    // MARK: - ADR-0023 W5: the attachment half

    /// The attachment types are a SECOND list, and the ingest list is untouched
    /// by them. This is the assertion that keeps W5 from having widened what a
    /// `.bib` folder ingests.
    func testAttachmentTypesDoNotEnterTheIngestList() throws {
        let capability = try XCTUnwrap(PublicationRecordKind.descriptor.fileDiscovery)
        XCTAssertEqual(
            capability.fileExtensions, ["bib", "bibtex", "ris"],
            """
            `fileExtensions` is the INGEST half and is pinned to \
            impress_core::bibliography_format, whose own test freezes it to the \
            BibTeX/RIS pair. A PDF is not a bibliography interchange format, and \
            adding one here would make that authority table lie in order to move a \
            file through a filter.
            """)
        XCTAssertEqual(capability.attachmentExtensions, ["pdf"])
        XCTAssertEqual(capability.attachmentTypes.map(\.id), ["pdf"])
        XCTAssertEqual(capability.discoveryExtensions, ["bib", "bibtex", "ris", "pdf"])
    }

    /// The PDF UTI is Apple's, read from `UniformTypeIdentifiers` — never
    /// spelled. ADR-0023 D1's "reference the authority, do not restate it"
    /// applies to the system's tables exactly as it applies to ours.
    func testThePDFUTIIsTheSystemsAndIsReadNotSpelled() throws {
        let capability = try XCTUnwrap(PublicationRecordKind.descriptor.fileDiscovery)
        XCTAssertEqual(capability.attachmentUTIIdentifiers, [UTType.pdf.identifier])
        XCTAssertEqual(
            capability.utiIdentifiers, ["com.impress.bibtex-entry"],
            "the INGEST UTI list must not have gained the PDF type")
        XCTAssertEqual(
            capability.discoveryUTIIdentifiers,
            ["com.impress.bibtex-entry", UTType.pdf.identifier],
            "a discovery query names both halves — that is how one gather finds both")
        XCTAssertEqual(
            UTType.pdf.preferredFilenameExtension, "pdf",
            "the extension is the system's too; if this ever changed the declaration would be wrong")
    }

    /// **The role marker, and the reason there is no `role` column.** W5's
    /// choice was between storing a role on `watched-file@1.0.0` and deriving
    /// it. The schema's own test (`folder_does_not_restate_the_capability`)
    /// already refuses to let a watched-folder row restate the extensions or
    /// the ingest unit; a per-file role is that same restatement one row down.
    func testTheIngestUnitOfADiscoveredFileIsDerivedFromTheDeclaration() throws {
        let capability = try XCTUnwrap(PublicationRecordKind.descriptor.fileDiscovery)
        XCTAssertEqual(capability.ingestUnit(forExtension: "bib"), .entries)
        XCTAssertEqual(capability.ingestUnit(forExtension: "RIS"), .entries)
        XCTAssertEqual(capability.ingestUnit(forExtension: "pdf"), .attachment)
        XCTAssertEqual(capability.ingestUnit(forExtension: "PDF"), .attachment)
        XCTAssertNil(capability.ingestUnit(forExtension: "typ"), "not a type this kind watches")

        XCTAssertEqual(capability.ingestUnit(forFileName: "/w/refs.bib"), .entries)
        XCTAssertEqual(
            capability.ingestUnit(forFileName: "/w/Papers/Einstein_1905_Zur.pdf"), .attachment)
        XCTAssertNil(capability.ingestUnit(forFileName: "README"), "no extension is no answer")
        XCTAssertNil(capability.ingestUnit(forFileName: "trailing."), "an empty extension is none")
    }

    /// Only publications have an attachment unit, and the others' emptiness is
    /// a decision rather than a gap: a manuscript folder has no attachment
    /// concept, and a `.vsz`'s data files are implore's `dataset_source`.
    func testOnlyPublicationsDeclareAttachmentTypes() {
        for descriptor in BuiltinRecordKinds.fileDiscoverable where descriptor.id != .publication {
            XCTAssertTrue(
                descriptor.fileDiscovery?.attachmentTypes.isEmpty ?? true,
                "\(descriptor.id.rawValue) grew an attachment unit with no ADR row")
            XCTAssertEqual(
                descriptor.fileDiscovery?.discoveryExtensions,
                descriptor.fileDiscovery?.fileExtensions,
                "with no attachments, what a folder LOOKS for is what it ingests")
        }
    }

    /// The filter a watched folder actually runs on is built from the UNION.
    /// This is the whole mechanism behind "the PDFs come from the SAME watched
    /// folder's discovery" — one folder, one registration, one gather.
    func testTheWatchedFolderFilterLooksForBothHalves() throws {
        let filter = try XCTUnwrap(FileDiscoveryFilter.forKindScope("publication"))
        XCTAssertEqual(filter.filenameExtensions, ["bib", "bibtex", "ris", "pdf"])
        XCTAssertTrue(filter.contentTypeIdentifiers.contains(UTType.pdf.identifier))
        XCTAssertEqual(
            filter, FileDiscoveryFilter.publications,
            "the two construction paths must agree; they are the same declaration")
    }

    /// `requiresFilenameFallback` is derived from the specs, never declared.
    func testTheFilenameFallbackFlagIsDerivedNotDeclared() throws {
        XCTAssertFalse(
            try XCTUnwrap(FigureRecordKind.descriptor.fileDiscovery).requiresFilenameFallback,
            ".vsz has org.veusz.document, so a type-only scope is complete")
        XCTAssertTrue(
            try XCTUnwrap(MessageRecordKind.descriptor.fileDiscovery).requiresFilenameFallback,
            "neither .mbox nor .eml has a UTI anywhere in the suite")
        XCTAssertTrue(
            try XCTUnwrap(ManuscriptRecordKind.descriptor.fileDiscovery).requiresFilenameFallback,
            "Typst and Markdown have no UTI; only .tex does")
    }

    /// The frozen halves — the two kinds with no Rust table behind them. These
    /// SHOULD fail on a deliberate change; that is what freezing is for.
    func testFigureAndMessageTypesAreFrozen() throws {
        XCTAssertEqual(
            try XCTUnwrap(FigureRecordKind.descriptor.fileDiscovery).fileExtensions, ["vsz"])
        XCTAssertEqual(
            try XCTUnwrap(MessageRecordKind.descriptor.fileDiscovery).fileExtensions,
            ["mbox", "eml"])
        XCTAssertTrue(
            try XCTUnwrap(MessageRecordKind.descriptor.fileDiscovery).utiIdentifiers.isEmpty)
    }

    // MARK: - Extraction

    private static func repoFile(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func rustSource(_ relativePath: String) throws -> String {
        try repoFile(relativePath)
    }

    /// Every `extensions: &["a", "b"]` array in a Rust grammar table, in source
    /// order.
    ///
    /// Deliberately anchored on `&[` with no lifetime between, which is what
    /// separates a table ROW (`extensions: &["typ"]`) from the struct FIELD
    /// declaration (`pub extensions: &'static [&'static str]`).
    private static func extensionArrays(in source: String) -> [[String]] {
        let pattern = try! NSRegularExpression(pattern: #"\bextensions:\s*&\[([^\]]*)\]"#)
        let quoted = try! NSRegularExpression(pattern: #""([^"]+)""#)
        var found: [[String]] = []
        let range = NSRange(source.startIndex..., in: source)
        pattern.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let inner = Range(match.range(at: 1), in: source) else { return }
            let list = String(source[inner])
            var items: [String] = []
            quoted.enumerateMatches(in: list, range: NSRange(list.startIndex..., in: list)) {
                m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: list) { items.append(String(list[r])) }
            }
            found.append(items)
        }
        return found
    }

    /// Every `uti: Some("…")` in a Rust grammar table, in source order. Rows
    /// with `uti: None` contribute nothing, which is exactly the shape
    /// `FileDiscoveryCapability.utiIdentifiers` has.
    private static func declaredUTIs(in source: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\buti:\s*Some\(\s*"([^"]+)""#)
        var found: [String] = []
        let range = NSRange(source.startIndex..., in: source)
        pattern.enumerateMatches(in: source, range: range) { match, _, _ in
            if let match, let r = Range(match.range(at: 1), in: source) {
                found.append(String(source[r]))
            }
        }
        return found
    }

    /// Repo root, derived from this test's own path so the suite is
    /// location-independent (same walk-up as `ChassisUTIDeclarationTests`).
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)   // …/Tests/PublicationManagerCoreTests/<this>
            .deletingLastPathComponent()  // …/Tests/PublicationManagerCoreTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/PublicationManagerCore
            .deletingLastPathComponent()  // …/imbib
            .deletingLastPathComponent()  // …/apps
            .deletingLastPathComponent()  // repo root
    }()
}
