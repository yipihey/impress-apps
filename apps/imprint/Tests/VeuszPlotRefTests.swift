import XCTest
@testable import imprint

final class VeuszPlotRefTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let plot = VeuszPlotRef(
            displayName: "Pulse profile",
            sourceRelativePath: "figures/pulse.vsz",
            renderedRelativePath: "figures/pulse.svg",
            exportFormat: .svg,
            lastRenderedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_500),
            renderStatus: .idle
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(plot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VeuszPlotRef.self, from: data)

        XCTAssertEqual(decoded, plot)
    }

    func testFailedStatusCarriesMessage() throws {
        let plot = VeuszPlotRef(
            displayName: "broken",
            sourceRelativePath: "figures/broken.vsz",
            renderedRelativePath: "figures/broken.svg",
            renderStatus: .failed("SyntaxError on line 3")
        )

        let data = try JSONEncoder().encode(plot)
        let decoded = try JSONDecoder().decode(VeuszPlotRef.self, from: data)

        guard case .failed(let msg) = decoded.renderStatus else {
            return XCTFail("Expected .failed status, got \(decoded.renderStatus)")
        }
        XCTAssertEqual(msg, "SyntaxError on line 3")
    }

    func testVersionedMetadataDefaultsPlotsToEmptyWhenMissing() throws {
        // Simulate a v1.2 document on disk — metadata.json has no `plots` key.
        let legacyJSON = """
        {
            "schemaVersion": 120,
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "Old Document",
            "authors": ["Alice"],
            "createdAt": "2024-01-01T00:00:00Z",
            "modifiedAt": "2024-01-02T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VersionedDocumentMetadata.self, from: legacyJSON)

        XCTAssertEqual(decoded.schemaVersion, 120)
        XCTAssertEqual(decoded.title, "Old Document")
        XCTAssertTrue(decoded.plots.isEmpty)
    }

    func testVersionedMetadataRoundTripsPlots() throws {
        let plots = [
            VeuszPlotRef(
                displayName: "Plot A",
                sourceRelativePath: "figures/a.vsz",
                renderedRelativePath: "figures/a.svg"
            ),
            VeuszPlotRef(
                displayName: "Plot B",
                sourceRelativePath: "figures/b.vsz",
                renderedRelativePath: "figures/b.png",
                exportFormat: .png
            ),
        ]

        let metadata = VersionedDocumentMetadata(
            schemaVersion: .current,
            id: UUID(),
            title: "With Plots",
            authors: [],
            plots: plots
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VersionedDocumentMetadata.self, from: data)

        XCTAssertEqual(decoded.plots.count, 2)
        XCTAssertEqual(decoded.plots[0].displayName, "Plot A")
        XCTAssertEqual(decoded.plots[1].exportFormat, .png)
    }

    func testDocumentMetadataDefaultsPlotsToEmptyWhenMissing() throws {
        // The app-internal DocumentMetadata mirrors VersionedDocumentMetadata
        // and must be just as tolerant of pre-v1.3 metadata.json files.
        let legacyJSON = """
        {
            "schemaVersion": 120,
            "id": "22222222-2222-2222-2222-222222222222",
            "title": "Legacy",
            "authors": [],
            "createdAt": "2024-01-01T00:00:00Z",
            "modifiedAt": "2024-01-02T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DocumentMetadata.self, from: legacyJSON)

        XCTAssertTrue(decoded.plots.isEmpty)
    }
}
