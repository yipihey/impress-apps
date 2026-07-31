// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Data only: no AppKit,
// no NSMetadataQuery, no store. `FolderWatchService`'s macOS engines consume
// it; nothing here consumes them.
//
//  FileDiscoveryFilter.swift
//  PublicationManagerCore
//
//  ADR-0023 D1/D5 — "which files does a watched folder discover", as a value.
//
//  ── Why this type exists at all ─────────────────────────────────────────────
//
//  ADR-0023 D1 says watchable file types are DECLARED, not coded: a record
//  kind's `FileDiscoveryCapability` names the UTIs and extensions it can
//  ingest, and the Spotlight query for a watched folder is DERIVED from that
//  capability. This file is the other end of that derivation and deliberately
//  knows nothing about descriptors.
//
//  The watcher needs exactly two facts per discoverable kind — a set of UTIs
//  and a set of filename extensions — and it needs them as a plain value it can
//  hash, encode, diff and turn into a predicate. Handing the engine a
//  `RecordKindDescriptor` instead would drag the whole declaration graph
//  (statuses, collections, viewers, triage) into a file-system watcher that has
//  no use for any of it, and would make the watcher untestable without
//  registering a record kind.
//
//  ── The W2 seam (read this before wiring an app up) ─────────────────────────
//
//  W2 (imbib) is what maps a descriptor's capability onto this type. That
//  mapping is ONE function on the app/adopter side and it belongs there, not
//  here:
//
//      FileDiscoveryFilter(
//          id: descriptor.id.rawValue,
//          contentTypeIdentifiers: descriptor.fileDiscovery?.contentTypes ?? [],
//          filenameExtensions:     descriptor.fileDiscovery?.extensions ?? [])
//
//  `id` is an OPAQUE string to everything in this package: it is echoed back on
//  every `DiscoveredFile` so the host can route a hit to the kind that asked
//  for it, and it is never parsed. Hosts should spell it as the record kind's
//  raw value so the round trip is obvious, but nothing enforces that, and
//  nothing here will break if a host watches a folder for a filter that
//  corresponds to no kind at all (an ad-hoc "any spreadsheet" folder, say).
//
//  The one rule the seam does impose: `id` must be STABLE across launches,
//  because it is persisted inside `WatchedFolderRegistration`.
//

import Foundation
import UniformTypeIdentifiers

// MARK: - Filter

/// The file types one watched folder should surface, as data.
///
/// A folder is watched with an ARRAY of these (a manuscripts folder that also
/// holds `.bib` files is two filters, not one merged filter), because the
/// discovered file has to be attributable back to the filter that claimed it —
/// see `DiscoveredFile.filterID`.
///
/// Both halves are matched, not one or the other:
///
///   * `contentTypeIdentifiers` matches by UTI **conformance** (the tree), so
///     `public.plain-text` claims a `.md` file the way Spotlight's
///     `kMDItemContentTypeTree` does. This is the half that catches a file
///     whose extension is unusual but whose type is declared, and the half that
///     lets an app claim its own exported UTI (imbib's
///     `com.impress.bibtex-entry`) without restating its extension table.
///   * `filenameExtensions` matches by extension, case-insensitively. This is
///     the half that still works when a volume carries no type metadata at all
///     — which is exactly the degraded case D6 is about, so it must not be the
///     part that is optional.
///
/// An empty filter matches NOTHING. That is deliberate: a folder watched with
/// no filter is a configuration bug, and the honest rendering of it is zero
/// discovered files with a visible reason, never "every file on the disk".
public struct FileDiscoveryFilter: Hashable, Sendable, Codable, Identifiable {

    /// The host's name for what this filter finds. Opaque here; echoed onto
    /// every match. See the W2 seam note in the file header.
    public let id: String

    /// UTIs, matched by conformance. Order is preserved for predicate
    /// stability; duplicates are dropped.
    public let contentTypeIdentifiers: [String]

    /// Filename extensions, lowercased and dot-stripped by `init`. Order is
    /// preserved; duplicates are dropped.
    public let filenameExtensions: [String]

    public init(
        id: String,
        contentTypeIdentifiers: [String] = [],
        filenameExtensions: [String] = []
    ) {
        self.id = id
        self.contentTypeIdentifiers = Self.normalized(
            contentTypeIdentifiers, transform: { $0.trimmingCharacters(in: .whitespaces) })
        self.filenameExtensions = Self.normalized(
            filenameExtensions,
            transform: {
                var value = $0.trimmingCharacters(in: .whitespaces).lowercased()
                while value.hasPrefix(".") { value.removeFirst() }
                return value
            })
    }

    /// Lowercase / dedupe / drop-empties, order-preserving.
    private static func normalized(
        _ values: [String], transform: (String) -> String
    ) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in values {
            let value = transform(raw)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            out.append(value)
        }
        return out
    }

    /// A filter that can never match. The engines refuse to start on one rather
    /// than watching everything.
    public var isEmpty: Bool {
        contentTypeIdentifiers.isEmpty && filenameExtensions.isEmpty
    }

    // MARK: Matching

    /// Extension-only match. The half that survives a volume with no type
    /// metadata, and the half the manual walk leans on.
    public func matchesExtension(of url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return filenameExtensions.contains(ext)
    }

    /// UTI-conformance match. `type` conforms to (or IS) one of the declared
    /// identifiers — the `kMDItemContentTypeTree` semantics, locally.
    public func matches(contentType type: UTType) -> Bool {
        for identifier in contentTypeIdentifiers {
            guard let declared = UTType(identifier) else { continue }
            if type.conforms(to: declared) { return true }
        }
        return false
    }

    /// Whether this filter claims `url`, consulting the file system for its
    /// type only when the extension did not already answer.
    ///
    /// The extension check runs FIRST on purpose: it needs no I/O, and on a
    /// foreign volume the content-type resolution is the part that comes back
    /// empty.
    public func matches(_ url: URL) -> Bool {
        if matchesExtension(of: url) { return true }
        guard !contentTypeIdentifiers.isEmpty else { return false }
        guard let type = FileDiscoveryFilter.contentType(of: url) else { return false }
        return matches(contentType: type)
    }

    /// The resolved content type of a URL, or nil when the volume/file cannot
    /// answer. Falls back to the extension's declared type so a file that
    /// exists only as a path (a walk result on a volume with no metadata) is
    /// still classified.
    static func contentType(of url: URL) -> UTType? {
        if let resolved = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return resolved
        }
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }
}

// MARK: - Collections of filters

public extension Array where Element == FileDiscoveryFilter {

    /// Every filter that claims `url`, in declaration order. A `.bib` in a
    /// folder watched for both bibliographies and manuscripts legitimately
    /// matches once; a `.md` claimed by two kinds legitimately matches twice,
    /// and the host decides what to do about that.
    func matching(_ url: URL) -> [FileDiscoveryFilter] {
        filter { $0.matches(url) }
    }

    /// The first claiming filter — the common case, and what the walk uses to
    /// stamp `DiscoveredFile.filterID`.
    func firstMatching(_ url: URL) -> FileDiscoveryFilter? {
        first { $0.matches(url) }
    }

    /// True when at least one filter could ever match anything.
    var canMatchAnything: Bool { contains { !$0.isEmpty } }

    /// The union of every declared extension, lowercased — the cheap prefilter
    /// the bounded walk applies before paying for a content-type lookup.
    var allExtensions: Set<String> {
        Set(flatMap(\.filenameExtensions))
    }
}

// MARK: - Spotlight predicate derivation

/// The Spotlight predicate for a set of filters, as a STRING.
///
/// Deliberately a string and deliberately in the cross-platform file: an
/// `NSPredicate` cannot be compared for equality in a useful way, and the thing
/// most worth pinning in a test is exactly this text — "did the filter table
/// turn into the query we think it did". `swift test` on any platform can
/// assert it; only `SpotlightFolderDiscoveryEngine` (macOS) ever turns it into
/// a predicate object.
public enum SpotlightPredicateFormat {

    /// `nil` when nothing could match — the caller must NOT start a query, and
    /// must not render the folder as empty either (see `WatchedFolderState`).
    ///
    /// Shape:
    ///
    ///     ((kMDItemContentTypeTree == "com.impress.bibtex-entry")
    ///       || (kMDItemFSName LIKE[c] "*.bib") || (kMDItemFSName LIKE[c] "*.ris"))
    ///
    /// `kMDItemContentTypeTree` is the conformance form (`mdfind`'s own), so a
    /// declared UTI claims its subtypes without them being listed. `LIKE[c]` on
    /// `kMDItemFSName` is the extension half; it is kept even when a UTI covers
    /// the same files, because an unindexed-but-named file on a mixed volume is
    /// the case the extension clause exists for.
    public static func predicate(for filters: [FileDiscoveryFilter]) -> String? {
        var clauses: [String] = []
        var seenTypes: Set<String> = []
        var seenExtensions: Set<String> = []

        for filter in filters {
            for identifier in filter.contentTypeIdentifiers where seenTypes.insert(identifier).inserted {
                clauses.append("(kMDItemContentTypeTree == \"\(escape(identifier))\")")
            }
        }
        for filter in filters {
            for ext in filter.filenameExtensions where seenExtensions.insert(ext).inserted {
                clauses.append("(kMDItemFSName LIKE[c] \"*.\(escape(ext))\")")
            }
        }

        guard !clauses.isEmpty else { return nil }
        return "(" + clauses.joined(separator: " || ") + ")"
    }

    /// Quotes are the only character that can break out of the literal; a
    /// backslash escape is what `NSPredicate(format:)` expects.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
