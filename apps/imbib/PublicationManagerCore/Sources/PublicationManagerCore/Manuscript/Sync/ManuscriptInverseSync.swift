#if os(macOS)
//
//  ManuscriptInverseSync.swift
//  PublicationManagerCore
//
//  Inverse-sync ("reverse search"): a click in the compiled preview → the
//  source char offset to move the editor caret to. Format-split:
//    • Typst — resolved entirely in PMC (ImprintCore is a PMC dependency), so
//      it works in imbib AND imprint. Part 1 uses the heuristic
//      `SourceMapUtils.lookup`; Part 2 prefers the real-layout typst-ide jump.
//    • LaTeX — resolved by the host's app-target SyncTeXService via the
//      `ManuscriptEditorEnvironment.inverseSyncResolver` seam; nil in imbib.
//
//  The resolved offset is applied by the caller as `session.cursorPosition`,
//  which the editor already scrolls-to and carets (SourceEditorView).
//

import Foundation
import ImprintCore

@MainActor
enum ManuscriptInverseSync {

    /// Resolve a preview click to a source char offset, or nil if it doesn't map
    /// (whitespace/margin, or an unsupported host). `page` is 1-indexed; `x`/`y`
    /// are PDF points with a top-left origin.
    static func resolveOffset(
        session: ManuscriptEditorSession,
        page: Int,
        x: Double,
        y: Double
    ) async -> Int? {
        switch session.format {
        case .typst:
            // In-PMC (works in imbib too). The entries come from imprint-core's
            // real-layout frame walk (accurate bboxes + span offsets), or the
            // text heuristic as a fallback; either flows through the same lookup.
            // Entries are page-indexed from 0.
            let result = SourceMapUtils.lookup(
                entries: session.vm.sourceMapEntries, page: page - 1, x: x, y: y)
            guard result.found else { return nil }
            return clamp(result.sourceOffset, to: session.source)

        case .latex:
            guard let resolver = ManuscriptEditorEnvironment.shared.inverseSyncResolver
            else { return nil }  // imbib / no LaTeX compiler → no-op
            let offset = await resolver(
                InverseSyncRequest(
                    manuscriptID: session.manuscriptID,
                    page: page, x: x, y: y, source: session.source))
            return offset.map { clamp($0, to: session.source) }
        }
    }

    /// Clamp an offset into the valid caret range for `source`. `cursorPosition`
    /// is applied as an NSRange location (UTF-16) but bounds-checked against
    /// `String.count`; both coincide for ASCII source. Clamp defensively.
    private static func clamp(_ offset: Int, to source: String) -> Int {
        max(0, min(offset, source.utf16.count))
    }
}

/// Converts a 1-indexed SyncTeX line/column into a UTF-16 char offset into
/// `source`, consistent with how the editor applies `cursorPosition`.
public enum ManuscriptSourceOffset {

    /// - Parameters:
    ///   - line: 1-indexed source line (SyncTeX convention).
    ///   - column: 0-based column within the line (clamped to the line length).
    /// - Returns: a UTF-16 offset into `source`, or nil if `line` is out of range.
    public static func offset(in source: String, line: Int, column: Int) -> Int? {
        guard line >= 1 else { return nil }

        let utf16 = source.utf16
        var index = utf16.startIndex
        var currentLine = 1

        // Advance to the start of the target line.
        while currentLine < line, index < utf16.endIndex {
            if utf16[index] == 0x0A {  // "\n"
                currentLine += 1
            }
            index = utf16.index(after: index)
        }
        // `line` past the end of the buffer → out of range.
        guard currentLine == line else { return nil }

        var offset = utf16.distance(from: utf16.startIndex, to: index)

        // Add the column, clamped to the end of this line (before the next "\n").
        var col = 0
        let target = max(0, column)
        while col < target, index < utf16.endIndex, utf16[index] != 0x0A {
            index = utf16.index(after: index)
            offset += 1
            col += 1
        }
        return min(offset, utf16.count)
    }
}
#endif
