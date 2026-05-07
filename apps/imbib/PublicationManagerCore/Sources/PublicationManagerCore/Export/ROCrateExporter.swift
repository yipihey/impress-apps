//
//  ROCrateExporter.swift
//  PublicationManagerCore
//
//  Phase 5.2 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.5 + ADR-0011 D10).
//
//  Exports a manuscript-revision as an RO-Crate 1.1 directory:
//
//    {output}/{manuscript-id}-{revision-id}/
//      ro-crate-metadata.json
//      sources/{revision-tag}.tex      (or .typ)
//      pdfs/{revision-tag}.pdf         (placeholder until imprint compile lands)
//      bibliography/references.bib     (cited entries only)
//      reviews/                        (one .md per review)
//      revision-notes/                 (one .md per revision-note)
//
//  See https://www.researchobject.org/ro-crate/1.1/ for the spec.
//  Phase 5 ships the minimum profile: a Dataset root entity describing the
//  manuscript revision plus File entities for each artifact. Future polish
//  may upgrade to specific RO-Crate Profiles (Workflow, Documentation, etc.).
//

import Foundation
import OSLog

private let exporterLog = Logger(subsystem: "com.imbib.app", category: "ro-crate-exporter")

// MARK: - Errors

public enum ROCrateExportError: Error, LocalizedError {
    case revisionNotFound(String)
    case manuscriptNotFound(String)
    case writeError(String)

    public var errorDescription: String? {
        switch self {
        case .revisionNotFound(let id):
            return "Manuscript revision not found: \(id)"
        case .manuscriptNotFound(let id):
            return "Manuscript not found: \(id)"
        case .writeError(let msg):
            return "RO-Crate write error: \(msg)"
        }
    }
}

// MARK: - Result

public struct ROCrateExportResult: Sendable {
    public let crateDirectory: URL
    public let metadataPath: URL
    public let payloadFileCount: Int
    public let manuscriptID: String
    public let revisionID: String
}

// MARK: - Exporter

/// Exports a journal manuscript-revision as an RO-Crate 1.1 directory.
///
/// Reads from the unified workspace store via ManuscriptBridge (which
/// already holds a SharedStore handle for journal items). Pure file
/// IO from there: builds the metadata JSON, writes payload files.
public actor ROCrateExporter {

    public static let shared = ROCrateExporter()

    private let bridge: ManuscriptBridge

    public init(bridge: ManuscriptBridge = ManuscriptBridge.shared) {
        self.bridge = bridge
    }

    // MARK: - Public API

    /// Export the named revision as an RO-Crate directory under `outputDirectory`.
    @discardableResult
    public func export(
        manuscriptID: String,
        revisionID: String,
        outputDirectory: URL
    ) async throws -> ROCrateExportResult {
        let manuscript = await bridge.getManuscript(id: manuscriptID)
        guard let manuscript else { throw ROCrateExportError.manuscriptNotFound(manuscriptID) }

        let revision = await bridge.getRevision(id: revisionID)
        guard let revision, revision.parentManuscriptRef == manuscriptID else {
            throw ROCrateExportError.revisionNotFound(revisionID)
        }

        let crateDir = outputDirectory.appendingPathComponent(
            "\(manuscriptID.prefix(8))-\(revision.revisionTag)",
            isDirectory: true
        )
        try createDirectory(at: crateDir)

        // Subdirectories
        let sourcesDir = crateDir.appendingPathComponent("sources", isDirectory: true)
        let pdfsDir    = crateDir.appendingPathComponent("pdfs",    isDirectory: true)
        let bibDir     = crateDir.appendingPathComponent("bibliography", isDirectory: true)
        let reviewsDir = crateDir.appendingPathComponent("reviews", isDirectory: true)
        let notesDir   = crateDir.appendingPathComponent("revision-notes", isDirectory: true)
        for d in [sourcesDir, pdfsDir, bibDir, reviewsDir, notesDir] {
            try createDirectory(at: d)
        }

        var payloadFiles: [PayloadFile] = []

        // 1. Source archive.
        //    Phase 8 bundles: copy the real `.tar.zst` archive bytes from
        //    BlobStore so the RO-Crate is self-contained and a recipient
        //    can reproduce the manuscript by extracting it.
        //    Phase 7-era inline-text revisions still emit a pointer file,
        //    since their bytes live in a different blob namespace
        //    (BlobStore resolution for inline text is a follow-up).
        let sourceFileName = "\(revision.revisionTag).\(sourceExtension(for: revision))"
        let sourceURL = sourcesDir.appendingPathComponent(sourceFileName)
        if revision.isBundle, let archiveURL = await bridge.getRevisionBundleArchiveURL(revisionID: revisionID) {
            try copyItem(at: archiveURL, to: sourceURL)
            let entries = revision.bundleEntries() ?? []
            payloadFiles.append(PayloadFile(
                relativePath: "sources/\(sourceFileName)",
                description: "Manuscript bundle for revision \(revision.revisionTag) — \(entries.count) files. Extract with `tar --zstd -xf`.",
                encodingFormat: "application/zstd"
            ))
            // Also list each bundle entry as a hasPart entry referencing
            // the same archive — gives downstream RO-Crate consumers the
            // file inventory without forcing extraction.
            for entry in entries {
                payloadFiles.append(PayloadFile(
                    relativePath: "sources/\(sourceFileName)#\(entry.path)",
                    description: "\(entry.displayRole): \(entry.path)",
                    encodingFormat: encodingFormat(forEntryPath: entry.path)
                ))
            }
        } else {
            let sourcePointer = "Blob reference: \(revision.sourceArchiveRef)\n" +
                "(Inline-text revisions don't yet resolve back to bytes; bundle revisions write their `.tar.zst` here directly.)\n"
            try writeData(sourcePointer.data(using: .utf8) ?? Data(), to: sourceURL)
            payloadFiles.append(PayloadFile(
                relativePath: "sources/\(sourceFileName)",
                description: "Source content for revision \(revision.revisionTag).",
                encodingFormat: revision.sourceArchiveRef.contains("tar.zst") ? "application/zstd" : "text/plain"
            ))
        }

        // 2. PDF artifact — same placeholder treatment until imprint compile lands.
        let pdfURL = pdfsDir.appendingPathComponent("\(revision.revisionTag).pdf")
        let pdfPointer = "PDF artifact reference: \(revision.pdfArtifactRef)\n" +
            "(Real PDF bytes are written by the snapshot job once imprint compile is wired.)\n"
        try writeData(pdfPointer.data(using: .utf8) ?? Data(), to: pdfURL)
        payloadFiles.append(PayloadFile(
            relativePath: "pdfs/\(revision.revisionTag).pdf",
            description: "Compiled PDF for revision \(revision.revisionTag).",
            encodingFormat: "application/pdf"
        ))

        // 3. Reviews — write one .md per review whose subject_ref is the revision.
        let reviews = await bridge.listReviews(manuscriptID: manuscriptID).filter { $0.subjectRef == revisionID }
        for review in reviews {
            let filename = "\(review.id.prefix(8))-\(review.verdict.rawValue).md"
            let body = "# Review (\(review.verdict.displayName))\n\n" +
                       "Reviewer: \(review.agentID ?? "human")\n\n" +
                       (review.summary.map { "**Summary:** \($0)\n\n" } ?? "") +
                       review.body
            try writeData(body.data(using: .utf8) ?? Data(), to: reviewsDir.appendingPathComponent(filename))
            payloadFiles.append(PayloadFile(
                relativePath: "reviews/\(filename)",
                description: "Review by \(review.agentID ?? "human"); verdict=\(review.verdict.displayName).",
                encodingFormat: "text/markdown"
            ))
        }

        // 4. Revision-notes — same per-item file pattern.
        let notes = await bridge.listRevisionNotes(manuscriptID: manuscriptID).filter { $0.subjectRef == revisionID }
        for note in notes {
            let filename = "\(note.id.prefix(8))-\(note.verdict.rawValue).md"
            var body = "# Revision Note (\(note.verdict.displayName))\n\n" +
                       "Author: \(note.agentID ?? "human")\n\n" +
                       note.body
            if let diff = note.diff, !diff.isEmpty {
                body += "\n\n## Proposed Diff\n\n```diff\n\(diff)\n```\n"
            }
            try writeData(body.data(using: .utf8) ?? Data(), to: notesDir.appendingPathComponent(filename))
            payloadFiles.append(PayloadFile(
                relativePath: "revision-notes/\(filename)",
                description: "Revision-note by \(note.agentID ?? "human"); verdict=\(note.verdict.displayName).",
                encodingFormat: "text/markdown"
            ))
        }

        // 5. Bibliography subset — Phase 5 ships an empty references.bib
        //    placeholder. Phase 5.5+ wires BibTeX extraction from the cited
        //    bibliography entries (requires a Cites-edge query path).
        let bibURL = bibDir.appendingPathComponent("references.bib")
        let bibContent = "% Bibliography subset for manuscript-revision \(revisionID)\n" +
            "% Cited-entry extraction is a Phase 5.5+ enhancement.\n"
        try writeData(bibContent.data(using: .utf8) ?? Data(), to: bibURL)
        payloadFiles.append(PayloadFile(
            relativePath: "bibliography/references.bib",
            description: "Bibliography subset (placeholder until cite-edge extraction lands).",
            encodingFormat: "text/x-bibtex"
        ))

        // 6. Build ro-crate-metadata.json.
        let metadataURL = crateDir.appendingPathComponent("ro-crate-metadata.json")
        let metadata = buildMetadata(
            manuscript: manuscript,
            revision: revision,
            payloadFiles: payloadFiles
        )
        try writeData(metadata, to: metadataURL)

        exporterLog.infoCapture(
            "ROCrateExporter: wrote crate at \(crateDir.path) with \(payloadFiles.count) payload files",
            category: "ro-crate-exporter"
        )

        return ROCrateExportResult(
            crateDirectory: crateDir,
            metadataPath: metadataURL,
            payloadFileCount: payloadFiles.count,
            manuscriptID: manuscriptID,
            revisionID: revisionID
        )
    }

    // MARK: - Metadata builder

    /// Build the `ro-crate-metadata.json` for the export.
    /// Conforms to RO-Crate 1.1 spec: a JSON-LD document with a Metadata
    /// File Descriptor entity and a Root Data Entity.
    private func buildMetadata(
        manuscript: JournalManuscript,
        revision: JournalRevision,
        payloadFiles: [PayloadFile]
    ) -> Data {
        var graph: [[String: Any]] = []

        // Metadata File Descriptor (always exactly this shape per spec).
        graph.append([
            "@id": "ro-crate-metadata.json",
            "@type": "CreativeWork",
            "conformsTo": ["@id": "https://w3id.org/ro/crate/1.1"],
            "about": ["@id": "./"],
        ])

        // Root Data Entity describing the crate.
        var rootEntity: [String: Any] = [
            "@id": "./",
            "@type": "Dataset",
            "name": manuscript.title,
            "description": "Journal manuscript-revision \(revision.revisionTag) (impress journal pipeline).",
            "datePublished": ISO8601DateFormatter().string(from: Date()),
            "hasPart": payloadFiles.map { ["@id": $0.relativePath] },
        ]
        if !manuscript.authors.isEmpty {
            rootEntity["author"] = manuscript.authors.map { name in
                ["@type": "Person", "name": name] as [String: Any]
            }
        }
        if let target = manuscript.journalTarget {
            rootEntity["publisher"] = ["@type": "Organization", "name": target] as [String: Any]
        }
        graph.append(rootEntity)

        // File entities for each payload file.
        for f in payloadFiles {
            graph.append([
                "@id":            f.relativePath,
                "@type":          "File",
                "name":           (f.relativePath as NSString).lastPathComponent,
                "description":    f.description,
                "encodingFormat": f.encodingFormat,
            ])
        }

        // Provenance entity for the revision itself.
        graph.append([
            "@id": "#manuscript-revision-\(revision.id)",
            "@type": "DigitalDocument",
            "name": "Revision \(revision.revisionTag)",
            "identifier": revision.id,
            "sha256": revision.contentHash,
            "isPartOf": ["@id": "./"],
        ])

        let crate: [String: Any] = [
            "@context": "https://w3id.org/ro/crate/1.1/context",
            "@graph":   graph,
        ]

        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: crate, options: opts))
            ?? Data("{}".utf8)
    }

    // MARK: - File helpers

    private struct PayloadFile {
        let relativePath: String
        let description: String
        let encodingFormat: String
    }

    private func sourceExtension(for revision: JournalRevision) -> String {
        if revision.sourceArchiveRef.contains("tar.zst") { return "tar.zst" }
        // Default: assume LaTeX if we don't know.
        return "tex"
    }

    private func createDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw ROCrateExportError.writeError(
                "createDirectory \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private func writeData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ROCrateExportError.writeError(
                "write \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func copyItem(at src: URL, to dst: URL) throws {
        do {
            // Ensure no stale file is in the way.
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            throw ROCrateExportError.writeError(
                "copy \(src.lastPathComponent) → \(dst.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /// Best-effort MIME for an entry path inside a manuscript bundle.
    /// Used to populate the `encodingFormat` of per-entry hasPart records
    /// even though all entries live inside a single `.tar.zst`.
    private func encodingFormat(forEntryPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "tex", "sty", "cls": return "application/x-tex"
        case "typ":                return "text/plain; format=typst"
        case "bib", "bbl":         return "application/x-bibtex"
        case "md", "markdown":     return "text/markdown"
        case "html", "htm":        return "text/html"
        case "pdf":                return "application/pdf"
        case "png":                return "image/png"
        case "jpg", "jpeg":        return "image/jpeg"
        case "gif":                return "image/gif"
        case "svg":                return "image/svg+xml"
        case "tiff", "tif":        return "image/tiff"
        case "webp":               return "image/webp"
        case "eps":                return "application/postscript"
        case "ttf", "otf":         return "font/\(ext)"
        case "json":               return "application/json"
        default:                   return "application/octet-stream"
        }
    }
}
