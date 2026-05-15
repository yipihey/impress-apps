//
//  ROCrateBuilder.swift
//  imprint
//
//  Builds an RO-Crate 1.1 metadata document for an .imprint bundle.
//  Per ADR-0014 D55: the overlay is a regenerated view of metadata.json
//  + bibliography.bib + plots[] — never authoritative state.
//
//  Spec: https://www.researchobject.org/ro-crate/1.1/
//

import Foundation

enum ROCrateBuilder {

    /// RO-Crate 1.1 JSON-LD context URL.
    static let contextURL = "https://w3id.org/ro/crate/1.1/context"

    /// File name of the RO-Crate manifest inside an .imprint bundle.
    static let manifestFilename = "ro-crate-metadata.json"

    /// Build the RO-Crate metadata document for an imprint document.
    ///
    /// The result is canonical JSON-LD ready to write to
    /// `ro-crate-metadata.json` inside the package bundle.
    static func build(for doc: ImprintDocument, bibKeys: [String]) -> Data? {
        var graph: [[String: Any]] = []

        // 1. Descriptor entity for the metadata file itself (required by spec).
        graph.append([
            "@id": manifestFilename,
            "@type": "CreativeWork",
            "conformsTo": ["@id": "https://w3id.org/ro/crate/1.1"],
            "about": ["@id": "./"]
        ])

        // 2. Root Dataset entity describing the manuscript.
        var root: [String: Any] = [
            "@id": "./",
            "@type": "Dataset",
            "name": doc.title,
            "datePublished": iso8601String(doc.modifiedAt),
            "dateCreated": iso8601String(doc.createdAt),
            "hasPart": []  // populated below
        ]

        // Authors → Person nodes. When ORCID is set, use the ORCID URL as @id
        // so the Person node is globally addressable.
        var authorRefs: [[String: String]] = []
        var personEntities: [[String: Any]] = []
        for (idx, name) in doc.authors.enumerated() {
            let authorID: String
            if idx == 0, let orcid = doc.orcid, !orcid.isEmpty {
                authorID = "https://orcid.org/\(orcid)"
            } else {
                authorID = "_:author-\(idx)"
            }
            authorRefs.append(["@id": authorID])

            var person: [String: Any] = [
                "@id": authorID,
                "@type": "Person",
                "name": name
            ]
            if idx == 0, let affiliation = doc.affiliation, !affiliation.isEmpty {
                person["affiliation"] = ["@type": "Organization", "name": affiliation]
            }
            personEntities.append(person)
        }
        if !authorRefs.isEmpty {
            root["author"] = authorRefs
        }

        if let license = doc.license, !license.isEmpty {
            // SPDX identifiers are commonly referenced by URL.
            root["license"] = ["@id": "https://spdx.org/licenses/\(license)"]
        }
        if let funder = doc.funder, !funder.isEmpty {
            root["funder"] = ["@type": "Organization", "name": funder]
        }
        if let embargo = doc.embargoUntil {
            root["temporalCoverage"] = "../\(iso8601DateOnly(embargo))"
            root["disambiguatingDescription"] = "Embargoed until \(iso8601DateOnly(embargo))"
        }

        // 3. Figure entries (CreativeWork) — one per tracked plot.
        var hasPart: [[String: String]] = []
        var figureEntities: [[String: Any]] = []
        for plot in doc.plots {
            let path = plot.renderedRelativePath
            hasPart.append(["@id": path])
            var fig: [String: Any] = [
                "@id": path,
                "@type": "CreativeWork",
                "name": plot.displayName,
                "encodingFormat": mimeType(for: plot.exportFormat),
                "isPartOf": ["@id": "./"]
            ]
            // Per-figure provenance sidecar link is wired in Phase 4 (ADR-0014 D57)
            // once VeuszPlotRef gains the provenanceRelativePath field.
            figureEntities.append(fig)
        }

        // 4. Cited papers — ScholarlyArticle stubs for every key in
        //    bibliography.bib. We don't try to parse the BibTeX; the @id
        //    is the bibtex key prefixed with `#bib-` so it resolves
        //    locally. A future enhancement could embed DOI URLs when known.
        var citationEntities: [[String: Any]] = []
        var citationRefs: [[String: String]] = []
        for key in bibKeys {
            let id = "#bib-\(key)"
            citationRefs.append(["@id": id])
            citationEntities.append([
                "@id": id,
                "@type": "ScholarlyArticle",
                "identifier": key
            ])
        }
        if !citationRefs.isEmpty {
            root["citation"] = citationRefs
        }

        root["hasPart"] = hasPart

        graph.append(root)
        graph.append(contentsOf: personEntities)
        graph.append(contentsOf: figureEntities)
        graph.append(contentsOf: citationEntities)

        let crate: [String: Any] = [
            "@context": contextURL,
            "@graph": graph
        ]

        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        return try? JSONSerialization.data(withJSONObject: crate, options: options)
    }

    /// Read FAIR fields back from an RO-Crate manifest. Returns nil when the
    /// data isn't a parseable RO-Crate or the root Dataset doesn't carry the
    /// fields. Used by the read path to honor an external editor's RO-Crate
    /// mutations (ADR-0014 D55, reverse-read precedence).
    static func readFAIRFields(from data: Data) -> ROCrateFAIRFields? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let graph = obj["@graph"] as? [[String: Any]]
        else {
            return nil
        }

        // The root Dataset has @id "./".
        guard let root = graph.first(where: { ($0["@id"] as? String) == "./" }) else {
            return nil
        }

        var out = ROCrateFAIRFields()

        // License: prefer the @id URL form; strip SPDX prefix when present.
        if let licenseObj = root["license"] as? [String: Any],
           let licenseID = licenseObj["@id"] as? String {
            let prefix = "https://spdx.org/licenses/"
            out.license = licenseID.hasPrefix(prefix)
                ? String(licenseID.dropFirst(prefix.count))
                : licenseID
        }

        // Funder: stored as an Organization with name.
        if let funderObj = root["funder"] as? [String: Any],
           let name = funderObj["name"] as? String {
            out.funder = name
        }

        // Author[0]: ORCID + affiliation lift back from the first Person node.
        if let authors = root["author"] as? [[String: String]],
           let firstAuthorRef = authors.first?["@id"] {
            let orcidPrefix = "https://orcid.org/"
            if firstAuthorRef.hasPrefix(orcidPrefix) {
                out.orcid = String(firstAuthorRef.dropFirst(orcidPrefix.count))
            }
            if let personNode = graph.first(where: { ($0["@id"] as? String) == firstAuthorRef }),
               let affObj = personNode["affiliation"] as? [String: Any],
               let affName = affObj["name"] as? String {
                out.affiliation = affName
            }
        }

        // Embargo lifts from temporalCoverage = "../<date>".
        if let coverage = root["temporalCoverage"] as? String,
           coverage.hasPrefix("../") {
            let dateStr = String(coverage.dropFirst(3))
            if let date = iso8601DateOnlyFormatter.date(from: dateStr) {
                out.embargoUntil = date
            }
        }

        return out
    }

    // MARK: - Helpers

    private static func mimeType(for format: VeuszPlotRef.ExportFormat) -> String {
        switch format {
        case .svg: return "image/svg+xml"
        case .png: return "image/png"
        case .pdf: return "application/pdf"
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601DateOnlyFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static func iso8601String(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    private static func iso8601DateOnly(_ date: Date) -> String {
        iso8601DateOnlyFormatter.string(from: date)
    }
}

/// FAIR-relevant fields liftable from an RO-Crate manifest. Used to honor
/// external-editor mutations on read (ADR-0014 D55, reverse-read precedence).
struct ROCrateFAIRFields: Sendable {
    var orcid: String?
    var affiliation: String?
    var funder: String?
    var license: String?
    var embargoUntil: Date?

    init() {}

    /// True when at least one field is populated.
    var isEmpty: Bool {
        orcid == nil && affiliation == nil && funder == nil && license == nil && embargoUntil == nil
    }
}
