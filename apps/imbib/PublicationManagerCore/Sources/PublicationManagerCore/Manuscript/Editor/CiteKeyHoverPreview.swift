//
//  CiteKeyHoverPreview.swift
//  imprint
//
//  Hover-triggered popover that shows a quick preview of a cited paper
//  (title, authors, year, abstract excerpt, notes excerpt) when the user
//  hovers over `\cite{key}` or `@key` in the source editor.
//

#if os(macOS)
import AppKit
import ImbibRustCore
import SwiftUI

// MARK: - Popover content

/// SwiftUI view shown inside the hover preview popover.
struct CiteKeyHoverView: View {
    let row: BibliographyRow
    /// Called when the pointer enters (true) or leaves (false) the popover
    /// content. The controller uses this to keep the popover alive while the
    /// user is travelling toward — or reading — it.
    var onHoverChanged: (Bool) -> Void = { _ in }

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
        .onHover { onHoverChanged($0) }
    }
}

// MARK: - Controller

/// Manages the lifecycle of the hover preview popover.
///
/// The popover is anchored *below* the cite key, so reaching its
/// "Open in paper panel" button means the pointer must leave the cite-key
/// characters and cross a gap of ordinary text. A naive dismiss-on-exit
/// therefore makes the button unreachable — the popover vanishes the moment
/// the user moves toward it. Two things keep it alive:
///
///   1. Leaving the key schedules a *deferred* close (`scheduleDismiss`)
///      rather than closing immediately, giving the pointer time to travel.
///   2. Hovering the popover content cancels that pending close entirely
///      (`popoverHoverChanged`), so it stays up as long as it is being read.
///
/// Only `dismiss()` closes immediately; it is for genuine teardown (editor
/// disappearing, document switching).
@MainActor
final class CiteKeyHoverController {
    /// Grace period after the pointer leaves the cite key before the popover
    /// closes. Long enough to cross the anchor gap without feeling sticky.
    private static let dismissGrace: Duration = .milliseconds(350)

    private var popover: NSPopover?
    private var currentKey: String?
    private weak var currentTextView: NSTextView?
    private var debounceTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    /// True while the pointer is inside the popover content.
    private var pointerInsidePopover = false

    /// Show (or update) the hover preview at the given character range.
    func show(
        in textView: NSTextView,
        citeKey: String,
        range: NSRange
    ) {
        // Any hover over a cite key cancels a pending close.
        dismissTask?.cancel()
        dismissTask = nil

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

    /// Close after a short grace period, unless the pointer reaches the popover
    /// (or returns to the cite key) first. Use this for every pointer-driven
    /// exit; use `dismiss()` only for hard teardown.
    func scheduleDismiss() {
        // A pending open that never got to show should just be abandoned.
        debounceTask?.cancel()
        debounceTask = nil

        guard popover?.isShown == true else {
            dismiss()
            return
        }
        guard dismissTask == nil else { return }  // already counting down

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dismissGrace)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.dismissTask = nil
                // The pointer made it into the popover — it stays until the
                // pointer leaves again, which re-enters this path.
                if self.pointerInsidePopover { return }
                self.dismiss()
            }
        }
    }

    /// Called from the popover's SwiftUI content as the pointer enters/leaves.
    func popoverHoverChanged(_ inside: Bool) {
        pointerInsidePopover = inside
        if inside {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleDismiss()
        }
    }

    /// Dismiss the popover immediately.
    func dismiss() {
        debounceTask?.cancel()
        debounceTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        pointerInsidePopover = false
        popover?.close()
        popover = nil
        currentKey = nil
        currentTextView = nil
    }

    // MARK: - Private

    private func presentPopover(in textView: NSTextView, citeKey: String, range: NSRange) {
        // Look up the paper via the host-provided citation search (nil → skip).
        guard let row = ManuscriptEditorEnvironment.shared.citationSearch?.findByCiteKey(citeKey) else {
            // No match / no search backing — optionally show "not in imbib" popover,
            // but for simplicity just skip.
            return
        }

        // Close any previous popover
        popover?.close()
        pointerInsidePopover = false

        let content = CiteKeyHoverView(row: row) { [weak self] inside in
            self?.popoverHoverChanged(inside)
        }
        let hosting = NSHostingController(rootView: content)
        // Size to the content: a fixed height clips tall previews, and the
        // "Open in paper panel" button is the last thing in the stack — it is
        // exactly what gets cut off.
        hosting.sizingOptions = .preferredContentSize
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

// MARK: - Cite-key detection
//
// There is deliberately NO detection code in this file. It used to hold
// `CiteKeyAtLocation`, a hand-rolled Swift copy of the cite-key grammar, and
// that copy had already drifted: it previewed Typst's `@param` / `@available`
// annotations and the domain half of `ada@example.org` as citations, because it
// only knew "an `@` followed by key characters".
//
// Hit-testing now goes through `ManuscriptCiteKeyLocator`, which forwards to
// `imprint_core::citations::hit` — derived from `citations::extract`, the one
// scanner that also backs the compile-time bibliography, the usage index and
// the iOS long-press. Detection cannot drift from the scanner because there is
// no second copy of the grammar to drift from. See `CiteKeyDetectionParityTests`.

#endif // os(macOS)
