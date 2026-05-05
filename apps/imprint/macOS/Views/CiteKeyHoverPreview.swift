//
//  CiteKeyHoverPreview.swift
//  imprint
//
//  Hover-triggered popover that shows a quick preview of a cited paper
//  (title, authors, year, abstract excerpt, notes excerpt) when the user
//  hovers over `\cite{key}` or `@key` in the source editor.
//

import AppKit
import ImbibRustCore
import SwiftUI

// MARK: - Popover content

/// SwiftUI view shown inside the hover preview popover.
struct CiteKeyHoverView: View {
    let row: BibliographyRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: cite key + year + starred/pdf indicators
            HStack(spacing: 6) {
                Text(row.citeKey)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let y = row.year {
                    Text("· \(y)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.hasDownloadedPdf {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                }
                if row.isStarred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                }
            }

            // Title
            Text(row.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // Authors
            if !row.authorString.isEmpty {
                Text(row.authorString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Venue
            if let venue = row.venue, !venue.isEmpty {
                Text(venue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .italic()
            }

            // Abstract excerpt
            if let abs = row.abstractText, !abs.isEmpty {
                Divider()
                Text(String(abs.prefix(280)) + (abs.count > 280 ? "…" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Notes excerpt
            if let note = row.note, !note.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.tertiary)
                        .font(.caption2)
                    Text(String(note.prefix(200)) + (note.count > 200 ? "…" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Open in paper panel button (Track E integration)
            Divider()
            HStack {
                Spacer()
                Button {
                    NotificationCenter.default.post(
                        name: .openPaperPanel,
                        object: nil,
                        userInfo: ["publicationID": row.id]
                    )
                } label: {
                    Label("Open in paper panel", systemImage: "square.split.2x1")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial)
    }
}

// MARK: - Controller

/// Manages the lifecycle of the hover preview popover.
@MainActor
final class CiteKeyHoverController {
    private var popover: NSPopover?
    private var currentKey: String?
    private weak var currentTextView: NSTextView?
    private var debounceTask: Task<Void, Never>?

    /// Show (or update) the hover preview at the given character range.
    func show(
        in textView: NSTextView,
        citeKey: String,
        range: NSRange
    ) {
        // If already showing for this key, nothing to do
        if currentKey == citeKey, popover?.isShown == true { return }

        // Debounce: short delay so the preview feels instant but we don't thrash
        // the popover system on every mouseMoved event.
        debounceTask?.cancel()
        let key = citeKey
        let targetRange = range
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            await MainActor.run {
                self?.presentPopover(in: textView, citeKey: key, range: targetRange)
            }
        }
    }

    /// Dismiss the popover if visible.
    func dismiss() {
        debounceTask?.cancel()
        debounceTask = nil
        popover?.close()
        popover = nil
        currentKey = nil
        currentTextView = nil
    }

    // MARK: - Private

    private func presentPopover(in textView: NSTextView, citeKey: String, range: NSRange) {
        // Look up the paper directly via the shared Rust store — no HTTP
        guard let row = ImprintPublicationService.shared.findByCiteKey(citeKey) else {
            // No match — optionally show "not in imbib" popover, but for simplicity just skip
            return
        }

        // Close any previous popover
        popover?.close()

        let content = CiteKeyHoverView(row: row)
        let hosting = NSHostingController(rootView: content)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 420, height: 200)

        let pop = NSPopover()
        pop.contentViewController = hosting
        pop.behavior = .transient
        pop.animates = false
        self.popover = pop
        self.currentKey = citeKey
        self.currentTextView = textView

        // Anchor to the cite-key rect
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard let window = textView.window else { return }
        let windowRect = window.convertFromScreen(screenRect)
        var viewRect = textView.convert(windowRect, from: nil)
        if viewRect.size.width == 0 { viewRect.size.width = 2 }
        if viewRect.size.height == 0 { viewRect.size.height = 16 }

        pop.show(relativeTo: viewRect, of: textView, preferredEdge: .maxY)
    }
}

// MARK: - Cite-key detection at a character index

/// Utilities for finding whether a character index falls inside a `\cite{key}`
/// or `@key` pattern, and returning the key + its range.
enum CiteKeyAtLocation {
    /// Scan the source for a cite key that covers `location`. Returns (key, range) or nil.
    static func find(in source: String, at location: Int, format: DocumentFormat) -> (key: String, range: NSRange)? {
        switch format {
        case .latex: return findLatex(in: source, at: location)
        case .typst: return findTypst(in: source, at: location)
        }
    }

    private static func findLatex(in source: String, at location: Int) -> (key: String, range: NSRange)? {
        let ns = source as NSString
        guard location >= 0, location < ns.length else { return nil }

        // Walk backwards for `{`, then ensure it's after a cite* command, then scan forward for `}`.
        var i = location
        // Move into the braces region if we're sitting on them
        while i >= 0 {
            let u = ns.character(at: i)
            if u == 125 /* } */ { return nil }
            if u == 123 /* { */ {
                // Check the command before this brace
                guard i > 0 else { return nil }
                var j = i - 1
                while j >= 0 {
                    let cu = ns.character(at: j)
                    if (cu >= 97 && cu <= 122) || (cu >= 65 && cu <= 90) || cu == 42 {
                        j -= 1
                    } else { break }
                }
                guard j >= 0, ns.character(at: j) == 92 /* \ */ else { return nil }
                let commandName = ns.substring(with: NSRange(location: j + 1, length: i - (j + 1))).lowercased()
                let isCite = commandName.hasPrefix("cite")
                    || commandName.hasPrefix("parencite")
                    || commandName.hasPrefix("textcite")
                    || commandName.hasPrefix("autocite")
                    || commandName.hasPrefix("footcite")
                    || commandName.hasPrefix("smartcite")
                    || commandName.hasPrefix("supercite")
                    || commandName.hasPrefix("nocite")
                guard isCite else { return nil }
                // Scan forward from i+1 to find the closing `}`, tracking commas
                var k = i + 1
                var keyStart = k
                var keyRange: NSRange? = nil
                while k < ns.length {
                    let kc = ns.character(at: k)
                    if kc == 125 /* } */ {
                        if location >= keyStart && location <= k {
                            let key = ns.substring(with: NSRange(location: keyStart, length: k - keyStart)).trimmingCharacters(in: .whitespaces)
                            if !key.isEmpty {
                                keyRange = NSRange(location: keyStart, length: k - keyStart)
                                return (key, keyRange!)
                            }
                        }
                        return nil
                    }
                    if kc == 44 /* , */ {
                        if location >= keyStart && location < k {
                            let key = ns.substring(with: NSRange(location: keyStart, length: k - keyStart)).trimmingCharacters(in: .whitespaces)
                            if !key.isEmpty { return (key, NSRange(location: keyStart, length: k - keyStart)) }
                        }
                        keyStart = k + 1
                        while keyStart < ns.length, ns.character(at: keyStart) == 32 || ns.character(at: keyStart) == 9 {
                            keyStart += 1
                        }
                    }
                    k += 1
                }
                return nil
            }
            i -= 1
            // Don't scan too far back — limit to 200 chars for performance
            if location - i > 200 { return nil }
        }
        return nil
    }

    private static func findTypst(in source: String, at location: Int) -> (key: String, range: NSRange)? {
        let ns = source as NSString
        guard location >= 0, location < ns.length else { return nil }

        // Walk backwards to find `@`, ensuring we stay on valid cite-key chars
        var i = location
        while i >= 0 {
            let u = ns.character(at: i)
            if u == 64 /* @ */ {
                // Scan forward for end of key
                var k = i + 1
                while k < ns.length {
                    let kc = ns.character(at: k)
                    let isKey = (kc >= 97 && kc <= 122) || (kc >= 65 && kc <= 90) || (kc >= 48 && kc <= 57) || kc == 45 || kc == 95
                    if !isKey { break }
                    k += 1
                }
                if k <= i + 1 { return nil }
                let keyRange = NSRange(location: i + 1, length: k - (i + 1))
                // Check location falls within @keyrange (inclusive of @)
                if location >= i && location < k {
                    let key = ns.substring(with: keyRange)
                    return (key, keyRange)
                }
                return nil
            }
            let isKeyChar = (u >= 97 && u <= 122) || (u >= 65 && u <= 90) || (u >= 48 && u <= 57) || u == 45 || u == 95
            if !isKeyChar { return nil }
            i -= 1
            if location - i > 80 { return nil }
        }
        return nil
    }
}
