//
//  SearchContext.swift
//  PublicationManagerCore
//
//  Context-aware search scope for iOS global search.
//

import SwiftUI
import Foundation

// MARK: - Search Context

/// Defines the scope for context-aware search.
///
/// The search context determines what gets searched when the user triggers
/// the global search palette. The context is derived from the current view state.
public enum SearchContext: Equatable, Sendable {
    /// Search all publications across all libraries
    case global

    /// Search publications in a specific library
    case library(UUID, String)

    /// Search publications in a specific collection
    case collection(UUID, String)

    /// Search publications matching a smart search
    case smartSearch(UUID, String)

    /// Search within a single publication (title, abstract, notes)
    case publication(UUID, String)

    /// Search within the PDF of a publication
    case pdf(UUID, String)

    // MARK: - Display Properties

    /// Human-readable name for the current context
    public var displayName: String {
        switch self {
        case .global:
            return "All Papers"
        case .library(_, let name):
            return name
        case .collection(_, let name):
            return name
        case .smartSearch(_, let name):
            return name
        case .publication(_, let title):
            return title.isEmpty ? "This Paper" : title
        case .pdf(_, let title):
            return title.isEmpty ? "PDF" : title
        }
    }

    /// Description of the search scope (e.g., "in Math Library")
    public var scopeDescription: String {
        switch self {
        case .global:
            return "all papers"
        case .library(_, let name):
            return "in \(name)"
        case .collection(_, let name):
            return "in \(name)"
        case .smartSearch(_, let name):
            return "in \(name)"
        case .publication(_, _):
            return "this paper"
        case .pdf(_, _):
            return "PDF"
        }
    }

    /// Icon name for the context
    public var iconName: String {
        switch self {
        case .global:
            return "magnifyingglass"
        case .library:
            return "books.vertical"
        case .collection:
            return "folder"
        case .smartSearch:
            return "sparkle.magnifyingglass"
        case .publication:
            return "doc.text"
        case .pdf:
            return "doc.richtext"
        }
    }

    /// Whether this context represents a global (unscoped) search
    public var isGlobal: Bool {
        if case .global = self {
            return true
        }
        return false
    }

    /// Whether this context represents a PDF search (requires special handling)
    public var isPDFSearch: Bool {
        if case .pdf = self {
            return true
        }
        return false
    }

    /// The publication ID if this context is for a single publication or PDF
    public var publicationID: UUID? {
        switch self {
        case .publication(let id, _), .pdf(let id, _):
            return id
        default:
            return nil
        }
    }

    /// The library ID if this context is for a library
    public var libraryID: UUID? {
        if case .library(let id, _) = self {
            return id
        }
        return nil
    }

    /// The collection ID if this context is for a collection
    public var collectionID: UUID? {
        if case .collection(let id, _) = self {
            return id
        }
        return nil
    }

    /// The smart search ID if this context is for a smart search
    public var smartSearchID: UUID? {
        if case .smartSearch(let id, _) = self {
            return id
        }
        return nil
    }
}

// MARK: - Environment Key

/// Environment key for passing search context through the view hierarchy
public struct SearchContextKey: EnvironmentKey {
    public static let defaultValue: SearchContext = .global
}

public extension EnvironmentValues {
    /// The current search context
    var searchContext: SearchContext {
        get { self[SearchContextKey.self] }
        set { self[SearchContextKey.self] = newValue }
    }
}
