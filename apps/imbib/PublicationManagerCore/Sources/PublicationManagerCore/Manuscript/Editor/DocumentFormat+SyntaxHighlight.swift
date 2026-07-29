//
//  DocumentFormat+SyntaxHighlight.swift
//  PublicationManagerCore
//
//  THE single mapping from a manuscript's `DocumentFormat` to the tree-sitter
//  grammar that highlights it, plus the shared highlighter-reuse policy.
//
//  Deliberately NOT platform-gated: `ImpressSyntaxHighlight` is cross-platform
//  (`ImpressTextStorage` is `NSTextStorage` on both AppKit and UIKit), so the
//  AppKit editor (`SourceEditorView`) and the UIKit editor
//  (`IOSSourceEditorView`) resolve their grammar and their cached highlighter
//  through the SAME code. Adding a grammar (or a format) is then one edit here
//  instead of one edit per editor.
//

import Foundation
import ImpressSyntaxHighlight

public extension DocumentFormat {

    /// Tree-sitter language for this format; `nil` = no grammar is vendored
    /// (Markdown/plain text render unhighlighted).
    var highlightLanguage: ImpressLanguage? {
        switch self {
        case .latex: return .latex
        case .typst: return .typst
        case .markdown, .plaintext: return nil
        }
    }

    /// Whether an editor should attempt syntax highlighting for this format.
    var isSyntaxHighlighted: Bool { highlightLanguage != nil }

    /// Get-or-create the per-editor `SyntaxHighlighter` for this format.
    ///
    /// `current` is the caller's cache (an editor coordinator's stored
    /// property). A highlighter holds a parser + the last parse tree, so it must
    /// be reused across keystrokes for incremental re-parsing to work — but it
    /// must be *replaced* when the document's format changes (e.g. the default
    /// `.typst` flips to `.latex` once the document loads) and *cleared* when
    /// the new format has no grammar, so stale colors don't linger.
    ///
    /// - Returns: the highlighter to use, or `nil` when this format has no
    ///   grammar (in which case `current` is cleared).
    func resolveHighlighter(_ current: inout SyntaxHighlighter?) -> SyntaxHighlighter? {
        guard let wanted = highlightLanguage else {
            current = nil
            return nil
        }
        if let existing = current, existing.language == wanted {
            return existing
        }
        let made = SyntaxHighlighter(language: wanted)
        current = made
        return made
    }
}
