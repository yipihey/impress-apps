//
//  Stage7ParityTests.swift
//  PublicationManagerCoreTests
//
//  Stage 7 item 9 parity suite for the parser batch.
//
//  `crates/imbib-core/tests/{stage7_parser_parity,stage7_pdf_parity,
//  stage7_abstract_parity}.rs` assert the same corpus at the Rust level. This
//  suite asserts it at the boundary the app actually uses — through the shimmed
//  Swift API and the `ImbibRustCore` bindings — so a bridge-level regression (a
//  lost field, an Int32 truncation, a stale xcframework, a UniFFI checksum
//  drift) fails here rather than passing in Rust while mbox import silently
//  breaks.
//
//  The fixtures are SHARED, not duplicated: this file reads the very same JSON
//  the Rust tests read. They were captured from the Swift implementations before
//  those bodies became shims; there is no regeneration path.
//

import Foundation
import Testing

@testable import PublicationManagerCore

@Suite("Stage 7 parser parity (FFI path)")
struct Stage7ParityTests {

    // MARK: - Fixture loading

    /// Golden → PublicationManagerCoreTests → Tests → PublicationManagerCore →
    /// imbib → apps → root.
    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url = url.deletingLastPathComponent() }
        return url
    }

    static var goldenDir: URL {
        repoRoot.appendingPathComponent("crates/imbib-core/test_fixtures/golden")
    }

    static func golden(_ name: String) throws -> [[String: Any]] {
        let url = goldenDir.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try #require(parsed as? [[String: Any]], "\(name) is not an array of objects")
    }

    // MARK: - Divergence exemptions
    //
    // Each entry names a case whose Swift-captured value was WRONG and is
    // deliberately not reproduced. The reasons live in
    // docs/parser-batch-swift-rust-split.md; the Rust suites assert the
    // corrected values positively. Hit counts are pinned so an exemption cannot
    // silently widen.

    /// Quoted-printable inputs whose Swift output was Latin-1 mojibake.
    static let quotedPrintableDivergences: Set<String> = [
        "=E2=80=94", "M=C3=BCller", "caf=C3=A9", "=E2=80=9Cquoted=E2=80=9D",
        "mixed =C3=BC and =3D and plain",
    ]

    /// RFC 2047 `Q` words whose declared charset Swift ignored.
    static let headerDivergences: Set<String> = [
        "=?UTF-8?Q?M=C3=BCller?=", "=?ISO-8859-2?Q?a=B1b?=",
    ]

    /// mbox cases whose message fields legitimately changed.
    static let mboxDivergences: Set<String> = [
        "quoted-printable-body", "lowercase-header-names", "encoded-word-subject",
    ]

    // MARK: - MIME primitives

    @Test("MIMEDecoder.quotedPrintableDecode round-trips UTF-8 through the FFI")
    func quotedPrintableParity() throws {
        let cases = try Self.golden("mime_quoted_printable_decode.json")
        #expect(cases.count == 28, "golden quoted-printable corpus size changed")

        var exempted = 0
        for c in cases {
            let input = c["input"] as? String ?? ""
            let want = c["output"] as? String ?? ""
            let got = MIMEDecoder.quotedPrintableDecode(input)
            if Self.quotedPrintableDivergences.contains(input) {
                exempted += 1
                #expect(got != want, "\(input) is exempt but now matches Swift")
                continue
            }
            #expect(got == want, "quoted-printable \(input.debugDescription)")
        }
        #expect(exempted == 5, "quoted-printable exemption count drifted")

        // The fix, asserted positively across the FFI.
        #expect(MIMEDecoder.quotedPrintableDecode("M=C3=BCller") == "Müller")
        #expect(MIMEDecoder.quotedPrintableDecode("=E2=80=94") == "—")
        // A genuinely Latin-1 body still decodes correctly when it says so.
        #expect(
            MIMEDecoder.quotedPrintableDecode("M=FCller", charset: "ISO-8859-1") == "Müller")
    }

    @Test("MIMEDecoder.base64Decode matches the golden corpus")
    func base64Parity() throws {
        let cases = try Self.golden("mime_base64_decode.json")
        #expect(cases.count == 14)
        for c in cases {
            let input = c["input"] as? String ?? ""
            let want = c["output"] as? String
            let got = MIMEDecoder.base64Decode(input)?.base64EncodedString()
            #expect(got == want, "base64 \(input.debugDescription)")
        }
    }

    @Test("MIMEDecoder.unescapeFromLines matches the golden corpus")
    func unescapeParity() throws {
        let cases = try Self.golden("mime_unescape_from_lines.json")
        #expect(cases.count == 18)
        for c in cases {
            let input = c["input"] as? String ?? ""
            #expect(
                MIMEDecoder.unescapeFromLines(input) == (c["output"] as? String ?? ""),
                "unescape \(input.debugDescription)")
        }
    }

    @Test("MIMEDecoder.extractBoundary matches the golden corpus")
    func boundaryParity() throws {
        let cases = try Self.golden("mime_extract_boundary.json")
        #expect(cases.count == 15)
        for c in cases {
            let input = c["input"] as? String ?? ""
            #expect(
                MIMEDecoder.extractBoundary(from: input) == c["output"] as? String,
                "boundary \(input.debugDescription)")
        }
    }

    @Test("MIMEDecoder.decodeHeaderValue honours the declared charset")
    func headerDecodeParity() throws {
        let cases = try Self.golden("mime_decode_header_value.json")
        #expect(cases.count == 23)

        var exempted = 0
        for c in cases {
            let input = c["input"] as? String ?? ""
            let want = c["output"] as? String ?? ""
            let got = MIMEDecoder.decodeHeaderValue(input)
            if Self.headerDivergences.contains(input) {
                exempted += 1
                #expect(got != want, "\(input) is exempt but now matches Swift")
                continue
            }
            #expect(got == want, "header \(input.debugDescription)")
        }
        #expect(exempted == Self.headerDivergences.count)

        #expect(MIMEDecoder.decodeHeaderValue("=?UTF-8?Q?M=C3=BCller?=") == "Müller")
        #expect(MIMEDecoder.decodeHeaderValue("=?ISO-8859-2?Q?a=B1b?=") == "aąb")
    }

    @Test("MIMEDecoder.decode reproduces every multipart golden case")
    func multipartParity() throws {
        let cases = try Self.golden("mime_multipart_decode.json")
        #expect(cases.count == 16)

        for c in cases {
            let name = c["name"] as? String ?? ""
            let parts = MIMEDecoder.decode(
                c["content"] as? String ?? "", boundary: c["boundary"] as? String ?? "")
            let want = c["parts"] as? [[String: Any]] ?? []
            #expect(parts.count == want.count, "\(name): part count")

            for (index, wantPart) in want.enumerated() where index < parts.count {
                let got = parts[index]
                #expect(got.contentType == wantPart["contentType"] as? String, "\(name)[\(index)]")
                #expect(
                    got.transferEncoding == wantPart["transferEncoding"] as? String,
                    "\(name)[\(index)] encoding")
                #expect(
                    got.filename == wantPart["filename"] as? String, "\(name)[\(index)] filename")
                let wantHeaders = wantPart["headers"] as? [String: String] ?? [:]
                #expect(got.headers == wantHeaders, "\(name)[\(index)] headers")
                if name != "quoted-printable-part" {
                    #expect(
                        got.content.base64EncodedString() == wantPart["contentBase64"] as? String,
                        "\(name)[\(index)] content")
                }
            }
        }
    }

    // MARK: - Whole-archive parsing

    @Test("MboxParser.parseContent reproduces every archive golden case")
    func mboxParity() async throws {
        let cases = try Self.golden("mbox_parse.json")
        #expect(cases.count == 23, "golden mbox corpus size changed")
        let parser = MboxParser()

        var exempted = 0
        for c in cases {
            let name = c["name"] as? String ?? ""
            let diverges = Self.mboxDivergences.contains(name)
            if diverges { exempted += 1 }

            let messages = await parser.parseContent(c["content"] as? String ?? "")
            let want = c["messages"] as? [[String: Any]] ?? []
            #expect(messages.count == want.count, "\(name): message count")

            for (index, wantMessage) in want.enumerated() where index < messages.count {
                let got = messages[index]
                if !diverges {
                    #expect(got.from == wantMessage["from"] as? String, "\(name)[\(index)] from")
                    #expect(
                        got.subject == wantMessage["subject"] as? String,
                        "\(name)[\(index)] subject")
                    #expect(got.body == wantMessage["body"] as? String, "\(name)[\(index)] body")
                    // The shim still mints a UUID for a missing Message-ID, so
                    // the assertion is on the shape when it was absent.
                    if wantMessage["messageIDIsGeneratedUUID"] as? Bool == true {
                        #expect(
                            UUID(uuidString: got.messageID) != nil,
                            "\(name)[\(index)] expected a generated UUID")
                    } else {
                        #expect(
                            got.messageID == wantMessage["messageID"] as? String,
                            "\(name)[\(index)] messageID")
                    }
                }

                let wantHeaders = wantMessage["headers"] as? [String: String] ?? [:]
                #expect(got.headers == wantHeaders, "\(name)[\(index)] headers")

                let wantAttachments = wantMessage["attachments"] as? [[String: Any]] ?? []
                #expect(
                    got.attachments.count == wantAttachments.count,
                    "\(name)[\(index)] attachment count")
                for (ai, wantAttachment) in wantAttachments.enumerated()
                where ai < got.attachments.count {
                    let gotAttachment = got.attachments[ai]
                    #expect(gotAttachment.filename == wantAttachment["filename"] as? String)
                    #expect(gotAttachment.contentType == wantAttachment["contentType"] as? String)
                    #expect(
                        gotAttachment.data.base64EncodedString()
                            == wantAttachment["dataBase64"] as? String)
                }
            }
        }
        #expect(exempted == Self.mboxDivergences.count, "mbox exemption count drifted")
    }

    @Test("The mbox round-trip no longer corrupts non-ASCII abstracts")
    func mboxRoundTripPreservesUnicode() async throws {
        // The bug the port existed to find: export → import mangled every
        // non-ASCII character, because the encoder writes UTF-8 octets as `=XX`
        // and the decoder read each octet as a Latin-1 scalar.
        let abstract = "Müller measured Ångström-scale α–β transitions — 50% of the sample."
        let message = MboxMessage(
            from: "imbib@localhost",
            subject: "Über Résumé",
            date: Date(timeIntervalSince1970: 1_704_067_200),
            messageID: "roundtrip",
            headers: ["X-Imbib-CiteKey": "müller2024"],
            body: abstract
        )
        let encoded = MIMEEncoder.encode(message)
        let parsed = await MboxParser().parseContent(encoded)

        #expect(parsed.count == 1)
        #expect(parsed.first?.body.trimmingCharacters(in: .whitespacesAndNewlines) == abstract)
        #expect(parsed.first?.subject == "Über Résumé")
    }

    // MARK: - Publishers

    @Test("PublisherHTMLParsers.parserID matches the golden corpus")
    func parserIDParity() throws {
        let cases = try Self.golden("publisher_parser_id.json")
        #expect(cases.count == 28)
        let parsers = PublisherHTMLParsers()
        for c in cases {
            let host = c["host"] as? String ?? ""
            #expect(
                parsers.parserID(for: host) == c["parserID"] as? String,
                "parserID \(host.debugDescription)")
        }
    }

    @Test("PublisherHTMLParsers.parse reproduces every landing-page golden case")
    func publisherParseParity() throws {
        let cases = try Self.golden("publisher_parse.json")
        #expect(cases.count == 60, "golden publisher corpus size changed")
        let parsers = PublisherHTMLParsers()
        for c in cases {
            let name = c["name"] as? String ?? ""
            let base = try #require(URL(string: c["baseURL"] as? String ?? ""))
            let got = parsers.parse(
                html: c["html"] as? String ?? "",
                baseURL: base,
                publisherHost: c["host"] as? String ?? ""
            )
            #expect(got?.absoluteString == c["pdfURL"] as? String, "publisher \(name)")
        }
    }

    @Test("DefaultPublisherRules reproduces the frozen table")
    func publisherRuleTableParity() throws {
        let want = try Self.golden("publisher_default_rules.json")
        let got = DefaultPublisherRules.rules.sorted { $0.id < $1.id }
        #expect(got.count == want.count, "rule count changed")

        for (wantRule, gotRule) in zip(want, got) {
            let id = wantRule["id"] as? String ?? ""
            #expect(gotRule.id == id)
            #expect(gotRule.name == wantRule["name"] as? String, "\(id) name")
            #expect(gotRule.doiPrefixes == wantRule["doiPrefixes"] as? [String], "\(id) prefixes")
            #expect(gotRule.pdfURLPattern == wantRule["pdfURLPattern"] as? String, "\(id) pattern")
            #expect(gotRule.requiresProxy == wantRule["requiresProxy"] as? Bool, "\(id) proxy")
            #expect(gotRule.captchaRisk.rawValue == wantRule["captchaRisk"] as? String, "\(id) risk")
            #expect(gotRule.preferOpenAlex == wantRule["preferOpenAlex"] as? Bool, "\(id) oa")
            #expect(gotRule.notes == wantRule["notes"] as? String, "\(id) notes")
            #expect(gotRule.htmlParserID == wantRule["htmlParserID"] as? String, "\(id) parser")
            #expect(
                gotRule.supportsLandingPageScraping
                    == wantRule["supportsLandingPageScraping"] as? Bool, "\(id) scraping")
        }
    }

    @Test("PublisherRule matching and URL construction match the golden corpus")
    func publisherRuleMatchParity() throws {
        let cases = try Self.golden("publisher_rule_match.json")
        #expect(cases.count == 23)
        let all = DefaultPublisherRules.rules
        for c in cases {
            let doi = c["doi"] as? String ?? ""
            let matched = all.filter { $0.matches(doi: doi) }.sorted { $0.id < $1.id }
            #expect(
                matched.map(\.id) == c["matchingRuleIDs"] as? [String],
                "matches \(doi.debugDescription)")

            let wantURLs = c["constructedURLs"] as? [[String: Any]] ?? []
            for (index, wantURL) in wantURLs.enumerated() where index < matched.count {
                #expect(matched[index].id == wantURL["ruleID"] as? String)
                #expect(
                    matched[index].constructPDFURL(doi: doi)?.absoluteString
                        == wantURL["url"] as? String,
                    "url \(doi.debugDescription) via \(matched[index].id)")
            }
        }
    }

    @Test("PublisherRegistry resolves the longest matching prefix, deterministically")
    func registryLookupIsDeterministic() async {
        // The old implementation iterated a Dictionary, so with two matching
        // prefixes the winner varied per process launch. Run it repeatedly: a
        // nondeterministic lookup fails this sooner or later, and a
        // shortest-prefix lookup fails it immediately.
        let registry = PublisherRegistry.shared
        for _ in 0..<50 {
            #expect(await registry.rule(forDOI: "10.1093/mnras/stab123")?.id == "mnras")
            #expect(await registry.rule(forDOI: "10.3847/1538-4357/abc")?.id == "iop-aas")
            #expect(await registry.rule(forDOI: "10.9999/unknown") == nil)
        }
    }

    // MARK: - Abstracts

    @Test("AbstractParser reproduces every abstract golden case")
    func abstractParity() throws {
        let cases = try Self.golden("abstract_parse.json")
        #expect(cases.count == 56, "golden abstract corpus size changed")
        for c in cases {
            let name = c["name"] as? String ?? ""
            let input = c["input"] as? String ?? ""

            #expect(
                AbstractParser.containsMath(input) == c["containsMath"] as? Bool,
                "containsMath \(name)")
            #expect(
                MathMLToLaTeX.convert(input) == c["mathmlConverted"] as? String,
                "mathml \(name)")

            let segments = AbstractParser.parse(input)
            let want = c["segments"] as? [[String: Any]] ?? []
            #expect(segments.count == want.count, "\(name): segment count")
            for (index, wantSegment) in want.enumerated() where index < segments.count {
                let got = segments[index]
                let gotKind: String
                switch got {
                case .text: gotKind = "text"
                case .inlineMath: gotKind = "inlineMath"
                case .displayMath: gotKind = "displayMath"
                }
                #expect(gotKind == wantSegment["kind"] as? String, "\(name)[\(index)] kind")
                #expect(got.value == wantSegment["value"] as? String, "\(name)[\(index)] value")
            }
        }
    }

    // MARK: - PDF / artifact pure logic

    @Test("PDFExtractedMetadata.isPlausibleTitle matches the golden corpus")
    func plausibleTitleParity() throws {
        let cases = try Self.golden("pdf_plausible_title.json")
        #expect(cases.count == 23)
        for c in cases {
            let input = c["input"] as? String ?? ""
            #expect(
                PDFExtractedMetadata.isPlausibleTitle(input) == c["isPlausible"] as? Bool,
                "isPlausibleTitle \(input.debugDescription)")
        }
    }

    @Test("PDFExtractedMetadata best* fields match the golden corpus")
    func bestFieldsParity() throws {
        let cases = try Self.golden("pdf_best_metadata.json")
        #expect(cases.count == 18)

        var exempted = 0
        for c in cases {
            let name = c["name"] as? String ?? ""
            let metadata = PDFExtractedMetadata(
                title: c["title"] as? String,
                author: c["author"] as? String,
                extractedDOI: c["extractedDOI"] as? String,
                extractedArXivID: c["extractedArXivID"] as? String,
                extractedBibcode: c["extractedBibcode"] as? String,
                firstPageText: c["firstPageText"] as? String,
                heuristicTitle: c["heuristicTitle"] as? String,
                heuristicAuthors: c["heuristicAuthors"] as? [String] ?? [],
                heuristicYear: c["heuristicYear"] as? Int
            )

            #expect(metadata.bestTitle == c["bestTitle"] as? String, "\(name) bestTitle")
            #expect(metadata.bestYear == c["bestYear"] as? Int, "\(name) bestYear")
            #expect(metadata.hasIdentifier == c["hasIdentifier"] as? Bool, "\(name) hasIdentifier")

            // The one divergence: a whitespace-only document author used to
            // discard heuristically recovered authors.
            if name == "authors-whitespace-only-doc" {
                exempted += 1
                #expect(metadata.bestAuthors == ["Kaiser, N."], "\(name) now recovers authors")
                continue
            }
            #expect(
                metadata.bestAuthors == c["bestAuthors"] as? [String] ?? [],
                "\(name) bestAuthors")
        }
        #expect(exempted == 1, "pdf best-fields exemption count drifted")
    }

    @Test("ArtifactMetadataExtractor meta scrapers match the golden corpus")
    func artifactMetaParity() throws {
        let cases = try Self.golden("artifact_meta_content.json")
        #expect(cases.count == 16)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let html = c["html"] as? String ?? ""
            #expect(
                ArtifactMetadataExtractor.extractMetaContent(from: html, property: "og:title")
                    == c["ogTitle"] as? String, "\(name) og:title")
            #expect(
                ArtifactMetadataExtractor.extractMetaContent(from: html, property: "og:description")
                    == c["ogDescription"] as? String, "\(name) og:description")
            #expect(
                ArtifactMetadataExtractor.extractMetaContent(from: html, name: "author")
                    == c["author"] as? String, "\(name) author")
        }
    }

    @Test("inferArtifactType still answers what it always did, across the split")
    func artifactTypeParity() throws {
        let cases = try Self.golden("artifact_infer_type.json")
        #expect(cases.count == 52)
        // The Rust half answers the filename hints and the extension table; the
        // `UTType.conforms` tail still answers the rest. Both halves together
        // must reproduce every captured answer — which is the point of asserting
        // through the Swift entry point rather than the Rust one.
        for c in cases {
            let filename = c["filename"] as? String ?? ""
            let url = URL(fileURLWithPath: "/tmp/corpus").appendingPathComponent(filename)
            #expect(
                ArtifactMetadataExtractor.inferArtifactType(from: url).rawValue
                    == c["artifactType"] as? String,
                "artifactType \(filename.debugDescription)")
        }
    }
}
