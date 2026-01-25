//
//  ExportTemplates.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Export Format

/// Built-in export formats.
public enum ExportFormat: String, CaseIterable, Identifiable {
    case bibtex
    case ris
    case plainText
    case markdown
    case html
    case csv

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bibtex: return "BibTeX"
        case .ris: return "RIS"
        case .plainText: return "Plain Text"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .csv: return "CSV"
        }
    }

    public var fileExtension: String {
        switch self {
        case .bibtex: return "bib"
        case .ris: return "ris"
        case .plainText: return "txt"
        case .markdown: return "md"
        case .html: return "html"
        case .csv: return "csv"
        }
    }

    public var mimeType: String {
        switch self {
        case .bibtex: return "application/x-bibtex"
        case .ris: return "application/x-research-info-systems"
        case .plainText: return "text/plain"
        case .markdown: return "text/markdown"
        case .html: return "text/html"
        case .csv: return "text/csv"
        }
    }
}

// MARK: - Export Template

/// A template for exporting publications.
public struct ExportTemplate: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var format: String  // ExportFormat.rawValue or "custom"
    public var template: String
    public var headerTemplate: String?
    public var footerTemplate: String?
    public var separator: String
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        format: String,
        template: String,
        headerTemplate: String? = nil,
        footerTemplate: String? = nil,
        separator: String = "\n\n",
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.template = template
        self.headerTemplate = headerTemplate
        self.footerTemplate = footerTemplate
        self.separator = separator
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Template Engine

/// Processes export templates with publication data.
public final class TemplateEngine {

    public static let shared = TemplateEngine()

    private init() {}

    // MARK: - Export

    /// Export publications using a template.
    public func export(_ publications: [CDPublication], using template: ExportTemplate) -> String {
        var result = ""

        // Header
        if let header = template.headerTemplate {
            result += processHeader(header, count: publications.count)
            result += "\n"
        }

        // Each publication
        let entries = publications.map { processTemplate(template.template, for: $0) }
        result += entries.joined(separator: template.separator)

        // Footer
        if let footer = template.footerTemplate {
            result += "\n"
            result += processFooter(footer, count: publications.count)
        }

        return result
    }

    /// Export publications using a built-in format.
    public func export(_ publications: [CDPublication], format: ExportFormat) -> String {
        // Use proper exporters for BibTeX and RIS instead of templates
        switch format {
        case .bibtex:
            let entries = publications.map { $0.toBibTeXEntry() }
            return BibTeXExporter().export(entries)

        case .ris:
            let bibtexEntries = publications.map { $0.toBibTeXEntry() }
            let risEntries = RISBibTeXConverter.toRIS(bibtexEntries)
            return RISExporter().export(risEntries)

        default:
            // Use template-based export for other formats
            let template = builtInTemplate(for: format)
            return export(publications, using: template)
        }
    }

    // MARK: - Template Processing

    private func processTemplate(_ template: String, for publication: CDPublication) -> String {
        var result = template

        // Basic fields
        result = result.replacingOccurrences(of: "{{citeKey}}", with: publication.citeKey)
        result = result.replacingOccurrences(of: "{{title}}", with: publication.title ?? "")
        result = result.replacingOccurrences(of: "{{authors}}", with: publication.authorString)
        result = result.replacingOccurrences(of: "{{year}}", with: publication.year > 0 ? String(publication.year) : "")
        result = result.replacingOccurrences(of: "{{entryType}}", with: publication.entryType)

        // Optional fields
        result = result.replacingOccurrences(of: "{{abstract}}", with: publication.abstract ?? "")
        result = result.replacingOccurrences(of: "{{doi}}", with: publication.doi ?? "")
        result = result.replacingOccurrences(of: "{{journal}}", with: publication.fields["journal"] ?? "")
        result = result.replacingOccurrences(of: "{{booktitle}}", with: publication.fields["booktitle"] ?? "")
        result = result.replacingOccurrences(of: "{{volume}}", with: publication.fields["volume"] ?? "")
        result = result.replacingOccurrences(of: "{{number}}", with: publication.fields["number"] ?? "")
        result = result.replacingOccurrences(of: "{{pages}}", with: publication.fields["pages"] ?? "")
        result = result.replacingOccurrences(of: "{{publisher}}", with: publication.fields["publisher"] ?? "")
        result = result.replacingOccurrences(of: "{{address}}", with: publication.fields["address"] ?? "")
        result = result.replacingOccurrences(of: "{{keywords}}", with: publication.fields["keywords"] ?? "")
        result = result.replacingOccurrences(of: "{{url}}", with: publication.fields["url"] ?? "")
        result = result.replacingOccurrences(of: "{{note}}", with: publication.fields["note"] ?? "")

        // Formatted fields
        result = result.replacingOccurrences(of: "{{firstAuthor}}", with: firstAuthor(publication))
        result = result.replacingOccurrences(of: "{{firstAuthorLastName}}", with: firstAuthorLastName(publication))
        result = result.replacingOccurrences(of: "{{authorList}}", with: authorList(publication))
        result = result.replacingOccurrences(of: "{{venue}}", with: venue(publication))
        result = result.replacingOccurrences(of: "{{doiURL}}", with: doiURL(publication))

        // Clean up empty optional sections (lines with only whitespace after substitution)
        result = cleanEmptyLines(result)

        return result
    }

    private func processHeader(_ template: String, count: Int) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{{count}}", with: String(count))
        result = result.replacingOccurrences(of: "{{date}}", with: formattedDate())
        return result
    }

    private func processFooter(_ template: String, count: Int) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{{count}}", with: String(count))
        result = result.replacingOccurrences(of: "{{date}}", with: formattedDate())
        return result
    }

    // MARK: - Helper Methods

    private func firstAuthor(_ pub: CDPublication) -> String {
        let authors = pub.authorString.components(separatedBy: " and ")
        return authors.first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func firstAuthorLastName(_ pub: CDPublication) -> String {
        let first = firstAuthor(pub)
        // Handle "Last, First" format
        if first.contains(",") {
            return first.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        // Handle "First Last" format
        return first.components(separatedBy: " ").last ?? ""
    }

    private func authorList(_ pub: CDPublication) -> String {
        let authors = pub.authorString.components(separatedBy: " and ")
        if authors.count <= 2 {
            return authors.joined(separator: " and ")
        }
        return "\(authors.first ?? "") et al."
    }

    private func venue(_ pub: CDPublication) -> String {
        if let journal = pub.fields["journal"], !journal.isEmpty {
            return journal
        }
        if let booktitle = pub.fields["booktitle"], !booktitle.isEmpty {
            return booktitle
        }
        return ""
    }

    private func doiURL(_ pub: CDPublication) -> String {
        guard let doi = pub.doi, !doi.isEmpty else { return "" }
        return "https://doi.org/\(doi)"
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter.string(from: Date())
    }

    private func cleanEmptyLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty
        }
        return filtered.joined(separator: "\n")
    }

    // MARK: - Built-in Templates

    public func builtInTemplate(for format: ExportFormat) -> ExportTemplate {
        switch format {
        case .bibtex:
            return bibtexTemplate
        case .ris:
            return risTemplate
        case .plainText:
            return plainTextTemplate
        case .markdown:
            return markdownTemplate
        case .html:
            return htmlTemplate
        case .csv:
            return csvTemplate
        }
    }

    public var allBuiltInTemplates: [ExportTemplate] {
        ExportFormat.allCases.map { builtInTemplate(for: $0) }
    }

    // BibTeX template
    private var bibtexTemplate: ExportTemplate {
        ExportTemplate(
            name: "BibTeX",
            format: ExportFormat.bibtex.rawValue,
            template: """
            @{{entryType}}{{{citeKey}},
                author = {{{authors}}},
                title = {{{title}}},
                year = {{{year}}},
                journal = {{{journal}}},
                booktitle = {{{booktitle}}},
                volume = {{{volume}}},
                number = {{{number}}},
                pages = {{{pages}}},
                publisher = {{{publisher}}},
                doi = {{{doi}}},
                abstract = {{{abstract}}}
            }
            """,
            separator: "\n\n",
            isBuiltIn: true
        )
    }

    // RIS template
    private var risTemplate: ExportTemplate {
        ExportTemplate(
            name: "RIS",
            format: ExportFormat.ris.rawValue,
            template: """
            TY  - JOUR
            AU  - {{authors}}
            TI  - {{title}}
            PY  - {{year}}
            JO  - {{journal}}
            VL  - {{volume}}
            IS  - {{number}}
            SP  - {{pages}}
            DO  - {{doi}}
            AB  - {{abstract}}
            ER  -
            """,
            separator: "\n\n",
            isBuiltIn: true
        )
    }

    // Plain text template (APA-like)
    private var plainTextTemplate: ExportTemplate {
        ExportTemplate(
            name: "Plain Text (APA-like)",
            format: ExportFormat.plainText.rawValue,
            template: """
            {{authorList}} ({{year}}). {{title}}. {{venue}}, {{volume}}({{number}}), {{pages}}. {{doiURL}}
            """,
            separator: "\n\n",
            isBuiltIn: true
        )
    }

    // Markdown template
    private var markdownTemplate: ExportTemplate {
        ExportTemplate(
            name: "Markdown",
            format: ExportFormat.markdown.rawValue,
            template: """
            ## {{title}}

            **Authors:** {{authors}}
            **Year:** {{year}}
            **Venue:** {{venue}}
            {{doiURL}}

            {{abstract}}
            """,
            headerTemplate: "# Bibliography\n\nExported {{count}} publications on {{date}}.\n",
            separator: "\n---\n\n",
            isBuiltIn: true
        )
    }

    // HTML template
    private var htmlTemplate: ExportTemplate {
        ExportTemplate(
            name: "HTML",
            format: ExportFormat.html.rawValue,
            template: """
            <div class="publication">
              <h3>{{title}}</h3>
              <p class="authors">{{authors}}</p>
              <p class="venue">{{venue}}, {{year}}</p>
              <p class="doi"><a href="{{doiURL}}">{{doi}}</a></p>
              <p class="abstract">{{abstract}}</p>
            </div>
            """,
            headerTemplate: """
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="UTF-8">
              <title>Bibliography</title>
              <style>
                body { font-family: system-ui, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
                .publication { margin-bottom: 20px; padding: 15px; border: 1px solid #ddd; border-radius: 8px; }
                .publication h3 { margin-top: 0; }
                .authors { font-style: italic; }
                .venue { color: #666; }
                .abstract { font-size: 0.9em; color: #444; }
              </style>
            </head>
            <body>
            <h1>Bibliography</h1>
            <p>{{count}} publications exported on {{date}}</p>
            """,
            footerTemplate: """
            </body>
            </html>
            """,
            separator: "\n",
            isBuiltIn: true
        )
    }

    // CSV template
    private var csvTemplate: ExportTemplate {
        ExportTemplate(
            name: "CSV",
            format: ExportFormat.csv.rawValue,
            template: "\"{{citeKey}}\",\"{{title}}\",\"{{authors}}\",\"{{year}}\",\"{{venue}}\",\"{{doi}}\"",
            headerTemplate: "\"Cite Key\",\"Title\",\"Authors\",\"Year\",\"Venue\",\"DOI\"",
            separator: "\n",
            isBuiltIn: true
        )
    }
}

// MARK: - Custom Template Storage

/// Manages custom export templates.
public actor CustomTemplateStorage {

    public static let shared = CustomTemplateStorage()

    private var customTemplates: [ExportTemplate] = []
    private let storageKey = "CustomExportTemplates"

    private init() {
        Task { await load() }
    }

    public func allTemplates() -> [ExportTemplate] {
        TemplateEngine.shared.allBuiltInTemplates + customTemplates
    }

    public func customTemplatesOnly() -> [ExportTemplate] {
        customTemplates
    }

    public func save(_ template: ExportTemplate) async {
        if let index = customTemplates.firstIndex(where: { $0.id == template.id }) {
            customTemplates[index] = template
        } else {
            customTemplates.append(template)
        }
        await persist()
    }

    public func delete(_ template: ExportTemplate) async {
        customTemplates.removeAll { $0.id == template.id }
        await persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let templates = try? JSONDecoder().decode([ExportTemplate].self, from: data) else {
            return
        }
        customTemplates = templates
    }

    private func persist() async {
        guard let data = try? JSONEncoder().encode(customTemplates) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
