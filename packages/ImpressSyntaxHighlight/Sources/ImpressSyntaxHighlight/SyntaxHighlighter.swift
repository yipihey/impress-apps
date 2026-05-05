//
//  SyntaxHighlighter.swift
//  ImpressSyntaxHighlight
//
//  Tree-sitter based syntax highlighter for impress apps.
//  Supports LaTeX and Typst. CRDT-compatible via incremental edit API.
//

import Foundation
import OSLog
import SwiftTreeSitter
import TreeSitterLaTeX
import TreeSitterTypst

/// Optional log callback so host apps can route messages into their own logging.
public struct ImpressSyntaxLog {
    nonisolated(unsafe) public static var callback: (@Sendable (String) -> Void)?
}

@inline(__always)
private func hlLog(_ message: String) {
    NSLog("[ImpressSyntaxHighlight] %@", message)
    ImpressSyntaxLog.callback?(message)
}

#if canImport(AppKit)
import AppKit
public typealias ImpressColor = NSColor
public typealias ImpressTextStorage = NSTextStorage
#elseif canImport(UIKit)
import UIKit
public typealias ImpressColor = UIColor
public typealias ImpressTextStorage = NSTextStorage
#endif

/// Languages supported by the highlighter.
public enum ImpressLanguage: Sendable, Equatable {
    case latex
    case typst

    fileprivate var tsLanguage: Language {
        switch self {
        case .latex: return Language(language: tree_sitter_latex())
        case .typst: return Language(language: tree_sitter_typst())
        }
    }

    fileprivate var highlightsResourceName: String {
        switch self {
        case .latex: return "latex-highlights"
        case .typst: return "typst-highlights"
        }
    }
}

/// Per-document syntax highlighter. Holds a parser, tree, and query for one language.
///
/// Usage:
/// ```
/// let highlighter = SyntaxHighlighter(language: .latex, theme: .impressDefault)
/// highlighter.highlight(textStorage: textView.textStorage!, source: textView.string)
/// ```
///
/// For CRDT/collaboration: call `applyEdit(...)` with tree-sitter edit deltas before
/// re-highlighting so tree-sitter re-parses only the affected subtrees.
public final class SyntaxHighlighter {
    public let language: ImpressLanguage
    private let parser: Parser
    private let query: Query?
    private var tree: MutableTree?
    public var theme: ImpressSyntaxTheme

    public init(language: ImpressLanguage, theme: ImpressSyntaxTheme = .impressDefault) {
        self.language = language
        self.theme = theme
        self.parser = Parser()
        let tsLang = language.tsLanguage
        try? self.parser.setLanguage(tsLang)

        // Load the highlights query from the package bundle
        if let url = Bundle.module.url(forResource: language.highlightsResourceName, withExtension: "scm"),
           let data = try? Data(contentsOf: url) {
            do {
                let q = try Query(language: tsLang, data: data)
                self.query = q
                hlLog("Loaded query for \(language.highlightsResourceName): \(q.patternCount) patterns, \(q.captureCount) captures")
            } catch {
                hlLog("Query FAILED for \(language.highlightsResourceName): \(error)")
                self.query = nil
            }
        } else {
            hlLog("Query file NOT FOUND: \(language.highlightsResourceName).scm")
            self.query = nil
        }
    }

    /// Re-parse the source from scratch and apply highlighting to the text storage.
    /// Use this on initial load or after large external changes.
    public func highlight(textStorage: ImpressTextStorage, source: String) {
        hlLog("highlight() called: source.count=\(source.count), query=\(query != nil ? "yes" : "nil")")
        let newTree = parser.parse(source)
        self.tree = newTree
        applyHighlights(to: textStorage, source: source)
    }

    /// Apply an incremental edit and re-parse only the affected subtrees.
    /// Call this before re-highlighting after a text mutation (local or CRDT remote).
    ///
    /// - Parameters:
    ///   - newSource: The full source after the edit.
    ///   - startByte: Byte offset where the edit starts.
    ///   - oldEndByte: Byte offset where the edit ended in the OLD source.
    ///   - newEndByte: Byte offset where the edit ends in the NEW source.
    ///   - textStorage: Text storage to update with new colors.
    public func applyEdit(
        newSource: String,
        startByte: Int,
        oldEndByte: Int,
        newEndByte: Int,
        textStorage: ImpressTextStorage
    ) {
        if let oldTree = tree {
            let edit = InputEdit(
                startByte: startByte,
                oldEndByte: oldEndByte,
                newEndByte: newEndByte,
                startPoint: Point(row: 0, column: startByte),
                oldEndPoint: Point(row: 0, column: oldEndByte),
                newEndPoint: Point(row: 0, column: newEndByte)
            )
            oldTree.edit(edit)
            self.tree = parser.parse(tree: oldTree, string: newSource)
        } else {
            self.tree = parser.parse(newSource)
        }
        applyHighlights(to: textStorage, source: newSource)
    }

    // MARK: - Private

    private func applyHighlights(to textStorage: ImpressTextStorage, source: String) {
        let hasTree = self.tree != nil
        let hasQuery = self.query != nil
        guard let tree, let query else {
            hlLog("applyHighlights: no tree or query (tree=\(hasTree), query=\(hasQuery)) — clearing colors")
            // Still reset colors so stale highlights from a previous language don't linger.
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.beginEditing()
            textStorage.addAttribute(.foregroundColor, value: theme.defaultColor, range: fullRange)
            textStorage.endEditing()
            return
        }
        let rootNode = tree.rootNode
        guard let rootNode else {
            hlLog("applyHighlights: no root node")
            return
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: theme.defaultColor, range: fullRange)

        let cursor = query.execute(node: rootNode, in: tree)
        var matchCount = 0
        var captureCount = 0
        var appliedCount = 0
        var sampleCaptures: [String] = []
        for match in cursor {
            matchCount += 1
            for capture in match.captures {
                captureCount += 1
                guard let captureName = capture.name else { continue }
                let nsRange = capture.node.range // SwiftTreeSitter's built-in UTF-16 conversion
                if sampleCaptures.count < 8 {
                    let safeEnd = min(NSMaxRange(nsRange), textStorage.length)
                    let safeLen = max(0, safeEnd - nsRange.location)
                    if safeLen > 0 {
                        let snippet = (textStorage.string as NSString).substring(with: NSRange(location: nsRange.location, length: min(30, safeLen)))
                        sampleCaptures.append("@\(captureName)[\(nsRange.location),\(nsRange.length)]=\"\(snippet)\"")
                    }
                }
                guard let color = theme.color(for: captureName) else { continue }
                if nsRange.location >= 0, NSMaxRange(nsRange) <= textStorage.length {
                    textStorage.addAttribute(.foregroundColor, value: color, range: nsRange)
                    appliedCount += 1
                }
            }
        }
        let langStr = (language == .latex) ? "latex" : "typst"
        hlLog("lang=\(langStr) matches=\(matchCount) captures=\(captureCount) applied=\(appliedCount) samples=[\(sampleCaptures.joined(separator: " | "))]")

        textStorage.endEditing()
    }

    /// Convert a tree-sitter byte range (UTF-16 code units × 2 bytes) to an NSRange.
    /// SwiftTreeSitter parses strings as UTF-16LE, so byteRange values are byte offsets
    /// into the UTF-16 representation. NSRange uses UTF-16 code unit indices, so we divide by 2.
    private func byteRangeToNSRange(_ byteRange: Range<UInt32>, in source: String) -> NSRange? {
        let startIndex = Int(byteRange.lowerBound) / 2
        let endIndex = Int(byteRange.upperBound) / 2
        guard startIndex <= endIndex else { return nil }
        return NSRange(location: startIndex, length: endIndex - startIndex)
    }
}
