// AgentDesk.swift — koine's agent desk from a Swift app
// (koine docs/plan-koine-research-os.md G-D5).
//
// "Ask an Agent…" (⌃⌥⌘A, `imbib.view.ask_agent` / `imprint.edit.ask_agent`
// in impress-keymap) files a request on the desk with `agent-service_ask`,
// passing the app's id so the request carries the app's own layout focus
// and selection as its context. Whichever agent is connected picks it up:
// impel-taskd's desk bridge (impress's own model and tools), or Claude Code
// over MCP (`agent-service_next`). The answer comes back on the desk, which
// this sheet lists. Rust decides everything; this file only calls verbs
// through `dispatchVerb` (impress-store-ffi links koine-agent in the kit).

import Foundation
import SwiftUI
import ImpressKit
import ImpressRustCore

public extension Notification.Name {
    /// Posted by an app's "Ask an Agent…" command.
    static let impressAskAgent = Notification.Name("impressAskAgent")
}

/// One request on the desk, as the sheet lists it.
public struct AgentDeskRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let status: String
    public let prompt: String
    public let answer: String?
    public let claimedBy: String?
}

/// Why a desk call did not happen: the verb's refusal message, or the
/// transport's.
public struct AgentDeskError: Error, Equatable, Sendable {
    public let message: String
}

/// The desk's verbs, called as the app on behalf of the person.
public enum AgentDesk {
    public static let askVerb = "agent-service_ask"
    public static let requestsVerb = "agent-service_requests"

    static func call(
        _ verb: String, _ args: [String: Any], app: String
    ) -> Result<[String: Any], AgentDeskError> {
        guard let argsData = try? JSONSerialization.data(withJSONObject: args),
              let argsJSON = String(data: argsData, encoding: .utf8)
        else { return .failure(AgentDeskError(message: "the arguments are not JSON")) }
        let caller = "{\"kind\":\"app\",\"name\":\"\(app)\"}"
        let result = dispatchVerb(name: verb, argsJson: argsJSON, callerJson: caller)
        guard let data = result.bodyJson.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failure(AgentDeskError(message: "\(verb) answered HTTP \(result.status)"))
        }
        if let ok = body["ok"] as? Bool, ok == false {
            let message = body["message"] as? String ?? body["code"] as? String ?? "refused"
            return .failure(AgentDeskError(message: message))
        }
        return .success(body)
    }

    /// File `prompt` for an agent, with `app`'s layout as the context.
    /// Answers the request's id.
    public static func ask(_ prompt: String, app: String) -> Result<String, AgentDeskError> {
        call(askVerb, ["prompt": prompt, "app_id": app], app: app).flatMap { body in
            guard let request = body["request"] as? [String: Any],
                  let id = request["id"] as? String
            else { return .failure(AgentDeskError(message: "the desk answered no request")) }
            return .success(id)
        }
    }

    /// The desk, newest first.
    public static func requests(app: String) -> Result<[AgentDeskRequest], AgentDeskError> {
        call(requestsVerb, [:], app: app).map { body in
            (body["rows"] as? [[String: Any]] ?? []).map { row in
                AgentDeskRequest(
                    id: row["id"] as? String ?? "",
                    kind: row["kind"] as? String ?? "",
                    status: row["status"] as? String ?? "",
                    prompt: row["prompt"] as? String ?? "",
                    answer: row["answer"] as? String,
                    claimedBy: row["claimed_by"] as? String)
            }
        }
    }
}

/// The sheet "Ask an Agent…" opens: a prompt, Ask, and the desk below it.
public struct AskAgentSheet: View {
    let app: String
    @Binding var isPresented: Bool
    @State private var prompt = ""
    @State private var status: String?
    @State private var requests: [AgentDeskRequest] = []

    public init(app: String, isPresented: Binding<Bool>) {
        self.app = app
        self._isPresented = isPresented
    }

    private var trimmed: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask an Agent")
                .font(.headline)
            Text("Whichever agent is connected picks this up from the desk, with what you have selected, and answers here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 80)
                .accessibilityLabel("What to ask")
            HStack {
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Ask") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            if !requests.isEmpty {
                Divider()
                Text("Desk")
                    .font(.subheadline)
                List(requests) { request in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(request.status) · \(request.kind)\(request.claimedBy.map { " · \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(request.prompt)
                        if let answer = request.answer {
                            Text(answer)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .padding(20)
        .impressResizableSheet(minWidth: 480, minHeight: 240, idealHeight: 420)
        .task { await watchDesk() }
    }

    // The desk verbs write the suite store, so they run off the main thread
    // (a store open on main can block on the App Group prompt); only the
    // results come back to the view.
    private func submit() {
        let prompt = trimmed
        let app = app
        status = "Filing…"
        Task {
            let result = await Task.detached { AgentDesk.ask(prompt, app: app) }.value
            switch result {
            case .success(let id):
                status = "Filed request \(id.prefix(8))."
                self.prompt = ""
            case .failure(let error):
                status = error.message
            }
            await refresh()
        }
    }

    private func refresh() async {
        let app = app
        let result = await Task.detached { AgentDesk.requests(app: app) }.value
        switch result {
        case .success(let rows):
            if rows != requests { requests = rows }
        case .failure(let error):
            status = error.message
        }
    }

    /// The answer arrives on the desk whenever the agent finishes, so the
    /// sheet re-reads it while it is open. One sleep per pass and an
    /// explicit cancellation check: `.task` cancels this when the sheet
    /// closes.
    private func watchDesk() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}

/// Presents `AskAgentSheet` for `app` whenever `.impressAskAgent` is posted.
struct AskAgentPresenter: ViewModifier {
    let app: String
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .impressAskAgent)) { _ in
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                AskAgentSheet(app: app, isPresented: $isPresented)
            }
    }
}

public extension View {
    /// The "Ask an Agent…" sheet for `app`, opened by `.impressAskAgent`.
    func askAgentSheet(app: String) -> some View {
        modifier(AskAgentPresenter(app: app))
    }
}
