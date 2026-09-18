#if os(macOS)
//
//  ManuscriptCitationInserter.swift
//  PublicationManagerCore
//
//  Putting a cite key into the manuscript the author is writing, asked for
//  from OUTSIDE the editor — imbib's papers window, imprint's HTTP API, an
//  `imprint://insert/citation/…` URL, an agent.
//
//  Why a registry and not a notification: the caller needs to know whether the
//  citation actually landed. imprint shipped a `POST
//  /api/documents/{id}/insert-citation` route that posted `.insertCitation`
//  and answered "Citation insert requested" — nothing observed that
//  notification, so the answer was always a lie. A registration is present
//  only while an editor for that manuscript is live, so "no editor open" is a
//  distinguishable outcome instead of silence.
//

import AppKit
import Foundation
import OSLog

/// What happened to an insertion request.
public enum CitationInsertOutcome: Equatable, Sendable {
    /// The keys went into the editor at the caret.
    case inserted(String)
    /// No editor is open for that manuscript (or for anything, when the
    /// request named no manuscript).
    case noEditor
    /// The editor refused the edit — the document is not editable right now.
    case refused(String)
    /// The request carried no cite key.
    case nothingToInsert

    public var didInsert: Bool {
        if case .inserted = self { return true }
        return false
    }

    /// One line for an HTTP body, a log, or a window's status.
    public var message: String {
        switch self {
        case .inserted(let text): return "inserted \(text)"
        case .noEditor: return "imprint has no open editor for that manuscript"
        case .refused(let why): return why
        case .nothingToInsert: return "no cite key to insert"
        }
    }
}

/// The live manuscript editors that can take a citation, keyed by manuscript.
///
/// An editor registers while it is mounted and unregisters when it goes away;
/// the most recently focused one answers a request that names no manuscript.
@MainActor
public final class ManuscriptCitationInserter {

    public static let shared = ManuscriptCitationInserter()

    private struct Entry {
        let insert: @MainActor ([String]) -> CitationInsertOutcome
        /// The document's citation syntax, so a caller can show what it will write.
        let format: @MainActor () -> DocumentFormat
        /// Open the inline citation palette at the caret — what a menu item or
        /// a shortcut outside the editor means by "Insert Citation…".
        let openPalette: @MainActor () -> Bool
    }

    private var entries: [UUID: Entry] = [:]
    /// Most recently focused manuscript first.
    private var recency: [UUID] = []

    private init() {}

    // MARK: - Registration (the editor's side)

    /// Register the editor for `manuscriptID`. Re-registering replaces the
    /// previous entry — SwiftUI re-creates representables freely.
    public func register(
        manuscriptID: UUID,
        format: @escaping @MainActor () -> DocumentFormat,
        insert: @escaping @MainActor ([String]) -> CitationInsertOutcome,
        openPalette: @escaping @MainActor () -> Bool = { false }
    ) {
        entries[manuscriptID] = Entry(insert: insert, format: format, openPalette: openPalette)
        noteFocused(manuscriptID)
        Logger.editor.debugCapture(
            "citation inserter: editor registered for \(manuscriptID)", category: "citation")
    }

    public func unregister(manuscriptID: UUID) {
        entries.removeValue(forKey: manuscriptID)
        recency.removeAll { $0 == manuscriptID }
    }

    /// Move a manuscript to the front of the recency list — called when its
    /// editor becomes the first responder, so an un-targeted insert lands in
    /// the manuscript the author was last writing.
    public func noteFocused(_ manuscriptID: UUID) {
        guard entries[manuscriptID] != nil else { return }
        recency.removeAll { $0 == manuscriptID }
        recency.insert(manuscriptID, at: 0)
    }

    // MARK: - Insertion (everyone else's side)

    /// The manuscript an un-targeted insert would land in.
    public var focusedManuscriptID: UUID? { recency.first }

    /// Whether an editor for `manuscriptID` is open right now.
    public func canInsert(into manuscriptID: UUID) -> Bool { entries[manuscriptID] != nil }

    /// The citation syntax of the open editor for `manuscriptID`.
    public func format(of manuscriptID: UUID) -> DocumentFormat? { entries[manuscriptID]?.format() }

    /// Insert cite keys into `manuscriptID`'s editor at its caret; with
    /// `manuscriptID` nil, into the most recently focused editor.
    @discardableResult
    public func insert(_ citeKeys: [String], into manuscriptID: UUID? = nil) -> CitationInsertOutcome {
        let keys = citeKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keys.isEmpty else { return .nothingToInsert }
        guard let id = manuscriptID ?? focusedManuscriptID, let entry = entries[id] else {
            Logger.editor.infoCapture(
                "citation inserter: no editor for \(manuscriptID?.uuidString ?? "the focused manuscript")",
                category: "citation")
            return .noEditor
        }
        let outcome = entry.insert(keys)
        Logger.editor.infoCapture(
            "citation inserter: \(keys.joined(separator: ", ")) → \(id): \(outcome.message)",
            category: "citation")
        return outcome
    }

    /// Open the inline citation palette in an editor — `manuscriptID`'s, or
    /// the most recently focused one.
    ///
    /// imprint's "Insert Citation…" (⇧⌘K) posted a notification nothing
    /// observed; ⌘S inside the editor was the only way to raise the palette.
    /// Both now come here.
    @discardableResult
    public func openPalette(for manuscriptID: UUID? = nil) -> Bool {
        guard let id = manuscriptID ?? focusedManuscriptID, let entry = entries[id] else {
            Logger.editor.infoCapture(
                "citation palette: no editor to open it in", category: "citation")
            return false
        }
        return entry.openPalette()
    }

    // MARK: - Citation text

    /// What a set of cite keys looks like in `format`.
    ///
    /// One definition, used by the editor's insertion and by imbib's papers
    /// window when it offers "Copy citation" — the panel this replaced had its
    /// own copy, which is how the two could disagree.
    public static func citationText(for citeKeys: [String], format: DocumentFormat) -> String {
        let keys = citeKeys.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return "" }
        switch format {
        case .latex:
            return "\\cite{\(keys.joined(separator: ","))}"
        case .typst:
            return keys.map { "@\($0)" }.joined(separator: " ")
        case .markdown:
            // Pandoc: one bracketed group, keys separated by semicolons.
            return keys.count == 1 ? "@\(keys[0])" : "[\(keys.map { "@\($0)" }.joined(separator: "; "))]"
        case .plaintext:
            return keys.joined(separator: ", ")
        }
    }
}
#endif
