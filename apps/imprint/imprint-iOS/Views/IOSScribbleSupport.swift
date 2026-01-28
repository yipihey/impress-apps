//
//  IOSScribbleSupport.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import UIKit
import SwiftUI

// MARK: - Scribble Support

/// Adds Apple Pencil Scribble support to imprint's text editor.
///
/// Scribble allows users to write anywhere in the editor with Apple Pencil,
/// and the handwriting is automatically converted to typed text.
///
/// UITextView has built-in Scribble support that activates automatically when:
/// - isUserInteractionEnabled is true
/// - isEditable is true
/// - The user has an Apple Pencil
///
/// Features supported out of the box:
/// - Write anywhere to insert text at cursor
/// - Scratch out text to delete it
/// - Tap and hold to select text
/// - Circle to select word
/// - Strikethrough to delete
extension SourceTextView {

    /// Configures Scribble behavior for the text view.
    func setupScribbleInteraction() {
        // UITextView has automatic Scribble support.
        // We just ensure the view is properly configured.
        isUserInteractionEnabled = true
        isEditable = true

        // Scribble works best with generous touch targets
        textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    }
}

// MARK: - Scribble Configuration

/// Configuration options for Scribble behavior in imprint.
public struct ScribbleConfiguration {
    /// Whether to show a visual indicator when Scribble is active
    public var showActiveIndicator = true

    /// Whether to enable scratch-to-delete
    public var enableScratchToDelete = true

    /// Whether to enable tap-and-hold selection
    public var enableTapHoldSelection = true

    /// Default configuration
    public static let `default` = ScribbleConfiguration()
}

// MARK: - Scribble Gesture Recognizers

/// A gesture recognizer for detecting Apple Pencil scratch-to-delete gestures.
class ScratchToDeleteGestureRecognizer: UIGestureRecognizer {

    /// Points in the current stroke
    private var strokePoints: [CGPoint] = []

    /// Minimum points to detect a scratch
    private let minimumPoints = 20

    /// Maximum width for a scratch gesture
    private let maxWidth: CGFloat = 100

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first,
              touch.type == .pencil else {
            state = .failed
            return
        }

        strokePoints = [touch.location(in: view)]
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }

        strokePoints.append(touch.location(in: view))
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if isScratchGesture() {
            state = .recognized
        } else {
            state = .failed
        }
        strokePoints = []
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
        strokePoints = []
    }

    override func reset() {
        strokePoints = []
    }

    /// Determines if the stroke pattern matches a scratch gesture.
    private func isScratchGesture() -> Bool {
        guard strokePoints.count >= minimumPoints else { return false }

        // Check if the stroke has multiple direction changes (zig-zag)
        var directionChanges = 0
        var previousDirection: CGFloat?

        for i in 1..<strokePoints.count {
            let dx = strokePoints[i].x - strokePoints[i-1].x

            if let prevDir = previousDirection {
                if (dx > 0 && prevDir < 0) || (dx < 0 && prevDir > 0) {
                    directionChanges += 1
                }
            }
            previousDirection = dx
        }

        // Check width of gesture
        let minX = strokePoints.map { $0.x }.min() ?? 0
        let maxX = strokePoints.map { $0.x }.max() ?? 0
        let width = maxX - minX

        // A scratch gesture has many direction changes and is not too wide
        return directionChanges >= 3 && width < maxWidth
    }
}

// MARK: - Preview

#Preview("Source Editor with Scribble") {
    IOSSourceEditorView(
        text: .constant("Write here with Apple Pencil..."),
        selection: .constant(nil)
    )
    .padding()
}
