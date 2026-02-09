//
//  LocalFilterService.swift
//  PublicationManagerCore
//

import Foundation
import ImpressFTUI

/// Parsed local filter that can be applied to `[PublicationRowData]`.
///
/// Mirrors the Rust `ReferenceFilter` syntax:
/// ```
/// flag:red tags:methods/hydro unread "exact phrase"
/// ```
public struct LocalFilter: Equatable, Sendable {
    public var textTerms: [String] = []
    public var flagQuery: FlagFilterQuery?
    public var tagQueries: [TagFilterQuery] = []
    public var readState: ReadStateFilter?

    public var isEmpty: Bool {
        textTerms.isEmpty && flagQuery == nil && tagQueries.isEmpty && readState == nil
    }
}

public enum FlagFilterQuery: Equatable, Sendable {
    /// Match flags by pattern: nil fields are wildcards.
    /// `flag:r-h` → pattern(red, dashed, half)
    /// `flag:r` → pattern(red, nil, nil) — any style/length
    /// `flag:*-*` → pattern(nil, dashed, nil) — any color with dashed
    case pattern(color: FlagColor?, style: FlagStyle?, length: FlagLength?)
    case hasAny       // flag:*
    case hasNone      // -flag:*
}

public enum TagFilterQuery: Equatable, Sendable {
    case has(String)      // tags:methods/hydro — match prefix
    case hasNot(String)   // -tags:methods
    case hasAll([String]) // tags:a+b — both required
}

public enum ReadStateFilter: Equatable, Sendable {
    case read
    case unread
}

/// Service for parsing and applying local filter expressions against publications.
@MainActor
public final class LocalFilterService {

    public static let shared = LocalFilterService()

    private init() {}

    /// Parse a filter expression string into a `LocalFilter`.
    public func parse(_ input: String) -> LocalFilter {
        var filter = LocalFilter()
        let tokens = tokenize(input)

        for token in tokens {
            // Flag queries
            if token.hasPrefix("flag:") || token.hasPrefix("-flag:") {
                if let fq = parseFlagQuery(token) {
                    filter.flagQuery = fq
                    continue
                }
            }

            // Tag queries
            if token.hasPrefix("tags:") || token.hasPrefix("-tags:") {
                if let tq = parseTagQuery(token) {
                    filter.tagQueries.append(tq)
                    continue
                }
            }

            // Read state
            switch token.lowercased() {
            case "unread":
                filter.readState = .unread
                continue
            case "read":
                filter.readState = .read
                continue
            default:
                break
            }

            // Everything else is a text search term
            filter.textTerms.append(token)
        }

        return filter
    }

    /// Apply a filter to a list of publications, returning only those that match.
    public func apply(_ filter: LocalFilter, to publications: [PublicationRowData]) -> [PublicationRowData] {
        guard !filter.isEmpty else { return publications }

        return publications.filter { pub in
            matches(pub, filter: filter)
        }
    }

    // MARK: - Private

    private func matches(_ pub: PublicationRowData, filter: LocalFilter) -> Bool {
        // Text terms: all must match (AND) against title, authors, abstract, venue
        for term in filter.textTerms {
            let lower = term.lowercased()
            let titleMatch = pub.title.localizedCaseInsensitiveContains(lower)
            let authorMatch = pub.authorString.localizedCaseInsensitiveContains(lower)
            let abstractMatch = pub.abstract?.localizedCaseInsensitiveContains(lower) ?? false
            let venueMatch = (pub.venue ?? "").localizedCaseInsensitiveContains(lower)
            if !titleMatch && !authorMatch && !abstractMatch && !venueMatch {
                return false
            }
        }

        // Flag query
        if let fq = filter.flagQuery {
            switch fq {
            case .pattern(let color, let style, let length):
                // Must have a flag to match any pattern
                guard let f = pub.flag else { return false }
                if let c = color { guard f.color == c else { return false } }
                if let s = style { guard f.style == s else { return false } }
                if let l = length { guard f.length == l else { return false } }
            case .hasAny:
                guard pub.flag != nil else { return false }
            case .hasNone:
                guard pub.flag == nil else { return false }
            }
        }

        // Tag queries: all must match (AND)
        for tq in filter.tagQueries {
            let tags = pub.tagDisplays
            switch tq {
            case .has(let path):
                let lower = path.lowercased()
                let found = tags.contains { tag in
                    tag.path.lowercased().hasPrefix(lower)
                }
                guard found else { return false }

            case .hasNot(let path):
                let lower = path.lowercased()
                let found = tags.contains { tag in
                    tag.path.lowercased().hasPrefix(lower)
                }
                guard !found else { return false }

            case .hasAll(let paths):
                for path in paths {
                    let lower = path.lowercased()
                    let found = tags.contains { tag in
                        tag.path.lowercased().hasPrefix(lower)
                    }
                    guard found else { return false }
                }
            }
        }

        // Read state
        if let rs = filter.readState {
            switch rs {
            case .unread: guard !pub.isRead else { return false }
            case .read: guard pub.isRead else { return false }
            }
        }

        return true
    }

    /// Tokenize filter text, respecting quoted strings.
    private func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for c in input {
            switch c {
            case "\"":
                inQuotes.toggle()
                if !inQuotes && !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            case " " where !inQuotes:
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default:
                current.append(c)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Parse `flag:` shorthand using the same grammar as flag input:
    ///
    /// - `flag:*` → any flagged, `-flag:*` → no flag
    /// - `flag:r` → red (any style/length)
    /// - `flag:r-h` → red, dashed, half
    /// - `flag:*-*` → any color, dashed, any length
    /// - `flag:red` → red (full name also accepted)
    ///
    /// Positions: `color[style][length]`, `*` = wildcard, missing = wildcard.
    private func parseFlagQuery(_ token: String) -> FlagFilterQuery? {
        if token.hasPrefix("-flag:") {
            let value = String(token.dropFirst(6))
            if value == "*" { return .hasNone }
            return nil
        }

        let value = String(token.dropFirst(5)) // "flag:"
        guard !value.isEmpty else { return nil }

        // Single * means "any flag"
        if value == "*" { return .hasAny }

        // Try full color name first (e.g. "flag:red", "flag:amber")
        if let color = FlagColor(rawValue: value.lowercased()) {
            return .pattern(color: color, style: nil, length: nil)
        }

        // Parse shorthand: up to 3 positional characters
        let chars = Array(value.lowercased())

        // Position 1: color (r/a/b/g or * for any)
        let color: FlagColor?
        if chars[0] == "*" {
            color = nil
        } else if let c = FlagColor.allCases.first(where: { $0.shortcut == chars[0] }) {
            color = c
        } else {
            return nil // invalid color character
        }

        guard chars.count > 1 else {
            return .pattern(color: color, style: nil, length: nil)
        }

        // Position 2: style (s/-/. or * for any)
        let style: FlagStyle?
        switch chars[1] {
        case "*": style = nil
        case "-": style = .dashed
        case ".": style = .dotted
        case "s": style = .solid
        default:
            // Could be a length character (e.g. "rh" = red, any style, half)
            if let l = FlagLength.allCases.first(where: { $0.shortcut == chars[1] }) {
                return .pattern(color: color, style: nil, length: l)
            }
            return nil
        }

        guard chars.count > 2 else {
            return .pattern(color: color, style: style, length: nil)
        }

        // Position 3: length (f/h/q or * for any)
        let length: FlagLength?
        switch chars[2] {
        case "*": length = nil
        default:
            length = FlagLength.allCases.first(where: { $0.shortcut == chars[2] })
        }

        return .pattern(color: color, style: style, length: length)
    }

    private func parseTagQuery(_ token: String) -> TagFilterQuery? {
        if token.hasPrefix("-tags:") {
            let value = String(token.dropFirst(6))
            guard !value.isEmpty else { return nil }
            return .hasNot(value)
        }

        let value = String(token.dropFirst(5)) // "tags:"
        guard !value.isEmpty else { return nil }

        // Check for AND: tags:a+b
        if value.contains("+") {
            let paths = value.components(separatedBy: "+").filter { !$0.isEmpty }
            if paths.count > 1 {
                return .hasAll(paths)
            }
        }

        return .has(value)
    }
}
