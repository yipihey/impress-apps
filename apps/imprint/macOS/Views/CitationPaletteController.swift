//
//  CitationPaletteController.swift
//  imprint
//
//  Manages showing/hiding the InlineCitationPalette as an NSPopover anchored
//  to the caret in an NSTextView. Used by the SourceEditorView coordinator
//  to provide inline citation search triggered by `\cite{` / `@`.
//

import AppKit
import ImbibRustCore
import SwiftUI

/// Observable model the SwiftUI palette reads from. The controller pushes
/// query updates here as the user types in the editor; the SwiftUI view
/// re-runs its search each time.
@MainActor
@Observable
final class CitationPaletteModel {
    var query: String = ""
    /// Bumped on every show() call so the SwiftUI view re-runs its search
    /// even if the query string hasn't changed.
    var revision: Int = 0
}

/// Controls the lifecycle of an inline citation palette NSPopover anchored
/// to a caret position in an NSTextView.
@MainActor
final class CitationPaletteController {
    private var popover: NSPopover?
    private weak var currentTextView: NSTextView?
    /// The character location where the insertion should occur (inside `\cite{...}` or after `@`).
    /// For LaTeX, this is inside the braces so we can insert multiple comma-separated keys.
    /// For Typst, this is right after `@` so we replace up to the next non-word char.
    private var insertionRange: NSRange = NSRange(location: 0, length: 0)
    private var format: DocumentFormat = .typst
    /// Shared model the SwiftUI palette reads from. Lives across show/hide.
    let model = CitationPaletteModel()

    /// Show or update the palette anchored to the caret. As the user keeps typing
    /// in the editor, this is called repeatedly with new query strings — the
    /// popover stays open and the search refreshes via the shared model.
    func show(
        in textView: NSTextView,
        at insertionRange: NSRange,
        initialQuery: String,
        alreadyCitedKeys: Set<String>,
        format: DocumentFormat
    ) {
        self.currentTextView = textView
        self.insertionRange = insertionRange
        self.format = format

        // Push the latest query into the shared model so the SwiftUI palette
        // re-runs its search. This works whether the popover is being shown
        // for the first time OR being updated mid-typing.
        model.query = initialQuery
        model.revision &+= 1

        // If popover is already showing, just keep it where it is and let the
        // model push drive the search refresh.
        if popover?.isShown == true {
            return
        }

        // First show: build hosting controller + popover
        let content = InlineCitationPalette(
            model: model,
            alreadyCitedKeys: alreadyCitedKeys,
            onInsert: { [weak self] row in
                self?.insert(row: row)
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingController = NSHostingController(rootView: content)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 480, height: 340)

        let pop = NSPopover()
        pop.contentViewController = hostingController
        // .applicationDefined: don't auto-dismiss when the user types in the
        // editor (which counts as "interacting outside the popover").
        // We dismiss manually when the trigger goes away.
        pop.behavior = .applicationDefined
        pop.animates = false
        pop.delegate = PopoverDelegate.shared
        self.popover = pop

        // Anchor to the caret rect
        let rect = self.caretRect(in: textView, at: insertionRange.location) ?? .zero
        pop.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        NotificationCenter.default.post(name: .inlineCitationPaletteOpened, object: nil)
    }

    /// Dismiss the palette without inserting anything.
    func dismiss() {
        let wasShowing = popover?.isShown == true
        popover?.close()
        popover = nil
        currentTextView = nil
        if wasShowing {
            NotificationCenter.default.post(name: .inlineCitationPaletteClosed, object: nil)
        }
    }

    /// Whether a palette is currently showing.
    var isShowing: Bool {
        popover?.isShown == true
    }

    // MARK: - Private

    private func insert(row: BibliographyRow) {
        guard let textView = currentTextView, let textStorage = textView.textStorage else {
            dismiss()
            return
        }
        let key = row.citeKey

        // Determine what to insert based on format
        let insertText: String
        let newCursor: Int
        switch format {
        case .latex:
            // insertionRange is right after `{` or after the last `,`. Insert just the key.
            insertText = key
            newCursor = insertionRange.location + key.count
        case .typst:
            // insertionRange covers what's already been typed after `@`; replace it with the key.
            insertText = key
            newCursor = insertionRange.location + key.count
        }

        let replaceRange = NSRange(location: insertionRange.location, length: insertionRange.length)
        if textView.shouldChangeText(in: replaceRange, replacementString: insertText) {
            textStorage.replaceCharacters(in: replaceRange, with: insertText)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: newCursor, length: 0))
        }

        // Post notification so ContentView can add to the manuscript library and bibliography
        NotificationCenter.default.post(
            name: .inlineCitationInserted,
            object: nil,
            userInfo: [
                "publicationID": row.id,
                "citeKey": row.citeKey,
            ]
        )

        dismiss()
    }

    private func caretRect(in textView: NSTextView, at location: Int) -> NSRect? {
        // NSTextView.firstRect(forCharacterRange:actualRange:) returns screen coords;
        // NSPopover needs a rect in the view's coordinate space, so we convert back.
        let range = NSRange(location: location, length: 0)
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard let window = textView.window else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        var viewRect = textView.convert(windowRect, from: nil)
        // Add a little height so the popover doesn't overlap the caret itself
        if viewRect.size.width == 0 { viewRect.size.width = 2 }
        if viewRect.size.height == 0 { viewRect.size.height = 16 }
        return viewRect
    }
}

extension Notification.Name {
    /// Posted when the inline citation palette inserts a citation into the editor.
    /// userInfo: `publicationID` (String), `citeKey` (String)
    static let inlineCitationInserted = Notification.Name("imprint.inlineCitationInserted")

    /// Posted to request opening the paper detail panel for a given publication.
    /// userInfo: `publicationID` (String)
    static let openPaperPanel = Notification.Name("imprint.openPaperPanel")

    /// Posted when the inline citation palette opens.
    static let inlineCitationPaletteOpened = Notification.Name("imprint.inlineCitationPaletteOpened")

    /// Posted when the inline citation palette closes (either by insert or cancel).
    static let inlineCitationPaletteClosed = Notification.Name("imprint.inlineCitationPaletteClosed")
}

/// Tiny delegate to keep popovers transient and properly clean up.
private final class PopoverDelegate: NSObject, NSPopoverDelegate {
    static let shared = PopoverDelegate()
    func popoverDidClose(_ notification: Notification) {
        // No-op; controller tracks its own lifecycle
    }
}

// MARK: - Trigger Detection

/// Describes a citation palette trigger found in the source.
struct CitationPaletteTrigger {
    /// Range in the source where insertion should happen (may be zero-length).
    let insertionRange: NSRange
    /// Initial query extracted from characters already typed inside the trigger.
    let initialQuery: String
}

enum CitationPaletteTriggerDetector {
    /// Scan backwards from `cursorLocation` to detect a citation trigger.
    /// Returns nil if no trigger is active at the cursor.
    static func detect(
        in source: String,
        at cursorLocation: Int,
        format: DocumentFormat
    ) -> CitationPaletteTrigger? {
        guard cursorLocation >= 0, cursorLocation <= (source as NSString).length else { return nil }

        switch format {
        case .latex:
            return detectLatex(in: source, at: cursorLocation)
        case .typst:
            return detectTypst(in: source, at: cursorLocation)
        }
    }

    // `\cite{...}` — cursor must be inside the braces (closed or open).
    // The detector finds the enclosing `{...}` pair (or unclosed `{`),
    // verifies the preceding command is a cite variant, and computes the
    // current key range (between the nearest commas around the cursor).
    private static func detectLatex(in source: String, at cursorLocation: Int) -> CitationPaletteTrigger? {
        let ns = source as NSString
        // Step 1: scan backwards for an open `{` that's not closed before the cursor.
        // Stop at newlines (cite commands don't span lines in normal LaTeX).
        var openBrace: Int? = nil
        var depth = 0
        var i = cursorLocation - 1
        let backLimit = max(0, cursorLocation - 300)
        while i >= backLimit {
            let ch = ns.character(at: i)
            if ch == 10 /* \n */ { return nil }
            if ch == 125 /* } */ { depth += 1 }
            else if ch == 123 /* { */ {
                if depth == 0 { openBrace = i; break }
                depth -= 1
            }
            i -= 1
        }
        guard let braceIdx = openBrace else { return nil }

        // Step 2: verify the command preceding the `{` is a cite variant.
        var j = braceIdx - 1
        while j >= 0 {
            let cu = ns.character(at: j)
            if isLetter(cu) || cu == 42 /* * */ { j -= 1 } else { break }
        }
        guard j >= 0, ns.character(at: j) == 92 /* \ */ else { return nil }
        let commandName = ns.substring(with: NSRange(location: j + 1, length: braceIdx - (j + 1))).lowercased()
        let isCite = commandName.hasPrefix("cite")
            || commandName.hasPrefix("parencite")
            || commandName.hasPrefix("textcite")
            || commandName.hasPrefix("autocite")
            || commandName.hasPrefix("footcite")
            || commandName.hasPrefix("smartcite")
            || commandName.hasPrefix("supercite")
            || commandName.hasPrefix("nocite")
        guard isCite else { return nil }

        // Step 3: find the matching closing `}` (or end-of-line if missing).
        var closeBrace = ns.length
        var k = braceIdx + 1
        var d2 = 0
        while k < ns.length {
            let ch = ns.character(at: k)
            if ch == 10 /* \n */ { closeBrace = k; break }
            if ch == 123 { d2 += 1 }
            else if ch == 125 {
                if d2 == 0 { closeBrace = k; break }
                d2 -= 1
            }
            k += 1
        }
        // The cursor must be within (braceIdx, closeBrace]
        guard cursorLocation > braceIdx, cursorLocation <= closeBrace else { return nil }

        // Step 4: compute the current key — bounded by the nearest commas inside braces.
        var keyStart = braceIdx + 1
        var m = braceIdx + 1
        while m < cursorLocation {
            if ns.character(at: m) == 44 /* , */ { keyStart = m + 1 }
            m += 1
        }
        // Skip whitespace after delimiter
        while keyStart < cursorLocation {
            let ch = ns.character(at: keyStart)
            if ch == 32 || ch == 9 { keyStart += 1 } else { break }
        }
        // Find end of current key — next comma or close brace after the cursor
        var keyEnd = cursorLocation
        var n = cursorLocation
        while n < closeBrace {
            let ch = ns.character(at: n)
            if ch == 44 /* , */ || ch == 125 { keyEnd = n; break }
            n += 1
            keyEnd = n
        }
        let length = max(0, keyEnd - keyStart)
        let queryRange = NSRange(location: keyStart, length: length)
        let initial = length > 0 ? ns.substring(with: queryRange) : ""
        return CitationPaletteTrigger(
            insertionRange: queryRange,
            initialQuery: initial
        )
    }

    // `@key` — cursor must be after `@` and on characters that form a valid cite key.
    private static func detectTypst(in source: String, at cursorLocation: Int) -> CitationPaletteTrigger? {
        let ns = source as NSString
        var i = cursorLocation - 1
        var atIndex: Int? = nil
        while i >= 0 {
            let uni = ns.character(at: i)
            if uni == 64 /* @ */ {
                atIndex = i
                break
            }
            if !isTypstCiteKeyChar(uni) { return nil }
            i -= 1
        }
        guard let at = atIndex else { return nil }
        // Ensure the char before `@` is not word-like (so we don't trigger on emails)
        if at > 0 {
            let before = ns.character(at: at - 1)
            if isTypstCiteKeyChar(before) || before == 64 { return nil }
        }
        let queryStart = at + 1
        let length = cursorLocation - queryStart
        let initial = length > 0 ? ns.substring(with: NSRange(location: queryStart, length: length)) : ""
        return CitationPaletteTrigger(
            insertionRange: NSRange(location: queryStart, length: length),
            initialQuery: initial
        )
    }

    private static func isLetter(_ u: UInt16) -> Bool {
        (u >= 97 && u <= 122) || (u >= 65 && u <= 90)  // a-z or A-Z
    }

    private static func isTypstCiteKeyChar(_ u: UInt16) -> Bool {
        isLetter(u)
            || (u >= 48 && u <= 57)  // 0-9
            || u == 45               // -
            || u == 95               // _
    }
}
