import Foundation
import SwiftUI

// Note: FFI integration with ImprintRustCore will be enabled after regenerating bindings
// For now, we use mock data to allow the UI to be developed and tested

/// Template category for filtering
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
}

/// Full template with source
public struct Template: Identifiable {
    public let metadata: TemplateMetadata
    public let typstSource: String
    public let latexPreamble: String?

    public var id: String { metadata.id }
    public var name: String { metadata.name }
}

/// Service for managing document templates
@MainActor @Observable
public final class TemplateService {
    public static let shared = TemplateService()

    public private(set) var templates: [TemplateMetadata] = []
    public private(set) var isLoading = false
    public private(set) var error: String?

    private init() {
        loadTemplates()
    }

    /// Load all available templates
    public func loadTemplates() {
        isLoading = true
        error = nil

        // TODO: Load from Rust FFI when bindings are regenerated
        // For now, use mock templates for UI development
        templates = mockTemplates()

        isLoading = false
    }

    /// Get a specific template by ID
    public func getTemplate(id: String) -> Template? {
        // TODO: Load from Rust FFI when bindings are regenerated
        guard let metadata = templates.first(where: { $0.id == id }) else { return nil }
        return Template(metadata: metadata, typstSource: mockTypstSource(for: id), latexPreamble: nil)
    }

    /// Search templates by query
    public func search(query: String) -> [TemplateMetadata] {
        guard !query.isEmpty else { return templates }

        let lowercasedQuery = query.lowercased()
        return templates.filter { template in
            template.name.lowercased().contains(lowercasedQuery) ||
            template.description.lowercased().contains(lowercasedQuery) ||
            template.tags.contains { $0.lowercased().contains(lowercasedQuery) }
        }
    }

    /// Filter templates by category
    public func templates(for category: TemplateCategory) -> [TemplateMetadata] {
        guard category != .all else { return templates }
        return templates.filter { $0.category == category }
    }

    /// Get templates grouped by category
    public func groupedTemplates() -> [(category: TemplateCategory, templates: [TemplateMetadata])] {
        var grouped: [TemplateCategory: [TemplateMetadata]] = [:]

        for template in templates {
            grouped[template.category, default: []].append(template)
        }

        return TemplateCategory.allCases.compactMap { category in
            guard category != .all, let templates = grouped[category], !templates.isEmpty else { return nil }
            return (category: category, templates: templates.sorted { $0.name < $1.name })
        }
    }

    // MARK: - Mock Data for Development
    // TODO: Replace with FFI integration when bindings are regenerated

    private func mockTemplates() -> [TemplateMetadata] {
        [
            TemplateMetadata(
                id: "generic",
                name: "Generic Article",
                version: "1.0.0",
                description: "A clean, minimal template for academic writing.",
                author: "imprint",
                license: "MIT",
                category: .custom,
                tags: ["general", "starter"],
                journal: nil,
                pageDefaults: PageDefaults(size: "a4", marginTop: 25, marginRight: 25, marginBottom: 25, marginLeft: 25, columns: 1, fontSize: 11),
                isBuiltin: true
            ),
            TemplateMetadata(
                id: "mnras",
                name: "Monthly Notices of the Royal Astronomical Society",
                version: "1.0.0",
                description: "Template for MNRAS submissions.",
                author: "imprint community",
                license: "MIT",
                category: .journal,
                tags: ["astronomy", "astrophysics"],
                journal: JournalInfo(publisher: "Oxford University Press", url: "https://academic.oup.com/mnras", latexClass: "mnras", issn: "0035-8711"),
                pageDefaults: PageDefaults(size: "a4", marginTop: 20, marginRight: 20, marginBottom: 20, marginLeft: 20, columns: 2, fontSize: 9),
                isBuiltin: true
            ),
            TemplateMetadata(
                id: "nature",
                name: "Nature",
                version: "1.0.0",
                description: "Template for Nature journal submissions.",
                author: "imprint community",
                license: "MIT",
                category: .journal,
                tags: ["multidisciplinary", "science"],
                journal: JournalInfo(publisher: "Springer Nature", url: "https://www.nature.com", latexClass: nil, issn: "0028-0836"),
                pageDefaults: PageDefaults(size: "a4", marginTop: 25, marginRight: 25, marginBottom: 25, marginLeft: 25, columns: 1, fontSize: 11),
                isBuiltin: true
            ),
            TemplateMetadata(
                id: "neurips",
                name: "NeurIPS",
                version: "1.0.0",
                description: "Template for NeurIPS conference submissions.",
                author: "imprint community",
                license: "MIT",
                category: .conference,
                tags: ["machine-learning", "ai", "conference"],
                journal: JournalInfo(publisher: "NeurIPS Foundation", url: "https://neurips.cc", latexClass: "neurips", issn: nil),
                pageDefaults: PageDefaults(size: "letter", marginTop: 25, marginRight: 25, marginBottom: 25, marginLeft: 25, columns: 1, fontSize: 10),
                isBuiltin: true
            )
        ]
    }

    private func mockTypstSource(for id: String) -> String {
        """
        // Template: \(id)

        #let article(
          title: none,
          authors: (),
          abstract: none,
          body
        ) = {
          set page(paper: "a4", margin: 2.5cm)
          set text(font: "New Computer Modern", size: 11pt)

          if title != none {
            align(center, text(size: 18pt, weight: "bold", title))
          }

          body
        }
        """
    }
}
