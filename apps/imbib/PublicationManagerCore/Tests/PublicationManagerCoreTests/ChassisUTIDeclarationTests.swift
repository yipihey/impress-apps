//
//  ChassisUTIDeclarationTests.swift
//  PublicationManagerCoreTests
//
//  Every `UTType(exportedAs:)` in chassis code must be declared as an EXPORTED
//  type in the Info.plist of each app that links the chassis, or the first
//  access faults at runtime ("was expected to be exported … but it was
//  imported instead"). Those declarations live once, in apps/chassis-utis.yml,
//  and are merged into all seven PMC-linking targets by XcodeGen.
//
//  This test is the referee between the two: a new `UTType(exportedAs:)` that
//  is not added to the shared template fails a `swift test` instead of
//  faulting at runtime in five apps — and a template entry whose code was
//  deleted fails too, so the list cannot accrete dead declarations.
//

import XCTest

final class ChassisUTIDeclarationTests: XCTestCase {

    /// Directories whose `UTType(exportedAs:)` call sites every PMC-linking
    /// app compiles.
    private static let exportingSources = [
        "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore",
        "packages/ImpressKit/Sources/ImpressKit",
    ]

    /// Exported types that are DECLARED PER APP rather than in the shared
    /// template. Their call sites are in shared code too, so each of these is
    /// only safe while every app that actually reaches its code path declares
    /// it — a weaker guarantee than the template gives. Do NOT add new
    /// identifiers here: new exported types go in the template.
    ///
    /// This list was TEN entries until the 2026-07-30 reachability audit, which
    /// found that none of the other nine had any business being per-app —
    /// several were not even per-app, just undeclared — and graduated them into
    /// `apps/chassis-utis.yml`. What the audit found, for the record:
    ///
    /// * `com.impress.paper-reference` — reached by imbib AND imprint, via two
    ///   shared PMC call sites: `MailStylePublicationRow`'s `.itemProvider`
    ///   (SharedViews/MailStylePublicationRow.swift:411, rendered through
    ///   `PublicationListView` → `UnifiedPublicationListWrapper` →
    ///   `SectionContentView`'s `.publicationList` route, which imprint hits on
    ///   its `.citedInManuscripts` section) and `SourceEditorView`'s `.onDrop`
    ///   (Manuscript/Editor/SourceEditorView.swift:81). It was EXPORTED only by
    ///   imbib; imprint/impel/impart merely IMPORTED it, which does not satisfy
    ///   `UTType(exportedAs:)`. A live latent fault, now fixed.
    /// * `com.impress.figure-reference` — same shared `.onDrop` array at
    ///   SourceEditorView.swift:81, so imbib and imprint both reach it. It was
    ///   EXPORTED only by implore, the one app that never reaches it.
    /// * `com.impress.document-reference`, `com.impress.conversation-ref`,
    ///   `com.impress.research-artifact-reference`,
    ///   `com.impress.veusz-plot-reference`, `com.impress.citation-key`,
    ///   `com.imbib.bibtex`, `com.imbib.bundle` — reached by ZERO apps today
    ///   (the `Transferable` conformances in ImpressKit/DataModels are never
    ///   used in a transfer position; `isBibTeX` / `isImbibBundle` /
    ///   `UTType.from(extension:)` have no callers). But their declaration
    ///   sites are ungated shared code every app compiles, and the per-app
    ///   state was arbitrary — veusz-plot-reference and
    ///   research-artifact-reference were exported by no app at all, and
    ///   `com.imbib.bibtex`/`com.imbib.bundle` appeared in no project.yml or
    ///   Info.plist anywhere. One `.draggable` would have faulted five apps.
    ///
    /// `com.impress.bibtex-entry` is the sole survivor because it is the only
    /// one that carries app-specific LaunchServices metadata: imbib declares it
    /// with `public.filename-extension: [bib]`
    /// (apps/imbib/imbib/project.yml). Hoisting it would change what
    /// `UTType(filenameExtension: "bib")` resolves to in the four other apps —
    /// and shared code reads exactly that, at
    /// `PublicationManagerCore/DragDrop/DragDropCoordinator.swift:86`. Nothing
    /// in any app reaches `UTType.impressBibTeXEntry` (zero uses beyond its
    /// declaration at ImpressUTTypes.swift:61), so there is no fault to fix and
    /// no reason to take that risk. If it ever acquires a real call site, move
    /// the call site out of ImpressKit rather than hoisting the `.bib` claim.
    private static let appDeclaredExceptions: Set<String> = [
        "com.impress.bibtex-entry",
    ]

    func testEveryExportedChassisUTTypeIsDeclaredInTheSharedTemplate() throws {
        let identifiers = try Self.exportedIdentifiersInSource()
        XCTAssertFalse(identifiers.isEmpty, "expected to find UTType(exportedAs:) call sites")

        let template = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("apps/chassis-utis.yml"),
            encoding: .utf8)

        for identifier in identifiers.subtracting(Self.appDeclaredExceptions).sorted() {
            XCTAssertTrue(
                template.contains("UTTypeIdentifier: \(identifier)"),
                """
                \(identifier) is built with UTType(exportedAs:) in chassis code but is \
                not declared in apps/chassis-utis.yml — every app linking the chassis \
                will fault on first access. Add it to the shared template (never to a \
                single app's project.yml) and re-run `xcodegen generate` in each app.
                """)
        }
    }

    /// The exception list must not go stale: every entry's call site still
    /// exists, and nothing in it is double-declared in the template.
    func testAppDeclaredExceptionsAreStillRealAndNotInTheTemplate() throws {
        let identifiers = try Self.exportedIdentifiersInSource()
        let template = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("apps/chassis-utis.yml"),
            encoding: .utf8)

        for identifier in Self.appDeclaredExceptions.sorted() {
            XCTAssertTrue(
                identifiers.contains(identifier),
                "\(identifier) is in appDeclaredExceptions but no chassis code builds it — remove the stale entry")
            XCTAssertFalse(
                template.contains("UTTypeIdentifier: \(identifier)"),
                "\(identifier) graduated into apps/chassis-utis.yml — remove it from appDeclaredExceptions")
        }
    }

    func testTheSharedTemplateDeclaresNothingTheCodeNoLongerExports() throws {
        let identifiers = try Self.exportedIdentifiersInSource()

        let template = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("apps/chassis-utis.yml"),
            encoding: .utf8)
        let declared = template
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("UTTypeIdentifier:") else { return nil }
                return trimmed.dropFirst("UTTypeIdentifier:".count)
                    .trimmingCharacters(in: .whitespaces)
            }

        for identifier in declared {
            XCTAssertTrue(
                identifiers.contains(identifier),
                """
                apps/chassis-utis.yml declares \(identifier), but no \
                UTType(exportedAs:) in chassis code builds it. Remove the dead \
                declaration (or, if the type moved into app-specific code, move the \
                declaration into that app's project.yml).
                """)
        }
    }

    // MARK: - Extraction

    private static func exportedIdentifiersInSource() throws -> Set<String> {
        let pattern = try NSRegularExpression(
            pattern: #"UTType\(\s*exportedAs:\s*"([^"]+)""#)
        var found: Set<String> = []
        for root in exportingSources {
            let rootURL = repoRoot.appendingPathComponent(root)
            let enumerator = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(text.startIndex..., in: text)
                pattern.enumerateMatches(in: text, range: range) { match, _, _ in
                    if let match, let idRange = Range(match.range(at: 1), in: text) {
                        found.insert(String(text[idRange]))
                    }
                }
            }
        }
        return found
    }

    /// Repo root, derived from this test's own path so the test is
    /// location-independent (same pattern as ChassisCrossPlatformContractTests).
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)          // …/Tests/PublicationManagerCoreTests/<this>
            .deletingLastPathComponent()          // …/Tests/PublicationManagerCoreTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/PublicationManagerCore
            .deletingLastPathComponent()          // …/imbib
            .deletingLastPathComponent()          // …/apps
            .deletingLastPathComponent()          // repo root
    }()
}
