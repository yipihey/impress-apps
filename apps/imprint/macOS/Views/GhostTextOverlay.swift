//
//  GhostTextOverlay.swift
//  imprint
//
//  Displays ghost text suggestions inline with the editor.
//  Ghost text appears faded after the cursor position.
//

import SwiftUI
import AppKit

/// Overlay view that displays ghost text suggestions.
///
/// This view is positioned absolutely over the text editor and shows
/// the AI-suggested completion text in a faded style.
struct GhostTextOverlay: View {
    let ghostText: String
    let cursorRect: CGRect
    let font: NSFont

    var body: some View {
        if !ghostText.isEmpty {
            Text(ghostText)
                .font(Font(font))
                .foregroundStyle(.secondary.opacity(0.5))
                .position(
                    x: cursorRect.maxX + textWidth / 2,
                    y: cursorRect.midY
                )
                .allowsHitTesting(false)
        }
    }

    private var textWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (ghostText as NSString).size(withAttributes: attributes)
        return size.width
    }
}

/// NSView subclass for rendering ghost text in an NSTextView.
///
/// This view is added as a subview of the text view and positioned
/// to appear after the cursor. It renders with a faded appearance.
class GhostTextNSView: NSView {

    // MARK: - Properties

    var ghostText: String = "" {
        didSet {
            needsDisplay = true
            isHidden = ghostText.isEmpty
        }
    }

    var textFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular) {
        didSet {
            needsDisplay = true
        }
    }

    var cursorPosition: NSPoint = .zero {
        didSet {
            updateFrame()
        }
    }

    var lineHeight: CGFloat = 17 {
        didSet {
            updateFrame()
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !ghostText.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.textColor.withAlphaComponent(0.4)
        ]

        ghostText.draw(at: .zero, withAttributes: attributes)
    }

    // MARK: - Layout

    private func updateFrame() {
        guard !ghostText.isEmpty else {
            frame = .zero
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let size = (ghostText as NSString).size(withAttributes: attributes)

        frame = NSRect(
            x: cursorPosition.x,
            y: cursorPosition.y,
            width: size.width + 4,
            height: lineHeight
        )
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Allow clicks to pass through to the text view
        return nil
    }
}

/// Extension to help position ghost text in an NSTextView.
extension NSTextView {

    /// Get the rect for the current cursor position.
    ///
    /// - Returns: The rect for the cursor, or zero rect if unavailable
    func cursorRect() -> NSRect {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return .zero
        }

        let selectedRange = selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)

        // Get the bounding rect for the insertion point
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphRange.location, length: 0), in: textContainer)

        // Adjust for text container origin
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y

        return rect
    }

    /// Get the point at the end of the current line (for ghost text positioning).
    ///
    /// - Returns: The point where ghost text should begin
    func endOfCurrentLinePoint() -> NSPoint {
        guard let layoutManager = layoutManager,
              let _ = textContainer else {
            return .zero
        }

        let selectedRange = selectedRange()
        let cursorIndex = selectedRange.location

        // Guard against empty document
        guard layoutManager.numberOfGlyphs > 0 else {
            return NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y)
        }

        // Get location of cursor character
        let safeIndex = min(cursorIndex, layoutManager.numberOfGlyphs - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeIndex)
        let location = layoutManager.location(forGlyphAt: glyphIndex)
        let lineFragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

        // Calculate position after cursor
        let point = NSPoint(
            x: lineFragmentRect.origin.x + location.x + textContainerOrigin.x,
            y: lineFragmentRect.origin.y + textContainerOrigin.y
        )

        return point
    }
}
