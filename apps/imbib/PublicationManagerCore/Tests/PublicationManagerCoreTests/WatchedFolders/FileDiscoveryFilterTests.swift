//
//  FileDiscoveryFilterTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D1/D5 — the filter type and the Spotlight predicate derived from
//  it.
//
//  The predicate assertions are the load-bearing ones. `NSMetadataQuery` is not
//  meaningfully testable headless (see `SpotlightFolderDiscoveryEngineTests`
//  for the honest account), so the thing most worth pinning is the TRANSLATION
//  — "this filter table becomes exactly this query" — which is a pure string
//  and runs on any platform.
//

import UniformTypeIdentifiers
import XCTest

@testable import PublicationManagerCore

final class FileDiscoveryFilterTests: XCTestCase {

    // MARK: - Normalisation

    func testExtensionsAreLowercasedAndDotStripped() {
        let filter = FileDiscoveryFilter(
            id: "bib", filenameExtensions: [".BIB", "Ris", "..tex", "  bib  "])

        // "  bib  " is the same extension as ".BIB" once trimmed and lowered,
        // so it must not appear twice — a duplicated clause in the derived
        // predicate is harmless but a duplicated MATCH is not.
        XCTAssertEqual(filter.filenameExtensions, ["bib", "ris", "tex"])
    }

    func testEmptyAndWhitespaceEntriesAreDropped() {
        let filter = FileDiscoveryFilter(
            id: "x", contentTypeIdentifiers: ["", "  ", "public.plain-text"],
            filenameExtensions: ["", ".", "  "])
        XCTAssertEqual(filter.contentTypeIdentifiers, ["public.plain-text"])
        XCTAssertTrue(filter.filenameExtensions.isEmpty)
    }

    func testAFilterWithNothingDeclaredMatchesNothing() {
        let filter = FileDiscoveryFilter(id: "empty")
        XCTAssertTrue(filter.isEmpty)
        XCTAssertFalse(filter.matches(URL(fileURLWithPath: "/tmp/anything.bib")))
        XCTAssertFalse([filter].canMatchAnything)
    }

    // MARK: - Matching

    func testExtensionMatchIsCaseInsensitiveAndNeedsNoFileSystem() {
        let filter = FileDiscoveryFilter(id: "bib", filenameExtensions: ["bib"])
        XCTAssertTrue(filter.matchesExtension(of: URL(fileURLWithPath: "/nowhere/A.BiB")))
        XCTAssertFalse(filter.matchesExtension(of: URL(fileURLWithPath: "/nowhere/A.bibx")))
        // No file exists at either path: the extension half must work on a
        // volume that answers no metadata questions at all, which is the whole
        // reason it is not the optional half.
        XCTAssertTrue(filter.matches(URL(fileURLWithPath: "/nowhere/A.BiB")))
    }

    func testUTIMatchUsesConformanceNotEquality() {
        let filter = FileDiscoveryFilter(
            id: "text", contentTypeIdentifiers: ["public.plain-text"])
        // A subtype the filter never names.
        XCTAssertTrue(filter.matches(contentType: .swiftSource))
        XCTAssertTrue(filter.matches(contentType: .plainText))
        XCTAssertFalse(filter.matches(contentType: .png))
    }

    func testFirstMatchingAttributesToTheFirstDeclaredFilter() {
        // Two filters that both claim `.txt`. Attribution must be deterministic
        // and must follow declaration order, because `DiscoveredFile.filterID`
        // is what routes a hit to a record kind.
        let filters = [
            FileDiscoveryFilter(id: "first", filenameExtensions: ["txt"]),
            FileDiscoveryFilter(id: "second", filenameExtensions: ["txt"]),
        ]
        XCTAssertEqual(
            filters.firstMatching(URL(fileURLWithPath: "/nowhere/a.txt"))?.id, "first")
        XCTAssertEqual(filters.matching(URL(fileURLWithPath: "/nowhere/a.txt")).count, 2)
    }

    func testAllExtensionsUnionsAcrossFilters() {
        let filters = [
            FileDiscoveryFilter(id: "bib", filenameExtensions: ["bib", "ris"]),
            FileDiscoveryFilter(id: "manuscript", filenameExtensions: ["typ", "bib"]),
        ]
        XCTAssertEqual(filters.allExtensions, ["bib", "ris", "typ"])
    }

    // MARK: - Spotlight predicate derivation

    func testPredicateIsNilWhenNothingCouldMatch() {
        XCTAssertNil(SpotlightPredicateFormat.predicate(for: []))
        XCTAssertNil(SpotlightPredicateFormat.predicate(for: [FileDiscoveryFilter(id: "e")]))
    }

    func testPredicateUsesContentTypeTreeAndFilenameClauses() {
        let filters = [
            FileDiscoveryFilter(
                id: "bibtex",
                contentTypeIdentifiers: ["com.impress.bibtex-entry"],
                filenameExtensions: ["bib", "ris"])
        ]
        XCTAssertEqual(
            SpotlightPredicateFormat.predicate(for: filters),
            "((kMDItemContentTypeTree == \"com.impress.bibtex-entry\")"
                + " || (kMDItemFSName LIKE[c] \"*.bib\")"
                + " || (kMDItemFSName LIKE[c] \"*.ris\"))")
    }

    func testPredicateGroupsAllTypesBeforeAllExtensionsAndDeduplicates() {
        // Two kinds that share `.bib`. One clause, not two — and the UTI
        // clauses lead, so the predicate text is stable regardless of how many
        // filters declare what.
        let filters = [
            FileDiscoveryFilter(
                id: "a", contentTypeIdentifiers: ["public.plain-text"],
                filenameExtensions: ["bib"]),
            FileDiscoveryFilter(
                id: "b", contentTypeIdentifiers: ["public.plain-text"],
                filenameExtensions: ["bib", "typ"]),
        ]
        XCTAssertEqual(
            SpotlightPredicateFormat.predicate(for: filters),
            "((kMDItemContentTypeTree == \"public.plain-text\")"
                + " || (kMDItemFSName LIKE[c] \"*.bib\")"
                + " || (kMDItemFSName LIKE[c] \"*.typ\"))")
    }

    func testPredicateEscapesQuotesSoAHostileIdentifierCannotBreakOut() {
        let filters = [
            FileDiscoveryFilter(id: "x", contentTypeIdentifiers: ["a\"b"])
        ]
        XCTAssertEqual(
            SpotlightPredicateFormat.predicate(for: filters),
            "((kMDItemContentTypeTree == \"a\\\"b\"))")
    }

    func testDerivedPredicateIsAcceptedByNSPredicate() {
        // The point of pinning the STRING is only worth anything if the string
        // is also a valid predicate. `NSPredicate(format:)` traps on malformed
        // input, so this is the contract test for the engine's one unchecked
        // step.
        let filters = [
            FileDiscoveryFilter(
                id: "bibtex",
                contentTypeIdentifiers: ["com.impress.bibtex-entry"],
                filenameExtensions: ["bib"])
        ]
        let format = try? XCTUnwrap(SpotlightPredicateFormat.predicate(for: filters))
        XCTAssertNotNil(NSPredicate(format: format ?? ""))
    }
}
