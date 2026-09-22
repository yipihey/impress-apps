//
//  RenderTree.swift
//  ImpressSurface
//
//  The Swift MIRROR of `impress_surface::resolve::{RenderTree, RenderNode,
//  RenderKind}` (`crates/impress-surface/src/resolve.rs`) and
//  `impress_surface::spec::{Event, EventKind}` (`crates/impress-surface/src/
//  spec.rs`) — what `SharedSurface.render(surfaceId:pane:)` hands back as
//  JSON, and what `SurfaceView` sends back through
//  `SharedSurface.dispatch(surfaceId:pane:eventJson:)`.
//
//  `RenderKind` is Rust's `#[serde(tag = "kind", rename_all = "snake_case")]`
//  — internally tagged, one flat JSON object per node (`{"kind": "column",
//  "items": […]}`). Swift's `Codable` has no built-in support for that shape
//  on an enum with per-case fields, so `RenderKind`'s `init(from:)` /
//  `encode(to:)` are hand-written, keyed by the `kind` tag — the same
//  discipline `LayoutModel.swift`'s header describes for the ADR-0031 wire
//  mirror, and pinned the same way: `RenderTreeGoldenTests` decodes the
//  actual Rust golden
//  (`crates/impress-surface/tests/golden/signal-explorer.render.json`)
//  rather than a hand-written fixture, so a serde change on either side
//  fails a test instead of a pane going silently blank.
//
//  An unrecognised `kind` string decodes to `.placeholder(unknownKind:
//  reason:)` rather than throwing — ADR-0033's "Defaults": "unknown widget
//  kinds degrade to a placeholder that keeps the node". This is the ONE
//  place besides Rust's own `resolve.rs` that rule has to be honoured: a
//  surface authored against a newer vocabulary than this build still renders
//  everything else.
//

import Foundation

// MARK: - Opaque JSON

/// An arbitrary JSON value — what a surface's `rows`, `spec`, `pairs`,
/// `lines`, `value` and field `options` carry, since those are the AGENT's
/// data, not this package's vocabulary. Mirrors `LayoutJSONValue`'s shape
/// (`Chassis/Layout/LayoutModel.swift` in PublicationManagerCore) — the same
/// idiom, kept as a separate type because this package must not depend on
/// PublicationManagerCore (ADR-0033 D7: kit-grade).
public enum SurfaceJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SurfaceJSONValue])
    case object([String: SurfaceJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SurfaceJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SurfaceJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrepresentable JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    public var objectValue: [String: SurfaceJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [SurfaceJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// A number, whether serde wrote it as an int or a double.
    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> SurfaceJSONValue? {
        objectValue?[key]
    }

    /// Parse a JSON string (the FFI hands every opaque value over as one).
    public static func decode(_ json: String) throws -> SurfaceJSONValue {
        try JSONDecoder().decode(SurfaceJSONValue.self, from: Data(json.utf8))
    }

    /// Serialize with sorted keys, so a hook fed this string gets a stable
    /// document.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// A short, human-legible rendering for the `.plain` hooks and for a
    /// `table`/`list` row's default cell text: a common "title-ish" key from
    /// an object when one exists, else the value stringified plainly.
    public var displayText: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .array(let value): return value.map(\.displayText).joined(separator: ", ")
        case .object(let value):
            for key in ["title", "name", "label", "text"] {
                if let found = value[key]?.stringValue, !found.isEmpty { return found }
            }
            return (try? jsonString()) ?? "{\u{2026}}"
        }
    }
}

// MARK: - RenderTree

/// What `SharedSurface.render(surfaceId:pane:)` returns, decoded —
/// `impress_surface::resolve::RenderTree`.
public struct RenderTree: Codable, Hashable, Sendable {
    public let root: RenderNode
    /// Ids of every `field`, `button`, `table`, `list` and `tabs` node, in
    /// depth-first reading order — what j/k walk (ADR-0033 "Defaults").
    public let focusOrder: [String]

    private enum CodingKeys: String, CodingKey {
        case root
        case focusOrder = "focus_order"
    }

    public init(root: RenderNode, focusOrder: [String]) {
        self.root = root
        self.focusOrder = focusOrder
    }

    /// Parse the JSON `SharedSurface.render`/`.dispatch` hand back.
    public static func decode(_ json: String) throws -> RenderTree {
        try JSONDecoder().decode(RenderTree.self, from: Data(json.utf8))
    }
}

/// `impress_surface::resolve::RenderNode` — always has an id (author-given
/// or auto-derived), unlike the authoring-side `Node` this mirrors nothing
/// of: this package never reads a `SurfaceSpec`, only what Rust already
/// resolved from one.
public struct RenderNode: Codable, Hashable, Sendable {
    public let id: String
    /// The common `label` annotation — NOT a `button`'s own display text
    /// (that is `RenderKind.button(label:)`); see `resolve.rs`'s module
    /// docs on why the two never collide in the wire shape.
    public let label: String?
    public let help: String?
    public let node: RenderKind

    private enum CodingKeys: String, CodingKey {
        case id, label, help, node
    }

    public init(id: String, label: String?, help: String?, node: RenderKind) {
        self.id = id
        self.label = label
        self.help = help
        self.node = node
    }
}

/// `impress_surface::resolve::RenderTab`.
public struct RenderTab: Codable, Hashable, Sendable {
    public let title: String
    public let body: RenderNode

    public init(title: String, body: RenderNode) {
        self.title = title
        self.body = body
    }
}

/// `impress_surface::resolve::RenderKind` — internally tagged on `"kind"`
/// (snake_case), hand-decoded because Swift's `Codable` cannot derive that
/// shape for an enum whose cases carry different fields. See this file's
/// header for the golden-pinned round trip and the unknown-kind rule.
///
/// `indirect` only where Rust boxes (`section`'s `body: Box<RenderNode>`):
/// every other recursive spot goes through `[RenderNode]`, already
/// heap-indirect via `Array`.
public enum RenderKind: Codable, Hashable, Sendable {
    case column(items: [RenderNode])
    case row(items: [RenderNode])
    case grid(columns: Int, items: [RenderNode])
    indirect case section(title: String, collapsed: Bool, body: RenderNode)
    case tabs(tabs: [RenderTab])
    case text(text: String)
    case table(rows: SurfaceJSONValue, columns: [String])
    case list(rows: SurfaceJSONValue)
    case plot(spec: SurfaceJSONValue)
    case image(blob: SurfaceJSONValue?, url: SurfaceJSONValue?)
    case field(field: SurfaceJSONValue, bind: String?, value: SurfaceJSONValue)
    case button(label: String)
    case status(level: String, message: String)
    case log(lines: SurfaceJSONValue)
    case kv(pairs: SurfaceJSONValue)
    case divider
    case spacer
    /// See the file header: an unrecognised `kind` tag ALSO lands here, with
    /// `unknownKind` carrying the raw string Rust could not name either
    /// (`RenderKind::Placeholder { unknown_kind, .. }`) — this build simply
    /// has one more reason than Rust does to produce this case (an old
    /// binary reading a tag a newer one invented).
    case placeholder(unknownKind: String?, reason: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case items
        case columns
        case title
        case collapsed
        case body
        case tabs
        case text
        case rows
        case spec
        case blob
        case url
        case field
        case bind
        case value
        case label
        case level
        case message
        case lines
        case pairs
        case unknownKind = "unknown_kind"
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "column":
            self = .column(items: try container.decode([RenderNode].self, forKey: .items))
        case "row":
            self = .row(items: try container.decode([RenderNode].self, forKey: .items))
        case "grid":
            self = .grid(
                columns: try container.decode(Int.self, forKey: .columns),
                items: try container.decode([RenderNode].self, forKey: .items))
        case "section":
            self = .section(
                title: try container.decode(String.self, forKey: .title),
                collapsed: try container.decode(Bool.self, forKey: .collapsed),
                body: try container.decode(RenderNode.self, forKey: .body))
        case "tabs":
            self = .tabs(tabs: try container.decode([RenderTab].self, forKey: .tabs))
        case "text":
            self = .text(text: try container.decode(String.self, forKey: .text))
        case "table":
            self = .table(
                rows: try container.decode(SurfaceJSONValue.self, forKey: .rows),
                columns: try container.decode([String].self, forKey: .columns))
        case "list":
            self = .list(rows: try container.decode(SurfaceJSONValue.self, forKey: .rows))
        case "plot":
            self = .plot(spec: try container.decode(SurfaceJSONValue.self, forKey: .spec))
        case "image":
            self = .image(
                blob: try container.decodeIfPresent(SurfaceJSONValue.self, forKey: .blob),
                url: try container.decodeIfPresent(SurfaceJSONValue.self, forKey: .url))
        case "field":
            self = .field(
                field: try container.decode(SurfaceJSONValue.self, forKey: .field),
                bind: try container.decodeIfPresent(String.self, forKey: .bind),
                value: try container.decode(SurfaceJSONValue.self, forKey: .value))
        case "button":
            self = .button(label: try container.decode(String.self, forKey: .label))
        case "status":
            self = .status(
                level: try container.decode(String.self, forKey: .level),
                message: try container.decode(String.self, forKey: .message))
        case "log":
            self = .log(lines: try container.decode(SurfaceJSONValue.self, forKey: .lines))
        case "kv":
            self = .kv(pairs: try container.decode(SurfaceJSONValue.self, forKey: .pairs))
        case "divider":
            self = .divider
        case "spacer":
            self = .spacer
        case "placeholder":
            self = .placeholder(
                unknownKind: try container.decodeIfPresent(String.self, forKey: .unknownKind),
                reason: try container.decodeIfPresent(String.self, forKey: .reason))
        default:
            // Forward-compat: ADR-0033's rule applies even to a `kind` tag
            // this build has literally never heard of.
            self = .placeholder(unknownKind: kind, reason: nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .column(let items):
            try container.encode("column", forKey: .kind)
            try container.encode(items, forKey: .items)
        case .row(let items):
            try container.encode("row", forKey: .kind)
            try container.encode(items, forKey: .items)
        case .grid(let columns, let items):
            try container.encode("grid", forKey: .kind)
            try container.encode(columns, forKey: .columns)
            try container.encode(items, forKey: .items)
        case .section(let title, let collapsed, let body):
            try container.encode("section", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(collapsed, forKey: .collapsed)
            try container.encode(body, forKey: .body)
        case .tabs(let tabs):
            try container.encode("tabs", forKey: .kind)
            try container.encode(tabs, forKey: .tabs)
        case .text(let text):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .table(let rows, let columns):
            try container.encode("table", forKey: .kind)
            try container.encode(rows, forKey: .rows)
            try container.encode(columns, forKey: .columns)
        case .list(let rows):
            try container.encode("list", forKey: .kind)
            try container.encode(rows, forKey: .rows)
        case .plot(let spec):
            try container.encode("plot", forKey: .kind)
            try container.encode(spec, forKey: .spec)
        case .image(let blob, let url):
            try container.encode("image", forKey: .kind)
            try container.encodeIfPresent(blob, forKey: .blob)
            try container.encodeIfPresent(url, forKey: .url)
        case .field(let field, let bind, let value):
            try container.encode("field", forKey: .kind)
            try container.encode(field, forKey: .field)
            try container.encodeIfPresent(bind, forKey: .bind)
            try container.encode(value, forKey: .value)
        case .button(let label):
            try container.encode("button", forKey: .kind)
            try container.encode(label, forKey: .label)
        case .status(let level, let message):
            try container.encode("status", forKey: .kind)
            try container.encode(level, forKey: .level)
            try container.encode(message, forKey: .message)
        case .log(let lines):
            try container.encode("log", forKey: .kind)
            try container.encode(lines, forKey: .lines)
        case .kv(let pairs):
            try container.encode("kv", forKey: .kind)
            try container.encode(pairs, forKey: .pairs)
        case .divider:
            try container.encode("divider", forKey: .kind)
        case .spacer:
            try container.encode("spacer", forKey: .kind)
        case .placeholder(let unknownKind, let reason):
            try container.encode("placeholder", forKey: .kind)
            try container.encodeIfPresent(unknownKind, forKey: .unknownKind)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

// MARK: - Events

/// `impress_surface::spec::Event` — what `SurfaceView` sends back through
/// `SharedSurface.dispatch(surfaceId:pane:eventJson:)`. Field names match
/// Rust's exactly, so no `CodingKeys` is needed in either direction.
public struct SurfaceEvent: Codable, Hashable, Sendable {
    public let widget: String
    public let kind: Kind
    public let value: SurfaceJSONValue

    public init(widget: String, kind: Kind, value: SurfaceJSONValue = .null) {
        self.widget = widget
        self.kind = kind
        self.value = value
    }

    /// `impress_surface::spec::EventKind` — snake_case, one word per case so
    /// `rename_all = "snake_case"` is a no-op on the wire spelling.
    public enum Kind: String, Codable, Hashable, Sendable {
        case change
        case click
        case select
        case submit
    }

    /// Serialize for `SharedSurface.dispatch(eventJson:)`.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
