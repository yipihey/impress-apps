//
//  LocalFilterService.swift
//  PublicationManagerCore
//

import Foundation
import ImpressFTUI

/// Searchable fields for field-qualified terms.
public enum SearchField: Equatable, Sendable {
    case title, author, abstract_, venue
}

/// A field-qualified text search term (e.g., `title:galaxy`).
public struct FieldTerm: Equatable, Sendable {
    public var field: SearchField
    public var term: String
}

/// Year filter (e.g., `year:2020`, `year:2020-2024`, `year:>2020`).
public enum YearFilter: Equatable, Sendable {
    case exact(Int)
    case range(Int, Int)
    case after(Int)
    case before(Int)

    func matches(_ year: Int?) -> Bool {
        guard let y = year else { return false }
        switch self {
        case .exact(let target): return y == target
        case .range(let lo, let hi): return y >= lo && y <= hi
        case .after(let target): return y > target
        case .before(let target): return y < target
        }
    }
}

/// Parsed local filter that can be applied to `[PublicationRowData]`.
///
/// Mirrors the Rust `ReferenceFilter` syntax:
/// ```
/// flag:red tags:methods/hydro unread "exact phrase" title:galaxy year:2020-2024 -excluded
/// ```
public struct LocalFilter: Equatable, Sendable {
    public var textTerms: [String] = []
    public var negatedTextTerms: [String] = []
    public var fieldTerms: [FieldTerm] = []
    public var yearFilter: YearFilter?
    public var flagQuery: FlagFilterQuery?
    public var tagQueries: [TagFilterQuery] = []
    public var readState: ReadStateFilter?

    public init(
        textTerms: [String] = [],
        negatedTextTerms: [String] = [],
        fieldTerms: [FieldTerm] = [],
        yearFilter: YearFilter? = nil,
        flagQuery: FlagFilterQuery? = nil,
        tagQueries: [TagFilterQuery] = [],
        readState: ReadStateFilter? = nil
    ) {
        self.textTerms = textTerms
        self.negatedTextTerms = negatedTextTerms
        self.fieldTerms = fieldTerms
        self.yearFilter = yearFilter
        self.flagQuery = flagQuery
        self.tagQueries = tagQueries
        self.readState = readState
    }

    public var isEmpty: Bool {
        textTerms.isEmpty && negatedTextTerms.isEmpty && fieldTerms.isEmpty
            && yearFilter == nil && flagQuery == nil && tagQueries.isEmpty && readState == nil
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
    case hasAny([String]) // tags:a|b — either matches (OR)
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
            // Flag queries (f: shortcut for flag:)
            if token.hasPrefix("f:") || token.hasPrefix("-f:") {
                let expanded = token.replacingOccurrences(of: "f:", with: "flag:")
                if let fq = parseFlagQuery(expanded) {
                    filter.flagQuery = fq
                    continue
                }
            }

            // Tag queries (t: shortcut for tags:)
            if token.hasPrefix("t:") || token.hasPrefix("-t:") {
                let expanded = token.replacingOccurrences(of: "t:", with: "tags:")
                if let tq = parseTagQuery(expanded) {
                    filter.tagQueries.append(tq)
                    continue
                }
            }

            // Flag queries (full prefix)
            if token.hasPrefix("flag:") || token.hasPrefix("-flag:") {
                if let fq = parseFlagQuery(token) {
                    filter.flagQuery = fq
                    continue
                }
            }

            // Tag queries (full prefix)
            if token.hasPrefix("tags:") || token.hasPrefix("-tags:") {
                if let tq = parseTagQuery(token) {
                    filter.tagQueries.append(tq)
                    continue
                }
            }

            // Field-qualified text terms
            if let ft = parseFieldTerm(token) {
                filter.fieldTerms.append(ft)
                continue
            }

            // Year filter
            if token.hasPrefix("year:") || token.hasPrefix("y:") {
                let value = token.hasPrefix("year:") ? String(token.dropFirst(5)) : String(token.dropFirst(2))
                if let yf = parseYearFilter(value) {
                    filter.yearFilter = yf
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

            // Negated text term: -word (but not -flag: or -tags:)
            if token.hasPrefix("-") && token.count > 1 {
                filter.negatedTextTerms.append(String(token.dropFirst()))
                continue
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
            let titleMatch = pub.title.localizedCaseInsensitiveContains(term)
            let authorMatch = pub.authorString.localizedCaseInsensitiveContains(term)
            let abstractMatch = pub.abstract?.localizedCaseInsensitiveContains(term) ?? false
            let venueMatch = (pub.venue ?? "").localizedCaseInsensitiveContains(term)
            if !titleMatch && !authorMatch && !abstractMatch && !venueMatch {
                return false
            }
        }

        // Negated text terms: none must match
        for term in filter.negatedTextTerms {
            let titleMatch = pub.title.localizedCaseInsensitiveContains(term)
            let authorMatch = pub.authorString.localizedCaseInsensitiveContains(term)
            let abstractMatch = pub.abstract?.localizedCaseInsensitiveContains(term) ?? false
            let venueMatch = (pub.venue ?? "").localizedCaseInsensitiveContains(term)
            if titleMatch || authorMatch || abstractMatch || venueMatch {
                return false
            }
        }

        // Field-qualified text terms: each must match its specific field
        for ft in filter.fieldTerms {
            let fieldValue: String
            switch ft.field {
            case .title: fieldValue = pub.title
            case .author: fieldValue = pub.authorString
            case .abstract_: fieldValue = pub.abstract ?? ""
            case .venue: fieldValue = pub.venue ?? ""
            }
            if !fieldValue.localizedCaseInsensitiveContains(ft.term) {
                return false
            }
        }

        // Year filter
        if let yf = filter.yearFilter {
            if !yf.matches(pub.year) {
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

            case .hasAny(let paths):
                let anyMatch = paths.contains { path in
                    let lower = path.lowercased()
                    return tags.contains { tag in
                        tag.path.lowercased().hasPrefix(lower)
                    }
                }
                guard anyMatch else { return false }
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

    /// Parse a field-qualified text term like `title:galaxy` or `au:smith`.
    private func parseFieldTerm(_ token: String) -> FieldTerm? {
        let prefixes: [(String, SearchField)] = [
            ("title:", .title), ("author:", .author), ("abstract:", .abstract_), ("venue:", .venue),
            ("ti:", .title), ("au:", .author), ("ab:", .abstract_), ("ve:", .venue),
            ("a:", .author), ("t:", .title), ("b:", .venue),
        ]
        for (prefix, field) in prefixes {
            if token.hasPrefix(prefix) {
                let rest = String(token.dropFirst(prefix.count))
                if !rest.isEmpty {
                    return FieldTerm(field: field, term: rest)
                }
            }
        }
        return nil
    }

    /// Parse a year filter value like `2020`, `2020-2024`, `>2020`, `<2020`.
    private func parseYearFilter(_ value: String) -> YearFilter? {
        // Range: 2020-2024
        if let dashIdx = value.firstIndex(of: "-"), dashIdx != value.startIndex {
            let start = String(value[value.startIndex..<dashIdx])
            let end = String(value[value.index(after: dashIdx)...])
            if let s = Int(start), let e = Int(end), s <= e {
                return .range(s, e)
            }
            return nil
        }
        // After: >=N or >N
        if value.hasPrefix(">="), let y = Int(value.dropFirst(2)) {
            return .range(y, 9999)
        }
        if value.hasPrefix(">"), let y = Int(value.dropFirst(1)) {
            return .after(y)
        }
        // Before: <=N or <N
        if value.hasPrefix("<="), let y = Int(value.dropFirst(2)) {
            return .range(0, y)
        }
        if value.hasPrefix("<"), let y = Int(value.dropFirst(1)) {
            return .before(y)
        }
        // Exact
        if let y = Int(value) {
            return .exact(y)
        }
        return nil
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

        // Check for OR: tags:a|b
        if value.contains("|") {
            let paths = value.components(separatedBy: "|").filter { !$0.isEmpty }
            if paths.count > 1 {
                return .hasAny(paths)
            }
        }

        return .has(value)
    }
}
