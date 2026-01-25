//
//  BibTeXEditor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI

// MARK: - BibTeX Editor

/// A text editor with BibTeX syntax highlighting.
///
/// Features:
/// - Syntax highlighting for entry types, field names, values
/// - Real-time validation
/// - Error markers
/// - Line numbers (optional)
public struct BibTeXEditor: View {

    // MARK: - Properties

    @Binding var text: String
    let isEditable: Bool
    let showLineNumbers: Bool
    let onSave: ((String) -> Void)?

    @State private var validationErrors: [BibTeXValidationError] = []
    @State private var isValidating = false

    // MARK: - Initialization

    public init(
        text: Binding<String>,
        isEditable: Bool = true,
        showLineNumbers: Bool = true,
        onSave: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.isEditable = isEditable
        self.showLineNumbers = showLineNumbers
        self.onSave = onSave
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Editor
            editorView

            // Validation bar
            if !validationErrors.isEmpty {
                validationBar
            }
        }
        .onChange(of: text) { _, newValue in
            validateDebounced(newValue)
        }
    }

    // MARK: - Editor View

    @ViewBuilder
    private var editorView: some View {
        if isEditable {
            editableEditor
        } else {
            readOnlyViewer
        }
    }

    private var editableEditor: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                if showLineNumbers {
                    lineNumbersView
                }

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollDisabled(true)
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .accessibilityIdentifier(AccessibilityID.Detail.BibTeX.editor)
            }
            .padding(.vertical, 8)
        }
        .background(editorBackground)
    }

    private var readOnlyViewer: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                if showLineNumbers {
                    lineNumbersView
                }

                highlightedText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            .padding(.vertical, 8)
        }
        .background(editorBackground)
    }

    private var lineNumbersView: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(1...max(1, text.components(separatedBy: "\n").count), id: \.self) { lineNumber in
                Text("\(lineNumber)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .background(lineNumberBackground)
    }

    private var highlightedText: some View {
        Text(BibTeXHighlighter.highlight(text))
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
    }

    // MARK: - Validation Bar

    private var validationBar: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            Text("\(validationErrors.count) issue\(validationErrors.count == 1 ? "" : "s")")
                .font(.caption)

            Spacer()

            if let first = validationErrors.first {
                Text(first.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.1))
    }

    // MARK: - Colors

    private var editorBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private var lineNumberBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    // MARK: - Validation

    private func validateDebounced(_ content: String) {
        isValidating = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            let errors = BibTeXValidator.validate(content)
            await MainActor.run {
                self.validationErrors = errors
                self.isValidating = false
            }
        }
    }
}

// MARK: - BibTeX Highlighter

/// Provides syntax highlighting for BibTeX content.
public enum BibTeXHighlighter {

    // MARK: - Colors

    private static var entryTypeColor: Color {
        #if os(macOS)
        Color(nsColor: .systemPurple)
        #else
        Color.purple
        #endif
    }

    private static var citeKeyColor: Color {
        #if os(macOS)
        Color(nsColor: .systemBlue)
        #else
        Color.blue
        #endif
    }

    private static var fieldNameColor: Color {
        #if os(macOS)
        Color(nsColor: .systemTeal)
        #else
        Color.teal
        #endif
    }

    private static var stringColor: Color {
        #if os(macOS)
        Color(nsColor: .systemGreen)
        #else
        Color.green
        #endif
    }

    private static var braceColor: Color {
        #if os(macOS)
        Color(nsColor: .systemOrange)
        #else
        Color.orange
        #endif
    }

    private static var commentColor: Color {
        .gray
    }

    private static var defaultColor: Color {
        #if os(macOS)
        Color(nsColor: .textColor)
        #else
        Color.primary
        #endif
    }

    // MARK: - Highlighting

    /// Highlights BibTeX content and returns an AttributedString.
    public static func highlight(_ content: String) -> AttributedString {
        var result = AttributedString()

        let lines = content.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let highlightedLine = highlightLine(line)
            result.append(highlightedLine)

            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }

        return result
    }

    private static func highlightLine(_ line: String) -> AttributedString {
        var result = AttributedString()

        // Check for comment
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("%") {
            var comment = AttributedString(line)
            comment.foregroundColor = commentColor
            return comment
        }

        // Check for entry type (@article, @book, etc.)
        if let entryMatch = line.range(of: #"@\w+"#, options: .regularExpression) {
            // Before @
            let beforeAt = String(line[..<entryMatch.lowerBound])
            if !beforeAt.isEmpty {
                result.append(AttributedString(beforeAt))
            }

            // Entry type
            var entryType = AttributedString(String(line[entryMatch]))
            entryType.foregroundColor = entryTypeColor
            entryType.font = .system(.body, design: .monospaced).bold()
            result.append(entryType)

            // After entry type - look for cite key
            let afterEntry = String(line[entryMatch.upperBound...])
            result.append(highlightCiteKeyAndRest(afterEntry))

            return result
        }

        // Check for field assignment (fieldname = value)
        if let fieldMatch = line.range(of: #"^\s*(\w+)\s*="#, options: .regularExpression) {
            // Leading whitespace and field name
            let fieldPart = String(line[fieldMatch])

            // Extract just the field name
            if let nameMatch = fieldPart.range(of: #"\w+"#, options: .regularExpression) {
                // Leading whitespace
                let leading = String(fieldPart[..<nameMatch.lowerBound])
                result.append(AttributedString(leading))

                // Field name
                var fieldName = AttributedString(String(fieldPart[nameMatch]))
                fieldName.foregroundColor = fieldNameColor
                result.append(fieldName)

                // " = " part
                let afterName = String(fieldPart[nameMatch.upperBound...])
                result.append(AttributedString(afterName))
            } else {
                result.append(AttributedString(fieldPart))
            }

            // Value part
            let valuePart = String(line[fieldMatch.upperBound...])
            result.append(highlightValue(valuePart))

            return result
        }

        // Check for closing brace or other content
        result.append(highlightBracesAndStrings(line))

        return result
    }

    private static func highlightCiteKeyAndRest(_ text: String) -> AttributedString {
        var result = AttributedString()

        // Look for {citekey,
        if let braceMatch = text.range(of: #"\{\s*(\w+)\s*,"#, options: .regularExpression) {
            // Opening brace
            var openBrace = AttributedString("{")
            openBrace.foregroundColor = braceColor
            result.append(openBrace)

            // Extract cite key
            let insideBrace = String(text[text.index(after: braceMatch.lowerBound)..<braceMatch.upperBound])
            if let keyMatch = insideBrace.range(of: #"\w+"#, options: .regularExpression) {
                // Leading whitespace
                let leading = String(insideBrace[..<keyMatch.lowerBound])
                result.append(AttributedString(leading))

                // Cite key
                var citeKey = AttributedString(String(insideBrace[keyMatch]))
                citeKey.foregroundColor = citeKeyColor
                citeKey.font = .system(.body, design: .monospaced).bold()
                result.append(citeKey)

                // Trailing (comma)
                let trailing = String(insideBrace[keyMatch.upperBound...])
                result.append(AttributedString(trailing.dropLast())) // Remove the comma we'll add back
            }

            result.append(AttributedString(","))

            // Rest of line
            let rest = String(text[braceMatch.upperBound...])
            if !rest.isEmpty {
                result.append(AttributedString(rest))
            }

            return result
        }

        // No match, just highlight braces
        result.append(highlightBracesAndStrings(text))
        return result
    }

    private static func highlightValue(_ text: String) -> AttributedString {
        var result = AttributedString()
        var currentIndex = text.startIndex
        var inBraces = 0
        var inQuotes = false
        var currentRun = ""

        while currentIndex < text.endIndex {
            let char = text[currentIndex]

            if char == "{" && !inQuotes {
                // Flush current run
                if !currentRun.isEmpty {
                    result.append(AttributedString(currentRun))
                    currentRun = ""
                }
                var brace = AttributedString("{")
                brace.foregroundColor = braceColor
                result.append(brace)
                inBraces += 1
            } else if char == "}" && !inQuotes {
                // Flush current run
                if !currentRun.isEmpty {
                    var str = AttributedString(currentRun)
                    if inBraces > 0 {
                        str.foregroundColor = stringColor
                    }
                    result.append(str)
                    currentRun = ""
                }
                var brace = AttributedString("}")
                brace.foregroundColor = braceColor
                result.append(brace)
                inBraces = max(0, inBraces - 1)
            } else if char == "\"" {
                // Flush current run
                if !currentRun.isEmpty {
                    var str = AttributedString(currentRun)
                    if inQuotes {
                        str.foregroundColor = stringColor
                    }
                    result.append(str)
                    currentRun = ""
                }
                var quote = AttributedString("\"")
                quote.foregroundColor = stringColor
                result.append(quote)
                inQuotes.toggle()
            } else {
                currentRun.append(char)
            }

            currentIndex = text.index(after: currentIndex)
        }

        // Flush remaining
        if !currentRun.isEmpty {
            var str = AttributedString(currentRun)
            if inBraces > 0 || inQuotes {
                str.foregroundColor = stringColor
            }
            result.append(str)
        }

        return result
    }

    private static func highlightBracesAndStrings(_ text: String) -> AttributedString {
        var result = AttributedString()
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let char = text[currentIndex]

            if char == "{" || char == "}" {
                var brace = AttributedString(String(char))
                brace.foregroundColor = braceColor
                result.append(brace)
            } else {
                result.append(AttributedString(String(char)))
            }

            currentIndex = text.index(after: currentIndex)
        }

        return result
    }
}

// MARK: - BibTeX Validator

/// Validates BibTeX syntax.
public enum BibTeXValidator {

    /// Validate BibTeX content and return any errors.
    public static func validate(_ content: String) -> [BibTeXValidationError] {
        var errors: [BibTeXValidationError] = []
        let lines = content.components(separatedBy: "\n")

        var braceDepth = 0
        var inEntry = false
        var entryStartLine = 0

        for (lineIndex, line) in lines.enumerated() {
            let lineNumber = lineIndex + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments
            if trimmed.hasPrefix("%") {
                continue
            }

            // Check for entry start
            if let entryMatch = trimmed.range(of: #"^@(\w+)\s*\{"#, options: .regularExpression) {
                if inEntry {
                    errors.append(BibTeXValidationError(
                        line: lineNumber,
                        message: "New entry started before previous entry closed"
                    ))
                }

                // Extract entry type
                let entryType = String(trimmed[entryMatch]).lowercased()
                    .replacingOccurrences(of: "@", with: "")
                    .replacingOccurrences(of: "{", with: "")
                    .trimmingCharacters(in: .whitespaces)

                let validTypes = ["article", "book", "inproceedings", "incollection",
                                  "phdthesis", "mastersthesis", "misc", "techreport",
                                  "unpublished", "proceedings", "manual", "booklet",
                                  "conference", "inbook", "string", "preamble", "comment"]

                if !validTypes.contains(entryType) {
                    errors.append(BibTeXValidationError(
                        line: lineNumber,
                        message: "Unknown entry type: @\(entryType)"
                    ))
                }

                inEntry = true
                entryStartLine = lineNumber
                braceDepth = 1

                // Count remaining braces on this line
                let afterEntry = String(trimmed[entryMatch.upperBound...])
                for char in afterEntry {
                    if char == "{" { braceDepth += 1 }
                    if char == "}" { braceDepth -= 1 }
                }

                if braceDepth == 0 {
                    inEntry = false
                }

                continue
            }

            // Count braces in regular lines
            if inEntry {
                for char in line {
                    if char == "{" { braceDepth += 1 }
                    if char == "}" { braceDepth -= 1 }
                }

                if braceDepth == 0 {
                    inEntry = false
                } else if braceDepth < 0 {
                    errors.append(BibTeXValidationError(
                        line: lineNumber,
                        message: "Unexpected closing brace"
                    ))
                    braceDepth = 0
                    inEntry = false
                }
            }
        }

        // Check for unclosed entry
        if inEntry && braceDepth > 0 {
            errors.append(BibTeXValidationError(
                line: entryStartLine,
                message: "Unclosed entry (missing \(braceDepth) closing brace\(braceDepth > 1 ? "s" : ""))"
            ))
        }

        return errors
    }
}

// MARK: - Validation Error

/// A BibTeX validation error.
public struct BibTeXValidationError: Identifiable {
    public let id = UUID()
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

// MARK: - Preview

#Preview("BibTeX Editor") {
    struct PreviewContainer: View {
        @State private var bibtex = """
        @article{Einstein1905,
            author = {Albert Einstein},
            title = {On the Electrodynamics of Moving Bodies},
            journal = {Annalen der Physik},
            year = {1905},
            volume = {17},
            pages = {891--921}
        }

        % This is a comment
        @book{Feynman1965,
            author = {Richard P. Feynman},
            title = {The Character of Physical Law},
            publisher = {MIT Press},
            year = {1965}
        }
        """

        var body: some View {
            BibTeXEditor(text: $bibtex, isEditable: true)
                .frame(width: 600, height: 400)
        }
    }

    return PreviewContainer()
}

#Preview("Read-Only BibTeX") {
    struct PreviewContainer: View {
        @State private var bibtex = """
        @article{Einstein1905,
            author = {Albert Einstein},
            title = {On the Electrodynamics of Moving Bodies},
            journal = {Annalen der Physik},
            year = {1905}
        }
        """

        var body: some View {
            BibTeXEditor(text: $bibtex, isEditable: false)
                .frame(width: 600, height: 300)
        }
    }

    return PreviewContainer()
}
