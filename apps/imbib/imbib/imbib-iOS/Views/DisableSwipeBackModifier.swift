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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Disable the interactive pop gesture recognizer
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Re-enable when leaving this view
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

    private var gestureWasEnabled: Bool?
    private weak var cachedSplitVC: UISplitViewController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        disableSplitViewGesture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restoreSplitViewGesture()
    }

    private func disableSplitViewGesture() {
        // Find the split view controller in the hierarchy
        var current: UIViewController? = self
        while let vc = current {
            if let split = vc as? UISplitViewController {
                cachedSplitVC = split

                // Disable the presentation gesture by finding and disabling
                // the edge pan gesture recognizer on the split view controller's view
                disableEdgePanGestures(in: split.view)
                break
            }
            current = vc.parent
        }
    }

    private func disableEdgePanGestures(in view: UIView) {
        // The UISplitViewController uses a screen edge pan gesture recognizer
        // to show/hide the primary column. We need to disable it.
        for gestureRecognizer in view.gestureRecognizers ?? [] {
            if let edgePan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer {
                if edgePan.edges.contains(.left) {
                    // This is the sidebar reveal gesture
                    if gestureWasEnabled == nil {
                        gestureWasEnabled = edgePan.isEnabled
                    }
                    edgePan.isEnabled = false
                }
            }
        }

        // Also check subviews (the gesture might be on a container view)
        for subview in view.subviews {
            disableEdgePanGestures(in: subview)
        }
    }

    private func restoreSplitViewGesture() {
        guard let split = cachedSplitVC else { return }

        // Re-enable the gesture when leaving this view
        restoreEdgePanGestures(in: split.view)
        gestureWasEnabled = nil
    }

    private func restoreEdgePanGestures(in view: UIView) {
        for gestureRecognizer in view.gestureRecognizers ?? [] {
            if let edgePan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer {
                if edgePan.edges.contains(.left) {
                    // Only restore if it was originally enabled
                    if let wasEnabled = gestureWasEnabled {
                        edgePan.isEnabled = wasEnabled
                    } else {
                        edgePan.isEnabled = true
                    }
                }
            }
        }

        for subview in view.subviews {
            restoreEdgePanGestures(in: subview)
        }
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
