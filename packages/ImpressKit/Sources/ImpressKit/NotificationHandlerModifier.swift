//
//  NotificationHandlerModifier.swift
//  ImpressKit
//
//  Generic view modifier for attaching multiple notification handlers.
//

import SwiftUI
import Combine

/// A view modifier that attaches multiple NotificationCenter observers
/// using a single `onReceive` with a merged publisher instead of
/// wrapping in nested `AnyView` layers.
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
        content
            .onReceive(mergedPublisher) { notification in
                for handler in handlers where handler.name == notification.name {
                    handler.action(notification)
                }
            }
    }

    private var mergedPublisher: AnyPublisher<Notification, Never> {
        let publishers = handlers.map {
            NotificationCenter.default.publisher(for: $0.name)
        }
        guard let first = publishers.first else {
            return Empty<Notification, Never>().eraseToAnyPublisher()
        }
        return publishers.dropFirst().reduce(first.eraseToAnyPublisher()) { merged, next in
            merged.merge(with: next).eraseToAnyPublisher()
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
