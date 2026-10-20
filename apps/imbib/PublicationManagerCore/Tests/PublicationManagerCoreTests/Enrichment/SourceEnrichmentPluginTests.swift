//
//  SourceEnrichmentPluginTests.swift
//  PublicationManagerCoreTests
//
//  The enrichment plugin over the Rust source verbs: the cases the retired
//  `ADSEnrichmentTests` pinned (capabilities, identifier resolution, the
//  no-identifier refusals, the missing-credential error), against a stubbed
//  verb caller — no network, no FFI store.
//

import XCTest
@testable import PublicationManagerCore

final class SourceEnrichmentPluginTests: XCTestCase {

    /// A client whose every verb call is refused `secret-missing`, as the
    /// pipeline answers when the adapter has no token.
    private func clientWithoutToken() -> SourceClient {
        SourceClient(call: { verb, _ in
            VerbReply(ok: false, bodyJSON: "{}", code: "secret-missing", message: "ads-token is not set (\(verb))")
        })
    }

    // MARK: - Capabilities

    func testEnrichmentCapabilities() {
        let caps = SourceEnrichmentPlugin(sourceID: "ads", client: clientWithoutToken()).enrichmentCapabilities
        XCTAssertTrue(caps.contains(.citationCount))
        XCTAssertTrue(caps.contains(.references))
        XCTAssertTrue(caps.contains(.abstract))
        XCTAssertTrue(caps.contains(.citations))
        XCTAssertFalse(caps.contains(.pdfURL))
        XCTAssertFalse(caps.contains(.openAccess))
    }

    func testMetadataNamesTheSource() {
        let plugin = SourceEnrichmentPlugin(sourceID: "ads", client: clientWithoutToken())
        XCTAssertEqual(plugin.metadata.id, "ads")
        XCTAssertEqual(plugin.metadata.name, "NASA ADS")
        XCTAssertEqual(plugin.metadata.credentialRequirement, .apiKey)
    }

    // MARK: - Identifier Resolution

    func testResolveIdentifierWithBibcode() async throws {
        let plugin = SourceEnrichmentPlugin(client: clientWithoutToken())
        let resolved = try await plugin.resolveIdentifier(from: [.bibcode: "2017arXiv170603762V"])
        XCTAssertEqual(resolved[.bibcode], "2017arXiv170603762V")
    }

    func testResolveIdentifierFromDOI() async throws {
        let plugin = SourceEnrichmentPlugin(client: clientWithoutToken())
        let resolved = try await plugin.resolveIdentifier(from: [.doi: "10.1234/test"])
        XCTAssertEqual(resolved[.doi], "10.1234/test")
        XCTAssertTrue(resolved[.bibcode]?.contains("doi:") == true)
    }

    func testResolveIdentifierFromArXiv() async throws {
        let plugin = SourceEnrichmentPlugin(client: clientWithoutToken())
        let resolved = try await plugin.resolveIdentifier(from: [.arxiv: "1706.03762"])
        XCTAssertEqual(resolved[.arxiv], "1706.03762")
        XCTAssertTrue(resolved[.bibcode]?.contains("arXiv:") == true)
    }

    func testCanonicalIdentifierPrefersBibcodeThenDOIThenArXiv() throws {
        XCTAssertEqual(try SourceEnrichmentPlugin.canonicalIdentifier(from: [.bibcode: "2020ApJ...1A", .doi: "10.1/x"]), "bibcode:2020ApJ...1A")
        XCTAssertEqual(try SourceEnrichmentPlugin.canonicalIdentifier(from: [.doi: "10.1/x", .arxiv: "2101.00001v2"]), "doi:10.1/x")
        XCTAssertEqual(try SourceEnrichmentPlugin.canonicalIdentifier(from: [.arxiv: "2101.00001v2"]), "arxiv:2101.00001")
        // A `resolveIdentifier` placeholder is already canonical.
        XCTAssertEqual(try SourceEnrichmentPlugin.canonicalIdentifier(from: [.bibcode: "doi:10.1/x"]), "doi:10.1/x")
    }

    // MARK: - Error Handling

    func testEnrichWithNoIdentifiers() async {
        let plugin = SourceEnrichmentPlugin(client: clientWithoutToken())
        do {
            _ = try await plugin.enrich(identifiers: [:], existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            guard case .noIdentifier = error else { return XCTFail("Expected noIdentifier, got \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichWithUnsupportedIdentifier() async {
        let plugin = SourceEnrichmentPlugin(client: clientWithoutToken())
        do {
            _ = try await plugin.enrich(identifiers: [.pmid: "12345678"], existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            guard case .noIdentifier = error else { return XCTFail("Expected noIdentifier, got \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichRequiresAPIKey() async {
        let plugin = SourceEnrichmentPlugin(sourceID: "ads", client: clientWithoutToken())
        do {
            _ = try await plugin.enrich(identifiers: [.bibcode: "2020ApJ...1A"], existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            guard case .authenticationRequired = error else { return XCTFail("Expected authenticationRequired, got \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBatchWithoutIdentifiersFailsEachRequest() async {
        let plugin = SourceEnrichmentPlugin(client: clientWithoutToken())
        let id = UUID()
        let results = await plugin.enrichBatch(requests: [(id, [.pmid: "1"])])
        guard case .failure(let error)? = results[id], case EnrichmentError.noIdentifier = error else {
            return XCTFail("Expected noIdentifier, got \(String(describing: results[id]))")
        }
    }

    // MARK: - Rows → the enrichment shapes

    func testFetchedWorkReadsCitationCountAndLocations() async throws {
        let work = """
        {"work": {"type": "article-journal", "title": "T", "author": [{"family": "Abel", "given": "T."}],
          "issued": {"date-parts": [[2002]]}, "DOI": "10.1/x",
          "ids": {"doi": "10.1/x", "bibcode": "2002ApJ...1A", "arxiv": "astro-ph/0101"},
          "locations": [{"source": "ads", "source_id": "2002ApJ...1A", "version": "published",
                         "url": "https://ui.adsabs.harvard.edu/abs/2002ApJ...1A", "pdf": "https://pub.example/x.pdf", "primary": true}],
          "provenance": {"fetched_at": "", "source": "ads", "source_id": "2002ApJ...1A"},
          "metrics": {"cited_by": {"value": 42, "source": "ads"}}}, "diagnostics": []}
        """
        let client = SourceClient(call: { verb, _ in
            XCTAssertEqual(verb, "bib-source-service_fetch")
            return VerbReply(ok: true, bodyJSON: work)
        })
        let result = try await client.fetchWork(id: "bibcode:2002ApJ...1A", sources: ["ads"])
        XCTAssertEqual(result?.bibcode, "2002ApJ...1A")
        XCTAssertEqual(result?.citationCount, 42)
        XCTAssertEqual(result?.year, 2002)
        XCTAssertEqual(result?.authors, ["Abel, T."])
        XCTAssertEqual(result?.pdfLinks.first?.url.absoluteString, "https://pub.example/x.pdf")
        XCTAssertEqual(result?.sourceID, "ads")
    }
}
