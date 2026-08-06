//
//  CompileDiagnostic.swift
//  PublicationManagerCore
//
//  One diagnostic shape for every compile backend the manuscript editor
//  fronts: Typst (structured over the imprint-core FFI, with byte ranges and
//  hints) and LaTeX (log-parsed, line-based). The compile strip and the
//  diagnostics panel render this; clicking one navigates the editor via
//  `editorOffset(in:)`.
//

import Foundation
import ImprintCore

/// A compiler diagnostic in user-source coordinates.
public struct CompileDiagnostic: Identifiable, Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable {
        case error
        case warning
        case info
    }

    public let severity: Severity
    public let message: String
    /// 1-indexed line in the source the editor shows.
    public let line: Int?
    /// 1-indexed character column.
    public let column: Int?
    /// UTF-8 byte range in the source (Typst only; LaTeX is line-based).
    public let byteStart: Int?
    public let byteEnd: Int?
    /// Remediation hints ("did you mean …", "try …").
    public let hints: [String]

    /// Content identity: two identical diagnostics collapse in a list, which
    /// is what a list of compiler messages wants.
    public var id: String {
        "\(severity.rawValue):\(line ?? -1):\(column ?? -1):\(message)"
    }

    public init(
        severity: Severity,
        message: String,
        line: Int? = nil,
        column: Int? = nil,
        byteStart: Int? = nil,
        byteEnd: Int? = nil,
        hints: [String] = []
    ) {
        self.severity = severity
        self.message = message
        self.line = line
        self.column = column
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.hints = hints
    }

    public init(_ typst: ImprintCore.TypstDiagnostic) {
        self.init(
            severity: typst.severity == .warning ? .warning : .error,
            message: typst.message,
            line: typst.line,
            column: typst.column,
            byteStart: typst.byteStart,
            byteEnd: typst.byteEnd,
            hints: typst.hints
        )
    }

    public init(_ latex: LaTeXDiagnostic) {
        let severity: Severity
        switch latex.severity {
        case .error: severity = .error
        case .warning: severity = .warning
        default: severity = .info
        }
        self.init(
            severity: severity,
            message: latex.message,
            line: latex.line > 0 ? latex.line : nil,
            column: latex.column,
            hints: []
        )
    }

    /// One-line display form: `line 12: message`.
    public var displayLine: String {
        if let line { return "line \(line): \(message)" }
        return message
    }

    /// The UTF-16 offset in `source` a click on this diagnostic should move
    /// the editor caret to (the editor's `cursorPosition` is a UTF-16 offset
    /// feeding `NSTextView.setSelectedRange`).
    ///
    /// Prefers the byte range; falls back to line/column arithmetic. The
    /// compile source may carry an appended virtual-bibliography line the
    /// editor does not show, so the result is clamped to `source`.
    public func editorOffset(in source: String) -> Int? {
        if let byteStart {
            let utf8 = source.utf8
            if let idx = utf8.index(
                utf8.startIndex, offsetBy: byteStart, limitedBy: utf8.endIndex),
                let inUTF16 = idx.samePosition(in: source.utf16) {
                return source.utf16.distance(from: source.utf16.startIndex, to: inUTF16)
            }
            // Past the visible source (e.g. inside the appended bibliography
            // line): land at the end rather than nowhere.
            return source.utf16.count
        }
        guard let line else { return nil }
        var current = 1
        var offset = 0
        for lineText in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if current == line {
                let columnOffset = max(0, (column ?? 1) - 1)
                let clamped = min(columnOffset, lineText.count)
                let colUTF16 = String(lineText.prefix(clamped)).utf16.count
                return min(offset + colUTF16, source.utf16.count)
            }
            offset += String(lineText).utf16.count + 1  // + newline
            current += 1
        }
        return nil
    }

    /// UTF-16 range for highlighting the offending token, when the byte range
    /// is available and non-empty.
    public func editorRange(in source: String) -> NSRange? {
        guard let start = editorOffset(in: source),
              let byteStart, let byteEnd, byteEnd > byteStart else { return nil }
        let utf8 = source.utf8
        guard let endIdx = utf8.index(
            utf8.startIndex, offsetBy: min(byteEnd, utf8.count), limitedBy: utf8.endIndex),
            let endUTF16 = endIdx.samePosition(in: source.utf16) else { return nil }
        let end = source.utf16.distance(from: source.utf16.startIndex, to: endUTF16)
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
