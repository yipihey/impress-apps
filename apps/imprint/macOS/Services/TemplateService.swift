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
        switch id {
        case "generic":
            return genericArticleTemplate
        case "mnras":
            return mnrasTemplate
        case "nature":
            return natureTemplate
        case "neurips":
            return neuripsTemplate
        default:
            return genericArticleTemplate
        }
    }

    // MARK: - Real Typst Templates

    private var genericArticleTemplate: String {
        """
        // Generic Academic Article
        #set page(paper: "a4", margin: 2.5cm)
        #set text(font: "New Computer Modern", size: 11pt)
        #set par(justify: true, leading: 0.65em)
        #set heading(numbering: "1.")

        // Title
        #align(center)[
          #text(size: 18pt, weight: "bold")[Your Title Here]

          #v(0.5em)
          #text(size: 12pt)[Author Name #super[1], Co-Author Name #super[2]]

          #v(0.3em)
          #text(size: 10pt, style: "italic")[
            #super[1] Department, University \\
            #super[2] Department, University
          ]

          #v(0.5em)
          #text(size: 10pt)[#datetime.today().display("[month repr:long] [day], [year]")]
        ]

        #v(1em)

        // Abstract
        #block(width: 85%, inset: (left: 1em, right: 1em))[
          *Abstract.* #lorem(80)
        ]

        #v(1em)

        = Introduction

        #lorem(120)

        = Methods

        #lorem(100)

        == Data Collection

        #lorem(60)

        == Analysis

        #lorem(60)

        = Results

        #lorem(100)

        The key equation is:

        $ E = m c^2 $

        = Discussion

        #lorem(100)

        = Conclusion

        #lorem(60)
        """
    }

    private var mnrasTemplate: String {
        """
        // MNRAS — Monthly Notices of the Royal Astronomical Society
        #set page(paper: "a4", margin: (top: 2cm, bottom: 2cm, left: 1.5cm, right: 1.5cm), columns: 2)
        #set text(font: "New Computer Modern", size: 9pt)
        #set par(justify: true, leading: 0.55em)
        #set heading(numbering: "1")

        // MNRAS header
        #place(top + left, dy: -1.5cm)[
          #text(size: 7pt, fill: gray)[Mon. Not. R. Astron. Soc. *000*, 000–000 (2026)]
        ]

        // Title block (spans both columns)
        #place(top + center, scope: "parent", float: true)[
          #block(width: 100%)[
            #align(center)[
              #text(size: 14pt, weight: "bold")[Title of Your MNRAS Paper]

              #v(0.5em)
              #text(size: 10pt)[A. Author#super[1]#sym.star, B. Coauthor#super[1,2]]

              #v(0.3em)
              #text(size: 8pt, style: "italic")[
                #super[1] Institute of Astronomy, University of Cambridge, Cambridge CB3 0HA, UK \\
                #super[2] Department of Physics, University of Oxford, Oxford OX1 3RH, UK
              ]

              #v(0.3em)
              #text(size: 8pt)[Accepted XXX. Received XXX; in original form XXX]
            ]

            #v(0.5em)
            #block(width: 90%, inset: (left: 1em, right: 1em))[
              #text(size: 8pt)[
                *ABSTRACT* \\
                #lorem(100)
              ]
            ]
            #v(0.3em)
            #text(size: 8pt)[*Key words:* galaxies: evolution — galaxies: formation — methods: numerical]
            #v(0.5em)
          ]
        ]

        = INTRODUCTION

        #lorem(120)

        = OBSERVATIONS AND DATA REDUCTION

        #lorem(100)

        == Spectroscopic data

        #lorem(80)

        = ANALYSIS

        #lorem(100)

        The luminosity function is given by:

        $ phi(L) = (phi^*) / (L^*) (L / L^*)^alpha exp(-L / L^*) $

        = RESULTS

        #lorem(100)

        = DISCUSSION

        #lorem(80)

        = CONCLUSIONS

        #lorem(60)

        = ACKNOWLEDGEMENTS

        We thank the anonymous referee for constructive comments.

        // DATA AVAILABILITY

        The data underlying this article will be shared on reasonable request.
        """
    }

    private var natureTemplate: String {
        """
        // Nature — Article Template
        #set page(paper: "a4", margin: (top: 2.5cm, bottom: 2.5cm, left: 2.5cm, right: 2.5cm))
        #set text(font: "New Computer Modern", size: 11pt)
        #set par(justify: true, leading: 0.65em)
        // Nature uses unnumbered headings
        #set heading(numbering: none)

        // Title
        #align(center)[
          #text(size: 20pt, weight: "bold")[Your Nature Article Title]

          #v(0.8em)
          #text(size: 12pt)[
            First Author#super[1,2]#sym.star,
            Second Author#super[2],
            Third Author#super[3]
          ]

          #v(0.5em)
          #text(size: 9pt)[
            #super[1] Department, University, City, Country \\
            #super[2] Institute, City, Country \\
            #super[3] Laboratory, City, Country \\
            #sym.star Corresponding author. e-mail: author\\@university.edu
          ]
        ]

        #v(1em)

        // Abstract (Nature: one paragraph, no heading, bold)
        #block(width: 100%)[
          #text(weight: "bold")[
            #lorem(80)
          ]
        ]

        #v(1em)

        // Main text (Nature uses minimal section headings)
        #lorem(150)

        = Methods

        #lorem(100)

        = Results

        #lorem(120)

        = Discussion

        #lorem(100)

        #v(1em)
        *References* will appear here.
        """
    }

    private var neuripsTemplate: String {
        """
        // NeurIPS — Conference Paper Template
        #set page(paper: "us-letter", margin: (top: 1in, bottom: 1in, left: 1.5in, right: 1.5in))
        #set text(font: "New Computer Modern", size: 10pt)
        #set par(justify: true, leading: 0.58em)
        #set heading(numbering: "1")

        // NeurIPS header
        #align(center)[
          #text(size: 8pt)[
            Advances in Neural Information Processing Systems 39 (NeurIPS 2026)
          ]

          #v(1.5em)
          #text(size: 17pt, weight: "bold")[Your NeurIPS Paper Title]

          #v(1em)
          #text(size: 12pt)[
            Author Name #super[1] #h(2em)
            Author Name #super[2] #h(2em)
            Author Name #super[1,3]
          ]

          #v(0.5em)
          #text(size: 10pt)[
            #super[1] University Department, City \\
            #super[2] Research Lab, City \\
            #super[3] Industry Research, City
          ]

          #v(0.3em)
          #text(size: 10pt, style: "italic")[
            \\{author1, author2, author3\\}\\@institution.edu
          ]
        ]

        #v(1.5em)

        // Abstract
        #align(center)[
          #block(width: 85%)[
            #align(left)[
              *Abstract*

              #lorem(80)
            ]
          ]
        ]

        #v(1em)

        = Introduction

        #lorem(120)

        = Related Work

        #lorem(100)

        = Method

        #lorem(100)

        == Problem Formulation

        #lorem(60)

        We minimize the following objective:

        $ cal(L)(theta) = bb(E)_(x tilde p_"data") [-log p_theta (x)] + lambda norm(theta)_2^2 $

        == Architecture

        #lorem(80)

        = Experiments

        #lorem(100)

        == Setup

        #lorem(60)

        == Results

        #lorem(80)

        = Conclusion

        #lorem(60)

        = Broader Impact

        #lorem(40)
        """
    }
}
