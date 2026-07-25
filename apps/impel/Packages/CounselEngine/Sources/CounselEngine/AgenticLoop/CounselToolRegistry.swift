import Foundation
import ImpelToolsFFI
import ImpressAI
import ImpressKit
import ImpressLogging
import OSLog

/// The tools available to the Counsel agent loop.
///
/// This used to be a hand-written list: 11 `AITool` literals built out of nested
/// `AnySendable` dictionaries, plus one `switch` case per tool that unpacked the
/// arguments and knew which sibling endpoint to call. Nothing checked that the
/// two halves agreed with each other, or with the suite. They did not — 11 tools
/// declared against 124 `#[impress_service]` methods that imbib and imprint
/// already generate. Anything shipped after the list was written (library backup,
/// for one) never reached the agent at all.
///
/// Both halves are now a projection of the `impel-tools` inventory, which is the
/// same inventory `crates/impress-mcp` serves. Declarations come from the trait
/// method's signature, descriptions from its doc comment, and dispatch is the
/// method's own generated handler. Adding a capability anywhere in the suite
/// makes it available here with no change to this file.
///
/// **Availability is not assumed.** `configure` reports, per sibling app,
/// whether the HTTP backend actually installed. When it did not — the app is not
/// running — that app's tools are withheld rather than advertised and failed on
/// call, because the alternative is worse than absence: the Rust layer would
/// otherwise fall through to the shared SQLite store and write it behind the
/// running app's back.
public actor CounselToolRegistry {
    private let logger = Logger(subsystem: "com.impress.impel", category: "tool-registry")

    /// The residue: capabilities with no `#[impress_service]` trait yet, still
    /// wired by hand over `SiblingBridge`.
    ///
    /// implore and impart have no `*-service` crate at all, so deriving
    /// everything from the inventory would have silently dropped these two —
    /// a capability regression disguised as a cleanup. They stay until the
    /// codegen reaches those apps, and this list is deliberately visible and
    /// deliberately short: it is the backlog, and it should only ever shrink.
    ///
    /// (imbib's backup routes are also HTTP-only, but the agent never had them,
    /// so nothing regresses by leaving them out until `imbib-service` grows a
    /// backup trait.)
    private static let residueTools: [AITool] = [
        AITool(
            name: "implore_list_figures",
            description: "List figures currently open in implore.",
            inputSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([String: AnySendable]()),
            ]
        ),
        AITool(
            name: "impart_list_conversations",
            description: "List recent research conversations in impart.",
            inputSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "limit": AnySendable([
                        "type": AnySendable("integer"),
                        "description": AnySendable("Max results (default 20)"),
                    ] as [String: AnySendable])
                ] as [String: AnySendable]),
            ]
        ),
    ]

    private static func isResidueTool(_ name: String) -> Bool {
        residueTools.contains { $0.name == name }
    }

    private let bridge = SiblingBridge.shared

    private var backends: ToolBackends?
    private var cachedTools: [AITool]?
    private var gate: ToolNamespaceGate

    public init(gate: ToolNamespaceGate = ToolNamespaceGate()) {
        self.gate = gate
    }

    // MARK: - Configuration

    /// Point the service traits at the running siblings. Idempotent; the Rust
    /// side latches the first call.
    ///
    /// Called lazily on first use rather than at init: this reaches out over
    /// HTTP, and nothing that touches the network belongs on the app-launch
    /// path (see the startup-grace invariant in the root CLAUDE.md).
    private func ensureConfigured() -> ToolBackends {
        if let backends { return backends }

        let resolved = configure(
            imbibUrl: Self.automationURL(for: .imbib),
            imprintUrl: Self.automationURL(for: .imprint)
        )
        backends = resolved

        logger.infoCapture(
            "Tool backends: imbib=\(String(describing: resolved.imbib)) "
                + "imprint=\(String(describing: resolved.imprint))",
            category: "tool-registry"
        )
        return resolved
    }

    // MARK: - Tool Definitions

    /// Every tool whose owning app is reachable right now.
    ///
    /// Not cached across configuration changes on purpose — a sibling launched
    /// mid-session should become usable without restarting impel.
    public func allTools() -> [AITool] {
        _ = ensureConfigured()

        if let cachedTools { return cachedTools }

        let descriptors = listAvailableTools()
        let admitted = descriptors.filter { gate.admits($0.namespace) }
        let tools = admitted.compactMap { descriptor -> AITool? in
            guard let schema = Self.decodeSchema(descriptor.inputSchemaJson) else {
                // A descriptor whose schema will not parse is a codegen bug, not
                // a runtime condition. Drop it rather than send the model a tool
                // it cannot call, and say so loudly.
                logger.errorCapture(
                    "Tool \(descriptor.name) has an unparseable input schema; dropped",
                    category: "tool-registry"
                )
                return nil
            }
            return AITool(
                name: descriptor.name,
                description: descriptor.description,
                inputSchema: schema
            )
        }

        let all = Set(descriptors.map(\.namespace).filter { !$0.isEmpty })
        logger.infoCapture(
            "Tools exposed: \(tools.count) of \(descriptors.count) reachable; "
                + "namespaces \(gate.enabled.sorted().joined(separator: ", ")) "
                + "open of \(all.count)",
            category: "tool-registry"
        )
        if descriptors.isEmpty {
            logger.warningCapture(
                "No tools available — no sibling app is reachable. "
                    + "The agent will have nothing to call.",
                category: "tool-registry"
            )
        }

        let complete = tools + Self.residueTools + Self.metaTools
        cachedTools = complete
        return complete
    }

    /// The two loop-level tools that open the rest of the surface. Declared
    /// here rather than in the inventory because they describe impel's own
    /// behaviour, not a capability of any sibling app.
    private static let metaTools: [AITool] = [
        AITool(
            name: ToolNamespaceGate.listNamespacesTool,
            description: "List the tool namespaces this impress suite offers, with how many "
                + "tools each holds and whether it is already enabled. Call this when the tool "
                + "you need does not appear in your current tool list.",
            inputSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([String: AnySendable]()),
            ]
        ),
        AITool(
            name: ToolNamespaceGate.enableNamespaceTool,
            description: "Enable a tool namespace so its tools become available to you on the "
                + "next turn. Use the exact namespace name from list_tool_namespaces, e.g. "
                + "'imbib-tags-service'.",
            inputSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "namespace": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Namespace to enable"),
                    ] as [String: AnySendable])
                ] as [String: AnySendable]),
                "required": AnySendable([AnySendable("namespace")]),
            ]
        ),
    ]

    /// Drop the cached list so the next `allTools()` re-probes. Call when a
    /// sibling app is known to have started or stopped.
    public func invalidate() {
        cachedTools = nil
    }

    /// Tools still wired by hand because their app has no service crate.
    /// Watch this shrink; it should never grow.
    public nonisolated var residueToolNames: [String] { Self.residueTools.map(\.name) }

    // MARK: - Tool Execution

    /// Execute a tool call by name against the generated handler.
    public func execute(_ toolUse: AIToolUse) async -> AIToolResult {
        _ = ensureConfigured()

        // Loop-level tools never reach the Rust layer.
        if ToolNamespaceGate.isMetaTool(toolUse.name) {
            return handleMetaTool(toolUse)
        }

        // Residue: still hand-dispatched, until implore and impart grow
        // service crates and can join the inventory like everything else.
        if Self.isResidueTool(toolUse.name) {
            return await executeResidue(toolUse)
        }

        let argsJSON: String
        do {
            argsJSON = try Self.encodeArguments(toolUse.input)
        } catch {
            logger.errorCapture(
                "Tool \(toolUse.name): could not encode arguments: \(error.localizedDescription)",
                category: "tool-registry"
            )
            return AIToolResult(
                toolUseId: toolUse.id,
                content: "Could not encode arguments: \(error.localizedDescription)",
                isError: true
            )
        }

        do {
            let result = try callTool(name: toolUse.name, argsJson: argsJSON)
            logger.infoCapture("Tool \(toolUse.name) executed successfully", category: "tool-registry")
            return AIToolResult(toolUseId: toolUse.id, content: result)
        } catch let error as ToolError {
            // `appUnavailable` is a fact about the environment, not a failure of
            // the call. Distinguish it so the transcript does not read as a bug
            // and the model does not retry into the same wall.
            let message = Self.describe(error)
            switch error {
            case .AppUnavailable:
                logger.warningCapture("Tool \(toolUse.name): \(message)", category: "tool-registry")
                cachedTools = nil
            default:
                logger.errorCapture("Tool \(toolUse.name): \(message)", category: "tool-registry")
            }
            return AIToolResult(toolUseId: toolUse.id, content: message, isError: true)
        } catch {
            logger.errorCapture(
                "Tool \(toolUse.name) failed: \(error.localizedDescription)",
                category: "tool-registry"
            )
            return AIToolResult(
                toolUseId: toolUse.id,
                content: "Error: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - Residue dispatch

    private func executeResidue(_ toolUse: AIToolUse) async -> AIToolResult {
        do {
            let result: String
            switch toolUse.name {
            case "implore_list_figures":
                let data = try await bridge.getRaw("/api/figures", from: .implore)
                result = String(data: data, encoding: .utf8) ?? "[]"

            case "impart_list_conversations":
                let limit: Int = toolUse.input["limit"]?.get() ?? 20
                let data = try await bridge.getRaw(
                    "/api/research/conversations", from: .impart,
                    query: ["limit": String(limit)]
                )
                result = String(data: data, encoding: .utf8) ?? "[]"

            default:
                return AIToolResult(
                    toolUseId: toolUse.id,
                    content: "Unknown tool: \(toolUse.name)",
                    isError: true
                )
            }
            logger.infoCapture(
                "Residue tool \(toolUse.name) executed successfully", category: "tool-registry")
            return AIToolResult(toolUseId: toolUse.id, content: result)
        } catch {
            logger.errorCapture(
                "Residue tool \(toolUse.name) failed: \(error.localizedDescription)",
                category: "tool-registry"
            )
            return AIToolResult(
                toolUseId: toolUse.id,
                content: "Error: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - Namespace gating

    private func handleMetaTool(_ toolUse: AIToolUse) -> AIToolResult {
        let descriptors = listAvailableTools()

        switch toolUse.name {
        case ToolNamespaceGate.listNamespacesTool:
            let summary = ToolNamespaceGate.summary(of: descriptors, enabled: gate.enabled)
            logger.infoCapture("Namespaces listed for the model", category: "tool-registry")
            return AIToolResult(toolUseId: toolUse.id, content: summary)

        case ToolNamespaceGate.enableNamespaceTool:
            guard let namespace: String = toolUse.input["namespace"]?.get() else {
                return AIToolResult(
                    toolUseId: toolUse.id,
                    content: "enable_tool_namespace requires a 'namespace' argument.",
                    isError: true
                )
            }
            let known = Set(descriptors.map(\.namespace).filter { !$0.isEmpty })
            guard gate.enable(namespace, known: known) else {
                logger.warningCapture(
                    "Model asked for unknown namespace '\(namespace)'", category: "tool-registry")
                return AIToolResult(
                    toolUseId: toolUse.id,
                    content: "No namespace named '\(namespace)'. Known namespaces: "
                        + known.sorted().joined(separator: ", "),
                    isError: true
                )
            }
            // The tool list changed; the next allTools() must rebuild it.
            cachedTools = nil
            let added = descriptors.filter { $0.namespace == namespace }.count
            logger.infoCapture(
                "Namespace '\(namespace)' enabled (+\(added) tools)", category: "tool-registry")
            return AIToolResult(
                toolUseId: toolUse.id,
                content: "Enabled \(namespace); its \(added) tools are available from your next "
                    + "turn onwards."
            )

        default:
            return AIToolResult(
                toolUseId: toolUse.id,
                content: "Unknown tool: \(toolUse.name)",
                isError: true
            )
        }
    }

    /// The sibling's automation API base. Loopback only — this is the same
    /// endpoint `SiblingBridge` probes, and the Rust HTTP backend takes it as a
    /// base URL rather than a port.
    private static func automationURL(for app: SiblingApp) -> String {
        "http://127.0.0.1:\(app.httpPort)"
    }

    // MARK: - JSON bridging

    /// A generated JSON Schema string as the `[String: AnySendable]` the
    /// Anthropic client wants.
    private static func decodeSchema(_ json: String) -> [String: AnySendable]? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object.mapValues(AnySendable.fromJSON)
    }

    /// The model's tool input as the JSON object the generated handler expects.
    private static func encodeArguments(_ input: [String: AnySendable]) throws -> String {
        let object = input.mapValues { $0.toJSONValue() }
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func describe(_ error: ToolError) -> String {
        // Cases keep the Rust spelling: UniFFI does not lower-camel enum cases.
        switch error {
        case let .UnknownTool(name):
            return "Unknown tool: \(name)"
        case let .BadArguments(name, message):
            return "\(name): arguments were not a JSON object — \(message)"
        case let .Handler(name, message):
            return "\(name) failed: \(message)"
        case let .AppUnavailable(app, name):
            return "\(app) is not running, so \(name) is unavailable. "
                + "Open \(app) and try again, or use a different approach."
        }
    }
}
