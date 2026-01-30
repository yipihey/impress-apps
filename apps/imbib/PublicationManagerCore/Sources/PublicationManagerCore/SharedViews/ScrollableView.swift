//
//  ScrollableView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Half Page Scroll Modifier (macOS)

/// A view modifier that enables half-page scrolling via j/k keys in the enclosing scroll view.
///
/// This modifier listens for scroll notifications and scrolls the nearest enclosing NSScrollView
/// by half the visible viewport height.
///
/// Usage:
/// ```swift
/// ScrollView {
///     // content
/// }
/// .halfPageScrollable()
/// .onKeyPress { press in
///     if press.characters == "j" {
///         NotificationCenter.default.post(name: .scrollDetailDown, object: nil)
///         return .handled
///     }
///     // ...
/// }
/// ```
public struct HalfPageScrollModifier: ViewModifier {
    @State private var scrollViewFinder = ScrollViewFinder()

    public func body(content: Content) -> some View {
        content
            .background(
                ScrollViewFinderView(finder: scrollViewFinder)
            )
            .onReceive(NotificationCenter.default.publisher(for: .scrollDetailDown)) { _ in
                scrollViewFinder.scrollHalfPageDown()
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollDetailUp)) { _ in
                scrollViewFinder.scrollHalfPageUp()
            }
    }
}

/// Helper class to find and control the enclosing NSScrollView
private class ScrollViewFinder: ObservableObject {
    weak var scrollView: NSScrollView?

    func scrollHalfPageDown() {
        guard let scrollView = scrollView else { return }

        let visibleHeight = scrollView.contentView.bounds.height
        var newOrigin = scrollView.contentView.bounds.origin
        newOrigin.y += visibleHeight / 2

        // Clamp to document bounds
        if let documentView = scrollView.documentView {
            let maxY = documentView.bounds.height - visibleHeight
            newOrigin.y = min(newOrigin.y, max(0, maxY))
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().scroll(to: newOrigin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollHalfPageUp() {
        guard let scrollView = scrollView else { return }

        let visibleHeight = scrollView.contentView.bounds.height
        var newOrigin = scrollView.contentView.bounds.origin
        newOrigin.y -= visibleHeight / 2

        // Clamp to document bounds
        newOrigin.y = max(0, newOrigin.y)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().scroll(to: newOrigin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// NSViewRepresentable that finds the enclosing NSScrollView
private struct ScrollViewFinderView: NSViewRepresentable {
    let finder: ScrollViewFinder

    func makeNSView(context: Context) -> NSView {
        let view = ScrollViewFinderNSView()
        view.finder = finder
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Custom NSView that walks the view hierarchy to find the enclosing NSScrollView
private class ScrollViewFinderNSView: NSView {
    weak var finder: ScrollViewFinder?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.findScrollView()
        }
    }

    private func findScrollView() {
        var current: NSView? = self
        while let view = current {
            if let scrollView = view as? NSScrollView {
                finder?.scrollView = scrollView
                return
            }
            current = view.superview
        }
    }
}

// MARK: - View Extension

public extension View {
    /// Enables half-page scrolling via j/k notifications in the enclosing scroll view.
    ///
    /// Add this modifier to any view inside a ScrollView to enable vim-style
    /// half-page scrolling when `.scrollDetailDown` or `.scrollDetailUp` notifications
    /// are posted.
    func halfPageScrollable() -> some View {
        modifier(HalfPageScrollModifier())
    }
}

#else

// MARK: - Half Page Scroll Modifier (iOS)

/// iOS implementation - no-op since touch scrolling is the primary interaction.
public struct HalfPageScrollModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
    }
}

public extension View {
    /// iOS: No-op modifier - touch scrolling is the primary interaction.
    func halfPageScrollable() -> some View {
        modifier(HalfPageScrollModifier())
    }
}

#endif
