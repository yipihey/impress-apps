//
//  PresenceCursorView.swift
//  imprint
//
//  Renders collaborator cursor overlays in the editor.
//  Shows colored carets with name labels and selection highlights.
//

import SwiftUI
import AppKit

// MARK: - Presence Cursor View

/// Overlay view that renders a single collaborator's cursor and selection.
///
/// Features:
/// - Colored caret (insertion point) at cursor position
/// - Name label above cursor
/// - Translucent selection highlight
/// - Smooth animations for cursor movement
struct PresenceCursorView: View {
    let collaborator: CollaboratorPresence
    let textLayoutInfo: TextLayoutInfo

    @State private var isNameVisible = true
    @State private var animatedPosition: CGPoint = .zero

    /// Time to hide name label after inactivity
    private let nameHideDelay: TimeInterval = 3.0

    var body: some View {
        ZStack {
            // Selection highlight
            if let selection = collaborator.selection,
               let selectionRect = textLayoutInfo.rect(for: selection.start, end: selection.end) {
                SelectionHighlightView(
                    rect: selectionRect,
                    color: collaborator.color
                )
            }

            // Cursor and name label
            if let cursorPosition = collaborator.cursorPosition,
               let cursorRect = textLayoutInfo.rect(forCharacterAt: cursorPosition) {
                CursorWithLabel(
                    collaborator: collaborator,
                    rect: cursorRect,
                    isNameVisible: isNameVisible
                )
            }
        }
        .allowsHitTesting(false)
        .onChange(of: collaborator.cursorPosition) { _, _ in
            // Show name on cursor movement
            showNameTemporarily()
        }
        .onAppear {
            // Hide name after initial display
            scheduleNameHide()
        }
    }

    private func showNameTemporarily() {
        isNameVisible = true
        scheduleNameHide()
    }

    private func scheduleNameHide() {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(nameHideDelay * 1_000_000_000))
            withAnimation(.easeOut(duration: 0.2)) {
                isNameVisible = false
            }
        }
    }
}

// MARK: - Cursor With Label

/// The cursor caret with an optional name label.
struct CursorWithLabel: View {
    let collaborator: CollaboratorPresence
    let rect: CGRect
    let isNameVisible: Bool

    @State private var isBlinking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Name label
            if isNameVisible {
                Text(collaborator.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(collaborator.color)
                    )
                    .offset(x: -2, y: -4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }

            // Cursor caret
            Rectangle()
                .fill(collaborator.color)
                .frame(width: 2, height: rect.height)
                .opacity(isBlinking ? 1.0 : 0.6)
        }
        .position(x: rect.minX, y: rect.midY)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: rect.origin)
        .onAppear {
            startBlinking()
        }
    }

    private func startBlinking() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.1)) {
                isBlinking.toggle()
            }
        }
    }
}

// MARK: - Selection Highlight View

/// Translucent highlight for collaborator's text selection.
struct SelectionHighlightView: View {
    let rect: CGRect
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color.opacity(0.2))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .overlay(
                Rectangle()
                    .stroke(color.opacity(0.4), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            )
    }
}

// MARK: - Text Layout Info

/// Information about text layout needed for cursor positioning.
///
/// This is populated by the text view and provides geometry for
/// converting character positions to screen coordinates.
@Observable
class TextLayoutInfo {
    var layoutManager: NSLayoutManager?
    var textContainer: NSTextContainer?
    var containerOrigin: CGPoint = .zero

    /// Get the rect for a character at the given position.
    func rect(forCharacterAt position: Int) -> CGRect? {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return nil
        }

        // Ensure position is valid
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: position)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            // Return rect at end of text
            return rectAtEndOfText()
        }

        var glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )

        // Adjust for container origin
        glyphRect.origin.x += containerOrigin.x
        glyphRect.origin.y += containerOrigin.y

        return glyphRect
    }

    /// Get the rect for a selection range.
    func rect(for start: Int, end: Int) -> CGRect? {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return nil
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: start, length: end - start),
            actualCharacterRange: nil
        )

        var selectionRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )

        // Adjust for container origin
        selectionRect.origin.x += containerOrigin.x
        selectionRect.origin.y += containerOrigin.y

        return selectionRect
    }

    private func rectAtEndOfText() -> CGRect? {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return nil
        }

        let lastGlyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
        var rect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: lastGlyphIndex, length: 1),
            in: textContainer
        )

        rect.origin.x += containerOrigin.x + rect.width
        rect.origin.y += containerOrigin.y

        return rect
    }
}

// MARK: - Presence Cursors Overlay

/// Container view that renders all collaborator cursors.
///
/// Usage: Add as an overlay to the text editor view.
struct PresenceCursorsOverlay: View {
    var collaborationService: CollaborationService
    var textLayoutInfo: TextLayoutInfo

    var body: some View {
        ZStack {
            ForEach(collaborationService.collaborators) { collaborator in
                PresenceCursorView(
                    collaborator: collaborator,
                    textLayoutInfo: textLayoutInfo
                )
            }
        }
    }
}

// MARK: - NSTextView Extension for Presence

extension NSTextView {
    /// Create a TextLayoutInfo from this text view.
    func createTextLayoutInfo() -> TextLayoutInfo {
        let info = TextLayoutInfo()
        info.layoutManager = self.layoutManager
        info.textContainer = self.textContainer

        // Get the text container origin
        if let textContainer = self.textContainer {
            info.containerOrigin = CGPoint(
                x: textContainerOrigin.x,
                y: textContainerOrigin.y
            )
        }

        return info
    }

    /// Update cursor position in collaboration service.
    func updateCollaborationCursor() {
        let position = selectedRange().location
        let selection: (Int, Int)?

        if selectedRange().length > 0 {
            selection = (selectedRange().location, selectedRange().location + selectedRange().length)
        } else {
            selection = nil
        }

        Task { @MainActor in
            CollaborationService.shared.updateLocalCursor(position: position, selection: selection)
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        // Simulated text background
        Color(nsColor: .textBackgroundColor)

        // Demo cursors
        let demoLayout = TextLayoutInfo()

        VStack {
            Text("This simulates the presence cursor overlay")
                .font(.system(size: 14, design: .monospaced))
        }

        // Cursor overlays would go here
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Alice")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.blue))

                Rectangle()
                    .fill(.blue)
                    .frame(width: 2, height: 18)
            }
            .offset(x: 50, y: 20)

            HStack(spacing: 4) {
                Text("Bob")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.green))

                Rectangle()
                    .fill(.green)
                    .frame(width: 2, height: 18)
            }
            .offset(x: 150, y: 40)
        }
    }
    .frame(width: 400, height: 200)
}
