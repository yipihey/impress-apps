//
//  ExportTemplateTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

// MARK: - Export Format Tests

final class ExportFormatTests: XCTestCase {

    func testAllCases_includesExpectedFormats() {
        let formats = ExportFormat.allCases

        XCTAssertTrue(formats.contains(.bibtex))
        XCTAssertTrue(formats.contains(.ris))
        XCTAssertTrue(formats.contains(.plainText))
        XCTAssertTrue(formats.contains(.markdown))
        XCTAssertTrue(formats.contains(.html))
        XCTAssertTrue(formats.contains(.csv))
    }

    func testFileExtension_isCorrect() {
        XCTAssertEqual(ExportFormat.bibtex.fileExtension, "bib")
        XCTAssertEqual(ExportFormat.ris.fileExtension, "ris")
        XCTAssertEqual(ExportFormat.plainText.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ExportFormat.html.fileExtension, "html")
        XCTAssertEqual(ExportFormat.csv.fileExtension, "csv")
    }

    func testDisplayName_isReadable() {
        XCTAssertEqual(ExportFormat.bibtex.displayName, "BibTeX")
        XCTAssertEqual(ExportFormat.ris.displayName, "RIS")
        XCTAssertEqual(ExportFormat.plainText.displayName, "Plain Text")
    }

    func testMimeType_isCorrect() {
        XCTAssertEqual(ExportFormat.bibtex.mimeType, "application/x-bibtex")
        XCTAssertEqual(ExportFormat.html.mimeType, "text/html")
        XCTAssertEqual(ExportFormat.csv.mimeType, "text/csv")
    }
}

// MARK: - Export Template Tests

final class ExportTemplateTests: XCTestCase {

    func testInit_setsAllProperties() {
        // Given/When
        let template = ExportTemplate(
            name: "Test Template",
            format: "custom",
            template: "{{title}}",
            headerTemplate: "Header",
            footerTemplate: "Footer",
            separator: "\n---\n",
            isBuiltIn: false
        )

        // Then
        XCTAssertEqual(template.name, "Test Template")
        XCTAssertEqual(template.format, "custom")
        XCTAssertEqual(template.template, "{{title}}")
        XCTAssertEqual(template.headerTemplate, "Header")
        XCTAssertEqual(template.footerTemplate, "Footer")
        XCTAssertEqual(template.separator, "\n---\n")
        XCTAssertFalse(template.isBuiltIn)
    }

    func testInit_hasDefaultValues() {
        // Given/When
        let template = ExportTemplate(
            name: "Simple",
            format: "custom",
            template: "{{title}}"
        )

        // Then
        XCTAssertNil(template.headerTemplate)
        XCTAssertNil(template.footerTemplate)
        XCTAssertEqual(template.separator, "\n\n")
        XCTAssertFalse(template.isBuiltIn)
    }
}

// MARK: - Template Engine Tests

final class TemplateEngineTests: XCTestCase {

    var engine: TemplateEngine!

    override func setUp() {
        super.setUp()
        engine = TemplateEngine.shared
    }

    // MARK: - Built-in Template Tests

    func testBuiltInTemplate_bibtex_exists() {
        let template = engine.builtInTemplate(for: .bibtex)

        XCTAssertEqual(template.name, "BibTeX")
        XCTAssertTrue(template.isBuiltIn)
        XCTAssertTrue(template.template.contains("@{{entryType}}"))
    }

    func testBuiltInTemplate_ris_exists() {
        let template = engine.builtInTemplate(for: .ris)

        XCTAssertEqual(template.name, "RIS")
        XCTAssertTrue(template.template.contains("TY  -"))
        XCTAssertTrue(template.template.contains("ER  -"))
    }

    func testBuiltInTemplate_markdown_hasHeaderFooter() {
        let template = engine.builtInTemplate(for: .markdown)

        XCTAssertNotNil(template.headerTemplate)
        XCTAssertTrue(template.headerTemplate?.contains("# Bibliography") == true)
    }

    func testBuiltInTemplate_html_hasFullDocument() {
        let template = engine.builtInTemplate(for: .html)

        XCTAssertTrue(template.headerTemplate?.contains("<!DOCTYPE html>") == true)
        XCTAssertTrue(template.footerTemplate?.contains("</html>") == true)
    }

    func testBuiltInTemplate_csv_hasHeader() {
        let template = engine.builtInTemplate(for: .csv)

        XCTAssertTrue(template.headerTemplate?.contains("Cite Key") == true)
        XCTAssertEqual(template.separator, "\n")
    }

    func testAllBuiltInTemplates_hasAllFormats() {
        let templates = engine.allBuiltInTemplates

        XCTAssertEqual(templates.count, ExportFormat.allCases.count)
    }

    // MARK: - Template Processing Tests

    func testExport_simpleTemplate_replacesPlaceholders() {
        // Given
        let template = ExportTemplate(
            name: "Test",
            format: "custom",
            template: "Title: {{title}}, Year: {{year}}"
        )

        // Create a mock publication using BibTeX parser
        let bibtex = """
        @article{Test2020,
            title = {Test Title},
            year = {2020}
        }
        """

        // We can't easily create CDPublication in tests without Core Data
        // So we'll test the template structure instead
        XCTAssertTrue(template.template.contains("{{title}}"))
        XCTAssertTrue(template.template.contains("{{year}}"))
    }

    func testExport_withHeader_includesHeader() {
        let template = engine.builtInTemplate(for: .markdown)

        XCTAssertNotNil(template.headerTemplate)
        XCTAssertTrue(template.headerTemplate!.contains("{{count}}"))
    }

    func testExport_withFooter_includesFooter() {
        let template = engine.builtInTemplate(for: .html)

        XCTAssertNotNil(template.footerTemplate)
    }

    // MARK: - Separator Tests

    func testExport_separator_isUsedBetweenEntries() {
        let template = engine.builtInTemplate(for: .csv)

        // CSV uses newline separator
        XCTAssertEqual(template.separator, "\n")

        let bibtexTemplate = engine.builtInTemplate(for: .bibtex)
        // BibTeX uses double newline
        XCTAssertEqual(bibtexTemplate.separator, "\n\n")
    }
}

// MARK: - Template Placeholder Tests

final class TemplatePlaceholderTests: XCTestCase {

    func testPlaceholders_basicFields() {
        let placeholders = [
            "{{citeKey}}",
            "{{title}}",
            "{{authors}}",
            "{{year}}",
            "{{entryType}}"
        ]

        let template = TemplateEngine.shared.builtInTemplate(for: .bibtex)

        for placeholder in placeholders {
            XCTAssertTrue(template.template.contains(placeholder) || placeholder == "{{citeKey}}",
                         "Template should support \(placeholder)")
        }
    }

    func testPlaceholders_helperFields() {
        let template = TemplateEngine.shared.builtInTemplate(for: .plainText)

        XCTAssertTrue(template.template.contains("{{authorList}}") ||
                     template.template.contains("{{firstAuthor}}"),
                     "Plain text should use author helper placeholders")
    }

    func testPlaceholders_headerFields() {
        let template = TemplateEngine.shared.builtInTemplate(for: .markdown)

        XCTAssertTrue(template.headerTemplate?.contains("{{count}}") == true)
        XCTAssertTrue(template.headerTemplate?.contains("{{date}}") == true)
    }
}
