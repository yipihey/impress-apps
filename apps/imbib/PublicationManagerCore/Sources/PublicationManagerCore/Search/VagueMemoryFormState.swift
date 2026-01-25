//
//  VagueMemoryFormState.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation

// MARK: - Decade Enum

/// Represents a decade for vague memory search
public enum Decade: String, CaseIterable, Sendable, Identifiable {
    case d1950s = "1950s"
    case d1960s = "1960s"
    case d1970s = "1970s"
    case d1980s = "1980s"
    case d1990s = "1990s"
    case d2000s = "2000s"
    case d2010s = "2010s"
    case d2020s = "2020s"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    /// Returns year range with a 2-year overlap buffer on each end
    /// to catch papers that might be slightly misremembered
    public var yearRange: (start: Int, end: Int) {
        switch self {
        case .d1950s: return (1948, 1962)
        case .d1960s: return (1958, 1972)
        case .d1970s: return (1968, 1982)
        case .d1980s: return (1978, 1992)
        case .d1990s: return (1988, 2002)
        case .d2000s: return (1998, 2012)
        case .d2010s: return (2008, 2022)
        case .d2020s: return (2018, Calendar.current.component(.year, from: Date()) + 1)
        }
    }

    /// Returns the actual decade years without buffer (for display)
    public var exactYearRange: (start: Int, end: Int) {
        switch self {
        case .d1950s: return (1950, 1959)
        case .d1960s: return (1960, 1969)
        case .d1970s: return (1970, 1979)
        case .d1980s: return (1980, 1989)
        case .d1990s: return (1990, 1999)
        case .d2000s: return (2000, 2009)
        case .d2010s: return (2010, 2019)
        case .d2020s: return (2020, 2029)
        }
    }
}

// MARK: - Vague Memory Form State

/// Stores the state of the Vague Memory search form for persistence across navigation.
///
/// This form is designed to help astronomers find papers from imperfect memories,
/// inspired by Neal Dalal's wish: "if someone writes a version that can translate
/// my vague 'hmm was there some paper in the 1970s on something related?' into
/// an actual ADS reference, that will change all of our lives."
public struct VagueMemoryFormState {

    // MARK: - Properties

    /// Selected decade (optional - if nil, no year filtering)
    public var selectedDecade: Decade? = nil

    /// Custom year range start (overrides decade if set)
    public var customYearFrom: Int? = nil

    /// Custom year range end (overrides decade if set)
    public var customYearTo: Int? = nil

    /// The vague memory description (e.g., "something about galaxy rotation")
    public var vagueMemory: String = ""

    /// Optional author hint (e.g., "starts with R" or "something like Rubin")
    public var authorHint: String = ""

    /// Maximum results to return (higher default for vague queries)
    public var maxResults: Int = 100

    // MARK: - Initialization

    public init(
        selectedDecade: Decade? = nil,
        customYearFrom: Int? = nil,
        customYearTo: Int? = nil,
        vagueMemory: String = "",
        authorHint: String = "",
        maxResults: Int = 100
    ) {
        self.selectedDecade = selectedDecade
        self.customYearFrom = customYearFrom
        self.customYearTo = customYearTo
        self.vagueMemory = vagueMemory
        self.authorHint = authorHint
        self.maxResults = maxResults
    }

    // MARK: - Computed Properties

    /// Whether the form is empty (nothing to search)
    public var isEmpty: Bool {
        vagueMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        authorHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Get the effective year range (custom overrides decade)
    public var effectiveYearRange: (start: Int?, end: Int?)? {
        // Custom years take precedence
        if customYearFrom != nil || customYearTo != nil {
            return (customYearFrom, customYearTo)
        }
        // Fall back to decade
        if let decade = selectedDecade {
            return (decade.yearRange.start, decade.yearRange.end)
        }
        return nil
    }

    // MARK: - Methods

    /// Clear all form fields
    public mutating func clear() {
        selectedDecade = nil
        customYearFrom = nil
        customYearTo = nil
        vagueMemory = ""
        authorHint = ""
        maxResults = 100
    }
}
