// Chassis WIRING file — CROSS-PLATFORM (macOS + iOS). Pure: no store, no UI.
//
//  BibliographyFileText.swift
//  PublicationManagerCore
//
//  ADR-0023 W2 — "a discovered bibliography file, as BibTeX".
//
//  ── Why this exists ─────────────────────────────────────────────────────────
//
//  imbib's real importer takes BibTeX text (`RustStoreAdapter.importBibTeX`,
//  and the Rust `import_bibtex_into` behind it, which owns the identifier
//  dedup). A `.ris` file is not BibTeX, and the ONE place in the app that
//  bridges the two is a private loop inside `LibraryViewModel.importRIS`:
//  parse with `RISParserFactory`, `toBibTeX()` each entry, import each.
//
//  A watched folder needs exactly that bridge and cannot use that loop —
//  `LibraryViewModel` is a `@MainActor` view model that reloads a publication
//  list and queues enrichment as side effects. So the bridge is lifted here as
//  a pure function, with the RIS half spelled the same way, and the watcher
//  calls it instead of growing a second RIS story.
//
//  `LibraryViewModel.importRIS` is deliberately NOT refactored onto this in W2:
//  it interleaves per-entry imports with `beginBatchMutation`/`recordRecentAdd`
//  bookkeeping that a watched folder must not perform (files the watcher finds
//  are not "papers the user just added"), and rewriting a shipped import path
//  is not this work package's risk to take.
//
//  ── The whole-file rule ─────────────────────────────────────────────────────
//
//  A watched `.bib` is imported as ONE blob, not entry by entry. That is what
//  the manual path does (`ContentView.importPreviewEntries` joins the selected
//  entries and calls `importBibTeX` once), and it is what makes the identifier
//  dedup a single pass over the library rather than N. RIS has no such option:
//  the conversion is per entry, so the entries are converted and then joined
//  back into one blob here, which restores the single-pass property.
//

import Foundation

/// Reading a discovered bibliography file as BibTeX.
public enum BibliographyFileText {

    /// Why a discovered file could not be turned into BibTeX.
    public enum Failure: Error, LocalizedError, Equatable {

        /// The extension is not one the publication kind declares. Should be
        /// unreachable — the watcher filters on the same declaration — and is
        /// carried anyway so a mis-filtered file is reported, not guessed at.
        case unsupportedExtension(String)

        /// The file could not be read, or is not text.
        case unreadable(path: String, reason: String)

        /// It read, and there was nothing in it.
        case empty(path: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedExtension(let ext):
                return "\(ext.isEmpty ? "This file" : ".\(ext) files") cannot be read as a bibliography."
            case .unreadable(let path, let reason):
                return "\((path as NSString).lastPathComponent) could not be read: \(reason)"
            case .empty(let path):
                return "\((path as NSString).lastPathComponent) is empty."
            }
        }
    }

    /// The extensions this reader handles, lowercased.
    ///
    /// Derived from the publication kind's declaration rather than listed, so
    /// this cannot drift from what the watcher actually discovers — ADR-0023
    /// D1's rule applied to the consumer side of the same capability.
    public static var supportedExtensions: Set<String> {
        Set(PublicationRecordKind.descriptor.fileDiscovery?.fileExtensions ?? [])
    }

    /// One discovered file's contents, as one BibTeX blob.
    ///
    /// `.bib` / `.bibtex` pass through unchanged — BibTeX is imbib's source of
    /// truth (imbib ADR-002) and re-serialising it would be a round trip with
    /// nothing to gain and fidelity to lose. `.ris` is parsed and converted.
    public static func bibtex(atPath path: String) throws -> String {
        try bibtex(at: URL(fileURLWithPath: path))
    }

    public static func bibtex(at url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw Failure.unsupportedExtension(ext)
        }

        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // A `.bib` written by a pre-Unicode tool is latin-1 more often than
            // it is broken. Try that before declaring the file unreadable —
            // silently dropping such a file would be indistinguishable from a
            // folder that simply has fewer papers in it.
            guard let fallback = try? String(contentsOf: url, encoding: .isoLatin1) else {
                throw Failure.unreadable(path: url.path, reason: error.localizedDescription)
            }
            return try normalize(fallback, ext: ext, path: url.path)
        }
        return try normalize(contents, ext: ext, path: url.path)
    }

    private static func normalize(_ contents: String, ext: String, path: String) throws -> String {
        guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.empty(path: path)
        }
        guard ext == "ris" else { return contents }

        let entries = try RISParserFactory.createParser().parse(contents)
        guard !entries.isEmpty else { throw Failure.empty(path: path) }
        // Same conversion `LibraryViewModel.importRIS` performs, joined into
        // one blob so the dedup pass runs once for the file rather than once
        // per entry.
        return entries
            .map { risEntry -> String in
                let entry = risEntry.toBibTeX()
                return entry.rawBibTeX ?? entry.synthesizeBibTeX()
            }
            .joined(separator: "\n\n")
    }
}
