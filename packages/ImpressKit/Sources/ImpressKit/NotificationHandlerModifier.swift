//
//  NotificationHandlerModifier.swift
//  ImpressKit
//
//  Generic view modifier for attaching multiple notification handlers.
//

import SwiftUI
import Combine

/// A view modifier that attaches multiple NotificationCenter observers.
///
/// Reduces boilerplate when a view needs to respond to several notifications.
///
/// Usage:
/// ```swift
/// .onNotifications([
///     (.showImportSheet, { _ in showImport = true }),
///     (.showExportSheet, { _ in showExport = true }),
///     (.navigateToItem, { note in handleNavigation(note) }),
/// ])
/// ```
public struct NotificationHandlerModifier: ViewModifier {
    let handlers: [(name: Notification.Name, action: (Notification) -> Void)]

    public init(_ handlers: [(Notification.Name, (Notification) -> Void)]) {
        self.handlers = handlers.map { (name: $0.0, action: $0.1) }
    }

    public func body(content: Content) -> some View {
        handlers.reduce(AnyView(content)) { view, handler in
            AnyView(
                view.onReceive(
                    NotificationCenter.default.publisher(for: handler.name)
                ) { notification in
                    handler.action(notification)
                }
            )
        }
    }
}

public extension View {
    /// Attach multiple notification handlers to this view.
    ///
    /// - Parameter handlers: An array of `(Notification.Name, handler)` tuples.
    /// - Returns: A view with all notification handlers attached.
    func onNotifications(_ handlers: [(Notification.Name, (Notification) -> Void)]) -> some View {
        modifier(NotificationHandlerModifier(handlers))
    }

    /// Attach multiple notification handlers that ignore the notification payload.
    ///
    /// - Parameter handlers: An array of `(Notification.Name, action)` tuples.
    /// - Returns: A view with all notification handlers attached.
    func onNotifications(_ handlers: [(Notification.Name, () -> Void)]) -> some View {
        modifier(NotificationHandlerModifier(handlers.map { name, action in
            (name, { _ in action() })
        }))
    }
}
