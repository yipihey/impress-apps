import Foundation
import ImprintCore
import ImpressLogging
import OSLog
import SwiftUI

//
//  TemplateService.swift
//
//  UI-facing view of the manuscript template registry.
//
//  The registry itself — the 25 built-in journal/conference templates, their
//  metadata, search, category filtering, and the starter-document scaffolder —
//  lives in Rust (`crates/imprint-core/src/templates/`) and is reached through
//  `ImprintCore.TemplateCatalog`. This service only re-shapes those values into
//  the SwiftUI-friendly types the template browser and pickers already use
//  (notably `TemplateCategory.all`, which has no Rust equivalent).
//
//  It deliberately holds no template *content*. Earlier revisions of this file
//  carried mock metadata and hand-written Typst source in Swift; those diverged
//  from the real templates and are gone.
//

/// Template category for filtering. Mirrors the Rust `TemplateCategory` plus an
/// `.all` pseudo-case used by the browser sidebar.
public enum TemplateCategory: String, CaseIterable, Identifiable {
    case all = "all"
    case journal = "journal"
    case conference = "conference"
    case thesis = "thesis"
    case report = "report"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All Templates"
        case .journal: return "Journals"
        case .conference: return "Conferences"
        case .thesis: return "Thesis"
        case .report: return "Reports"
        case .custom: return "Custom"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "doc.text"
        case .journal: return "newspaper"
        case .conference: return "person.3"
        case .thesis: return "graduationcap"
        case .report: return "doc.richtext"
        case .custom: return "folder"
        }
    }

    /// Bridge from the FFI enum.
    init(_ ffi: FfiTemplateCategory) {
        switch ffi {
        case .journal: self = .journal
        case .conference: self = .conference
        case .thesis: self = .thesis
        case .report: self = .report
        case .custom: self = .custom
        }
    }

    /// Bridge to the FFI enum. `.all` has no counterpart.
    var ffiCategory: FfiTemplateCategory? {
        switch self {
        case .all: return nil
        case .journal: return .journal
        case .conference: return .conference
        case .thesis: return .thesis
        case .report: return .report
        case .custom: return .custom
        }
    }
}

/// Journal-specific information
public struct JournalInfo: Identifiable {
    public let id = UUID()
    public let publisher: String
    public let url: String?
    public let latexClass: String?
    public let issn: String?
}

/// Page layout defaults
public struct PageDefaults {
    public let size: String
    public let marginTop: Double
    public let marginRight: Double
    public let marginBottom: Double
    public let marginLeft: Double
    public let columns: Int
    public let fontSize: Double

    public var marginsTuple: (Double, Double, Double, Double) {
        (marginTop, marginRight, marginBottom, marginLeft)
    }
}

/// Template metadata
public struct TemplateMetadata: Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let author: String
    public let license: String
    public let category: TemplateCategory
    public let tags: [String]
    public let journal: JournalInfo?
    public let pageDefaults: PageDefaults
    public let isBuiltin: Bool

    public var displayCategory: String {
        if let journal = journal {
            return journal.publisher
        }
        return category.displayName
    }

    init(_ ffi: FfiTemplateMetadata) {
        self.id = ffi.id
        self.name = ffi.name
        self.version = ffi.version
        self.description = ffi.description
        self.author = ffi.author
        self.license = ffi.license
        self.category = TemplateCategory(ffi.category)
        self.tags = ffi.tags
        self.journal = ffi.journal.map {
            JournalInfo(
                publisher: $0.publisher, url: $0.url, latexClass: $0.latexClass, issn: $0.issn)
        }
        self.pageDefaults = PageDefaults(
            size: ffi.pageDefaults.size,
            marginTop: ffi.pageDefaults.marginTop,
            marginRight: ffi.pageDefaults.marginRight,
            marginBottom: ffi.pageDefaults.marginBottom,
            marginLeft: ffi.pageDefaults.marginLeft,
            columns: Int(ffi.pageDefaults.columns),
            fontSize: ffi.pageDefaults.fontSize)
        self.isBuiltin = ffi.isBuiltin
    }
}

/// Full template with source
public struct Template: Identifiable {
    public let metadata: TemplateMetadata
    public let typstSource: String
    public let latexPreamble: String?

    public var id: String { metadata.id }
    public var name: String { metadata.name }
}

/// Service for managing document templates.
@MainActor @Observable
public final class TemplateService {
    public static let shared = TemplateService()

    public private(set) var templates: [TemplateMetadata] = []
    public private(set) var isLoading = false
    public private(set) var error: String?

    private init() {
        loadTemplates()
    }

    /// Load all available templates from the Rust registry.
    ///
    /// Synchronous and cheap — the registry is compiled-in data, there is no
    /// I/O and no background task, so this is safe to call during launch.
    public func loadTemplates() {
        isLoading = true
        error = nil

        let loaded = TemplateCatalog.all().map(TemplateMetadata.init)
        templates = loaded

        if loaded.isEmpty {
            error = "No templates available"
            Logger.documents.errorCapture(
                "Template registry returned zero templates", category: "templates")
        } else {
            Logger.documents.infoCapture(
                "Loaded \(loaded.count) manuscript templates: "
                    + loaded.prefix(6).map(\.id).joined(separator: ", ")
                    + (loaded.count > 6 ? ", …" : ""),
                category: "templates")
        }

        isLoading = false
    }

    /// Get a specific template by ID, including its Typst style-definition source.
    public func getTemplate(id: String) -> Template? {
        guard let ffi = ImprintCore.getTemplate(id: id) else {
            Logger.documents.warningCapture(
                "getTemplate('\(id)') — no such template", category: "templates")
            return nil
        }
        return Template(
            metadata: TemplateMetadata(ffi.metadata),
            typstSource: ffi.typstSource,
            latexPreamble: ffi.latexPreamble)
    }

    /// Build a complete, compilable starter document from a template.
    ///
    /// This is what "new manuscript from template X" must store — the raw
    /// `typstSource` is a style definition only and renders a blank page.
    /// Returns nil if the id is unknown.
    public func starterDocument(
        templateID: String,
        title: String,
        authors: [String] = [],
        affiliations: [String] = [],
        abstract: String? = nil,
        keywords: [String] = [],
        includeSections: Bool = true
    ) -> String? {
        TemplateCatalog.starterDocument(
            templateID: templateID,
            title: title,
            authors: authors,
            affiliations: affiliations,
            abstract: abstract,
            keywords: keywords,
            includeSections: includeSections)
    }

    /// Search templates by query (name, description, tags).
    public func search(query: String) -> [TemplateMetadata] {
        guard !query.isEmpty else { return templates }
        return TemplateCatalog.search(query).map(TemplateMetadata.init)
    }

    /// Filter templates by category.
    public func templates(for category: TemplateCategory) -> [TemplateMetadata] {
        guard let ffiCategory = category.ffiCategory else { return templates }
        return TemplateCatalog.inCategory(ffiCategory).map(TemplateMetadata.init)
    }

    /// Get templates grouped by category, for sectioned pickers and browsers.
    public func groupedTemplates() -> [(category: TemplateCategory, templates: [TemplateMetadata])] {
        var grouped: [TemplateCategory: [TemplateMetadata]] = [:]

        for template in templates {
            grouped[template.category, default: []].append(template)
        }

        return TemplateCategory.allCases.compactMap { category in
            guard category != .all, let templates = grouped[category], !templates.isEmpty else {
                return nil
            }
            return (category: category, templates: templates.sorted { $0.name < $1.name })
        }
    }
}
