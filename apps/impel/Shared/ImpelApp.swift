import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressAI
import ImpressKit
import ImpressKeyboard
import PublicationManagerCore
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
    @State private var captureGateway: CaptureGateway?
    @State private var emlWatcher: EMLFolderWatcher?

    init() {
        // Register default settings (HTTP automation enabled by default for MCP)
        UserDefaults.standard.register(defaults: [
            "httpAutomationEnabled": true,
            // THE sibling-app table (ImpressKit) — never a second literal.
            "httpAutomationPort": Int(ImpelHTTPServer.defaultPort)
        ])
    }

    /// impel's window: the unified chassis (PMC's `TabContentView` on the Agents
    /// facet) with dashboard / threads / roster / escalations / suggestions /
    /// counsel as app-owned custom surfaces.
    ///
    /// Stage 4c: this is now the ONLY root. The classic `ContentView` and the
    /// `impel.useChassisWindow` flag are deleted — see ImpelChassisRoot's header
    /// for the parity gaps that had to close first. The flag is not kept as a
    /// kill switch because there is nothing left to switch TO: every surface the
    /// classic dashboard rendered is registered here, over the same views.
    private var chassisRoot: some View {
        ImpelChassisRoot()
            .environmentObject(client)
            .environmentObject(mailGatewayState)
            .onOpenURL { url in
                handleURL(url)
            }
    }

    var body: some Scene {
        WindowGroup {
            chassisRoot
                .task {
                    // Wire client reference for HTTP router
                    ImpelHTTPRouterState.shared.client = client

                    // Start HTTP automation server
                    await ImpelHTTPServer.shared.start()

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

                        // Wire TaskOrchestrator to HTTP router for Task API
                        ImpelHTTPRouterState.shared.orchestrator = engine.taskOrchestrator
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

                        // Start capture@ gateway for email-to-artifact pipeline
                        if mailGatewayState.captureEnabled,
                           let store = await mailGatewayState.messageStore {
                            let capture = CaptureGateway(store: store)
                            await capture.start()
                            captureGateway = capture
                        }

                        // Start EML folder watcher
                        if mailGatewayState.emlWatcherEnabled,
                           let store = await mailGatewayState.messageStore {
                            let watcher = EMLFolderWatcher(store: store)
                            await watcher.start()
                            emlWatcher = watcher
                        }
                    }
                }
        }
        .handlesExternalEvents(matching: Set(["impel"]))
        .commands {
            // Edit menu - ensure text field clipboard always works
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    if TextFieldFocusDetection.isTextFieldFocused() {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Cut") {
                    if TextFieldFocusDetection.isTextFieldFocused() {
                        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Paste") {
                    if TextFieldFocusDetection.isTextFieldFocused() {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("Select All") {
                    if TextFieldFocusDetection.isTextFieldFocused() {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("a", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                // Stage 4c: lowercase. `"R"` + `.command` registers ⌘⇧R in
                // SwiftUI (a capital literal implies Shift), so the menu said ⌘R,
                // `KeyboardHelpView` said ⌘R, and the chord was ⌘⇧R — harmless
                // while ContentView ALSO handled ⌘R itself in `handleKeyPress`,
                // and a silent regression the moment that handler was deleted.
                Button("Refresh") {
                    Task { await client.refresh() }
                }
                .keyboardShortcut("r", modifiers: [.command])
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

            // ⌘⇧F → the chassis's builtin store-wide "Search Everything"
            // surface (ADR-0022 D6). impel had NO ⌘⇧F binding, so the
            // universal chord in docs/keyboard-grammar.md was unclaimed here.
            // Reaches the chassis window; harmless in the classic dashboard,
            // which simply has no observer.
            ImpressStoreSearchCommands()

            // ⌘/ → the keyboard cheat sheet. It used to be reachable ONLY from
            // the classic ContentView's own key handler, so it appeared in no
            // menu and did nothing in the chassis window; as a command it works
            // from the menu bar and needs no focused view.
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(
                        name: .impelShowKeyboardHelp, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command])
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
        guard let engine = await mailGatewayState.counselEngine else {
            throw ImpelIntentError.counselUnavailable
        }

        // Use the Task API instead of going through the email path
        let taskRequest = TaskRequest(
            intent: "general",
            query: question,
            sourceApp: "shortcut"
        )
        let result = try await engine.taskOrchestrator.submitAndWait(taskRequest)
        return result.responseText ?? "Task completed."
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
    ///
    /// Stage 4c: these used to set `@State navigateToTab: DashboardTab?`, which
    /// only the classic `ContentView` observed — so once the chassis became the
    /// default window every one of these URLs navigated NOTHING. They now post
    /// PMC's `.chassisNavigateToSurface` with the id of the registered surface
    /// (`ImpelChassisRoot.surfaceIDsByURLSection`), which `TabContentView` turns
    /// into a sidebar selection.
    private func handleURL(_ url: URL) {
        guard let parsed = ImpressURL.parse(url), parsed.app == .impel else { return }

        switch parsed.action {
        case "open":
            // Thread DETAIL is still list-level only (the classic window had no
            // thread detail view either — `selectedThread` was never read), so
            // an id lands the user on the thread list, honestly.
            if parsed.resourceType == "thread", let idStr = parsed.resourceID,
               UUID(uuidString: idStr) != nil {
                navigate(toSection: "threads")
            }

        case "ask":
            if let question = parsed.parameters["question"], !question.isEmpty {
                navigate(toSection: "counsel")
                // Submit to counsel via Task API
                Task {
                    guard let engine = mailGatewayState.counselEngine else { return }
                    let taskRequest = TaskRequest(
                        intent: "general",
                        query: question,
                        sourceApp: "url-scheme"
                    )
                    _ = try? await engine.taskOrchestrator.submitAndWait(taskRequest)
                }
            }

        case "navigate":
            if let section = parsed.resourceType {
                navigate(toSection: section)
            }

        default:
            break
        }
    }

    /// Select the custom surface a URL section names. An unknown section posts
    /// nothing (the chassis ignores unclaimed ids anyway) rather than silently
    /// landing the user somewhere they did not ask for.
    private func navigate(toSection section: String) {
        guard let surfaceID = ImpelChassisRoot.surfaceIDsByURLSection[section] else { return }
        NotificationCenter.default.post(
            name: .chassisNavigateToSurface, object: surfaceID)
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
    @AppStorage("captureGatewayEnabled") var captureEnabled = true
    @AppStorage("emlWatcherEnabled") var emlWatcherEnabled = true

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
