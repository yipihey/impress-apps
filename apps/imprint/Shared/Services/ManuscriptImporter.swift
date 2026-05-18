//
//  ManuscriptImporter.swift
//
//  Phase 2 of the unified-store pivot
//  (/Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md).
//
//  Imports a `.tex` or `.imprint` from a user-chosen URL into the unified
//  store as a `manuscript` item. The original file is *detached* — once
//  imported, edits go to the store; recovering a standalone copy is an
//  explicit Export (phase 5).
//
//  Dedup rules (mirroring the plan's "Deduplication and identity rules"):
//   - `.imprint` bundles: dedup key = `metadata.json.id`. Upsert-no-payload-overwrite
//     if an item already exists with that UUID.
//   - `.tex` files: dedup key = SHA-256(file bytes). Path is captured into
//     `import_source.original_path` (informational) but is NOT part of the
//     dedup key — moving a .tex file shouldn't lose its association.
//

import CommonCrypto
import Foundation
import ImpressLogging
import OSLog

public enum ManuscriptImportError: LocalizedError {
    case unreadableFile(URL, Error)
    case unsupportedExtension(String)
    case invalidImprintBundle(URL)
    case adapterFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let url, let err):
            return "Couldn't read \(url.lastPathComponent): \(err.localizedDescription)"
        case .unsupportedExtension(let ext):
            return "Unsupported file extension: .\(ext). imprint imports .tex and .imprint files."
        case .invalidImprintBundle(let url):
            return "\(url.lastPathComponent) is not a valid .imprint bundle (missing main.typ or metadata.json)."
        case .adapterFailure(let message):
            return "Failed to write manuscript into the store: \(message)"
        }
    }
}

/// Result of an import — tells the caller which manuscript to open and
/// whether it was newly created or already existed (dedup hit).
public struct ManuscriptImportResult: Equatable {
    public let manuscriptID: UUID
    public let wasAlreadyInStore: Bool
}

/// Drives the .tex / .imprint import flow into the unified store.
///
/// `@MainActor` because all writes go through `ManuscriptStoreAdapter`
/// which is main-actor-isolated. The actual file I/O happens on the
/// calling thread before any adapter call — no nested-await complexity.
@MainActor
public enum ManuscriptImporter {

    /// Import the file at `url`. Returns the manuscript ID (newly created
    /// or matched to an existing one). The caller is expected to open the
    /// editor window for the returned ID.
    @discardableResult
    public static func importDocument(at url: URL) throws -> ManuscriptImportResult {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tex", "ltx":
            return try importLaTeX(at: url)
        case "imprint":
            return try importImprintBundle(at: url)
        default:
            throw ManuscriptImportError.unsupportedExtension(ext)
        }
    }

    // MARK: - .tex import

    /// Read a `.tex` file and either find a matching existing manuscript
    /// (by SHA-256 of body bytes) or create a new one.
    private static func importLaTeX(at url: URL) throws -> ManuscriptImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ManuscriptImportError.unreadableFile(url, error)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        let hash = sha256Hex(body)

        // Dedup: look for an existing manuscript with the same body hash.
        // O(n) over manuscripts — acceptable at imprint's scale; if it
        // matters later we can index body_content_hash in the FFI search.
        if let existing = findExistingByHash(hash) {
            Logger.sharedStore.infoCapture(
                "Import \(url.lastPathComponent): dedup hit, manuscript \(existing.id)",
                category: "manuscript-import"
            )
            return ManuscriptImportResult(manuscriptID: existing.id, wasAlreadyInStore: true)
        }

        let title = inferTitleFromLaTeX(body) ?? url.deletingPathExtension().lastPathComponent
        let importSource = ImportSource(
            kind: .tex,
            originalPath: url.path,
            originalPathBookmarkBase64: try? bookmarkBase64(for: url)
        )

        let adapter = ManuscriptStoreAdapter.shared
        let id: UUID
        do {
            id = try adapter.createManuscript(
                title: title,
                format: .latex,
                body: body
            )
            try adapter.updateMetadata(id: id, importSource: importSource)
        } catch {
            throw ManuscriptImportError.adapterFailure(error.localizedDescription)
        }
        Logger.sharedStore.infoCapture(
            "Imported \(url.lastPathComponent) → manuscript \(id) (\(body.utf8.count) bytes)",
            category: "manuscript-import"
        )
        return ManuscriptImportResult(manuscriptID: id, wasAlreadyInStore: false)
    }

    // MARK: - .imprint bundle import

    /// Read a `.imprint` bundle (package directory) and either find a
    /// matching existing manuscript (by `metadata.json.id`) or create one.
    /// Brings body + figures + bibliography across into the unified store.
    private static func importImprintBundle(at url: URL) throws -> ManuscriptImportResult {
        // Sanity: must be a directory with the expected children.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw ManuscriptImportError.invalidImprintBundle(url)
        }

        let bodyURL = url.appendingPathComponent("main.typ")
        let metadataURL = url.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: bodyURL.path),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            // Could be a LaTeX-format .imprint with main.tex instead.
            let altBodyURL = url.appendingPathComponent("main.tex")
            if FileManager.default.fileExists(atPath: altBodyURL.path),
               FileManager.default.fileExists(atPath: metadataURL.path) {
                return try importImprintBundle(
                    rootURL: url,
                    bodyURL: altBodyURL,
                    metadataURL: metadataURL,
                    format: .latex
                )
            }
            throw ManuscriptImportError.invalidImprintBundle(url)
        }
        return try importImprintBundle(
            rootURL: url,
            bodyURL: bodyURL,
            metadataURL: metadataURL,
            format: .typst
        )
    }

    private static func importImprintBundle(
        rootURL: URL,
        bodyURL: URL,
        metadataURL: URL,
        format: ManuscriptFormat
    ) throws -> ManuscriptImportResult {
        let bodyData: Data
        let metadataData: Data
        do {
            bodyData = try Data(contentsOf: bodyURL)
            metadataData = try Data(contentsOf: metadataURL)
        } catch {
            throw ManuscriptImportError.unreadableFile(rootURL, error)
        }
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        // Extract id + title from metadata.json. Be lenient: if the JSON is
        // garbage, fall back to a fresh UUID + filename.
        let metadata = (try? JSONSerialization.jsonObject(with: metadataData)) as? [String: Any] ?? [:]
        let bundleID = (metadata["id"] as? String).flatMap(UUID.init(uuidString:))
        let title = metadata["title"] as? String ?? rootURL.deletingPathExtension().lastPathComponent
        let authors = metadata["authors"] as? [String] ?? []

        let adapter = ManuscriptStoreAdapter.shared

        // Dedup by bundle metadata.json.id (the canonical key per the plan).
        if let id = bundleID, let existing = adapter.manuscript(id: id) {
            Logger.sharedStore.infoCapture(
                "Import \(rootURL.lastPathComponent): dedup hit on bundle UUID, manuscript \(existing.id)",
                category: "manuscript-import"
            )
            // Upsert-no-payload-overwrite: don't clobber edited in-store
            // content with bundle bytes. The plan's conflict-resolution
            // sheet (use bundle / keep in-store / both) is a follow-up.
            return ManuscriptImportResult(manuscriptID: existing.id, wasAlreadyInStore: true)
        }

        // New import.
        let importSource = ImportSource(
            kind: .imprint,
            originalPath: rootURL.path,
            originalPathBookmarkBase64: try? bookmarkBase64(for: rootURL)
        )

        let manuscriptID: UUID
        do {
            // Preserve the bundle's UUID if present so future re-imports
            // dedup against the same item. If absent, the adapter assigns
            // a fresh one.
            if let id = bundleID {
                // Upsert with the explicit ID via the FFI directly (the
                // adapter's createManuscript always generates a fresh ID).
                manuscriptID = try createWithExplicitID(
                    id: id,
                    title: title,
                    format: format,
                    body: body,
                    authors: authors,
                    importSource: importSource
                )
            } else {
                manuscriptID = try adapter.createManuscript(
                    title: title,
                    format: format,
                    body: body,
                    authors: authors
                )
                try adapter.updateMetadata(id: manuscriptID, importSource: importSource)
            }
        } catch {
            throw ManuscriptImportError.adapterFailure(error.localizedDescription)
        }

        // Copy figures/ into the manuscript working dir, best-effort.
        copyFiguresIfPresent(from: rootURL, to: manuscriptID)

        Logger.sharedStore.infoCapture(
            "Imported \(rootURL.lastPathComponent) → manuscript \(manuscriptID)",
            category: "manuscript-import"
        )
        return ManuscriptImportResult(manuscriptID: manuscriptID, wasAlreadyInStore: false)
    }

    // MARK: - Helpers

    /// Find a manuscript whose `body_content_hash` matches `hash`. Linear
    /// scan; acceptable until usage proves it's a hot path.
    private static func findExistingByHash(_ hash: String) -> ManuscriptModel? {
        let adapter = ManuscriptStoreAdapter.shared
        for m in adapter.listManuscripts(limit: 10_000) where m.bodyContentHash == hash {
            return m
        }
        return nil
    }

    /// Inserts a manuscript item with a caller-specified UUID (used when
    /// preserving a `.imprint` bundle's `metadata.json.id`).
    private static func createWithExplicitID(
        id: UUID,
        title: String,
        format: ManuscriptFormat,
        body: String,
        authors: [String],
        importSource: ImportSource
    ) throws -> UUID {
        // The adapter's createManuscript generates its own UUID. To
        // preserve the bundle's ID we go through updateMetadata + setBody,
        // but those expect an existing item. So we first upsert via the
        // raw FFI with the explicit id, then layer on the metadata.
        let adapter = ManuscriptStoreAdapter.shared
        let now = ISO8601DateFormatter().string(from: Date())
        let bodyHash = sha256Hex(body)
        let importJSON: String = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(importSource),
                  let text = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return text
        }()
        let payload: [String: Any] = [
            "title": title,
            "status": "draft",
            "current_revision_ref": id.uuidString,
            "authors": authors,
            "format": format.rawValue,
            "body_content": body,
            "body_content_hash": bodyHash,
            "body_modified_at": now,
            "format_schema_version": 140,
            "import_source": importJSON,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let payloadString = String(data: json, encoding: .utf8) else {
            throw ManuscriptImportError.adapterFailure("payload not UTF-8")
        }
        try adapter.sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: "manuscript",
            payloadJson: payloadString
        )
        // The raw upsert bypasses didMutate; nudge the version manually.
        adapter.refresh()
        return id
    }

    /// Copy `<bundle>/figures/*` into the manuscript's working dir.
    /// Best-effort: copy failures are logged, not thrown.
    private static func copyFiguresIfPresent(from bundleURL: URL, to manuscriptID: UUID) {
        let figuresSrc = bundleURL.appendingPathComponent("figures", isDirectory: true)
        guard FileManager.default.fileExists(atPath: figuresSrc.path) else { return }
        do {
            let dst = try ManuscriptWorkingDirectory().figuresDirectory(forManuscriptID: manuscriptID)
            let children = try FileManager.default.contentsOfDirectory(
                at: figuresSrc,
                includingPropertiesForKeys: nil
            )
            for child in children {
                let target = dst.appendingPathComponent(child.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: child, to: target)
            }
            Logger.sharedStore.infoCapture(
                "Copied \(children.count) figure file(s) for manuscript \(manuscriptID)",
                category: "manuscript-import"
            )
        } catch {
            Logger.sharedStore.warningCapture(
                "Figures copy failed for manuscript \(manuscriptID): \(error.localizedDescription)",
                category: "manuscript-import"
            )
        }
    }

    /// Extract the document title from `\title{...}` in a LaTeX source.
    /// Returns nil if no title declaration is found.
    private static func inferTitleFromLaTeX(_ source: String) -> String? {
        // Scan for `\title{...}` — naive but matches every well-formed doc.
        // Avoids dragging in a full LaTeX parser for this one heuristic.
        guard let range = source.range(of: #"\title{"#, options: .literal) else { return nil }
        var depth = 1
        var idx = range.upperBound
        var result = ""
        while idx < source.endIndex && depth > 0 {
            let c = source[idx]
            if c == "{" { depth += 1; result.append(c) }
            else if c == "}" {
                depth -= 1
                if depth > 0 { result.append(c) }
            } else {
                result.append(c)
            }
            idx = source.index(after: idx)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Compute a base64 string of a security-scoped bookmark for `url`.
    /// Used so a future "Reveal original in Finder" can navigate back.
    /// Throws if bookmark creation fails (e.g. file moved before we could
    /// resolve it).
    private static func bookmarkBase64(for url: URL) throws -> String {
        #if os(macOS)
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return data.base64EncodedString()
        #else
        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return data.base64EncodedString()
        #endif
    }

    /// SHA-256 hex of a UTF-8 string. Duplicated from
    /// `ManuscriptStoreAdapter.sha256Hex` to avoid making that private
    /// helper public. Trivially cheap; not worth a shared dep.
    private static func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
