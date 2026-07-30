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
    /// it — a weaker guarantee than the template gives, kept for now because
    /// the declarations pre-date the template and carry per-app document-type
    /// metadata. Follow-up (recorded in the capability matrix): audit which
    /// linking apps reach each call site, then either move the identifier
    /// into the template or move its call site out of shared code. Do NOT add
    /// new identifiers here — new exported types go in the template.
    private static let appDeclaredExceptions: Set<String> = [
        "com.imbib.bibtex",
        "com.imbib.bundle",
        "com.impress.bibtex-entry",
        "com.impress.citation-key",
        "com.impress.conversation-ref",
        "com.impress.document-reference",
        "com.impress.figure-reference",
        "com.impress.paper-reference",
        "com.impress.research-artifact-reference",
        "com.impress.veusz-plot-reference",
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
