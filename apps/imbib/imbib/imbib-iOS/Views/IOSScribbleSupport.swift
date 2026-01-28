//
//  IOSScribbleSupport.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-28.
//

import UIKit
import SwiftUI

// MARK: - Scribble Support

/// Adds Apple Pencil Scribble support to imbib's text editors.
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

// MARK: - Scribble Configuration

/// Configuration options for Scribble behavior in imbib.
public struct ScribbleConfiguration {
    /// Whether to show a visual indicator when Scribble is active
    public var showActiveIndicator = true

    /// Whether to enable scratch-to-delete gesture
    public var enableScratchToDelete = true

    /// Whether to enable tap-and-hold selection
    public var enableTapHoldSelection = true

    /// Text container insets for comfortable Pencil writing
    public var writingInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

    /// Default configuration
    public static let `default` = ScribbleConfiguration()
}

// MARK: - UITextView Extension

extension UITextView {

    /// Configures the text view for optimal Scribble interaction.
    func setupScribbleInteraction(configuration: ScribbleConfiguration = .default) {
        // UITextView has automatic Scribble support.
        // We just ensure the view is properly configured.
        isUserInteractionEnabled = true
        isEditable = true

        // Scribble works best with generous touch targets
        textContainerInset = configuration.writingInsets
    }
}

// MARK: - Scribble Gesture Recognizers

/// A gesture recognizer for detecting Apple Pencil scratch-to-delete gestures.
///
/// This provides a custom implementation that can be used alongside system Scribble.
class ScratchToDeleteGestureRecognizer: UIGestureRecognizer {

    /// Points in the current stroke
    private var strokePoints: [CGPoint] = []

    /// Minimum points to detect a scratch
    private let minimumPoints = 20

    /// Maximum width for a scratch gesture
    private let maxWidth: CGFloat = 100

    /// Callback when scratch gesture is detected
    var onScratchDetected: ((CGRect) -> Void)?

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
            // Calculate bounding rect of scratch
            let bounds = scratchBounds()
            onScratchDetected?(bounds)
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

    /// Calculate the bounding rectangle of the scratch gesture.
    private func scratchBounds() -> CGRect {
        guard !strokePoints.isEmpty else { return .zero }

        let minX = strokePoints.map { $0.x }.min() ?? 0
        let maxX = strokePoints.map { $0.x }.max() ?? 0
        let minY = strokePoints.map { $0.y }.min() ?? 0
        let maxY = strokePoints.map { $0.y }.max() ?? 0

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Scribble Status View

/// A small indicator showing when Scribble is active.
struct ScribbleStatusIndicator: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "pencil.tip")
                .font(.caption)
            Text("Scribble")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .opacity(isActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

// MARK: - Preview

#Preview("Scribble Status Indicator") {
    VStack(spacing: 20) {
        ScribbleStatusIndicator(isActive: true)
        ScribbleStatusIndicator(isActive: false)
    }
    .padding()
}
