import Foundation
import ImpelToolsFFI

/// Which slice of the suite's 123 tools the model is shown this round.
///
/// Deriving the tool surface from the service inventory took impel from 11
/// tools to 123 — and ~13k tokens of JSON Schema in every single request, which
/// is both expensive and measurably worse for tool selection: a model choosing
/// among 123 similarly-named options picks wrong more often than one choosing
/// among 20.
///
/// So the surface is opened on demand. A small set of discovery namespaces is
/// live from the start; the rest arrive when the model asks for them through
/// `list_tool_namespaces` / `enable_tool_namespace`. Those two are resolved
/// here and never reach the Rust layer — they are facts about the loop, not
/// capabilities of the suite.
///
/// This is loop policy, deliberately in one place and deliberately *not* a
/// second copy of the tool list: it names namespaces, never individual tools,
/// so it cannot drift as capabilities are added. A new method in an
/// already-enabled namespace simply appears.
public struct ToolNamespaceGate: Sendable {

    /// Namespaces live before the model asks for anything.
    ///
    /// The discovery entry points, because almost every task starts by finding
    /// something: search the library, search the outside world. 16 tools,
    /// ~1.7k tokens. Everything else — tags, annotations, artifacts, undo,
    /// manuscripts, throughline — is one `enable_tool_namespace` call away.
    public static let defaultNamespaces: Set<String> = [
        "imbib-search-service",
        "imbib-scix-service",
    ]

    public private(set) var enabled: Set<String>

    public init(enabled: Set<String> = ToolNamespaceGate.defaultNamespaces) {
        self.enabled = enabled
    }

    // MARK: - Meta-tools

    public static let listNamespacesTool = "list_tool_namespaces"
    public static let enableNamespaceTool = "enable_tool_namespace"

    public static func isMetaTool(_ name: String) -> Bool {
        name == listNamespacesTool || name == enableNamespaceTool
    }

    /// Whether a namespace is currently open.
    public func admits(_ namespace: String) -> Bool {
        enabled.contains(namespace)
    }

    /// Open a namespace. Returns false when no such namespace exists, so the
    /// model gets a correction rather than a silent no-op.
    @discardableResult
    public mutating func enable(_ namespace: String, known: Set<String>) -> Bool {
        guard known.contains(namespace) else { return false }
        enabled.insert(namespace)
        return true
    }

    // MARK: - Descriptions

    /// A human-readable inventory of namespaces, built from the descriptors
    /// themselves — counts and membership are never hand-written.
    public static func summary(of descriptors: [ToolDescriptor], enabled: Set<String>) -> String {
        var counts: [String: Int] = [:]
        for d in descriptors where !d.namespace.isEmpty {
            counts[d.namespace, default: 0] += 1
        }
        let rows = counts.keys.sorted().map { ns -> String in
            let state = enabled.contains(ns) ? "enabled" : "available"
            return "- \(ns) (\(counts[ns] ?? 0) tools, \(state))"
        }
        return """
            Tool namespaces in this impress suite. Enabled ones are already \
            listed among your tools; call \(enableNamespaceTool) with a namespace \
            name to add the rest.

            \(rows.joined(separator: "\n"))
            """
    }
}
