//
//  KoineStyle.swift
//  ImpressSurface
//
//  The Swift half of `docs/plan-koine-style.md`. Slot names and the checks
//  on a value are the same ones `crates/koine/src/style.rs` applies. This
//  file does not link that crate. `KoineStyleTests` reads the committed
//  vocabulary file and fails when the two tables drift.
//
//  `automatic` applies no modifier. A sheet whose frontend id is not `swift`
//  is not painted: a line template is never used as a color.
//

import SwiftUI

public enum KoineValueKind: String, Equatable, Sendable {
    case color
    case spacing
    case font
    case line
}

public struct KoineSlot: Equatable, Sendable {
    public let name: String
    public let kind: KoineValueKind
    public let defaultValue: String

    public init(name: String, kind: KoineValueKind, defaultValue: String) {
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

public enum KoineStyleError: Error, Equatable, LocalizedError {
    case unknownFrontend(String)
    case unknownSlot(frontend: String, slot: String)
    case invalidValue(slot: String, kind: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownFrontend(let frontend):
            return "unknown frontend '\(frontend)'"
        case .unknownSlot(let frontend, let slot):
            return "\(frontend) has no slot '\(slot)'"
        case .invalidValue(let slot, let kind, let reason):
            return "slot '\(slot)' is \(kind), and \(reason)"
        }
    }
}

/// Values for one frontend. Every required slot is present after `make`.
public struct KoineStyleSheet: Equatable, Sendable {
    public static let swiftID = "swift"
    public static let tuiID = "tui"
    /// The browser (koine `koine-dioxus`, docs/plan-koine-web.md D3). Its
    /// value kinds are Swift's; Swift never paints its sheet, it only keeps
    /// the book complete so a file an agent or the page wrote round-trips.
    public static let webID = "web"
    public static let frontendIDs = [swiftID, tuiID, webID]
    public static let colorTokens = [
        "automatic", "accent", "primary", "secondary", "error", "warning", "info",
    ]
    public static let fontTokens = ["automatic", "body", "title", "mono"]
    public static let placeholders = [
        "columns", "label", "level", "message", "text", "title", "value",
    ]
    public static let spacingMax = 64

    public static let swiftDefault = KoineStyleSheet.make(swiftID)

    public let frontend: String
    public private(set) var values: [String: String]

    public static func slots(frontend: String) -> [KoineSlot]? {
        tables[frontend]
    }

    public static func make(_ frontend: String) -> KoineStyleSheet {
        guard let slots = tables[frontend] else {
            preconditionFailure("unknown frontend '\(frontend)'")
        }
        var values: [String: String] = [:]
        for slot in slots {
            values[slot.name] = slot.defaultValue
        }
        return KoineStyleSheet(frontend: frontend, values: values)
    }

    /// The sheet Swift paints. Another frontend's sheet is left alone and the
    /// Swift default is used instead.
    var paintedBySwift: KoineStyleSheet {
        frontend == Self.swiftID ? self : .swiftDefault
    }

    public func value(_ slot: String) -> String {
        if let stored = values[slot] {
            return stored
        }
        return Self.slots(frontend: frontend)?.first { $0.name == slot }?.defaultValue ?? ""
    }

    public mutating func set(slot: String, raw: String) throws {
        let decl = try declaration(slot)
        try Self.check(slot: slot, kind: decl.kind, raw: raw)
        values[slot] = raw
    }

    public mutating func reset(slot: String) throws {
        let decl = try declaration(slot)
        values[slot] = decl.defaultValue
    }

    public mutating func resetAll() {
        self = Self.make(frontend)
    }

    /// Spacing for a Swift slot, or 0 when this sheet is not Swift's.
    public func spacing(_ slot: String) -> CGFloat {
        guard frontend == Self.swiftID, let n = Int(value(slot)) else { return 0 }
        return CGFloat(n)
    }

    /// The system color for a color slot, or nil for `automatic` and for a
    /// sheet this frontend does not paint.
    public func color(_ slot: String) -> Color? {
        guard frontend == Self.swiftID else { return nil }
        return KoinePaint.color(for: value(slot))
    }

    private func declaration(_ slot: String) throws -> KoineSlot {
        guard let decl = Self.slots(frontend: frontend)?.first(where: { $0.name == slot }) else {
            throw KoineStyleError.unknownSlot(frontend: frontend, slot: slot)
        }
        return decl
    }

    static func check(slot: String, kind: KoineValueKind, raw: String) throws {
        switch kind {
        case .color:
            guard colorTokens.contains(raw) else {
                throw KoineStyleError.invalidValue(
                    slot: slot, kind: kind.rawValue, reason: "'\(raw)' is not a color token")
            }
        case .font:
            guard fontTokens.contains(raw) else {
                throw KoineStyleError.invalidValue(
                    slot: slot, kind: kind.rawValue, reason: "'\(raw)' is not a font token")
            }
        case .spacing:
            let canonical = raw.count == 1 || !raw.hasPrefix("0")
            let parsed = Int(raw)
            if !canonical || parsed == nil || (parsed ?? 0) < 0 || (parsed ?? 0) > spacingMax {
                throw KoineStyleError.invalidValue(
                    slot: slot,
                    kind: kind.rawValue,
                    reason: "'\(raw)' is not an integer from 0 to \(spacingMax)")
            }
        case .line:
            try checkLine(slot: slot, raw: raw)
        }
    }

    private static func checkLine(slot: String, raw: String) throws {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw KoineStyleError.invalidValue(
                slot: slot, kind: KoineValueKind.line.rawValue, reason: "it is empty")
        }
        var rest = Substring(raw)
        while let start = rest.range(of: "{") {
            let after = rest[start.upperBound...]
            guard let end = after.range(of: "}") else {
                throw KoineStyleError.invalidValue(
                    slot: slot, kind: KoineValueKind.line.rawValue, reason: "it has an unclosed '{'")
            }
            let name = String(after[..<end.lowerBound])
            if !placeholders.contains(name) {
                throw KoineStyleError.invalidValue(
                    slot: slot,
                    kind: KoineValueKind.line.rawValue,
                    reason: "'{\(name)}' names an unknown placeholder")
            }
            rest = after[end.upperBound...]
        }
    }

    private static let tables: [String: [KoineSlot]] = [
        swiftID: [
            KoineSlot(name: "column", kind: .spacing, defaultValue: "8"),
            KoineSlot(name: "row", kind: .spacing, defaultValue: "8"),
            KoineSlot(name: "text", kind: .font, defaultValue: "automatic"),
            KoineSlot(name: "section", kind: .font, defaultValue: "automatic"),
            KoineSlot(name: "button", kind: .color, defaultValue: "automatic"),
            KoineSlot(name: "field", kind: .font, defaultValue: "automatic"),
            KoineSlot(name: "list", kind: .spacing, defaultValue: "0"),
            KoineSlot(name: "table", kind: .spacing, defaultValue: "0"),
            KoineSlot(name: "status.error", kind: .color, defaultValue: "error"),
            KoineSlot(name: "status.warning", kind: .color, defaultValue: "warning"),
            KoineSlot(name: "status.info", kind: .color, defaultValue: "info"),
            KoineSlot(name: "focus", kind: .color, defaultValue: "automatic"),
        ],
        tuiID: [
            KoineSlot(name: "column", kind: .spacing, defaultValue: "2"),
            KoineSlot(name: "row", kind: .spacing, defaultValue: "2"),
            KoineSlot(name: "text", kind: .line, defaultValue: "text {text}"),
            KoineSlot(name: "section", kind: .line, defaultValue: "section {title}"),
            KoineSlot(name: "button", kind: .line, defaultValue: "button {label}"),
            KoineSlot(name: "field", kind: .line, defaultValue: "field {value}"),
            KoineSlot(name: "list", kind: .line, defaultValue: "list"),
            KoineSlot(name: "table", kind: .line, defaultValue: "table {columns}"),
            KoineSlot(name: "status.error", kind: .line, defaultValue: "status error: {message}"),
            KoineSlot(name: "status.warning", kind: .line, defaultValue: "status warning: {message}"),
            KoineSlot(name: "status.info", kind: .line, defaultValue: "status info: {message}"),
            KoineSlot(name: "focus", kind: .line, defaultValue: ">"),
        ],
        webID: [
            KoineSlot(name: "column", kind: .spacing, defaultValue: "8"),
            KoineSlot(name: "row", kind: .spacing, defaultValue: "8"),
            KoineSlot(name: "text", kind: .font, defaultValue: "automatic"),
            KoineSlot(name: "section", kind: .font, defaultValue: "automatic"),
            KoineSlot(name: "button", kind: .color, defaultValue: "automatic"),
            KoineSlot(name: "field", kind: .font, defaultValue: "automatic"),
            KoineSlot(name: "list", kind: .spacing, defaultValue: "0"),
            KoineSlot(name: "table", kind: .spacing, defaultValue: "0"),
            KoineSlot(name: "status.error", kind: .color, defaultValue: "error"),
            KoineSlot(name: "status.warning", kind: .color, defaultValue: "warning"),
            KoineSlot(name: "status.info", kind: .color, defaultValue: "info"),
            KoineSlot(name: "focus", kind: .color, defaultValue: "automatic"),
        ],
    ]
}

/// Sheets for every declared frontend. `set` works while no view is showing
/// the sheet. This process does not share the book with another process.
public struct KoineStyleBook: Equatable, Sendable {
    private var sheets: [String: KoineStyleSheet]

    public init() {
        var sheets: [String: KoineStyleSheet] = [:]
        for frontend in KoineStyleSheet.frontendIDs {
            sheets[frontend] = KoineStyleSheet.make(frontend)
        }
        self.sheets = sheets
    }

    public func sheet(frontend: String) -> KoineStyleSheet? {
        sheets[frontend]
    }

    public mutating func set(frontend: String, slot: String, raw: String) throws {
        guard var sheet = sheets[frontend] else {
            throw KoineStyleError.unknownFrontend(frontend)
        }
        try sheet.set(slot: slot, raw: raw)
        sheets[frontend] = sheet
    }

    public mutating func reset(frontend: String, slot: String) throws {
        guard var sheet = sheets[frontend] else {
            throw KoineStyleError.unknownFrontend(frontend)
        }
        try sheet.reset(slot: slot)
        sheets[frontend] = sheet
    }

    public mutating func resetAll(frontend: String) throws {
        guard sheets[frontend] != nil else {
            throw KoineStyleError.unknownFrontend(frontend)
        }
        sheets[frontend] = KoineStyleSheet.make(frontend)
    }

    public mutating func replace(_ sheet: KoineStyleSheet) throws {
        guard sheets[sheet.frontend] != nil else {
            throw KoineStyleError.unknownFrontend(sheet.frontend)
        }
        sheets[sheet.frontend] = sheet
    }
}

private struct KoineStyleKey: EnvironmentKey {
    static let defaultValue = KoineStyleSheet.swiftDefault
}

public extension EnvironmentValues {
    /// The sheet the surface paints. The default is the Swift sheet, which
    /// draws what `SurfaceView` drew before a sheet existed.
    var koineStyle: KoineStyleSheet {
        get { self[KoineStyleKey.self] }
        set { self[KoineStyleKey.self] = newValue }
    }
}

enum KoinePaint {
    static func color(for token: String) -> Color? {
        switch token {
        case "automatic": return nil
        case "accent": return .accentColor
        case "primary": return .primary
        case "secondary": return .secondary
        case "error": return .red
        case "warning": return .orange
        case "info": return .secondary
        default: return nil
        }
    }

    static func font(for token: String) -> Font? {
        switch token {
        case "automatic": return nil
        case "body": return .body
        case "title": return .title
        case "mono": return .system(.body, design: .monospaced)
        default: return nil
        }
    }
}

extension View {
    @ViewBuilder
    func koineFont(_ token: String) -> some View {
        if let font = KoinePaint.font(for: token) {
            self.font(font)
        } else {
            self
        }
    }
}
