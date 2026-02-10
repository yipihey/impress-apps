import Foundation

/// Darwin notification management for cross-app signaling.
///
/// Darwin notifications are signal-only (no payload). Payloads are written to
/// the shared container before posting the notification.
///
/// Naming: `com.impress.suite.{app}.{event}`
public struct ImpressNotification: Sendable {

    // MARK: - Well-Known Events

    /// imbib: paper added/removed/modified
    public static let libraryChanged = "library-changed"
    /// imbib: collection structure changed
    public static let collectionChanged = "collection-changed"
    /// imprint: document saved
    public static let documentSaved = "document-saved"
    /// imprint: bibliography updated
    public static let bibliographyUpdated = "bibliography-updated"
    /// impart: new message arrived
    public static let messageReceived = "message-received"
    /// implore: figure ready for embedding
    public static let figureExported = "figure-exported"
    /// impel: agent thread finished
    public static let threadCompleted = "thread-completed"
    /// impel: human review needed
    public static let escalationCreated = "escalation-created"
    /// impel: structured task completed (Task API)
    public static let taskCompleted = "task-completed"

    // MARK: - Posting

    /// Posts a Darwin notification from the specified app.
    /// - Parameters:
    ///   - event: The event name (e.g., "library-changed").
    ///   - app: The source app posting the notification.
    ///   - resourceIDs: Optional resource IDs to include in the payload.
    public static func post(_ event: String, from app: SiblingApp, resourceIDs: [String]? = nil) {
        // Write payload if resource IDs provided
        if let resourceIDs, !resourceIDs.isEmpty {
            let payload = NotificationPayload(
                event: event,
                source: app,
                timestamp: Date(),
                resourceIDs: resourceIDs
            )
            if let data = try? JSONEncoder().encode(payload) {
                let name = darwinName(event: event, app: app)
                try? SharedContainer.writeNotificationPayload(name: name, data: data)
            }
        }

        // Post Darwin notification
        let name = darwinNotificationName(event: event, app: app)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Posts a heartbeat notification for the given app.
    public static func postHeartbeat(from app: SiblingApp) {
        let payload = NotificationPayload(
            event: "heartbeat",
            source: app,
            timestamp: Date(),
            resourceIDs: nil
        )
        if let data = try? JSONEncoder().encode(payload) {
            let name = "heartbeat.\(app.rawValue)"
            try? SharedContainer.writeNotificationPayload(name: name, data: data)
        }

        let notifName = darwinNotificationName(event: "heartbeat", app: app)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(notifName as CFString), nil, nil, true)
    }

    // MARK: - Observing

    /// Observes a Darwin notification from a specific app.
    /// - Parameters:
    ///   - event: The event name to observe.
    ///   - app: The source app to listen for.
    ///   - handler: Called on the notification's delivery queue when the event fires.
    /// - Returns: An opaque token. Hold a strong reference to keep observing; release to stop.
    public static func observe(_ event: String, from app: SiblingApp, handler: @escaping @Sendable () -> Void) -> DarwinObservation {
        let name = darwinNotificationName(event: event, app: app)
        return DarwinObservation(name: name, handler: handler)
    }

    /// Reads the latest payload for a notification event.
    /// - Parameters:
    ///   - event: The event name.
    ///   - app: The source app.
    /// - Returns: The decoded payload, or nil if not available.
    public static func latestPayload(for event: String, from app: SiblingApp) -> NotificationPayload? {
        let name = darwinName(event: event, app: app)
        guard let data = SharedContainer.readNotificationPayload(name: name) else { return nil }
        return try? JSONDecoder().decode(NotificationPayload.self, from: data)
    }

    // MARK: - Helpers

    private static func darwinNotificationName(event: String, app: SiblingApp) -> String {
        "com.impress.suite.\(app.rawValue).\(event)"
    }

    private static func darwinName(event: String, app: SiblingApp) -> String {
        "\(app.rawValue).\(event)"
    }
}

// MARK: - Payload

/// Payload stored as a JSON file in the shared container alongside Darwin notifications.
public struct NotificationPayload: Codable, Sendable {
    public let event: String
    public let source: SiblingApp
    public let timestamp: Date
    public let resourceIDs: [String]?

    public init(event: String, source: SiblingApp, timestamp: Date, resourceIDs: [String]?) {
        self.event = event
        self.source = source
        self.timestamp = timestamp
        self.resourceIDs = resourceIDs
    }
}

// MARK: - Darwin Observation Token

/// An observation token for a Darwin notification. Deregisters when deallocated.
public final class DarwinObservation: @unchecked Sendable {
    private let name: String
    private let handler: @Sendable () -> Void
    private var registered = true

    init(name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let observation = Unmanaged<DarwinObservation>.fromOpaque(observer).takeUnretainedValue()
                observation.handler()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        guard registered else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(name as CFString), nil)
    }

    /// Explicitly stop observing.
    public func invalidate() {
        guard registered else { return }
        registered = false
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(name as CFString), nil)
    }
}
