//
//  AIConversationWorkspaceView.swift
//  MessageManagerCore
//
//  A deliberately thin native surface over Rust's display-ready AI
//  projections. SwiftUI owns selection, composer text, and inline creation
//  state; conversation policy, durable messages/tasks, CAS metadata, and
//  provenance identifiers remain in impress-ai.
//

import Foundation
import ImpressAI
import ImpressLogging
@preconcurrency import ImpressRustCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AIConversationWorkspaceModel {
    private let store: ImpartAIStore
    private let workerController: any ImpressModelWorkerStarting

    private(set) var conversations: [AiConversationRow] = []
    private(set) var conversation: AiConversationView?
    private(set) var newConversationTools: [AiToolOption] = []
    private(set) var hostStatus: AiModelHostStatus?
    private(set) var workerStatus: AiWorkerStatus?
    private(set) var pendingAttachments: [ImpartAIAttachment] = []
    var selectedConversationID: String?
    var composerText = ""
    var searchText = ""
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var isCheckingHost = false
    private(set) var isCheckingWorker = false
    private(set) var isSuggestingTitle = false
    private(set) var errorMessage: String?

    init(
        store: ImpartAIStore = .shared,
        workerController: any ImpressModelWorkerStarting = ImpressModelWorkerController.shared
    ) {
        self.store = store
        self.workerController = workerController
    }

    var filteredConversations: [AiConversationRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedStandardContains(query)
                || $0.model.localizedStandardContains(query)
                || ($0.summary?.localizedStandardContains(query) ?? false)
        }
    }

    var availableModels: [AiModelRow] {
        hostStatus?.models ?? []
    }

    var hostIsReachable: Bool {
        guard let state = hostStatus?.state else { return false }
        return state == "ready" || state == "empty"
    }

    var workerIsActive: Bool {
        guard let state = workerStatus?.state else { return false }
        return state == "starting" || state == "settling" || state == "ready"
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loadedRows = try await store.conversations()
            let loadedTools = try await store.toolOptions()
            conversations = loadedRows
            newConversationTools = loadedTools

            if let selectedConversationID,
               loadedRows.contains(where: { $0.id == selectedConversationID }) {
                await loadConversation(id: selectedConversationID)
            } else {
                selectedConversationID = loadedRows.first?.id
                await loadConversation(id: selectedConversationID)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadConversation(id: String?) async {
        guard let id, let uuid = UUID(uuidString: id) else {
            conversation = nil
            return
        }
        do {
            let loaded = try await store.conversation(id: uuid)
            guard selectedConversationID == id else { return }
            conversation = loaded
            errorMessage = nil
        } catch {
            conversation = nil
            errorMessage = error.localizedDescription
        }
    }

    func refreshHost() async {
        isCheckingHost = true
        defer { isCheckingHost = false }
        do {
            hostStatus = try await store.configuredModelHostStatus()
        } catch {
            hostStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func connectHost() async {
        #if os(macOS)
        isCheckingHost = true
        do {
            try await OMLXServiceController.shared.startOMLX()
            isCheckingHost = false
            await refreshHost()
        } catch {
            isCheckingHost = false
            errorMessage = error.localizedDescription
        }
        #else
        await refreshHost()
        #endif
    }

    func refreshWorker() async {
        isCheckingWorker = true
        defer { isCheckingWorker = false }
        do {
            workerStatus = try await store.modelWorkerStatus()
        } catch {
            workerStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func connectWorker() async {
        #if os(macOS)
        isCheckingWorker = true
        do {
            try await workerController.startWorker()
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                let status = try await store.modelWorkerStatus()
                workerStatus = status
                if ["starting", "settling", "ready"].contains(status.state) {
                    break
                }
            }
            isCheckingWorker = false
        } catch is CancellationError {
            isCheckingWorker = false
        } catch {
            isCheckingWorker = false
            errorMessage = error.localizedDescription
        }
        #else
        await refreshWorker()
        #endif
    }

    func ensureWorkerIfInstalled() async {
        #if os(macOS)
        guard !workerIsActive, ImpressModelWorkerController.isInstalled else { return }
        await connectWorker()
        #endif
    }

    func refreshAll() async {
        await load()
        await refreshHost()
        await refreshWorker()
    }

    @discardableResult
    func createConversation(
        title: String,
        model: String,
        enabledTools: [String]
    ) async -> Bool {
        isMutating = true
        defer { isMutating = false }
        do {
            let id = try await store.createConversation(
                title: title, model: model, enabledTools: enabledTools)
            selectedConversationID = id.uuidString.lowercased()
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func sendComposer() async {
        guard let conversationID = selectedConversationID.flatMap(UUID.init(uuidString:)) else {
            return
        }
        let body = composerText
        let attachments = pendingAttachments
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
        else { return }

        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await store.queueUserTurn(
                conversationID: conversationID,
                body: body,
                attachmentIDs: attachments.map(\.itemID))
            if composerText == body {
                composerText = ""
            }
            if pendingAttachments == attachments {
                pendingAttachments = []
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setTool(id: String, enabled: Bool) async {
        guard let view = conversation,
              let conversationID = UUID(uuidString: view.conversation.id)
        else { return }

        var tools = Set(view.toolOptions.filter(\.enabled).map(\.id))
        if enabled {
            tools.insert(id)
        } else {
            tools.remove(id)
        }

        isMutating = true
        defer { isMutating = false }
        do {
            try await store.setEnabledTools(tools.sorted(), conversationID: conversationID)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setModel(_ model: String) async {
        guard let id = conversation?.conversation.id,
              let conversationID = UUID(uuidString: id)
        else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await store.setConversationModel(model, conversationID: conversationID)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameConversation(_ title: String) async {
        guard let id = conversation?.conversation.id,
              let conversationID = UUID(uuidString: id)
        else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await store.setConversationTitle(title, conversationID: conversationID)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func suggestConversationTitle() async {
        guard let id = conversation?.conversation.id,
              let conversationID = UUID(uuidString: id)
        else { return }
        isMutating = true
        do {
            let taskID = try await store.suggestConversationTitle(conversationID: conversationID)
            isMutating = false
            isSuggestingTitle = true
            defer { isSuggestingTitle = false }
            for _ in 0..<180 {
                if Task.isCancelled { return }
                let state = try await store.taskState(taskID: taskID)
                if state == "completed" || state == "failed" {
                    await load()
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            await load()
        } catch is CancellationError {
            isMutating = false
        } catch {
            isMutating = false
            errorMessage = error.localizedDescription
        }
    }

    func addAttachments(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            var imported: [ImpartAIAttachment] = []
            for url in urls {
                imported.append(try await store.ingestAttachment(fileURL: url))
            }
            pendingAttachments.append(contentsOf: imported)
            logInfo(
                "Display: \(pendingAttachments.count) AI composer attachments ready",
                category: "ai-store")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.itemID == id }
    }

    func watchPendingTasks() async {
        while !Task.isCancelled, (conversation?.conversation.pendingTaskCount ?? 0) > 0 {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await loadConversation(id: selectedConversationID)
            await refreshWorker()
        }
        await load()
    }

    func dismissError() {
        errorMessage = nil
    }

    func reportImportError(_ error: Error) {
        let cocoaError = error as NSError
        guard cocoaError.code != CocoaError.Code.userCancelled.rawValue else { return }
        errorMessage = error.localizedDescription
    }
}

/// Shared macOS/iOS conversation surface for the local oMLX workflow.
///
/// The view renders Rust's `AiConversationRow` / `AiConversationView` records
/// directly. It does not decode graph payloads, execute models, or maintain a
/// second conversation store.
public struct AIConversationWorkspaceView: View {
    @State private var model = AIConversationWorkspaceModel()

    public init() {}

    public var body: some View {
        @Bindable var model = model
        let workspace = model
        let pendingTaskCount = model.conversation?.conversation.pendingTaskCount ?? 0

        NavigationSplitView {
            AIConversationListColumn(model: model)
        } detail: {
            AIConversationDetailColumn(model: model)
        }
        .task {
            await workspace.refreshAll()
            await workspace.ensureWorkerIfInstalled()
        }
        .task(id: pendingTaskCount) {
            guard pendingTaskCount > 0 else { return }
            await workspace.watchPendingTasks()
        }
        .onChange(of: model.selectedConversationID) { _, id in
            let workspace = model
            Task {
                await workspace.loadConversation(id: id)
            }
        }
        .alert(
            "Local AI",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) {
                model.dismissError()
            }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

private struct AIConversationListColumn: View {
    @Bindable var model: AIConversationWorkspaceModel
    @State private var isCreating = false
    @State private var title = ""
    @State private var modelID =
        UserDefaults.standard.string(forKey: AISettingsKey.selectedModelId) ?? ""
    @State private var enabledTools: Set<String> = []

    var body: some View {
        let workspace = model
        List(selection: $model.selectedConversationID) {
            Section {
                AIModelHostCard(
                    status: model.hostStatus,
                    isChecking: model.isCheckingHost,
                    refresh: refreshHost,
                    connect: connectHost)
                AIModelWorkerCard(
                    status: model.workerStatus,
                    isChecking: model.isCheckingWorker,
                    refresh: refreshWorker,
                    connect: connectWorker)
            }

            if isCreating {
                Section("New Conversation") {
                    TextField("Title (optional)", text: $title)
                    newConversationModelControl
                    newConversationToolMenu
                    Button("Create", systemImage: "plus", action: createConversation)
                        .disabled(!canCreate || model.isMutating)
                }
            }

            Section("Local AI") {
                ForEach(model.filteredConversations, id: \.id) { conversation in
                    AIConversationRowView(conversation: conversation)
                        .tag(conversation.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Local AI")
        .searchable(text: $model.searchText, prompt: "Conversations")
        .refreshable {
            await workspace.refreshAll()
        }
        .onChange(of: model.hostStatus?.checkedAtMs) {
            chooseDiscoveredModelIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup {
                Button("New Conversation", systemImage: "plus") {
                    isCreating.toggle()
                }
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await workspace.refreshAll() }
                }
            }
        }
        .overlay {
            if model.isLoading && model.conversations.isEmpty {
                ProgressView("Loading conversations…")
            }
        }
    }

    private var canCreate: Bool {
        !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var newConversationToolMenu: some View {
        Menu {
            ForEach(model.newConversationTools, id: \.id) { option in
                Toggle(
                    option.label,
                    isOn: Binding(
                        get: { enabledTools.contains(option.id) },
                        set: { enabled in
                            if enabled {
                                enabledTools.insert(option.id)
                            } else {
                                enabledTools.remove(option.id)
                            }
                        }))
            }
        } label: {
            Label(toolMenuTitle, systemImage: "wrench.and.screwdriver")
        }
    }

    @ViewBuilder
    private var newConversationModelControl: some View {
        if model.availableModels.isEmpty {
            TextField("oMLX model identifier", text: $modelID)
        } else {
            Picker("Model", selection: $modelID) {
                ForEach(model.availableModels, id: \.id) { model in
                    AIModelPickerLabel(model: model)
                        .tag(model.id)
                }
            }
        }
    }

    private var toolMenuTitle: String {
        enabledTools.isEmpty ? "No tools" : "\(enabledTools.count) tools"
    }

    private func createConversation() {
        let workspace = model
        let enteredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedTitle = enteredTitle.isEmpty ? "New chat" : enteredTitle
        let capturedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedTools = enabledTools.sorted()
        Task {
            guard await workspace.createConversation(
                title: capturedTitle,
                model: capturedModel,
                enabledTools: capturedTools)
            else { return }
            title = ""
            enabledTools = []
            isCreating = false
        }
    }

    private func refreshHost() {
        let workspace = model
        Task { await workspace.refreshHost() }
    }

    private func connectHost() {
        let workspace = model
        Task { await workspace.connectHost() }
    }

    private func refreshWorker() {
        let workspace = model
        Task { await workspace.refreshWorker() }
    }

    private func connectWorker() {
        let workspace = model
        Task { await workspace.connectWorker() }
    }

    private func chooseDiscoveredModelIfNeeded() {
        guard !model.availableModels.isEmpty else { return }
        if !model.availableModels.contains(where: { $0.id == modelID }) {
            modelID = model.availableModels.first?.id ?? modelID
        }
    }
}

private struct AIModelWorkerCard: View {
    let status: AiWorkerStatus?
    let isChecking: Bool
    let refresh: () -> Void
    let connect: () -> Void

    private var isActive: Bool {
        guard let state = status?.state else { return false }
        return state == "starting" || state == "settling" || state == "ready"
    }

    private var title: String {
        switch status?.state {
        case "ready": "Worker ready"
        case "starting": "Worker starting"
        case "settling": "Worker settling"
        case "failed": "Worker failed"
        case "stale": "Worker stopped"
        default: "Worker unavailable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(status?.state == "ready" ? .green : isActive ? .orange : .secondary)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.callout)
                    .bold()
                Spacer()
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(status?.detail ?? "Checking this device’s Impress model worker…")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let status, status.completedTotal > 0 || status.failedTotal > 0 {
                Text("\(status.completedTotal) completed · \(status.failedTotal) failed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Button("Check", systemImage: "arrow.clockwise", action: refresh)
                    .controlSize(.small)
                #if os(macOS)
                if !isActive {
                    Button("Start Worker", systemImage: "gearshape.2", action: connect)
                        .controlSize(.small)
                }
                #else
                Text("Runs on your Mac or server")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                #endif
            }
            .disabled(isChecking)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct AIModelHostCard: View {
    let status: AiModelHostStatus?
    let isChecking: Bool
    let refresh: () -> Void
    let connect: () -> Void

    private var isReachable: Bool {
        status?.state == "ready" || status?.state == "empty"
    }

    private var connectTitle: String {
        #if os(macOS)
        "Start oMLX"
        #else
        "Try Again"
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isReachable ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(isReachable ? "oMLX online" : "oMLX unavailable")
                    .font(.callout)
                    .bold()
                Spacer()
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(status?.endpoint ?? OpenAICompatibleProvider.defaultEndpoint.absoluteString)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            Text(status?.detail ?? "Checking the configured oMLX host…")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Check", systemImage: "arrow.clockwise", action: refresh)
                    .controlSize(.small)
                if !isReachable {
                    Button(
                        connectTitle,
                        systemImage: "bolt.horizontal.circle",
                        action: connect)
                        .controlSize(.small)
                }
            }
            .disabled(isChecking)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct AIModelPickerLabel: View {
    let model: AiModelRow

    var body: some View {
        HStack {
            Circle()
                .fill(model.loaded ? .green : .secondary)
                .frame(width: 7, height: 7)
            Text(model.id)
            if !model.modalities.isEmpty {
                Text(model.modalities.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AIConversationRowView: View {
    let conversation: AiConversationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.title)
                    .lineLimit(1)
                Spacer()
                if conversation.pendingTaskCount > 0 {
                    Label(
                        "\(conversation.pendingTaskCount) pending",
                        systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(conversation.pendingTaskCount) pending tasks")
                }
            }
            Text(conversation.model)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Text("\(conversation.messageCount) messages")
                Text(Date(timeIntervalSince1970: Double(conversation.lastActivityAtMs) / 1_000),
                     format: .dateTime.month(.abbreviated).day().hour().minute())
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct AIConversationDetailColumn: View {
    @Bindable var model: AIConversationWorkspaceModel

    var body: some View {
        if let conversation = model.conversation {
            VStack(spacing: 0) {
                AIConversationHeader(
                    conversation: conversation,
                    models: model.availableModels,
                    hostState: model.hostStatus?.state,
                    isMutating: model.isMutating,
                    isSuggestingTitle: model.isSuggestingTitle,
                    setTool: setTool,
                    setModel: setModel,
                    renameTitle: renameTitle,
                    suggestTitle: suggestTitle)
                Divider()
                AIConversationTranscript(messages: conversation.messages, tasks: conversation.tasks)
                Divider()
                AIConversationComposer(model: model)
            }
            .navigationTitle(conversation.conversation.title)
        } else {
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "sparkles",
                description: Text("Choose a synced conversation or create one."))
        }
    }

    private func setTool(_ id: String, _ enabled: Bool) {
        let workspace = model
        Task {
            await workspace.setTool(id: id, enabled: enabled)
        }
    }

    private func setModel(_ id: String) {
        let workspace = model
        Task {
            await workspace.setModel(id)
        }
    }

    private func renameTitle(_ title: String) {
        let workspace = model
        Task {
            await workspace.renameConversation(title)
        }
    }

    private func suggestTitle() {
        let workspace = model
        Task {
            await workspace.suggestConversationTitle()
        }
    }
}

private struct AIConversationHeader: View {
    let conversation: AiConversationView
    let models: [AiModelRow]
    let hostState: String?
    let isMutating: Bool
    let isSuggestingTitle: Bool
    let setTool: (String, Bool) -> Void
    let setModel: (String) -> Void
    let renameTitle: (String) -> Void
    let suggestTitle: () -> Void
    @State private var isRenaming = false
    @State private var titleDraft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    HStack {
                        TextField("Conversation title", text: $titleDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveTitle)
                        Button("Save", systemImage: "checkmark", action: saveTitle)
                            .labelStyle(.iconOnly)
                            .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel", systemImage: "xmark", action: cancelRename)
                            .labelStyle(.iconOnly)
                    }
                } else {
                    Text(conversation.conversation.title)
                        .font(.headline)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(hostState == "ready" ? .green : .secondary)
                        .frame(width: 7, height: 7)
                    Text("\(conversation.conversation.provider) · \(conversation.conversation.model)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if conversation.conversation.pendingTaskCount > 0 {
                Label(
                    "\(conversation.conversation.pendingTaskCount) pending",
                    systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            modelMenu
            toolMenu
            titleMenu
        }
        .padding()
    }

    private var titleMenu: some View {
        Menu {
            Button("Rename Conversation", systemImage: "pencil", action: beginRename)
            Button("Suggest Title", systemImage: "sparkles", action: suggestTitle)
                .disabled(isSuggestingTitle || conversation.messages.isEmpty)
        } label: {
            if isSuggestingTitle {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Suggesting conversation title")
            } else {
                Label("Conversation Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
        }
        .disabled(isMutating)
    }

    private func beginRename() {
        titleDraft = conversation.conversation.title
        isRenaming = true
    }

    private func cancelRename() {
        titleDraft = ""
        isRenaming = false
    }

    private func saveTitle() {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        renameTitle(title)
        cancelRename()
    }

    private var toolMenu: some View {
        Menu {
            ForEach(conversation.toolOptions, id: \.id) { option in
                Toggle(
                    isOn: Binding(
                        get: { option.enabled },
                        set: { setTool(option.id, $0) })
                ) {
                    VStack(alignment: .leading) {
                        Text(option.label)
                        Text(option.description)
                    }
                }
            }
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .disabled(isMutating)
    }

    private var modelMenu: some View {
        Menu {
            if models.isEmpty {
                Text("No models currently reachable")
            } else {
                ForEach(models, id: \.id) { model in
                    Button {
                        setModel(model.id)
                    } label: {
                        HStack {
                            Text(model.id)
                            if model.id == conversation.conversation.model {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Model", systemImage: "cpu")
        }
        .disabled(isMutating || models.isEmpty)
    }
}

private struct AIConversationTranscript: View {
    let messages: [AiMessageRow]
    let tasks: [AiTaskRow]
    private let bottomAnchor = "ai-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "Ready for a Message",
                            systemImage: "text.bubble",
                            description: Text(
                                "Messages queue locally and sync even when oMLX is offline."))
                    }
                    ForEach(messages, id: \.id) { message in
                        AIMessageBubble(message: message)
                    }
                    ForEach(tasks, id: \.id) { task in
                        AITaskProgressRow(task: task)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: messages.last?.id) {
                withAnimation {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }
}

private struct AIMessageBubble: View {
    let message: AiMessageRow

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(message.role.capitalized)
                        .font(.caption)
                        .bold()
                    Spacer()
                    Text(message.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ChatMarkdownView(content: message.body)
                if !message.sources.isEmpty {
                    AIMessageSources(sources: message.sources)
                }
                if !message.toolInvocations.isEmpty {
                    AIMessageTools(tools: message.toolInvocations)
                }
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("Thinking") {
                        ChatMarkdownView(content: reasoning)
                    }
                }
                if !message.attachments.isEmpty {
                    AIMessageAttachments(attachments: message.attachments)
                }
                AIMessageProvenance(message: message)
            }
            .padding(12)
            .background(isUser ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
            .clipShape(.rect(cornerRadius: 12))
            if !isUser { Spacer(minLength: 36) }
        }
    }
}

private struct AIMessageSources: View {
    let sources: [AiWebSourceRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Sources")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(sources, id: \.id) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        Label(source.title, systemImage: "link")
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct AIMessageTools: View {
    let tools: [AiToolInvocationRow]

    var body: some View {
        DisclosureGroup("Tools used · \(tools.count)") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(tools, id: \.id) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(tool.tool)
                                .font(.caption)
                                .bold()
                            Spacer()
                            Text(tool.state)
                                .font(.caption2)
                                .foregroundStyle(tool.error == nil ? Color.secondary : Color.red)
                        }
                        if !tool.provider.isEmpty {
                            Text(tool.provider)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let detail = tool.error ?? tool.resultSummary, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(tool.error == nil ? Color.secondary : Color.red)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(7)
                    .background(.quaternary)
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct AIMessageAttachments: View {
    let attachments: [AiAttachmentRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(attachments, id: \.id) { attachment in
                HStack {
                    Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                    VStack(alignment: .leading) {
                        Text(attachment.fileName ?? attachment.mimeType)
                            .lineLimit(1)
                        Text("\(attachment.byteLength) bytes · sha256 \(attachment.sha256.prefix(12))…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct AIMessageProvenance: View {
    let message: AiMessageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let model = message.model {
                Text("Model: \(model)")
            }
            if let runID = message.producedByRunId {
                Text("Run: \(runID)")
            }
            Text("Message: \(message.id)")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
}

private struct AITaskProgressRow: View {
    let task: AiTaskRow

    private var detail: String {
        if let error = task.error { return error }
        if task.state == "pending" { return "Waiting for the laptop’s Impress model worker" }
        if let runID = task.runId { return "Run \(runID)" }
        return task.id
    }

    var body: some View {
        HStack(spacing: 10) {
            if task.state == "pending" || task.state == "running" {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: task.state == "failed" ? "exclamationmark.triangle" : "checkmark.circle")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(task.error == nil ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(task.state.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 10))
    }
}

private struct AIConversationComposer: View {
    @Bindable var model: AIConversationWorkspaceModel
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingAttachments, id: \.itemID) { attachment in
                            AIComposerAttachmentChip(
                                attachment: attachment,
                                remove: { removeAttachment(attachment.itemID) })
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button("Attach", systemImage: "paperclip") {
                    isImporting = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(model.isMutating)

                TextField("Message local AI", text: $model.composerText, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend)
            }
        }
        .padding()
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image, .audio, .plainText, .json, .data],
            allowsMultipleSelection: true,
            onCompletion: importFiles)
    }

    private var canSend: Bool {
        !model.isMutating
            && (!model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.pendingAttachments.isEmpty)
    }

    private func send() {
        let workspace = model
        Task {
            await workspace.sendComposer()
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            let workspace = model
            Task {
                await workspace.addAttachments(from: urls)
            }
        } catch {
            model.reportImportError(error)
        }
    }

    private func removeAttachment(_ id: UUID) {
        model.removeAttachment(id: id)
    }
}

private struct AIComposerAttachmentChip: View {
    let attachment: ImpartAIAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.fileName ?? attachment.mimeType)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteLength), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Remove attachment", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }
}
