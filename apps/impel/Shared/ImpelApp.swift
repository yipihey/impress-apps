import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressAI
import ImpressKit
import Foundation
import OSLog

/// Main application entry point for impel
///
/// impel is a monitoring dashboard for the impel agent orchestration system,
/// providing a read-only view of research threads, agent status, and escalations.
/// Also runs the counsel@ mail gateway for email-based agent interaction.
@main
struct ImpelApp: App {
    @StateObject private var client = ImpelClient()
    @StateObject private var mailGatewayState = MailGatewayState()
    @State private var navigateToTab: DashboardTab?

    var body: some Scene {
        WindowGroup {
            ContentView(navigateToTab: $navigateToTab)
                .environmentObject(client)
                .environmentObject(mailGatewayState)
                .onOpenURL { url in
                    handleURL(url)
                }
                .task {
                    // Load mock data for development
                    await client.loadMockData()

                    // Register AI providers
                    await AIProviderManager.shared.registerBuiltInProviders()

                    // Initialize CounselEngine and set as task handler
                    do {
                        let engine = try CounselEngine()
                        let store = await mailGatewayState.messageStore
                        if let store = store {
                            await mailGatewayState.setTaskHandler(engine.makeTaskHandler(store: store))
                        } else {
                            // Gateway not started yet — register after start
                            await mailGatewayState.setCounselEngine(engine)
                        }
                        await mailGatewayState.setCounselEngineRef(engine)
                    } catch {
                        counselLogger.error("Failed to initialize CounselEngine: \(error.localizedDescription)")
                    }

                    // Start heartbeat for SiblingDiscovery
                    startHeartbeat(for: .impel)

                    // Register counsel intent service for App Intents (AskCounselIntent)
                    if #available(macOS 14.0, *) {
                        CounselIntentServiceLocator.service = ImpelCounselIntentService(
                            mailGatewayState: mailGatewayState
                        )
                    }

                    // Start mail gateway if enabled
                    if mailGatewayState.isEnabled {
                        await mailGatewayState.startGateway()

                        // Rehydrate IMAP store from persisted conversations
                        if let engine = mailGatewayState.counselEngine,
                           let store = await mailGatewayState.messageStore {
                            await engine.rehydrateMailStore(store: store)
                        }
                    }
                }
        }
        .handlesExternalEvents(matching: Set(["impel"]))
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Refresh") {
                    Task { await client.refresh() }
                }
                .keyboardShortcut("R", modifiers: [.command])
            }

            CommandMenu("Server") {
                Button("Connect...") {
                    // TODO: Show connection dialog
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])

                Button("Disconnect") {
                    client.disconnect()
                }
                .disabled(!client.isConnected)

                Divider()

                Button("Load Demo Data") {
                    Task { await client.loadMockData() }
                }
            }

            CommandMenu("Counsel") {
                Toggle("Mail Gateway Enabled", isOn: $mailGatewayState.isEnabled)
                    .onChange(of: mailGatewayState.isEnabled) { _, enabled in
                        Task {
                            if enabled {
                                await mailGatewayState.startGateway()
                            } else {
                                await mailGatewayState.stopGateway()
                            }
                        }
                    }

                Divider()

                if mailGatewayState.smtpRunning {
                    Text("SMTP: port \(mailGatewayState.smtpPort)")
                    Text("IMAP: port \(mailGatewayState.imapPort)")
                } else {
                    Text("Gateway stopped")
                }
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(mailGatewayState)
        }
        #endif
    }
}

// MARK: - Counsel Intent Service

@available(macOS 14.0, *)
final class ImpelCounselIntentService: CounselIntentService, @unchecked Sendable {
    private let mailGatewayState: MailGatewayState

    init(mailGatewayState: MailGatewayState) {
        self.mailGatewayState = mailGatewayState
    }

    func ask(question: String) async throws -> String {
        guard let engine = await mailGatewayState.counselEngine,
              let store = await mailGatewayState.messageStore else {
            throw ImpelIntentError.counselUnavailable
        }
        let request = CounselRequest(
            subject: "Shortcut Query",
            body: question,
            from: "shortcut@localhost",
            intent: .general
        )
        let handler = engine.makeTaskHandler(store: store)
        let result = await handler(request)
        return result.body
    }
}

// MARK: - URL Handling

extension ImpelApp {
    /// Handle incoming impel:// URLs.
    ///
    /// Supported URL patterns:
    /// - `impel://open/thread/{uuid}` — navigate to a specific thread
    /// - `impel://ask?question={text}` — submit a question to counsel
    /// - `impel://navigate/{threads|counsel|escalations|agents|suggestions|dashboard}` — navigate to section
    private func handleURL(_ url: URL) {
        guard let parsed = ImpressURL.parse(url), parsed.app == .impel else { return }

        switch parsed.action {
        case "open":
            if parsed.resourceType == "thread", let idStr = parsed.resourceID,
               let _ = UUID(uuidString: idStr) {
                navigateToTab = .threads
            }

        case "ask":
            if let question = parsed.parameters["question"], !question.isEmpty {
                navigateToTab = .counsel
                // Submit to counsel via mail gateway if running
                Task {
                    guard let engine = mailGatewayState.counselEngine,
                          let store = await mailGatewayState.messageStore else { return }
                    let request = CounselRequest(
                        subject: "URL Query",
                        body: question,
                        from: "url-scheme@localhost",
                        intent: .general
                    )
                    let handler = engine.makeTaskHandler(store: store)
                    let _ = await handler(request)
                }
            }

        case "navigate":
            if let section = parsed.resourceType {
                switch section {
                case "threads": navigateToTab = .threads
                case "counsel": navigateToTab = .counsel
                case "escalations": navigateToTab = .escalations
                case "agents": navigateToTab = .agents
                case "suggestions": navigateToTab = .suggestions
                case "dashboard": navigateToTab = .dashboard
                default: break
                }
            }

        default:
            break
        }
    }
}

/// Start a periodic heartbeat so SiblingDiscovery can detect this app as running.
private func startHeartbeat(for app: SiblingApp) {
    Task.detached {
        while !Task.isCancelled {
            ImpressNotification.postHeartbeat(from: app)
            try? await Task.sleep(for: .seconds(25))
        }
    }
}

private let counselLogger = Logger(subsystem: "com.impress.impel", category: "counsel")

// MARK: - Mail Gateway State

/// Observable state for the mail gateway, available as an environment object.
@MainActor
class MailGatewayState: ObservableObject {
    @AppStorage("counselGatewayEnabled") var isEnabled = true
    @AppStorage("counselSMTPPort") var smtpPort = 2525
    @AppStorage("counselIMAPPort") var imapPort = 1143
    @AppStorage("counselSystemPrompt") var counselSystemPrompt = ""

    @Published var smtpRunning = false
    @Published var imapRunning = false
    @Published var activeThreadCount = 0
    @Published var totalMessages = 0
    @Published var counselThreads: [CounselThread] = []

    /// Persistent conversation data from CounselEngine.
    @Published var persistentConversations: [CounselConversation] = []
    @Published var selectedConversationToolExecutions: [CounselToolExecution] = []

    private var coordinator: MailGatewayCoordinator?
    private var statusTask: Task<Void, Never>?
    private(set) var counselEngine: CounselEngine?
    private var pendingCounselEngine: CounselEngine?

    /// The message store from the coordinator (for CounselEngine integration).
    var messageStore: MessageStore? {
        get async {
            await coordinator?.messageStoreRef
        }
    }

    func startGateway() async {
        guard coordinator == nil else { return }

        let config = MailGatewayConfiguration(
            smtpPort: UInt16(smtpPort),
            imapPort: UInt16(imapPort)
        )
        let coord = MailGatewayCoordinator(configuration: config)
        coordinator = coord

        // If CounselEngine was registered before gateway start, wire it up now
        if let engine = pendingCounselEngine {
            let store = await coord.messageStoreRef
            await coord.setTaskHandler(engine.makeTaskHandler(store: store))
            pendingCounselEngine = nil
        } else if let handler = pendingTaskHandler {
            await coord.setTaskHandler(handler)
        }

        await coord.start()

        // Update status
        let status = await coord.status()
        smtpRunning = status.smtpRunning
        imapRunning = status.imapRunning

        // Start periodic status updates (poll every 2s for responsiveness)
        statusTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let coord = self.coordinator else { break }
                let status = await coord.status()
                self.smtpRunning = status.smtpRunning
                self.imapRunning = status.imapRunning
                self.activeThreadCount = status.activeThreads
                self.totalMessages = status.totalMessages
                self.counselThreads = await coord.activeThreads()

                // Also refresh persistent conversation data
                if let engine = self.counselEngine {
                    self.persistentConversations = (try? engine.allConversations()) ?? []
                }
            }
        }
    }

    func stopGateway() async {
        statusTask?.cancel()
        statusTask = nil
        await coordinator?.stop()
        coordinator = nil
        smtpRunning = false
        imapRunning = false
    }

    /// Set the task handler that processes counsel requests.
    func setTaskHandler(_ handler: @escaping @Sendable (CounselRequest) async -> CounselTaskResult) async {
        pendingTaskHandler = handler
        // If coordinator is already running, apply immediately
        if let coord = coordinator {
            await coord.setTaskHandler(handler)
        }
    }

    /// Set the CounselEngine to be wired up when gateway starts.
    func setCounselEngine(_ engine: CounselEngine) async {
        pendingCounselEngine = engine
    }

    /// Store a reference to the CounselEngine for data access.
    func setCounselEngineRef(_ engine: CounselEngine) async {
        counselEngine = engine
    }

    /// Load tool executions for a specific conversation.
    func loadToolExecutions(conversationID: String) {
        guard let engine = counselEngine else { return }
        selectedConversationToolExecutions = (try? engine.toolExecutions(for: conversationID)) ?? []
    }

    private var pendingTaskHandler: (@Sendable (CounselRequest) async -> CounselTaskResult)?
}
