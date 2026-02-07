//
//  MailGatewayCoordinator.swift
//  ImpelMail
//
//  Top-level coordinator that manages SMTP, IMAP, and the counsel gateway.
//

import Foundation
import OSLog

/// Configuration for the mail gateway.
public struct MailGatewayConfiguration: Sendable {
    /// SMTP port for receiving email (default: 2525)
    public let smtpPort: UInt16

    /// IMAP port for serving email to clients (default: 1143)
    public let imapPort: UInt16

    /// Hostname for SMTP greeting (default: impress.local)
    public let hostname: String

    public init(
        smtpPort: UInt16 = 2525,
        imapPort: UInt16 = 1143,
        hostname: String = "impress.local"
    ) {
        self.smtpPort = smtpPort
        self.imapPort = imapPort
        self.hostname = hostname
    }
}

/// Gateway status for UI display.
public struct MailGatewayStatus: Sendable {
    public let smtpRunning: Bool
    public let imapRunning: Bool
    public let smtpPort: UInt16
    public let imapPort: UInt16
    public let activeThreads: Int
    public let totalMessages: Int
}

/// Coordinates the mail gateway: SMTP server, IMAP server, and counsel gateway.
///
/// Usage:
/// ```swift
/// let coordinator = MailGatewayCoordinator()
/// await coordinator.start()
///
/// // Optionally set a task handler for AI execution
/// await coordinator.setTaskHandler { request in
///     // Execute task using ImpressAI
///     return "Results: ..."
/// }
/// ```
public actor MailGatewayCoordinator {

    private let logger = Logger(subsystem: "com.impress.impel", category: "mailGateway")

    private let store: MessageStore
    private let smtp: SMTPServer
    private let imap: IMAPServer
    private let gateway: CounselGateway
    private let configuration: MailGatewayConfiguration

    private(set) var isRunning = false

    public init(configuration: MailGatewayConfiguration = .init()) {
        self.configuration = configuration
        self.store = MessageStore()
        self.smtp = SMTPServer(port: configuration.smtpPort, hostname: configuration.hostname, store: store)
        self.imap = IMAPServer(port: configuration.imapPort, store: store)
        self.gateway = CounselGateway(store: store)
    }

    /// Start all mail gateway services.
    public func start() async {
        guard !isRunning else {
            logger.info("Mail gateway already running")
            return
        }

        logger.info("Starting mail gateway (SMTP:\(self.configuration.smtpPort) IMAP:\(self.configuration.imapPort))")

        // Start the counsel gateway first so it can receive messages
        await gateway.start()

        // Start servers
        await smtp.start()
        await imap.start()

        isRunning = true
        logger.info("Mail gateway started — counsel@\(self.configuration.hostname) ready")
    }

    /// Stop all mail gateway services.
    public func stop() async {
        guard isRunning else { return }

        await smtp.stop()
        await imap.stop()

        isRunning = false
        logger.info("Mail gateway stopped")
    }

    /// Set the task execution handler.
    ///
    /// The handler receives a `CounselRequest` and should return the response body text.
    /// This is where you plug in ImpressAI for actual agent execution.
    public func setTaskHandler(_ handler: @escaping @Sendable (CounselRequest) async -> CounselTaskResult) async {
        await gateway.setTaskHandler(handler)
    }

    /// Current gateway status.
    public func status() async -> MailGatewayStatus {
        MailGatewayStatus(
            smtpRunning: await smtp.isRunning,
            imapRunning: await imap.isRunning,
            smtpPort: configuration.smtpPort,
            imapPort: configuration.imapPort,
            activeThreads: await gateway.activeThreads.count,
            totalMessages: await store.totalCount
        )
    }

    /// Active counsel threads.
    public func activeThreads() async -> [CounselThread] {
        await gateway.activeThreads
    }

    /// Public access to the message store (for CounselEngine integration).
    public var messageStoreRef: MessageStore {
        store
    }
}
