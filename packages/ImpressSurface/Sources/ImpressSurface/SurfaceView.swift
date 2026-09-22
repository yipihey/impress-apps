//
//  SurfaceView.swift
//  ImpressSurface
//
//  Maps a `RenderTree` to SwiftUI, one node kind to one SwiftUI construct,
//  with no logic beyond that mapping and the keyboard grammar (ADR-0033 D2:
//  "the Swift renderer maps RenderTree nodes to SwiftUI one to one and holds
//  no logic"). Every interaction becomes a raw `SurfaceEvent` sent back
//  through `onEvent`; nothing here decides whether a widget's id has a
//  handler — that is `impress_surface::reduce::reduce`, in Rust, on the far
//  side of `SharedSurface.dispatch`.
//
//  ## Keyboard (ADR-0033 Defaults, `docs/keyboard-grammar.md` "Surface
//  panes")
//
//  j / k walk `tree.focusOrder`; Enter activates the focused widget; Escape
//  leaves a field. All of it lives under ONE `.keyboardGuarded` +
//  `.focusable()` pair on the OUTERMOST container (CLAUDE.md "Keyboard
//  Shortcuts Must Not Steal Text Field Input" — `.focusable()` never goes on
//  a view that contains a text field).
//
//  The grammar needs TWO separate pieces of focus state, not one, because a
//  single `@FocusState` would make j/k unusable the moment it lands on a
//  `text`/`number` field — giving that field REAL AppKit focus immediately
//  would swallow the very next `j` as a typed letter:
//
//  - `highlightedID` (`@State`) — the navigation cursor j/k always moves,
//    rendered as a highlight ring. Purely a Swift-side highlight; never
//    AppKit focus by itself.
//  - `focusedWidgetID` (`@FocusState`) — REAL focus. j/k also sets this
//    immediately for every widget kind that is not a `text`/`number` field
//    (a slider/select/toggle/date/button/table/list/tabs stop is not a
//    free-typing surface, so giving it real focus does not break `j`/`k` —
//    `TextFieldFocusDetection.isTextFieldFocused()` only guards an actual
//    editable text view). For a `text`/`number` field, `focusedWidgetID` is
//    set ONLY by Enter — the moment `.keyboardGuarded` is expected to start
//    yielding to the field, per the grammar's "begin editing a field".
//    Escape clears `focusedWidgetID` back to nil (real focus drops; the
//    highlight ring stays), which is "leave a field back to widget focus".
//
//  This two-layer split, the exact bubbling of Return/Escape between a
//  focused AppKit control and this view's own `.onKeyPress`, and whether
//  `.focused(_:equals:)` behaves as expected on `Table`/`TabView` are the
//  parts of this file `docs/plan-agent-surfaces.md` S7 marks Mac-only —
//  nothing here compiles or runs on Linux.
//

import SwiftUI
import ImpressKeyboard
import ImpressTheme
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SurfaceView

public struct SurfaceView: View {

    public let tree: RenderTree
    public let hooks: SurfaceHooks
    public let onEvent: (SurfaceEvent) -> Void

    @FocusState private var focusedWidgetID: String?
    @State private var highlightedID: String?

    public init(
        tree: RenderTree,
        hooks: SurfaceHooks = .plain,
        onEvent: @escaping (SurfaceEvent) -> Void
    ) {
        self.tree = tree
        self.hooks = hooks
        self.onEvent = onEvent
    }

    public var body: some View {
        ScrollView {
            SurfaceNodeView(
                node: tree.root,
                hooks: hooks,
                highlightedID: $highlightedID,
                focusedWidgetID: $focusedWidgetID,
                onEvent: send
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        // The OUTERMOST container, and the only one: no child of this tree
        // gets its own `.focusable()` (CLAUDE.md).
        .focusable()
        .keyboardGuarded { press in handleGuardedKey(press) }
        // Return / Escape are special keys — CLAUDE.md's exception list
        // ("Handlers that only match special keys ... don't conflict with
        // text input") — so they stay OUTSIDE `.keyboardGuarded` and are
        // free to fire even while a field has real focus. Whether a focused
        // AppKit control (a `TextField`'s own `onSubmit`, a focused
        // `Table`'s native Enter handling) consumes one before it bubbles
        // here is exactly the Mac-only part; see the file header.
        .onKeyPress(keys: [.return]) { _ in
            guard highlightedID != nil else { return .ignored }
            activateHighlighted()
            return .handled
        }
        .onKeyPress(keys: [.escape]) { _ in
            guard focusedWidgetID != nil else { return .ignored }
            focusedWidgetID = nil
            return .handled
        }
        .onAppear {
            if highlightedID == nil {
                highlightedID = tree.focusOrder.first
            }
        }
        .onChange(of: tree.focusOrder) { _, newOrder in
            // A fresh render (a `dispatch` reply, an invalidation re-render)
            // replaces the tree wholesale. Keep the cursor on the same
            // widget id if it still exists; otherwise the first stop — never
            // point it at a widget this tree no longer has.
            if let current = highlightedID, !newOrder.contains(current) {
                highlightedID = newOrder.first
            }
        }
    }

    // MARK: j / k

    private func handleGuardedKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        switch press.characters {
        case "j":
            move(by: 1)
            return .handled
        case "k":
            move(by: -1)
            return .handled
        default:
            return .ignored
        }
    }

    private func move(by delta: Int) {
        let order = tree.focusOrder
        guard !order.isEmpty else { return }
        let currentIndex = highlightedID.flatMap { order.firstIndex(of: $0) }
        let startIndex = currentIndex ?? (delta > 0 ? -1 : 0)
        let nextIndex = ((startIndex + delta) % order.count + order.count) % order.count
        let next = order[nextIndex]
        highlightedID = next
        if !isTextEntryField(id: next) {
            focusedWidgetID = next
        }
    }

    /// Every `SurfaceEvent` leaving this view funnels through here — the one
    /// point that also calls `hooks.log`, so a host gets a trace line for
    /// every widget interaction without this file threading `hooks` into
    /// each leaf view's own event-sending code.
    private func send(_ event: SurfaceEvent) {
        hooks.log("surface event: widget \(event.widget) kind \(event.kind.rawValue)")
        onEvent(event)
    }

    // MARK: Enter

    private func activateHighlighted() {
        guard let id = highlightedID,
            let target = SurfaceView.node(id: id, in: tree.root)
        else { return }
        switch target.node {
        case .button:
            send(SurfaceEvent(widget: id, kind: .click, value: .null))
        case .field(let fieldSpec, _, _):
            // "Begin editing a field" — the one case `move(by:)` withheld
            // real focus for. Every other kind already has it.
            if SurfaceView.isTextEntry(fieldSpec) {
                focusedWidgetID = id
            }
        default:
            // Table/list "select the highlighted row" and tabs' own stop
            // ("switching tabs", per `resolve.rs`'s doc comment on
            // `focus_order`) both fall to the control's own native keyboard
            // handling once it holds real focus — which `move(by:)` already
            // gave it. Mac-verify.
            focusedWidgetID = id
        }
    }

    private func isTextEntryField(id: String) -> Bool {
        guard let target = SurfaceView.node(id: id, in: tree.root),
            case .field(let fieldSpec, _, _) = target.node
        else { return false }
        return SurfaceView.isTextEntry(fieldSpec)
    }

    private static func isTextEntry(_ fieldSpec: SurfaceJSONValue) -> Bool {
        guard let subKind = fieldSpec.objectValue?.keys.first else { return false }
        return subKind == "text" || subKind == "number"
    }

    /// Depth-first search for a node id — the tree is small (a pane's whole
    /// worth of widgets), so this is a plain walk rather than a maintained
    /// index.
    private static func node(id: String, in node: RenderNode) -> RenderNode? {
        if node.id == id { return node }
        switch node.node {
        case .column(let items), .row(let items):
            for item in items {
                if let found = SurfaceView.node(id: id, in: item) { return found }
            }
        case .grid(_, let items):
            for item in items {
                if let found = SurfaceView.node(id: id, in: item) { return found }
            }
        case .section(_, _, let body):
            return SurfaceView.node(id: id, in: body)
        case .tabs(let tabs):
            for tab in tabs {
                if let found = SurfaceView.node(id: id, in: tab.body) { return found }
            }
        default:
            break
        }
        return nil
    }
}

// MARK: - Node dispatch

/// One `RenderNode` → one SwiftUI construct. Recurses through ordinary
/// struct composition (a fresh `SurfaceNodeView` per child), not a
/// self-referential `body`, so `some View` stays legal.
private struct SurfaceNodeView: View {
    let node: RenderNode
    let hooks: SurfaceHooks
    let highlightedID: Binding<String?>
    let focusedWidgetID: FocusState<String?>.Binding
    let onEvent: (SurfaceEvent) -> Void

    private var isHighlighted: Bool { highlightedID.wrappedValue == node.id }

    var body: some View {
        content
            .overlay(highlightRing)
    }

    @ViewBuilder
    private var highlightRing: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch node.node {
        case .column(let items):
            VStack(alignment: .leading, spacing: 8) { children(items) }

        case .row(let items):
            HStack(alignment: .top, spacing: 8) { children(items) }

        case .grid(let columns, let items):
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8), count: max(1, columns)),
                spacing: 8
            ) {
                children(items)
            }

        case .section(let title, let collapsed, let body):
            SurfaceSectionView(
                title: title, collapsedByDefault: collapsed, bodyNode: body,
                hooks: hooks, highlightedID: highlightedID, focusedWidgetID: focusedWidgetID,
                onEvent: onEvent)

        case .tabs(let tabs):
            SurfaceTabsView(
                id: node.id, tabs: tabs, hooks: hooks, highlightedID: highlightedID,
                focusedWidgetID: focusedWidgetID, onEvent: onEvent)

        case .text(let text):
            hooks.renderMarkdown(text)

        case .table(let rows, let columns):
            SurfaceTableView(
                id: node.id, rows: rows, columns: columns, focusedWidgetID: focusedWidgetID,
                onEvent: onEvent)

        case .list(let rows):
            hooks.renderListRows((try? rows.jsonString()) ?? "[]") { ids in
                onEvent(
                    SurfaceEvent(
                        widget: node.id, kind: .select,
                        value: .array(ids.map(SurfaceJSONValue.string))))
            }

        case .plot(let spec):
            hooks.renderPlot((try? spec.jsonString()) ?? "{}")

        case .image(let blob, let url):
            SurfaceImageView(blob: blob, url: url)

        case .field(let fieldSpec, _, let value):
            SurfaceFieldView(
                id: node.id, label: node.label, fieldSpec: fieldSpec, value: value,
                focusedWidgetID: focusedWidgetID, onEvent: onEvent)

        case .button(let label):
            Button(label) {
                onEvent(SurfaceEvent(widget: node.id, kind: .click, value: .null))
            }
            .focused(focusedWidgetID, equals: node.id)

        case .status(let level, let message):
            SurfaceStatusView(level: level, message: message)

        case .log(let lines):
            SurfaceLogView(lines: lines)

        case .kv(let pairs):
            SurfaceKVView(pairs: pairs)

        case .divider:
            Divider()

        case .spacer:
            Spacer()

        case .placeholder(let unknownKind, let reason):
            SurfacePlaceholderView(unknownKind: unknownKind, reason: reason)
        }
    }

    @ViewBuilder
    private func children(_ items: [RenderNode]) -> some View {
        ForEach(items, id: \.id) { child in
            SurfaceNodeView(
                node: child, hooks: hooks, highlightedID: highlightedID,
                focusedWidgetID: focusedWidgetID, onEvent: onEvent)
        }
    }
}

// MARK: - Containers

private struct SurfaceSectionView: View {
    let title: String
    let collapsedByDefault: Bool
    let bodyNode: RenderNode
    let hooks: SurfaceHooks
    let highlightedID: Binding<String?>
    let focusedWidgetID: FocusState<String?>.Binding
    let onEvent: (SurfaceEvent) -> Void

    // Local-only: the vocabulary defines no "toggle section" action
    // (`docs/agent-surfaces.md` § Actions), so a user's expand/collapse
    // click never round-trips as a `SurfaceEvent` — `collapsed` seeds the
    // INITIAL state and nothing more.
    @State private var expanded: Bool

    init(
        title: String, collapsedByDefault: Bool, bodyNode: RenderNode,
        hooks: SurfaceHooks, highlightedID: Binding<String?>,
        focusedWidgetID: FocusState<String?>.Binding,
        onEvent: @escaping (SurfaceEvent) -> Void
    ) {
        self.title = title
        self.collapsedByDefault = collapsedByDefault
        self.bodyNode = bodyNode
        self.hooks = hooks
        self.highlightedID = highlightedID
        self.focusedWidgetID = focusedWidgetID
        self.onEvent = onEvent
        _expanded = State(initialValue: !collapsedByDefault)
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: $expanded) {
            SurfaceNodeView(
                node: bodyNode, hooks: hooks, highlightedID: highlightedID,
                focusedWidgetID: focusedWidgetID, onEvent: onEvent)
        }
    }
}

private struct SurfaceTabsView: View {
    let id: String
    let tabs: [RenderTab]
    let hooks: SurfaceHooks
    let highlightedID: Binding<String?>
    let focusedWidgetID: FocusState<String?>.Binding
    let onEvent: (SurfaceEvent) -> Void

    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                SurfaceNodeView(
                    node: tab.body, hooks: hooks, highlightedID: highlightedID,
                    focusedWidgetID: focusedWidgetID, onEvent: onEvent)
                    .tabItem { Text(tab.title) }
                    .tag(index)
            }
        }
        .focused(focusedWidgetID, equals: id)
    }
}

// MARK: - Table / list

private struct SurfaceTableRow: Identifiable, Hashable {
    let id: String
    let cells: [String: String]
}

private struct SurfaceTableView: View {
    let id: String
    let rows: SurfaceJSONValue
    let columns: [String]
    let focusedWidgetID: FocusState<String?>.Binding
    let onEvent: (SurfaceEvent) -> Void

    @State private var selection = Set<String>()

    var body: some View {
        content
            .focused(focusedWidgetID, equals: id)
            .frame(minHeight: 120)
            .onChange(of: selection) { _, newValue in
                onEvent(
                    SurfaceEvent(
                        widget: id, kind: .select,
                        value: .array(newValue.sorted().map(SurfaceJSONValue.string))))
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        Table(tableRows, selection: $selection) {
            TableColumnForEach(columns, id: \.self) { column in
                TableColumn(column) { row in Text(row.cells[column] ?? "") }
            }
        }
        #else
        List(tableRows, selection: $selection) { row in
            Text(columns.map { row.cells[$0] ?? "" }.joined(separator: "   "))
        }
        #endif
    }

    private var tableRows: [SurfaceTableRow] {
        guard let array = rows.arrayValue else { return [] }
        return array.enumerated().map { index, item in
            let object = item.objectValue ?? [:]
            var cells: [String: String] = [:]
            for column in columns { cells[column] = object[column]?.displayText ?? "" }
            let rowID = object["id"]?.stringValue ?? String(index)
            return SurfaceTableRow(id: rowID, cells: cells)
        }
    }
}

// MARK: - Field

private struct SurfaceFieldView: View {
    let id: String
    let label: String?
    let fieldSpec: SurfaceJSONValue
    let value: SurfaceJSONValue
    let focusedWidgetID: FocusState<String?>.Binding
    let onEvent: (SurfaceEvent) -> Void

    private var subKind: String? { fieldSpec.objectValue?.keys.first }
    private var options: SurfaceJSONValue {
        subKind.flatMap { fieldSpec.objectValue?[$0] } ?? .object([:])
    }
    private var isFocused: Bool { focusedWidgetID.wrappedValue == id }

    var body: some View {
        switch subKind {
        case "text": textField
        case "number": numberField
        case "slider": sliderField
        case "select": selectField
        case "toggle": toggleField
        case "date": dateField
        default:
            Text(label ?? id)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: text

    @State private var textDraft: String = ""

    private var textField: some View {
        TextField(label ?? "", text: $textDraft)
            .focused(focusedWidgetID, equals: id)
            .onSubmit {
                onEvent(SurfaceEvent(widget: id, kind: .change, value: .string(textDraft)))
            }
            .onAppear { textDraft = value.stringValue ?? "" }
            .onChange(of: value) { _, newValue in
                guard !isFocused else { return }
                textDraft = newValue.stringValue ?? ""
            }
    }

    // MARK: number

    @State private var numberDraft: String = ""

    private var numberField: some View {
        TextField(label ?? "", text: $numberDraft)
            .focused(focusedWidgetID, equals: id)
            .onSubmit {
                guard let parsed = Double(numberDraft) else { return }
                onEvent(SurfaceEvent(widget: id, kind: .change, value: .double(parsed)))
            }
            .onAppear { numberDraft = value.doubleValue.map { String($0) } ?? "" }
            .onChange(of: value) { _, newValue in
                guard !isFocused else { return }
                numberDraft = newValue.doubleValue.map { String($0) } ?? ""
            }
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }

    // MARK: slider

    private var sliderMin: Double { options.objectValue?["min"]?.doubleValue ?? 0 }
    private var sliderMax: Double { options.objectValue?["max"]?.doubleValue ?? 1 }
    private var sliderStep: Double { max(options.objectValue?["step"]?.doubleValue ?? 1, 0.0001) }

    @State private var sliderDraft: Double = 0

    private var sliderField: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
            Slider(
                value: $sliderDraft, in: sliderMin...max(sliderMax, sliderMin + sliderStep),
                step: sliderStep,
                onEditingChanged: { editing in
                    if !editing {
                        onEvent(
                            SurfaceEvent(widget: id, kind: .change, value: .double(sliderDraft)))
                    }
                }
            )
            .focused(focusedWidgetID, equals: id)
        }
        .onAppear { sliderDraft = value.doubleValue ?? sliderMin }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            sliderDraft = newValue.doubleValue ?? sliderMin
        }
    }

    // MARK: select

    private var selectOptions: [String] {
        options.arrayValue?.compactMap(\.stringValue)
            ?? options.objectValue?["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    @State private var selectDraft: String = ""

    private var selectField: some View {
        Picker(label ?? "", selection: $selectDraft) {
            ForEach(selectOptions, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .focused(focusedWidgetID, equals: id)
        .onAppear { selectDraft = value.stringValue ?? selectOptions.first ?? "" }
        .onChange(of: selectDraft) { _, newValue in
            guard newValue != (value.stringValue ?? "") else { return }
            onEvent(SurfaceEvent(widget: id, kind: .change, value: .string(newValue)))
        }
        .onChange(of: value) { _, newValue in
            // Resync when the tree changed for a reason OTHER than this
            // picker's own edit (another widget's action wrote `bind`, an
            // external `surface_update`) — guarded the same way the
            // `.onChange(of: selectDraft)` above is, so the round trip
            // doesn't re-fire a `.change` event for a value that came FROM
            // the tree in the first place.
            guard !isFocused, newValue.stringValue != selectDraft else { return }
            selectDraft = newValue.stringValue ?? selectOptions.first ?? ""
        }
    }

    // MARK: toggle

    @State private var toggleDraft: Bool = false

    private var toggleField: some View {
        Toggle(label ?? "", isOn: $toggleDraft)
            .focused(focusedWidgetID, equals: id)
            .onAppear { toggleDraft = value.boolValue ?? false }
            .onChange(of: toggleDraft) { _, newValue in
                guard newValue != (value.boolValue ?? false) else { return }
                onEvent(SurfaceEvent(widget: id, kind: .change, value: .bool(newValue)))
            }
            .onChange(of: value) { _, newValue in
                guard !isFocused, newValue.boolValue != toggleDraft else { return }
                toggleDraft = newValue.boolValue ?? false
            }
    }

    // MARK: date

    @State private var dateDraft: Date = Date()

    private var dateField: some View {
        DatePicker(label ?? "", selection: $dateDraft, displayedComponents: [.date])
            .focused(focusedWidgetID, equals: id)
            .onAppear { dateDraft = SurfaceFieldView.parseDate(value) ?? Date() }
            .onChange(of: dateDraft) { _, newValue in
                let iso = ISO8601DateFormatter().string(from: newValue)
                guard iso != value.stringValue else { return }
                onEvent(SurfaceEvent(widget: id, kind: .change, value: .string(iso)))
            }
            .onChange(of: value) { _, newValue in
                guard !isFocused, let parsed = SurfaceFieldView.parseDate(newValue),
                    parsed != dateDraft
                else { return }
                dateDraft = parsed
            }
    }

    private static func parseDate(_ value: SurfaceJSONValue) -> Date? {
        guard let string = value.stringValue else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Display-only widgets

private struct SurfaceImageView: View {
    let blob: SurfaceJSONValue?
    let url: SurfaceJSONValue?

    var body: some View {
        Group {
            if let blob, let data = SurfaceImageView.decodeBase64(blob), let platformImage = SurfaceImageView.image(from: data) {
                platformImage
                    .resizable()
                    .scaledToFit()
            } else if let urlString = url?.stringValue, let realURL = URL(string: urlString) {
                AsyncImage(url: realURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .foregroundStyle(.secondary)
    }

    private static func decodeBase64(_ value: SurfaceJSONValue) -> Data? {
        guard let string = value.stringValue else { return nil }
        return Data(base64Encoded: string)
    }

    private static func image(from data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }
}

private struct SurfaceStatusView: View {
    let level: String
    let message: String

    private var symbol: String {
        switch level.lowercased() {
        case "error": return "xmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "success", "ok": return "checkmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch level.lowercased() {
        case "error": return .red
        case "warning": return .orange
        case "success", "ok": return .green
        default: return .secondary
        }
    }

    var body: some View {
        Label(message, systemImage: symbol)
            .foregroundStyle(tint)
    }
}

private struct SurfaceLogView: View {
    let lines: SurfaceJSONValue

    private var lineStrings: [String] {
        lines.arrayValue?.map(\.displayText) ?? [lines.displayText]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lineStrings.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .frame(minHeight: 80, maxHeight: 200)
        .background(Color.platformControlBackground)
    }
}

private struct SurfaceKVView: View {
    let pairs: SurfaceJSONValue

    private var entries: [(String, String)] {
        if let object = pairs.objectValue {
            return object.keys.sorted().map { ($0, object[$0]?.displayText ?? "") }
        }
        if let array = pairs.arrayValue {
            return array.enumerated().map { (String($0.offset), $0.element.displayText) }
        }
        return []
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(entries, id: \.0) { key, value in
                GridRow {
                    Text(key).foregroundStyle(.secondary)
                    Text(value)
                }
            }
        }
    }
}

private struct SurfacePlaceholderView: View {
    let unknownKind: String?
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                unknownKind.map { "Unsupported: \($0)" } ?? "Unavailable",
                systemImage: "questionmark.square.dashed")
            if let reason {
                Text(reason)
                    .font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }
}
