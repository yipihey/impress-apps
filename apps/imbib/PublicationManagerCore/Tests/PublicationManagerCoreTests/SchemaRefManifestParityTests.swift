//
//  SchemaRefManifestParityTests.swift
//  PublicationManagerCore
//
//  The Swift half of the schema-ref guard (the Rust half is
//  `crates/*/tests/schema_ref_manifest.rs`; the exhaustive call-site half is
//  `scripts/check-schema-refs.sh`).
//
//  Why this exists: the impress store matches `items.schema_ref` by EXACT
//  EQUALITY. A descriptor that declares a ref nothing writes does not fail, log,
//  or throw — its whole record kind simply never appears, in grouped search, in
//  the Related section, in counts. `ArtifactRecordKind` is in exactly that state
//  right now (see the `artifact-descriptor-ref` divergence), and it took a lint
//  to notice.
//
//  Descriptors are the one place Swift declares refs as DATA rather than as a
//  literal buried in a query, so they are the one place a test can check them
//  exhaustively. Everything else is covered by the shell lint, which reads the
//  same manifest — deliberately, so the two halves cannot disagree about what
//  the vocabulary is.
//

import XCTest
@testable import PublicationManagerCore

final class SchemaRefManifestParityTests: XCTestCase {

    // MARK: - Descriptors vs the manifest

    /// Every schema ref a shipped descriptor declares must be a ref the
    /// manifest knows. A ref that is neither canonical nor a tracked
    /// divergence is a typo, and a typo here empties a whole record kind.
    @MainActor
    func testEveryDescriptorSchemaRefIsInTheManifest() throws {
        let manifest = try Self.manifest()
        let known = manifest.canonical.union(manifest.divergingRefs)

        for descriptor in BuiltinRecordKinds.all {
            for ref in descriptor.schemaRefs {
                XCTAssertTrue(
                    known.contains(ref),
                    """
                    Record kind '\(descriptor.id.rawValue)' declares schema ref \
                    '\(ref)', which schema-refs.json does not list.

                    The store matches schema_ref by exact equality, so this kind \
                    currently resolves for zero rows. Either correct the spelling \
                    to the canonical one, or — if this is a genuinely new kind — \
                    add it to `canonical` in schema-refs.json naming its writer.
                    """)
            }
        }
    }

    /// A descriptor ref that is only reachable via `knownDivergences` is a
    /// KNOWN BUG, not a passing case. This test pins the exact set so fixing
    /// one forces the manifest to shrink, and adding one is impossible without
    /// a deliberate edit to a file called `knownDivergences`.
    @MainActor
    func testDescriptorRefsRelyingOnDivergencesAreExactlyTheKnownOnes() throws {
        let manifest = try Self.manifest()
        var relying: Set<String> = []

        for descriptor in BuiltinRecordKinds.all {
            for ref in descriptor.schemaRefs where !manifest.canonical.contains(ref) {
                relying.insert(ref)
            }
        }

        XCTAssertEqual(
            relying, [],
            """
            The set of descriptor refs that are NOT canonical changed.

            It is EMPTY as of 2026-07-29: 'artifact' was the last one, and \
            ArtifactRecordKind now declares the eight real \
            impress/artifact/{code,dataset,general,media,note,poster,\
            presentation,webpage} refs, so the artifact-descriptor-ref entry \
            was dropped from schema-refs.json in the same change.

            If this grew, you introduced a new silently-empty record kind: a \
            descriptor whose refs nothing writes resolves for zero rows, and \
            its records land in the 'unknown kind' bucket of grouped search \
            and the Related section.
            """)
    }

    /// Descriptors must not disagree with each other about a kind's spelling —
    /// two kinds claiming the same base name with different suffixes is the
    /// writer/reader split in miniature.
    @MainActor
    func testNoTwoDescriptorsClaimTheSameBaseNameDifferently() {
        var spellingsByBase: [String: Set<String>] = [:]
        for descriptor in BuiltinRecordKinds.all {
            for ref in descriptor.schemaRefs {
                spellingsByBase[RecordKindSchemaRef.baseName(ref), default: []].insert(ref)
            }
        }
        for (base, spellings) in spellingsByBase {
            XCTAssertEqual(
                spellings.count, 1,
                "descriptors spell '\(base)' \(spellings.count) ways: \(spellings.sorted())")
        }
    }

    // MARK: - The manifest's own invariants

    /// The manifest must not itself contain the bug: two canonical spellings
    /// of one kind would let a writer and a reader each pick one, pass the
    /// lint, and still never meet.
    func testManifestHasOneCanonicalSpellingPerBaseName() throws {
        let manifest = try Self.manifest()
        var byBase: [String: [String]] = [:]
        for ref in manifest.canonical {
            byBase[RecordKindSchemaRef.baseName(ref), default: []].append(ref)
        }
        for (base, refs) in byBase where refs.count > 1 {
            XCTAssertTrue(
                Set(refs).isSubset(of: manifest.divergingRefs),
                "schema-refs.json has \(refs.count) canonical spellings of '\(base)' "
                + "(\(refs.sorted())) with no knownDivergences entry covering them")
        }
    }

    /// `knownDivergences` is a ratchet: it may shrink as splits are fixed,
    /// never grow. Without the budget it would become a place to make new
    /// mismatches legal.
    func testKnownDivergencesStayWithinBudget() throws {
        let manifest = try Self.manifest()
        XCTAssertLessThanOrEqual(
            manifest.divergenceCount, manifest.divergenceBudget,
            "knownDivergences grew to \(manifest.divergenceCount) "
            + "(budget \(manifest.divergenceBudget)). This list is a RATCHET.")
    }

    /// The refs imbib itself reads must be canonical — no divergence escape
    /// hatch for this app's own publication and citation-usage paths, which
    /// are where the bug has actually bitten users.
    func testImbibReadPathRefsAreCanonical() throws {
        let manifest = try Self.manifest()
        for ref in ["imbib/bibliography-entry", "citation-usage", "manuscript-section"] {
            XCTAssertTrue(
                manifest.canonical.contains(ref),
                "'\(ref)' must be canonical — imbib reads it directly")
        }
    }

    // MARK: - Manifest loading

    private struct Manifest {
        let canonical: Set<String>
        let divergingRefs: Set<String>
        let divergenceCount: Int
        let divergenceBudget: Int
    }

    /// `<repo>/schema-refs.json`, derived from this test's own path so the test
    /// is location-independent (same approach as ChassisCrossPlatformContractTests).
    private static func manifest() throws -> Manifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/PublicationManagerCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/PublicationManagerCore
            .deletingLastPathComponent()   // …/imbib
            .deletingLastPathComponent()   // …/apps
            .deletingLastPathComponent()   // <repo>
            .appendingPathComponent("schema-refs.json")

        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "schema-refs.json is not a JSON object")

        let canonical = try XCTUnwrap(root["canonical"] as? [String: Any]).keys
        let divergences = try XCTUnwrap(root["knownDivergences"] as? [[String: Any]])
        let refs = divergences.flatMap { ($0["refs"] as? [String]) ?? [] }

        return Manifest(
            canonical: Set(canonical),
            divergingRefs: Set(refs),
            divergenceCount: divergences.count,
            divergenceBudget: try XCTUnwrap(root["knownDivergenceBudget"] as? Int))
    }
}
