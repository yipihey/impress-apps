//
//  RISExporter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - RIS Exporter

/// Exports RIS entries to RIS format string.
public final class RISExporter: Sendable {

    private static let logger = Logger(subsystem: "PublicationManagerCore", category: "RISExporter")

    public init() {}

    // MARK: - Public API

    /// Export multiple RIS entries to a single RIS string.
    /// - Parameter entries: Array of RIS entries to export
    /// - Returns: RIS formatted string
    public func export(_ entries: [RISEntry]) -> String {
        entries.map { export($0) }.joined(separator: "\n\n")
    }

    /// Export a single RIS entry to RIS format.
    /// - Parameter entry: RIS entry to export
    /// - Returns: RIS formatted string
    public func export(_ entry: RISEntry) -> String {
        var lines: [String] = []

        // TY must be first
        lines.append(formatTag(.TY, value: entry.type.rawValue))

        // Add all tags in order
        for tagValue in entry.tags {
            // Skip TY (already added) and ER (will add at end)
            if tagValue.tag == .TY || tagValue.tag == .ER {
                continue
            }
            lines.append(formatTag(tagValue.tag, value: tagValue.value))
        }

        // ER must be last
        lines.append(formatTag(.ER, value: ""))

        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    /// Format a single RIS tag line.
    /// - Parameters:
    ///   - tag: The RIS tag
    ///   - value: The tag value
    /// - Returns: Formatted tag line (e.g., "AU  - Smith, John")
    private func formatTag(_ tag: RISTag, value: String) -> String {
        "\(tag.rawValue)  - \(value)"
    }

    // MARK: - Builder API

    /// Create a RIS entry builder for constructing entries programmatically.
    public static func builder(type: RISReferenceType) -> RISEntryBuilder {
        RISEntryBuilder(type: type)
    }
}

// MARK: - RIS Entry Builder

/// Builder for constructing RIS entries programmatically.
public final class RISEntryBuilder {

    private var type: RISReferenceType
    private var tags: [RISTagValue] = []

    public init(type: RISReferenceType) {
        self.type = type
    }

    /// Add an author.
    @discardableResult
    public func author(_ name: String) -> Self {
        tags.append(RISTagValue(tag: .AU, value: name))
        return self
    }

    /// Add multiple authors.
    @discardableResult
    public func authors(_ names: [String]) -> Self {
        for name in names {
            tags.append(RISTagValue(tag: .AU, value: name))
        }
        return self
    }

    /// Set the title.
    @discardableResult
    public func title(_ title: String) -> Self {
        tags.append(RISTagValue(tag: .TI, value: title))
        return self
    }

    /// Set the year.
    @discardableResult
    public func year(_ year: Int) -> Self {
        tags.append(RISTagValue(tag: .PY, value: String(year)))
        return self
    }

    /// Set the year with full date.
    @discardableResult
    public func date(year: Int, month: Int? = nil, day: Int? = nil) -> Self {
        var dateString = String(year)
        if let month = month {
            dateString += "/\(String(format: "%02d", month))"
            if let day = day {
                dateString += "/\(String(format: "%02d", day))"
            }
        }
        tags.append(RISTagValue(tag: .PY, value: dateString))
        return self
    }

    /// Set the journal name.
    @discardableResult
    public func journal(_ name: String) -> Self {
        tags.append(RISTagValue(tag: .JF, value: name))
        return self
    }

    /// Set the secondary title (journal for articles, book title for chapters).
    @discardableResult
    public func secondaryTitle(_ title: String) -> Self {
        tags.append(RISTagValue(tag: .T2, value: title))
        return self
    }

    /// Set the volume.
    @discardableResult
    public func volume(_ volume: String) -> Self {
        tags.append(RISTagValue(tag: .VL, value: volume))
        return self
    }

    /// Set the issue number.
    @discardableResult
    public func issue(_ issue: String) -> Self {
        tags.append(RISTagValue(tag: .IS, value: issue))
        return self
    }

    /// Set the start page.
    @discardableResult
    public func startPage(_ page: String) -> Self {
        tags.append(RISTagValue(tag: .SP, value: page))
        return self
    }

    /// Set the end page.
    @discardableResult
    public func endPage(_ page: String) -> Self {
        tags.append(RISTagValue(tag: .EP, value: page))
        return self
    }

    /// Set start and end pages.
    @discardableResult
    public func pages(start: String, end: String) -> Self {
        tags.append(RISTagValue(tag: .SP, value: start))
        tags.append(RISTagValue(tag: .EP, value: end))
        return self
    }

    /// Set pages from a range string like "100-115".
    @discardableResult
    public func pages(_ range: String) -> Self {
        let parts = range.components(separatedBy: CharacterSet(charactersIn: "-–—"))
        if parts.count >= 2 {
            tags.append(RISTagValue(tag: .SP, value: parts[0].trimmingCharacters(in: .whitespaces)))
            tags.append(RISTagValue(tag: .EP, value: parts[1].trimmingCharacters(in: .whitespaces)))
        } else if parts.count == 1 {
            tags.append(RISTagValue(tag: .SP, value: parts[0].trimmingCharacters(in: .whitespaces)))
        }
        return self
    }

    /// Set the DOI.
    @discardableResult
    public func doi(_ doi: String) -> Self {
        tags.append(RISTagValue(tag: .DO, value: doi))
        return self
    }

    /// Set the abstract.
    @discardableResult
    public func abstract(_ abstract: String) -> Self {
        tags.append(RISTagValue(tag: .AB, value: abstract))
        return self
    }

    /// Add a keyword.
    @discardableResult
    public func keyword(_ keyword: String) -> Self {
        tags.append(RISTagValue(tag: .KW, value: keyword))
        return self
    }

    /// Add multiple keywords.
    @discardableResult
    public func keywords(_ keywords: [String]) -> Self {
        for keyword in keywords {
            tags.append(RISTagValue(tag: .KW, value: keyword))
        }
        return self
    }

    /// Add a URL.
    @discardableResult
    public func url(_ url: String) -> Self {
        tags.append(RISTagValue(tag: .UR, value: url))
        return self
    }

    /// Set the publisher.
    @discardableResult
    public func publisher(_ publisher: String) -> Self {
        tags.append(RISTagValue(tag: .PB, value: publisher))
        return self
    }

    /// Set the place published.
    @discardableResult
    public func place(_ place: String) -> Self {
        tags.append(RISTagValue(tag: .CY, value: place))
        return self
    }

    /// Set the ISSN or ISBN.
    @discardableResult
    public func issn(_ issn: String) -> Self {
        tags.append(RISTagValue(tag: .SN, value: issn))
        return self
    }

    /// Set the reference ID.
    @discardableResult
    public func referenceID(_ id: String) -> Self {
        tags.append(RISTagValue(tag: .ID, value: id))
        return self
    }

    /// Add a note.
    @discardableResult
    public func note(_ note: String) -> Self {
        tags.append(RISTagValue(tag: .N1, value: note))
        return self
    }

    /// Add an editor.
    @discardableResult
    public func editor(_ name: String) -> Self {
        tags.append(RISTagValue(tag: .A2, value: name))
        return self
    }

    /// Add multiple editors.
    @discardableResult
    public func editors(_ names: [String]) -> Self {
        for name in names {
            tags.append(RISTagValue(tag: .A2, value: name))
        }
        return self
    }

    /// Set the edition.
    @discardableResult
    public func edition(_ edition: String) -> Self {
        tags.append(RISTagValue(tag: .ET, value: edition))
        return self
    }

    /// Set the language.
    @discardableResult
    public func language(_ language: String) -> Self {
        tags.append(RISTagValue(tag: .LA, value: language))
        return self
    }

    /// Add a custom tag.
    @discardableResult
    public func tag(_ tag: RISTag, value: String) -> Self {
        tags.append(RISTagValue(tag: tag, value: value))
        return self
    }

    /// Build the RIS entry.
    public func build() -> RISEntry {
        RISEntry(type: type, tags: tags)
    }
}

// MARK: - Convenience Extensions

extension RISEntry {
    /// Export this entry to RIS format.
    public func toRIS() -> String {
        RISExporter().export(self)
    }
}

extension Array where Element == RISEntry {
    /// Export all entries to RIS format.
    public func toRIS() -> String {
        RISExporter().export(self)
    }
}
