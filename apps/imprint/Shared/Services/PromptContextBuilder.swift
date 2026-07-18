//
//  PromptContextBuilder.swift
//  imprint
//
//  Assembles the structured context (outline, surrounding sections, cited
//  papers, containing section) that AI author-task prompts substitute via
//  {{outline}}, {{surrounding_sections}}, {{cited_papers}}, {{paragraph}},
//  {{section_heading}}. Kept dependency-light (SectionExtractor + regex) so both
//  the editor path and the HTTP task endpoint share one implementation.
//

import Foundation

enum PromptContextBuilder {

    /// Build the context for a task acting on `range` of `source`.
    static func build(
        range: NSRange,
        source: String,
        documentTitle: String?,
        documentID: UUID,
        format: SectionFormat
    ) -> DocumentContext {
        let ns = source as NSString
        let sections = SectionExtractor.extract(from: source, documentID: documentID, format: format)
        let loc = range.location
        let idx = sections.firstIndex(where: { $0.start <= loc && loc < $0.end })
        let containing = idx.map { sections[$0] }

        // Containing section body → {{paragraph}}.
        let paragraph = containing.map { sec -> String in
            let start = min(max(0, sec.bodyStart), ns.length)
            let end = min(max(start, sec.end), ns.length)
            return ns.substring(with: NSRange(location: start, length: end - start))
        }

        // Indented heading list → {{outline}}.
        let minLevel = sections.map(\.level).min() ?? 1
        let outline = sections.isEmpty ? nil : sections.map { s in
            String(repeating: "  ", count: max(0, s.level - minLevel)) + "- " + s.title
        }.joined(separator: "\n")

        // Previous/next section titles → {{surrounding_sections}}.
        var surrounding: String?
        if let idx {
            var lines: [String] = []
            if idx > 0 { lines.append("Previous section: \(sections[idx - 1].title)") }
            if idx + 1 < sections.count { lines.append("Next section: \(sections[idx + 1].title)") }
            surrounding = lines.isEmpty ? nil : lines.joined(separator: "\n")
        }

        // Cite keys within the containing section (or the range) → {{cited_papers}}.
        let scanRange: NSRange = containing.map {
            NSRange(location: $0.start, length: min(max($0.start, $0.end), ns.length) - $0.start)
        } ?? range
        let citeKeys = extractCiteKeys(in: ns, range: scanRange)
        let citedPapers = citeKeys.isEmpty ? nil : citeKeys.joined(separator: ", ")

        return DocumentContext(
            documentTitle: documentTitle,
            surroundingParagraph: paragraph,
            sectionHeading: containing?.title,
            fullSource: source,
            outline: outline,
            surroundingSections: surrounding,
            citedPapers: citedPapers
        )
    }

    /// Cite keys (`\cite{...}`, `\citep{a,b}`, Typst `@key`) inside `range`.
    private static func extractCiteKeys(in ns: NSString, range: NSRange) -> [String] {
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return [] }
        let text = ns.substring(with: range) as NSString
        let full = NSRange(location: 0, length: text.length)
        var keys: Set<String> = []

        if let re = try? NSRegularExpression(pattern: "\\\\[a-zA-Z]*cite[a-zA-Z]*\\*?\\{([^}]*)\\}") {
            for m in re.matches(in: text as String, range: full) {
                for k in text.substring(with: m.range(at: 1)).split(separator: ",") {
                    let s = k.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { keys.insert(s) }
                }
            }
        }
        if let re = try? NSRegularExpression(pattern: "@([a-zA-Z0-9_:.-]+)") {
            for m in re.matches(in: text as String, range: full) {
                keys.insert(text.substring(with: m.range(at: 1)))
            }
        }
        return keys.sorted()
    }
}
