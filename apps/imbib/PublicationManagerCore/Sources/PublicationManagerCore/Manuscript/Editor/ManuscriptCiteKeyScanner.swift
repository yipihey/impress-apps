//
//  ManuscriptCiteKeyScanner.swift
//  PublicationManagerCore
//
//  The cite keys a manuscript uses, in reading order — the editor's live
//  buffer when there is one, the stored body when there is not, plus the other
//  text files of a multi-file manuscript (ADR-0030), which cite from their own
//  chapters.
//
//  Extracted from the Papers panel's view model when the panel was replaced by
//  imbib's papers window: the SCAN is not a panel concern, it is what
//  `syncManuscriptPapers` needs from whoever asks. The scanner itself is Rust's
//  (`ManuscriptCiteKeyLocator`), so the editor's highlighting, the window's
//  sync and the `project-*` verbs all recognise the same citations.
//

import Foundation

public enum ManuscriptCiteKeyScanner {

    /// Distinct cite keys in reading order: `buffer` first, then `otherFiles`.
    public static func citeKeys(
        buffer: String,
        format: DocumentFormat,
        otherFiles: [(text: String, format: DocumentFormat)] = []
    ) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for (text, fileFormat) in [(buffer, format)] + otherFiles.map({ ($0.text, $0.format) }) {
            for hit in ManuscriptCiteKeyLocator.allCiteKeys(in: text, format: fileFormat)
            where seen.insert(hit.key).inserted {
                keys.append(hit.key)
            }
        }
        return keys
    }

    /// The keys of a manuscript as the STORE has it — for a caller with no
    /// editor buffer (a URL, an app verb, an agent).
    @MainActor
    public static func keys(
        of manuscriptID: UUID,
        detail: ManuscriptDetail? = nil,
        format: DocumentFormat? = nil
    ) -> [String] {
        let detail = detail ?? RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)
        guard let detail else { return [] }
        // A blob ref is not markup; the project's files below still scan.
        let body = detail.bodyIsBlobRef ? "" : detail.bodyContent
        let bodyFormat = format ?? DocumentFormat(rawValue: detail.format) ?? .typst
        return citeKeys(
            buffer: body, format: bodyFormat, otherFiles: projectTexts(of: manuscriptID))
    }

    /// The text files of a multi-file manuscript, with the format their
    /// extension implies. Empty for a one-file manuscript.
    @MainActor
    public static func projectTexts(
        of manuscriptID: UUID
    ) -> [(text: String, format: DocumentFormat)] {
        ManuscriptProjectModel.shared(for: manuscriptID).files.compactMap { file in
            guard file.isText, let text = file.content, let format = format(forPath: file.path) else {
                return nil
            }
            return (text, format)
        }
    }

    public static func format(forPath path: String) -> DocumentFormat? {
        switch (path as NSString).pathExtension.lowercased() {
        case "typ": return .typst
        case "tex", "ltx": return .latex
        case "md", "markdown": return .markdown
        default: return nil
        }
    }
}
