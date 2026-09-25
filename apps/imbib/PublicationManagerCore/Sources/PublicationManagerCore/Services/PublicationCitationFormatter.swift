//
//  PublicationCitationFormatter.swift
//  PublicationManagerCore
//
//  Edit ▸ Copy as Citation (⇧⌘C): a formatted reference for the selection.
//

import Foundation
import ImpressLogging
import ImprintCore
import PDFKit

/// A formatted reference ("A. Author, B. Author, "Title," *Journal*, …") for
/// publications, as plain text.
///
/// imbib has no citation formatter, and this does not add one: it asks
/// imprint's Typst renderer (`ImprintCore.TypstRenderer`, already linked by
/// this package for manuscript compiles) to typeset `#bibliography(…, full:
/// true)` over the publications' store BibTeX — Typst formats bibliographies
/// with hayagriva and its bundled CSL styles — and reads the text back out of
/// the PDF with PDFKit. The style is imprint's: imprint never passes a
/// `style:` to `#bibliography`, so its manuscripts use Typst's default, and so
/// does this. When Typst is unavailable or the render fails, the fallback is
/// imbib's own "Plain Text (APA-like)" export template.
@MainActor
public enum PublicationCitationFormatter {

    public enum Source: String, Sendable {
        /// Typst's bibliography (hayagriva), imprint's default style.
        case typst
        /// `TemplateEngine`'s plain-text export template.
        case plainText
    }

    public struct Formatted: Sendable {
        public let text: String
        public let source: Source
    }

    /// The Typst document that typesets `bibliography.bib` (the renderer's
    /// virtual file for `RenderOptions.bibSource`) as one reference per line:
    /// a page far wider than any reference, so no entry wraps.
    static let typstSource = """
        #set page(width: 400cm, height: auto, margin: 0pt)
        #set par(justify: false)
        #bibliography("bibliography.bib", title: none, full: true)
        """

    public static func format(ids: [UUID], store: RustStoreAdapter = .shared) async -> Formatted? {
        guard !ids.isEmpty else { return nil }
        let bibtex = store.exportBibTeX(ids: ids)
        if !bibtex.isEmpty, let text = await typstReferences(bibtex: bibtex) {
            return Formatted(text: text, source: .typst)
        }
        let models = ids.compactMap { store.getPublicationDetail(id: $0) }
        guard !models.isEmpty else { return nil }
        let text = TemplateEngine.shared.export(models, format: .plainText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Formatted(text: text, source: .plainText)
    }

    /// The references Typst typesets for `bibtex`, one per line; `nil` when
    /// the renderer is unavailable, reports an error, or yields no text.
    static func typstReferences(bibtex: String) async -> String? {
        guard TypstRenderer.isNativeAvailable else {
            logWarning("Copy as Citation: Typst renderer unavailable", category: "clipboard")
            return nil
        }
        do {
            let output = try await TypstRenderer().render(
                typstSource, options: RenderOptions(bibSource: bibtex))
            guard output.errors.isEmpty, !output.pdfData.isEmpty else {
                logWarning(
                    "Copy as Citation: Typst could not format the selection: \(output.errors.joined(separator: "; "))",
                    category: "clipboard")
                return nil
            }
            guard let raw = PDFDocument(data: output.pdfData)?.string else { return nil }
            let references = references(fromExtractedText: raw)
            return references.isEmpty ? nil : references.joined(separator: "\n")
        } catch {
            logWarning("Copy as Citation: Typst render failed: \(error.localizedDescription)", category: "clipboard")
            return nil
        }
    }

    /// One reference per non-empty line of the PDF's text, without the list
    /// labels a numeric style puts in front (`[1]`, `1.`) — a copied citation
    /// is going somewhere that numbers its own list. PDFKit reads the label
    /// COLUMN before the text, so with several references every label can
    /// arrive on the first line (`[1] [2] [3] A. Author, …`); a run of them is
    /// stripped, not just one.
    nonisolated static func references(fromExtractedText text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespaces)
                if let labels = s.range(of: #"^((\[\d+\]|\d+\.)(\s+|$))+"#, options: .regularExpression) {
                    s.removeSubrange(labels)
                }
                return s
            }
            .filter { !$0.isEmpty }
    }
}
