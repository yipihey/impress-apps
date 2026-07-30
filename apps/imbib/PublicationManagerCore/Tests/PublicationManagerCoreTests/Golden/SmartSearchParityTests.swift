//
//  SmartSearchParityTests.swift
//  PublicationManagerCoreTests
//
//  Stage 7 item 8 parity suite for the smart-search port.
//
//  `crates/impress-smart-search/tests/golden_parity.rs` asserts the same corpus
//  at the Rust level. This suite asserts it at the boundary the app actually
//  uses — through `ImpressSmartSearch`'s public API and the `ImbibRustCore`
//  bindings — so a bridge-level regression (a lost field, an Int32 truncation,
//  a stale xcframework, a UniFFI checksum drift) fails here rather than
//  passing silently in Rust and breaking the Cmd+S overlay.
//
//  The fixtures are SHARED, not duplicated: this file reads the very same JSON
//  the Rust test reads. They were captured from the Swift implementations before
//  those bodies were replaced; there is no regeneration path.
//

import Foundation
import ImbibRustCore
import ImpressSmartSearch
import Testing

@Suite("Smart search golden parity (FFI path)")
struct SmartSearchParityTests {

    // The clock the goldens were captured against.
    static let thisYear: Int32 = 2026
    static let today = "2026-07-30"

    // MARK: - Fixture loading

    /// Walk up from this file to the repo root: Golden → PublicationManagerCoreTests
    /// → Tests → PublicationManagerCore → imbib → apps → root.
    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url = url.deletingLastPathComponent() }
        return url
    }

    static var goldenDir: URL {
        repoRoot.appendingPathComponent("crates/impress-smart-search/test_fixtures/golden")
    }

    static func golden(_ name: String) throws -> [[String: Any]] {
        let url = goldenDir.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try #require(parsed as? [[String: Any]], "\(name) is not an array of objects")
    }

    // MARK: - Intent classification

    @Test("IntentClassifier.classify matches the golden corpus")
    func classifyParity() throws {
        let cases = try Self.golden("intent_classify.json")
        #expect(cases.count == 288, "golden classify corpus size changed")

        var mismatches: [String] = []
        var skipped = 0
        for c in cases {
            let input = c["input"] as? String ?? ""
            let wantKind = c["kind"] as? String ?? ""
            guard !Self.isBomReaderArtifact(input: input, expectedKind: wantKind) else {
                skipped += 1
                continue
            }
            let intent = IntentClassifier.classify(input)

            if intent.kindRawValue != wantKind {
                mismatches.append("kind[\(Self.tag(input))]: want \(wantKind), got \(intent.kindRawValue)")
                continue
            }
            let wantLabel = c["label"] as? String ?? ""
            if intent.label != wantLabel {
                mismatches.append("label[\(Self.tag(input))]: want '\(wantLabel)', got '\(intent.label)'")
            }

            switch intent {
            case .identifier(let id):
                if id.typeName != c["idKind"] as? String {
                    mismatches.append("idKind[\(Self.tag(input))]: got \(id.typeName)")
                }
                if id.value != c["value"] as? String {
                    mismatches.append("idValue[\(Self.tag(input))]: got \(id.value)")
                }
            case .fielded(let q), .freeText(let q):
                if q != c["query"] as? String {
                    mismatches.append("query[\(Self.tag(input))]: want '\(c["query"] as? String ?? "")', got '\(q)'")
                }
            case .reference(let blocks):
                if blocks != c["blocks"] as? [String] {
                    mismatches.append("blocks[\(Self.tag(input))]: got \(blocks)")
                }
            case .url(let u):
                if u.absoluteString != c["url"] as? String {
                    mismatches.append("url[\(Self.tag(input))]: want '\(c["url"] as? String ?? "")', got '\(u.absoluteString)'")
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(25).joined(separator: "\n"))")
        #expect(skipped == Self.expectedSkips, "BOM-exemption count changed: \(skipped)")
    }

    @Test("IntentClassifier.splitReferenceBlocks matches the golden corpus")
    func splitBlocksParity() throws {
        let cases = try Self.golden("intent_split_reference_blocks.json")
        #expect(cases.count == 288)
        var mismatches: [String] = []
        for c in cases {
            let input = c["input"] as? String ?? ""
            let want = c["blocks"] as? [String] ?? []
            let got = IntentClassifier.splitReferenceBlocks(input)
            if got != want {
                mismatches.append("[\(Self.tag(input))] want \(want), got \(got)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(25).joined(separator: "\n"))")
    }

    // MARK: - ADS normalization

    @Test("ADSQueryNormalizer.normalize matches the golden corpus")
    func normalizeParity() throws {
        let cases = try Self.golden("ads_normalize.json")
        #expect(cases.count == 125, "golden normalizer corpus size changed")
        var mismatches: [String] = []
        for c in cases {
            let input = c["input"] as? String ?? ""
            let r = ADSQueryNormalizer.normalize(input)
            if r.correctedQuery != c["corrected"] as? String {
                mismatches.append("corrected[\(Self.tag(input))]: want '\(c["corrected"] as? String ?? "")', got '\(r.correctedQuery)'")
            }
            if r.corrections != c["corrections"] as? [String] {
                mismatches.append("corrections[\(Self.tag(input))]: want \(c["corrections"] as? [String] ?? []), got \(r.corrections)")
            }
            if r.wasModified != c["wasModified"] as? Bool {
                mismatches.append("wasModified[\(Self.tag(input))]")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(25).joined(separator: "\n"))")
    }

    // MARK: - Reference validation

    @Test("ReferenceParser validation drops invented identifiers, per the goldens")
    func validateParity() throws {
        let cases = try Self.golden("reference_validate.json")
        #expect(cases.count == 15, "golden validate corpus size changed")
        var mismatches: [String] = []
        for c in cases {
            guard let p = c["parsed"] as? [String: Any],
                  let want = c["citation"] as? [String: Any] else { continue }
            let parsed = ParsedReference(
                authors: p["authors"] as? [String] ?? [],
                title: p["title"] as? String ?? "",
                year: p["year"] as? Int ?? 0,
                journal: p["journal"] as? String ?? "",
                volume: p["volume"] as? String ?? "",
                pages: p["pages"] as? String ?? "",
                doi: p["doi"] as? String ?? "",
                arxiv: p["arxiv"] as? String ?? "",
                bibcode: p["bibcode"] as? String ?? "",
                confidence: p["confidence"] as? Double ?? 0
            )
            let raw = c["raw"] as? String ?? ""
            let got = ReferenceParser.validate(parsed, raw: raw)
            let tag = Self.tag("\(parsed.authors)/\(parsed.year)")

            if got.authors != want["authors"] as? [String] ?? [] {
                mismatches.append("authors[\(tag)]: got \(got.authors)")
            }
            for (label, gotValue, wantKey) in [
                ("title", got.title, "title"), ("journal", got.journal, "journal"),
                ("volume", got.volume, "volume"), ("pages", got.pages, "pages"),
                ("doi", got.doi, "doi"), ("arxiv", got.arxiv, "arxiv"),
                ("bibcode", got.bibcode, "bibcode"), ("freeText", got.freeText, "freeText"),
            ] as [(String, String?, String)] {
                let wantValue = want[wantKey] as? String
                if gotValue != wantValue {
                    mismatches.append("\(label)[\(tag)]: want \(wantValue ?? "nil"), got \(gotValue ?? "nil")")
                }
            }
            let wantYear = want["year"] as? Int
            if got.year != wantYear {
                mismatches.append("year[\(tag)]: want \(wantYear.map(String.init) ?? "nil"), got \(got.year.map(String.init) ?? "nil")")
            }
            if got.hasIdentifier != want["hasIdentifier"] as? Bool {
                mismatches.append("hasIdentifier[\(tag)]")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(25).joined(separator: "\n"))")
    }

    // MARK: - Rewriter (through the bindings, so the pinned year is used)

    @Test("Deterministic rewrite matches the golden corpus")
    func degenerateRewriteParity() throws {
        let cases = try Self.golden("rewriter_degenerate.json")
        #expect(cases.count == 83, "golden degenerate corpus size changed")
        var mismatches: [String] = []
        for c in cases {
            let input = c["input"] as? String ?? ""
            let r = smartSearchDegenerateRewrite(input: input, thisYear: Self.thisYear)
            if r.query != c["query"] as? String {
                mismatches.append("query[\(Self.tag(input))]: want '\(c["query"] as? String ?? "")', got '\(r.query)'")
            }
            if r.interpretation != c["interpretation"] as? String {
                mismatches.append("interpretation[\(Self.tag(input))]")
            }
            if r.source != c["source"] as? String {
                mismatches.append("source[\(Self.tag(input))]")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(25).joined(separator: "\n"))")
    }

    @Test("ADS query assembly from model parts matches the golden corpus")
    func buildQueryParity() throws {
        let cases = try Self.golden("rewriter_build_query.json")
        #expect(cases.count == 39, "golden buildQuery corpus size changed")
        var mismatches: [String] = []
        for c in cases {
            guard let p = c["parts"] as? [String: Any] else { continue }
            let parts = SmartSearchQueryParts(
                authors: p["authors"] as? [String] ?? [],
                bibstem: p["bibstem"] as? String ?? "",
                topicWords: p["topicWords"] as? [String] ?? [],
                yearFrom: Int32(p["yearFrom"] as? Int ?? 0),
                yearTo: Int32(p["yearTo"] as? Int ?? 0),
                refereedOnly: p["refereedOnly"] as? Bool ?? false
            )
            let original = c["originalInput"] as? String ?? ""
            let got = smartSearchBuildAdsQuery(
                parts: parts, originalInput: original, thisYear: Self.thisYear
            )
            if got != c["query"] as? String {
                mismatches.append("[\(Self.tag(original))] want '\(c["query"] as? String ?? "")', got '\(got)'")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(25).joined(separator: "\n"))")
    }

    // MARK: - Page extraction

    @Test("Page identifier extraction matches the golden corpus")
    func pageExtractionParity() throws {
        let cases = try Self.golden("url_extract.json")
        #expect(cases.count == 77, "golden HTML corpus size changed")
        var mismatches: [String] = []
        for c in cases {
            let html = c["html"] as? String ?? ""
            let got = smartSearchExtractPageIdentifiers(html: html)
            if got.pageTitle != c["title"] as? String {
                mismatches.append("title[\(Self.tag(html))]: want \(c["title"] as? String ?? "nil"), got \(got.pageTitle ?? "nil")")
            }
            let wantIDs = (c["identifiers"] as? [[String: String]] ?? []).map { ($0["kind"] ?? "", $0["value"] ?? "") }
            let gotIDs = got.identifiers.map { ($0.kind, $0.value) }
            if wantIDs.count != gotIDs.count || !zip(wantIDs, gotIDs).allSatisfy({ $0 == $1 }) {
                mismatches.append("identifiers[\(Self.tag(html))]: want \(wantIDs), got \(gotIDs)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(25).joined(separator: "\n"))")
    }

    // MARK: - Prompts

    @Test("Model prompts are byte-identical to the goldens")
    func promptParity() throws {
        let cases = try Self.golden("prompts.json")
        #expect(cases.count == 4)
        for c in cases {
            let input = c["input"] as? String ?? ""
            #expect(
                smartSearchRewritePrompt(input: input, thisYear: Self.thisYear, today: Self.today)
                    == c["rewritePrompt"] as? String,
                "rewrite prompt drifted for '\(Self.tag(input))'"
            )
            #expect(
                smartSearchReferencePrompt(block: input) == c["referencePrompt"] as? String,
                "reference prompt drifted for '\(Self.tag(input))'"
            )
        }
    }

    // MARK: - Helpers

    /// `JSONSerialization` cannot round-trip U+FEFF: it writes the bytes
    /// faithfully but **strips the scalar when reading** — even from the escaped
    /// `\uFEFF` form (verified both directions with a standalone probe). The
    /// stripping happens during decode, so the loaded `String` carries no trace
    /// of the BOM and the case cannot be recognised by inspecting the input.
    ///
    /// One corpus entry is affected: `"\u{FEFF}10.1086/164143"`, which Swift
    /// classifies as `.freeText` (the BOM defeats the whole-string DOI match).
    /// Read from JSON by Foundation it arrives as a bare `10.1086/164143`, which
    /// correctly classifies as `.identifier` — so the "mismatch" is the reader's,
    /// not the port's.
    ///
    /// The entry stays in the corpus: BOM-prefixed paste is real (copying from a
    /// web page or Word produces it) and `golden_parity.rs` does assert it,
    /// because `serde_json` preserves the scalar. Here it is exempted by the
    /// exact `(input, expectedKind)` pair, which cannot mask anything else —
    /// the corpus also contains a plain `10.1086/164143` expecting
    /// `.identifier`, so a genuine regression on that input still fails. The
    /// hit count is pinned below.
    static func isBomReaderArtifact(input: String, expectedKind: String) -> Bool {
        input == "10.1086/164143" && expectedKind == "freeText"
    }

    static let expectedSkips = 1

    static func tag(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
    }
}
