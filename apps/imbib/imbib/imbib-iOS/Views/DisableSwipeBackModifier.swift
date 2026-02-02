//
//  DisableSwipeBackModifier.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI
import UIKit

/// A view modifier that disables the iOS navigation swipe-back gesture.
///
/// This is needed when a view has swipe actions on the leading edge (swipe right)
/// that conflict with the navigation controller's interactive pop gesture.
///
/// Usage:
/// ```swift
/// List { ... }
///     .disableSwipeBack()
/// ```
struct DisableSwipeBackModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(DisableSwipeBackView())
    }
}

/// UIViewControllerRepresentable that disables the interactive pop gesture
private struct DisableSwipeBackView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DisableSwipeBackViewController {
        DisableSwipeBackViewController()
    }

    func updateUIViewController(_ uiViewController: DisableSwipeBackViewController, context: Context) {}
}

/// View controller that disables the navigation controller's pop gesture on appear
private class DisableSwipeBackViewController: UIViewController {

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Disable the interactive pop gesture recognizer early
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Ensure it stays disabled after view is fully visible
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Re-enable after view is fully gone
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }
}

/// A conditional version that only disables swipe-back when enabled
struct ConditionalDisableSwipeBackModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(DisableSwipeBackView())
                .background(DisableSplitViewGestureView())
        } else {
            content
        }
    }
}

// MARK: - Split View Controller Gesture Disabler

/// UIViewControllerRepresentable that disables the UISplitViewController's
/// primary column presentation gesture (the edge swipe to reveal sidebar).
///
/// This is essential for inbox views with swipe-right-to-keep actions,
/// as the NavigationSplitView's sidebar reveal gesture conflicts with
/// the List's swipe actions.
private struct DisableSplitViewGestureView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DisableSplitViewGestureViewController {
        DisableSplitViewGestureViewController()
    }

    func updateUIViewController(_ uiViewController: DisableSplitViewGestureViewController, context: Context) {}
}

/// View controller that finds and disables the split view controller's presentation gesture
private class DisableSplitViewGestureViewController: UIViewController {

    private var disabledGestures: [UIGestureRecognizer] = []
    private weak var cachedSplitVC: UISplitViewController?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        disableSplitViewGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Ensure gestures stay disabled after view is fully visible
        disableSplitViewGesture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        restoreSplitViewGesture()
    }

    private func disableSplitViewGesture() {
        // Find the split view controller in the hierarchy
        var current: UIViewController? = self
        while let vc = current {
            if let split = vc as? UISplitViewController {
                cachedSplitVC = split

                // Disable the presentation gesture by finding and disabling
                // edge pan gesture recognizers on the split view controller's view
                // and all parent views up to the window
                disableEdgePanGestures(in: split.view)

                // Also check the view controller's view hierarchy
                if let window = split.view.window {
                    disableEdgePanGestures(in: window)
                }
                break
            }
            current = vc.parent
        }

        // Also check our own view hierarchy for any edge pan gestures
        if let window = view.window {
            disableEdgePanGestures(in: window)
        }
    }

    private func disableEdgePanGestures(in view: UIView) {
        // The UISplitViewController uses a screen edge pan gesture recognizer
        // to show/hide the primary column. We need to disable it.
        for gestureRecognizer in view.gestureRecognizers ?? [] {
            if let edgePan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer {
                // Disable left edge gestures (sidebar reveal) and right edge gestures
                // to prevent any navigation interference with swipe actions
                if edgePan.edges.contains(.left) || edgePan.edges.contains(.right) {
                    if edgePan.isEnabled && !disabledGestures.contains(where: { $0 === edgePan }) {
                        edgePan.isEnabled = false
                        disabledGestures.append(edgePan)
                    }
                }
            }
        }

        // Also check subviews (the gesture might be on a container view)
        for subview in view.subviews {
            disableEdgePanGestures(in: subview)
        }
    }

    private func restoreSplitViewGesture() {
        // Re-enable all gestures we disabled
        for gesture in disabledGestures {
            gesture.isEnabled = true
        }
        disabledGestures.removeAll()
    }
}

extension View {
    /// Disables the iOS navigation swipe-back gesture for this view.
    ///
    /// Use this on list views with leading-edge swipe actions (swipe right)
    /// to prevent conflict with the navigation back gesture.
    func disableSwipeBack() -> some View {
        modifier(DisableSwipeBackModifier())
    }

    /// Conditionally disables the iOS navigation swipe-back gesture.
    ///
    /// - Parameter condition: When true, disables the swipe-back gesture
    func disableSwipeBack(when condition: Bool) -> some View {
        modifier(ConditionalDisableSwipeBackModifier(isEnabled: condition))
    }
}
