//
//  TemplateCatalog.swift
//  ImprintCore
//
//  Thin Swift façade over the Rust template registry in `imprint-core`.
//
//  All template logic — the registry, search, category filtering, and the
//  starter-document scaffolder — lives in Rust (`crates/imprint-core/src/
//  templates/`). This file does exactly two things:
//
//    1. forwards to the generated UniFFI free functions, and
//    2. flattens `FfiTemplateMetadata` into JSON-ready dictionaries so the HTTP
//       routers in *both* imprint (port 23121) and imbib (port 23120) can serve
//       an identical payload without either app re-deriving the shape.
//
//  Nothing here decides what a template *is*. If you find yourself adding
//  behaviour to this file, it probably belongs in the Rust crate.
//

import Foundation
import ImpressLogging
import OSLog

nonisolated(unsafe) private let templateLogger = Logger(
    subsystem: "com.impress.imprint", category: "templates")

/// Catalog of journal/conference manuscript templates.
///
/// Stateless: every call goes straight to the Rust registry, which builds
/// itself from compiled-in data. Safe to call from any isolation domain and
/// cheap enough to call per request — there is no cache to invalidate and no
/// background work, so this is safe during the app-launch grace window.
public enum TemplateCatalog {

    // MARK: - Serialization

    /// JSON-ready dictionary for a template's metadata.
    public static func dictionary(for metadata: FfiTemplateMetadata) -> [String: Any] {
        var dict: [String: Any] = [
            "id": metadata.id,
            "name": metadata.name,
            "version": metadata.version,
            "description": metadata.description,
            "author": metadata.author,
            "license": metadata.license,
            "category": categoryName(metadata.category),
            "tags": metadata.tags,
            "is_builtin": metadata.isBuiltin,
            "page_defaults": [
                "size": metadata.pageDefaults.size,
                "columns": Int(metadata.pageDefaults.columns),
                "font_size": metadata.pageDefaults.fontSize,
                "margin_top": metadata.pageDefaults.marginTop,
                "margin_right": metadata.pageDefaults.marginRight,
                "margin_bottom": metadata.pageDefaults.marginBottom,
                "margin_left": metadata.pageDefaults.marginLeft,
            ],
        ]
        if let journal = metadata.journal {
            var journalDict: [String: Any] = ["publisher": journal.publisher]
            journalDict["url"] = journal.url
            journalDict["latex_class"] = journal.latexClass
            journalDict["issn"] = journal.issn
            dict["journal"] = journalDict
        }
        return dict
    }

    /// Stable lowercase wire name for a category. These strings are part of the
    /// HTTP and MCP contract — `?category=journal` matches on them.
    public static func categoryName(_ category: FfiTemplateCategory) -> String {
        switch category {
        case .journal: return "journal"
        case .conference: return "conference"
        case .thesis: return "thesis"
        case .report: return "report"
        case .custom: return "custom"
        }
    }

    /// Parse a wire category name. Returns nil for unknown values so callers
    /// can reject with a 400 rather than silently returning everything.
    public static func category(named name: String) -> FfiTemplateCategory? {
        switch name.lowercased() {
        case "journal": return .journal
        case "conference": return .conference
        case "thesis": return .thesis
        case "report": return .report
        case "custom": return .custom
        default: return nil
        }
    }

    // MARK: - Queries

    /// All templates, sorted by category then name for a stable listing order.
    public static func all() -> [FfiTemplateMetadata] {
        sorted(listTemplates())
    }

    /// Templates in one category.
    public static func inCategory(_ category: FfiTemplateCategory) -> [FfiTemplateMetadata] {
        sorted(listTemplatesByCategory(category: category))
    }

    /// Free-text search across name, description, and tags.
    public static func search(_ query: String) -> [FfiTemplateMetadata] {
        sorted(searchTemplates(query: query))
    }

    /// Metadata for one template id, or nil if unknown.
    public static func metadata(id: String) -> FfiTemplateMetadata? {
        getTemplate(id: id)?.metadata
    }

    /// Raw Typst style-definition source for one template.
    ///
    /// Note this is a *style definition only* — compiling it renders a blank
    /// page. To create a new manuscript use ``starterDocument(templateID:...)``.
    public static func source(id: String) -> String? {
        getTemplateSource(id: id)
    }

    /// Number of templates in the registry.
    public static func count() -> Int {
        Int(templateCount())
    }

    // MARK: - Document creation

    /// Build a complete, compilable starter document from a template.
    ///
    /// Returns nil if `templateID` is unknown. The returned Typst source is the
    /// template's style definition plus a `#show:` invocation seeded with the
    /// supplied values plus (optionally) a section skeleton — i.e. something
    /// that actually renders, unlike the raw template source.
    public static func starterDocument(
        templateID: String,
        title: String,
        authors: [String] = [],
        affiliations: [String] = [],
        abstract: String? = nil,
        keywords: [String] = [],
        includeSections: Bool = true
    ) -> String? {
        let options = FfiScaffoldOptions(
            title: title,
            authors: authors,
            affiliations: affiliations,
            abstractText: abstract,
            keywords: keywords,
            includeSections: includeSections
        )
        guard let source = newDocumentFromTemplate(templateId: templateID, options: options) else {
            templateLogger.warningCapture(
                "Template scaffold requested for unknown template '\(templateID)'",
                category: "templates")
            return nil
        }
        templateLogger.infoCapture(
            "Scaffolded '\(title)' from template '\(templateID)' (\(source.count) chars, "
                + "\(authors.count) authors, sections=\(includeSections))",
            category: "templates")
        return source
    }

    // MARK: - Private

    private static func sorted(_ templates: [FfiTemplateMetadata]) -> [FfiTemplateMetadata] {
        templates.sorted {
            let lhs = categoryName($0.category)
            let rhs = categoryName($1.category)
            return lhs == rhs ? $0.name < $1.name : lhs < rhs
        }
    }
}
