//
//  ScopeBracketOverlay.swift
//  imprint
//
//  Mathematica-style left-margin structural scope brackets drawn over the source editor.
//
//  Each visible scope level is drawn as a thin vertical bar with small horizontal
//  serifs at the top and bottom, positioned in the left margin of the text view.
//  Brackets are invisible at rest; they fade in on hover or during scope-keyed selection.
//
//  Architecture:
//    ScopeBracketOverlay (NSView, placed as sibling of TypstTextView inside the scroll view)
//      └── Draws brackets using Core Graphics in drawRect
//      └── NSTrackingArea for hover detection
//      └── Observes ScopeSelectionController for active scope changes
//

import AppKit
import SwiftUI

// MARK: - Scope Bracket Overlay

/// Transparent NSView overlay that draws structural scope brackets in the left margin.
///
/// Position this view at the same frame as the text view it annotates, but with
/// a pointer-events pass-through so it doesn't block text interaction.
final class ScopeBracketOverlay: NSView {

    // MARK: - Configuration

    /// Width of the bracket area in the left margin.
    static let marginWidth: CGFloat = 28

    /// Horizontal spacing between nested bracket levels (rightmost = finest scope).
    private let levelSpacing: CGFloat = 5

    /// Width of the vertical bar.
    private let barWidth: CGFloat = 1.5

    /// Length of the horizontal serif at each cap.
    private let serifLength: CGFloat = 5

    /// Opacity when bracket is not hovered/active (0 = invisible).
    private let restingOpacity: CGFloat = 0

    /// Opacity when the bracket is hovered.
    private let hoveredOpacity: CGFloat = 0.7

    /// Opacity when the bracket is the currently active (keyboard-selected) scope.
    private let activeOpacity: CGFloat = 1.0

    // MARK: - State

    /// The scope levels to draw. Set from SourceEditorView/Coordinator.
    var visibleScopes: [TextScope] = [] {
        didSet { needsDisplay = true }
    }

    /// The currently keyboard-active scope level (if any).
    var activeScope: TextScope? {
        didSet { needsDisplay = true }
    }

    /// The scope level the mouse is currently hovering over (nil = none).
    private var hoveredScopeLevel: ScopeLevel? {
        didSet { needsDisplay = true }
    }

    /// Called when a bracket is clicked — passes back the tapped scope level.
    var onScopeClicked: ((TextScope) -> Void)?

    // MARK: - Text View Reference

    /// Weak reference to the text view to compute bracket y-coordinates.
    weak var textView: NSTextView?

    // MARK: - Hover Fade

    /// Whether brackets are currently in their "hover visible" state.
    private var isHovered: Bool = false {
        didSet {
            if oldValue != isHovered {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    ctx.allowsImplicitAnimation = true
                    needsDisplay = true
                }
            }
        }
    }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTracking()
    }

    private func setupTracking() {
        // Pass through mouse events to the text view beneath
        // NSView.isOpaque = false already, but also make it non-blocking
        // by overriding hitTest below.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Hit Testing

    /// Only intercept hits on the bracket margin area; pass all others through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if point.x < Self.marginWidth {
            return self
        }
        return nil
    }

    // MARK: - Mouse Tracking

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoveredScopeLevel = nil
        toolTip = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredScope(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hovered = hoveredScopeLevel,
           let scope = visibleScopes.first(where: { $0.level == hovered }) {
            onScopeClicked?(scope)
        }
    }

    private func updateHoveredScope(at point: NSPoint) {
        guard !visibleScopes.isEmpty, let textView = textView else {
            hoveredScopeLevel = nil
            toolTip = nil
            return
        }

        // Check which bracket column the mouse is in
        for scope in visibleScopes.reversed() { // front-to-back
            let bracketX = bracketX(for: scope.level)
            if abs(point.x - bracketX) < 8 {
                // Check if y is within the bracket's vertical extent
                if let (topY, bottomY) = bracketYRange(for: scope, in: textView) {
                    let (visTopY, visBottomY) = clampToVisibleRect(topY: topY, bottomY: bottomY)
                    if point.y >= visBottomY && point.y <= visTopY {
                        hoveredScopeLevel = scope.level
                        toolTip = scopeTooltip(scope)
                        return
                    }
                }
            }
        }
        hoveredScopeLevel = nil
        toolTip = nil
    }

    /// Build the tooltip string for a scope bracket.
    private func scopeTooltip(_ scope: TextScope) -> String {
        let levelName = scope.level.description.capitalized
        if let label = scope.label, !label.isEmpty {
            return "\(levelName): \(label)\nClick to select"
        }
        return "\(levelName)\nClick to select"
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !visibleScopes.isEmpty, let textView = textView else { return }

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()

        for scope in visibleScopes {
            guard let (topY, bottomY) = bracketYRange(for: scope, in: textView) else { continue }
            drawBracket(scope: scope, topY: topY, bottomY: bottomY, in: context)
        }

        context?.restoreGState()
    }

    private func drawBracket(scope: TextScope, topY: CGFloat, bottomY: CGFloat, in context: CGContext?) {
        guard let ctx = context else { return }

        let x = bracketX(for: scope.level)
        let (clampedTop, clampedBottom) = clampToVisibleRect(topY: topY, bottomY: bottomY)

        // Determine opacity
        var opacity: CGFloat
        if activeScope?.level == scope.level {
            opacity = activeOpacity
        } else if hoveredScopeLevel == scope.level {
            opacity = hoveredOpacity
        } else if isHovered {
            opacity = 0.25  // dim visible when hovering the margin
        } else {
            opacity = restingOpacity
        }

        guard opacity > 0 else { return }

        let color = bracketColor(for: scope.level).withAlphaComponent(opacity)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(barWidth)
        ctx.setLineCap(.round)

        // Vertical bar
        ctx.move(to: CGPoint(x: x, y: clampedTop))
        ctx.addLine(to: CGPoint(x: x, y: clampedBottom))
        ctx.strokePath()

        // Top serif (only if bracket top is visible)
        if clampedTop >= topY - 2 {
            ctx.move(to: CGPoint(x: x, y: clampedTop))
            ctx.addLine(to: CGPoint(x: x + serifLength, y: clampedTop))
            ctx.strokePath()
        }

        // Bottom serif (only if bracket bottom is visible)
        if clampedBottom <= bottomY + 2 {
            ctx.move(to: CGPoint(x: x, y: clampedBottom))
            ctx.addLine(to: CGPoint(x: x + serifLength, y: clampedBottom))
            ctx.strokePath()
        }

        // Label tooltip region — no drawing needed, handled by tooltip
    }

    // MARK: - Geometry Helpers

    /// X position for a given scope level in the left margin (finer scopes are rightmost).
    private func bracketX(for level: ScopeLevel) -> CGFloat {
        // document = leftmost (x=4), word = rightmost (x=4 + 6*5 = 34)
        // But we clamp to marginWidth
        let maxLevel = ScopeLevel.document.rawValue
        let normalizedPosition = CGFloat(maxLevel - level.rawValue) // 0 = finest (word), 6 = coarsest (document)
        let x = 4.0 + normalizedPosition * levelSpacing
        return x
    }

    /// Returns the (top, bottom) y-coordinates in overlay-view coordinates for a scope's range.
    /// NSTextView and NSView use flipped coordinates — top > bottom numerically in flipped views.
    private func bracketYRange(for scope: TextScope, in textView: NSTextView) -> (CGFloat, CGFloat)? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }

        let nsSource = textView.string as NSString
        let length = nsSource.length
        guard scope.range.location <= length else { return nil }

        let safeRange = NSRange(
            location: scope.range.location,
            length: min(scope.range.length, length - scope.range.location)
        )
        guard safeRange.length > 0 else { return nil }

        // Get bounding rect in text container coordinates
        var glyphRange = NSRange()
        layoutManager.characterRange(forGlyphRange: safeRange, actualGlyphRange: &glyphRange)
        let textContainerRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        // Convert to textView coordinates, then to overlay coordinates
        let tvOrigin = textView.textContainerOrigin
        let topInTV = textContainerRect.minY + tvOrigin.y
        let bottomInTV = textContainerRect.maxY + tvOrigin.y

        // Convert from textView to overlay coordinates
        let topPoint = convert(NSPoint(x: 0, y: topInTV), from: textView)
        let bottomPoint = convert(NSPoint(x: 0, y: bottomInTV), from: textView)

        return (topPoint.y, bottomPoint.y)
    }

    /// Clamp bracket extent to visible rect (for scrolled views).
    private func clampToVisibleRect(topY: CGFloat, bottomY: CGFloat) -> (CGFloat, CGFloat) {
        let visRect = visibleRect
        // In AppKit default (non-flipped) coords: larger y = higher on screen.
        // visibleRect.minY = bottom, visibleRect.maxY = top.
        let clampedTop = min(topY, visRect.maxY)
        let clampedBottom = max(bottomY, visRect.minY)
        return (clampedTop, clampedBottom)
    }

    /// Color for each scope level. Finer scopes are more muted; coarser are more saturated.
    private func bracketColor(for level: ScopeLevel) -> NSColor {
        switch level {
        case .word:           return NSColor.systemBlue.withAlphaComponent(0.5)
        case .sentence:       return NSColor.systemBlue.withAlphaComponent(0.6)
        case .paragraph:      return NSColor.systemIndigo.withAlphaComponent(0.7)
        case .subsection:     return NSColor.systemPurple.withAlphaComponent(0.75)
        case .section:        return NSColor.systemPurple.withAlphaComponent(0.85)
        case .chapter:        return NSColor.systemTeal.withAlphaComponent(0.9)
        case .document:       return NSColor.systemGray.withAlphaComponent(0.5)
        }
    }
}

// MARK: - SwiftUI Hosting

/// SwiftUI-side representable for inserting the bracket overlay into a view hierarchy.
struct ScopeBracketOverlayView: NSViewRepresentable {
    var scopes: [TextScope]
    var activeScope: TextScope?
    var textView: NSTextView?
    var onScopeClicked: (TextScope) -> Void

    func makeNSView(context: Context) -> ScopeBracketOverlay {
        let overlay = ScopeBracketOverlay()
        overlay.onScopeClicked = onScopeClicked
        return overlay
    }

    func updateNSView(_ nsView: ScopeBracketOverlay, context: Context) {
        nsView.visibleScopes = scopes
        nsView.activeScope = activeScope
        nsView.textView = textView
        nsView.needsDisplay = true
    }
}
