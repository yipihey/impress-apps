//
//  ManuscriptCitationResolver.swift
//  PublicationManagerCore
//
//  Turning a cite key into a paper — and, when it doesn't, into an honest
//  reason.
//
//  `ManuscriptCitationSearching.findByCiteKey` returns nil for two completely
//  different situations:
//
//    1. the library has papers, none of them has this cite key;
//    2. the library has NO papers on this device at all.
//
//  On iOS (2) is the common case, not the edge case: imprint-iOS reads the
//  shared store that imbib-iOS populates, and imbib's CloudKit sync ships
//  DEFAULT OFF (ADR-0020). A fresh install has an empty publication table. A UI
//  that renders both as "not in your library" tells a user their citation is
//  wrong when in fact nothing has arrived yet — the empty-state failure this
//  project has already paid for once.
//
//  `CitationResolution` keeps the two apart, and carries the count that
//  justifies the claim, so the UI can show its work instead of asserting.
//  The same three-way answer is available to agents as the Rust service method
//  `imbib-search-service_resolve-cite-key` (`status`: `resolved` /
//  `unknown-key` / `empty-library`), which runs the same store lookup.
//

import Foundation
import ImbibRustCore

// MARK: - Resolution

/// What a cite key resolved to, or why it didn't.
public enum CitationResolution: Equatable {
    /// The paper.
    case resolved(BibliographyRow)

    /// The library has publications, but none with this cite key.
    /// `libraryCount` is how many it does have — nil when the backing search
    /// can't say (a host that installed a citation search without a count).
    case unknownKey(citeKey: String, libraryCount: Int?)

    /// The library holds no publications at all on this device, so the key was
    /// never really tested. NOT the same as the key being wrong.
    case emptyLibrary(citeKey: String)

    /// No citation search is installed in `ManuscriptEditorEnvironment` — the
    /// host never wired the seam, so nothing could be looked up.
    case unavailable(citeKey: String)

    /// The key that was looked up, in every case.
    public var citeKey: String {
        switch self {
        case .resolved(let row): return row.citeKey
        case .unknownKey(let key, _), .emptyLibrary(let key), .unavailable(let key): return key
        }
    }

    /// The paper, when there is one.
    public var row: BibliographyRow? {
        if case .resolved(let row) = self { return row }
        return nil
    }

    /// The `status` string the Rust `resolve_cite_key` service method reports
    /// for the same situation. Keeping the two vocabularies identical is what
    /// lets an agent and a human compare notes about the same citation.
    public var status: String {
        switch self {
        case .resolved: return "resolved"
        case .unknownKey: return "unknown-key"
        case .emptyLibrary: return "empty-library"
        case .unavailable: return "unavailable"
        }
    }
}

// MARK: - Programmatic trigger

extension Notification.Name {
    /// "Inspect this cite key" — the programmatic form of the gesture.
    ///
    /// `userInfo["citeKey"]` is the key (with or without a leading `@`). Posting
    /// this is exactly equivalent to the user long-pressing that citation, so an
    /// agent, a URL handler (`imprint://inspect/citation/{key}`) or a UI test can
    /// drive the affordance without synthesizing a touch. imprint-iOS observes it
    /// in `IOSContentView`.
    public static let inspectCiteKey = Notification.Name("impress.inspectCiteKey")
}

// MARK: - Resolver

/// Resolves manuscript cite keys against the host's installed citation search.
public enum ManuscriptCitationResolver {

    /// Normalize a key as it appears in source: trim, drop a leading `@`.
    public static func normalize(_ citeKey: String) -> String {
        var key = citeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("@") { key.removeFirst() }
        return key
    }

    /// Resolve `citeKey` through `ManuscriptEditorEnvironment.shared.citationSearch`.
    @MainActor
    public static func resolve(_ citeKey: String) -> CitationResolution {
        let key = normalize(citeKey)
        guard let search = ManuscriptEditorEnvironment.shared.citationSearch else {
            return .unavailable(citeKey: key)
        }
        if let row = search.findByCiteKey(key) {
            return .resolved(row)
        }
        // The miss needs a reason, and the only evidence that distinguishes the
        // two reasons is how many publications exist at all.
        guard let count = search.libraryPublicationCount() else {
            return .unknownKey(citeKey: key, libraryCount: nil)
        }
        return count == 0 ? .emptyLibrary(citeKey: key) : .unknownKey(citeKey: key, libraryCount: count)
    }
}
