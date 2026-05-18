//
//  ManuscriptExporter.swift
//
//  Phase 5 of the unified-store pivot
//  (/Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md).
//
//  Writes a manuscript that lives in the unified store back to a
//  self-contained directory the user can hand to a collaborator, push
//  to Git, or submit to arXiv. Two output shapes:
//
//   - `.imprint` bundle — lossless round-trip; same internal layout
//     `ImprintDocument.fileWrapper(configuration:)` produces today
//     (main.{typ|tex} + metadata.json + bibliography.bib + figures/).
//   - Standalone .tex project — plain directory with main.tex +
//     references.bib + figures/. For collaborators who don't run
//     imprint.
//
//  Both flows read the manuscript body + metadata from
//  `ManuscriptStoreAdapter` and the figures from
//  `ManuscriptWorkingDirectory`. The manuscript on disk is *not*
//  detached on export — the in-store copy stays canonical; the export
//  is a one-shot copy.
//

import Foundation
import ImpressLogging
import OSLog

public enum ManuscriptExportError: LocalizedError {
    case manuscriptNotFound(UUID)
    case destinationCreateFailed(URL, Error)
    case writeFailed(URL, Error)

    public var errorDescription: String? {
        switch self {
        case .manuscriptNotFound(let id):
            return "Manuscript \(id) not found in the store."
        case .destinationCreateFailed(let url, let error):
            return "Couldn't create export directory at \(url.path): \(error.localizedDescription)"
        case .writeFailed(let url, let error):
            return "Failed to write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

/// Drives the export of a manuscript to a user-chosen path.
///
/// `@MainActor` because all reads of the manuscript item go through
/// the `@MainActor`-isolated `ManuscriptStoreAdapter`. Actual file I/O
/// happens after the adapter snapshot is captured into a local
/// `ManuscriptModel`.
@MainActor
public enum ManuscriptExporter {

    /// Export a manuscript to the user-chosen destination URL as a
    /// `.imprint` bundle. `destinationURL` should already include the
    /// `.imprint` extension; the bundle is created as a directory at
    /// that path. Overwrites if the directory already exists.
    public static func exportAsBundle(
        manuscriptID: UUID,
        to destinationURL: URL
    ) throws {
        guard let m = ManuscriptStoreAdapter.shared.manuscript(id: manuscriptID) else {
            throw ManuscriptExportError.manuscriptNotFound(manuscriptID)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destinationURL)
        do {
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            throw ManuscriptExportError.destinationCreateFailed(destinationURL, error)
        }

        // main.{typ|tex}
        let bodyFileName = m.format.bodyFileName
        let bodyURL = destinationURL.appendingPathComponent(bodyFileName)
        try writeText(m.body, to: bodyURL)

        // metadata.json — mirrors today's ImprintDocument export. Keep
        // the field surface compatible with the legacy reader so a
        // .imprint exported here re-imports cleanly into an older build.
        let metadata: [String: Any] = [
            "schemaVersion": 140,
            "id": m.id.uuidString,
            "title": m.title,
            "authors": m.authors,
            "createdAt": ISO8601DateFormatter().string(from: m.createdAt),
            "modifiedAt": m.bodyModifiedAt
                .map { ISO8601DateFormatter().string(from: $0) }
                ?? ISO8601DateFormatter().string(from: m.createdAt),
            "plots": [] as [Any],
        ]
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        let metadataURL = destinationURL.appendingPathComponent("metadata.json")
        do {
            try metadataData.write(to: metadataURL, options: .atomic)
        } catch {
            throw ManuscriptExportError.writeFailed(metadataURL, error)
        }

        // figures/ — best-effort copy from the manuscript working dir.
        try copyFigures(from: manuscriptID, to: destinationURL)

        Logger.sharedStore.infoCapture(
            "Exported manuscript \(manuscriptID) as .imprint bundle to \(destinationURL.path)",
            category: "manuscript-export"
        )
    }

    /// Export a manuscript to the user-chosen destination URL as a
    /// standalone project directory (main.tex/typ + references.bib +
    /// figures/). For LaTeX manuscripts, the directory is ready for
    /// `latexmk main.tex` out of the box.
    public static func exportAsProject(
        manuscriptID: UUID,
        to destinationURL: URL
    ) throws {
        guard let m = ManuscriptStoreAdapter.shared.manuscript(id: manuscriptID) else {
            throw ManuscriptExportError.manuscriptNotFound(manuscriptID)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destinationURL)
        do {
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            throw ManuscriptExportError.destinationCreateFailed(destinationURL, error)
        }

        // Body file.
        let bodyURL = destinationURL.appendingPathComponent(m.format.bodyFileName)
        try writeText(m.body, to: bodyURL)

        // Figures.
        try copyFigures(from: manuscriptID, to: destinationURL)

        // references.bib — TODO once bibliography-entry items are wired
        // through Cites edges (phase 4a / follow-ups). For now, emit an
        // empty placeholder so the project structure is uniform.
        let bibURL = destinationURL.appendingPathComponent("references.bib")
        try writeText("% Exported by imprint. Add citations to populate.\n", to: bibURL)

        Logger.sharedStore.infoCapture(
            "Exported manuscript \(manuscriptID) as standalone project to \(destinationURL.path)",
            category: "manuscript-export"
        )
    }

    // MARK: - Helpers

    private static func writeText(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw ManuscriptExportError.writeFailed(
                url,
                NSError(
                    domain: "imprint.export",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "body not UTF-8"]
                )
            )
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ManuscriptExportError.writeFailed(url, error)
        }
    }

    /// Copy every file under `<working dir>/figures/` for the given
    /// manuscript into `<dest>/figures/`. Creates the destination
    /// directory even when there are no figures so downstream tooling
    /// can rely on it.
    private static func copyFigures(from manuscriptID: UUID, to destinationURL: URL) throws {
        let workingDir = ManuscriptWorkingDirectory()
        let figuresDst = destinationURL.appendingPathComponent("figures", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: figuresDst, withIntermediateDirectories: true)

        let figureFiles: [String: Data]
        do {
            figureFiles = try workingDir.readFigures(forManuscriptID: manuscriptID)
        } catch {
            // No figures dir or unreadable — that's fine for a freshly-
            // created manuscript. Don't throw.
            Logger.sharedStore.infoCapture(
                "No figures to export for manuscript \(manuscriptID): \(error.localizedDescription)",
                category: "manuscript-export"
            )
            return
        }
        for (name, data) in figureFiles {
            let target = figuresDst.appendingPathComponent(name)
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                throw ManuscriptExportError.writeFailed(target, error)
            }
        }
        if !figureFiles.isEmpty {
            Logger.sharedStore.infoCapture(
                "Exported \(figureFiles.count) figure file(s) for manuscript \(manuscriptID)",
                category: "manuscript-export"
            )
        }
    }
}
