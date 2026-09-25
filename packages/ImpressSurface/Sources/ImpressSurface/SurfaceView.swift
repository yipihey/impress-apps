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
//  j / k walk `tree.focusOrder`; Enter activates the highlighted widget;
//  Escape leaves a widget. This view puts NO `.focusable()` anywhere — it
//  contains text fields, and a focus target around a text field swallows
//  keys before AppKit sees them (CLAUDE.md, pitfalls rule 5; review SK-K14,
//  which found one here, nested inside the layout root's own). The keys
//  reach it two ways:
//
//  - from the HOST's one focus target, through `SurfaceKeyInput` — the
//    layout root forwards j / k / ⏎ / ⎋ to the focused surface pane;
//  - from inside, when one of its widgets has focus: the `.keyboardGuarded`
//    and special-key handlers on its outermost container hear the keys that
//    widget did not use.
//
//  The grammar needs TWO separate pieces of focus state, not one, because a
//  single `@FocusState` would make j/k unusable the moment it lands on a
//  `text`/`number` field — giving that field REAL AppKit focus immediately
//  would swallow the very next `j` as a typed letter:
//
//  - `highlightedID` (`@State`) — the navigation cursor j/k always moves,
//    rendered as a highlight ring. Purely a Swift-side highlight; never
//    AppKit focus by itself.
//  - `focusedWidgetID` (`@FocusState`) — REAL focus, given ONLY by Enter, for
//    every kind. j / k used to hand real focus to a table as they passed it,
//    and NSTableView's type-select then ate the next j / k: navigation
//    stuck on the first table (SK-K14). Escape clears it (real focus drops;
//    the highlight stays), which is "leave a widget back to widget focus".
//
//  ## Typed values are never lost (SK-K3)
//
//  A text or number field sends its value when it loses focus, on Return
//  (then a `submit`), and — through `SurfaceDraftBook` — before any other
//  widget's click, select or submit leaves this view, so a button acts on
//  what the person typed even though clicking a button does not take focus
//  from the field.
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
    /// Keys the host routes in from its own focus target; nil for a host
    /// that has none (the view's own handlers still work once a widget has
    /// focus).
    public let keyInput: SurfaceKeyInput?

    @FocusState private var focusedWidgetID: String?
    @State private var highlightedID: String?
    @State private var drafts = SurfaceDraftBook()

    public init(
        tree: RenderTree,
        hooks: SurfaceHooks = .plain,
        keyInput: SurfaceKeyInput? = nil,
        onEvent: @escaping (SurfaceEvent) -> Void
    ) {
        self.tree = tree
        self.hooks = hooks
        self.keyInput = keyInput
        self.onEvent = onEvent
    }

    public var body: some View {
        ScrollView {
            SurfaceNodeView(
                node: tree.root,
                hooks: hooks,
                highlightedID: $highlightedID,
                focusedWidgetID: $focusedWidgetID,
                drafts: drafts,
                onEvent: send
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        // No `.focusable()` (see the file header). These fire for keys a
        // focused widget inside did not use; the host's root forwards the
        // same keys through `keyInput` when no widget has focus.
        .keyboardGuarded { press in handleGuardedKey(press) }
        // Return / Escape are special keys — CLAUDE.md's exception list —
        // so they stay OUTSIDE `.keyboardGuarded`. A focused `TextField`
        // uses Return itself (`onSubmit`), so only an unclaimed one arrives.
        .onKeyPress(keys: [.return]) { _ in
            handle(.activate) ? .handled : .ignored
        }
        .onKeyPress(keys: [.escape]) { _ in
            handle(.leave) ? .handled : .ignored
        }
        .onAppear {
            if highlightedID == nil {
                highlightedID = tree.focusOrder.first
            }
            installKeyInput()
        }
        .onChange(of: tree) { _, _ in installKeyInput() }
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

    // MARK: Keys

    /// Point the host's key input at THIS tree (the closure reads the
    /// struct it was made from, so it is re-made when the tree changes).
    private func installKeyInput() {
        guard let keyInput else { return }
        let view = self
        keyInput.handler = { key in view.handle(key) }
    }

    private func handleGuardedKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        switch press.characters {
        case "j": return handle(.next) ? .handled : .ignored
        case "k": return handle(.previous) ? .handled : .ignored
        default: return .ignored
        }
    }

    /// The whole grammar, whichever way the key arrived.
    private func handle(_ key: SurfaceKeyInput.Key) -> Bool {
        switch key {
        case .next:
            return move(by: 1)
        case .previous:
            return move(by: -1)
        case .activate:
            guard highlightedID != nil else { return false }
            activateHighlighted()
            return true
        case .leave:
            guard focusedWidgetID != nil else { return false }
            focusedWidgetID = nil
            return true
        }
    }

    /// j / k move the HIGHLIGHT and nothing else (SK-K14): real focus is
    /// Enter's to give.
    private func move(by delta: Int) -> Bool {
        let order = tree.focusOrder
        guard !order.isEmpty else { return false }
        let currentIndex = highlightedID.flatMap { order.firstIndex(of: $0) }
        let startIndex = currentIndex ?? (delta > 0 ? -1 : 0)
        let nextIndex = ((startIndex + delta) % order.count + order.count) % order.count
        highlightedID = order[nextIndex]
        return true
    }

    /// Every `SurfaceEvent` leaving this view funnels through here — the one
    /// point that also calls `hooks.log`, so a host gets a trace line for
    /// every widget interaction without this file threading `hooks` into
    /// each leaf view's own event-sending code. A click, select or submit
    /// goes out AFTER the `change` of every field whose typed value was not
    /// yet sent (SK-K3).
    private func send(_ event: SurfaceEvent) {
        let events = drafts.outgoing(event)
        if events.count > 1 {
            hooks.log(
                "surface: \(events.count - 1) typed value(s) sent before \(event.kind.rawValue) "
                    + "on \(event.widget)")
        }
        for outgoing in events { onEvent(outgoing) }
    }

    // MARK: Enter

    private func activateHighlighted() {
        guard let id = highlightedID,
            let target = SurfaceView.node(id: id, in: tree.root)
        else { return }
        switch target.node {
        case .button:
            send(SurfaceEvent(widget: id, kind: .click, value: .null))
        default:
            // A field begins editing; a table, list or tab strip takes real
            // focus, and its own native keys (arrows, type-select) work from
            // there until Escape hands the keys back to j / k.
            focusedWidgetID = id
        }
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
    let drafts: SurfaceDraftBook
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
                drafts: drafts, onEvent: onEvent)

        case .tabs(let tabs):
            SurfaceTabsView(
                id: node.id, tabs: tabs, hooks: hooks, highlightedID: highlightedID,
                focusedWidgetID: focusedWidgetID, drafts: drafts, onEvent: onEvent)

        case .text(let text):
            hooks.renderMarkdown(text)

        case .table(let rows, let columns):
            SurfaceTableView(
                id: node.id, rows: rows, columns: columns, focusedWidgetID: focusedWidgetID,
                onEvent: onEvent)

        case .list(let rows):
            // Inside the column's ScrollView a `List` has no intrinsic height
            // and collapses to nothing — the heading drew and six rows did
            // not (Mac, 2026-09-23). The floor is for a host whose hook
            // returns a List (`.plain` does); a host that returns a stack
            // simply exceeds it.
            hooks.renderListRows((try? rows.jsonString()) ?? "[]") { ids in
                onEvent(
                    SurfaceEvent(
                        widget: node.id, kind: .select,
                        value: .array(ids.map(SurfaceJSONValue.string))))
            }
            .frame(minHeight: 240)

        case .plot(let spec):
            hooks.renderPlot((try? spec.jsonString()) ?? "{}")

        case .image(let blob, let url):
            SurfaceImageView(blob: blob, url: url)

        case .field(let fieldSpec, _, let value):
            SurfaceFieldView(
                id: node.id, label: node.label, fieldSpec: fieldSpec, value: value,
                focusedWidgetID: focusedWidgetID, drafts: drafts, onEvent: onEvent)

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
                focusedWidgetID: focusedWidgetID, drafts: drafts, onEvent: onEvent)
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
    let drafts: SurfaceDraftBook
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
        drafts: SurfaceDraftBook,
        onEvent: @escaping (SurfaceEvent) -> Void
    ) {
        self.title = title
        self.collapsedByDefault = collapsedByDefault
        self.bodyNode = bodyNode
        self.hooks = hooks
        self.highlightedID = highlightedID
        self.focusedWidgetID = focusedWidgetID
        self.drafts = drafts
        self.onEvent = onEvent
        _expanded = State(initialValue: !collapsedByDefault)
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: $expanded) {
            SurfaceNodeView(
                node: bodyNode, hooks: hooks, highlightedID: highlightedID,
                focusedWidgetID: focusedWidgetID, drafts: drafts, onEvent: onEvent)
        }
    }
}

private struct SurfaceTabsView: View {
    let id: String
    let tabs: [RenderTab]
    let hooks: SurfaceHooks
    let highlightedID: Binding<String?>
    let focusedWidgetID: FocusState<String?>.Binding
    let drafts: SurfaceDraftBook
    let onEvent: (SurfaceEvent) -> Void

    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                SurfaceNodeView(
                    node: tab.body, hooks: hooks, highlightedID: highlightedID,
                    focusedWidgetID: focusedWidgetID, drafts: drafts, onEvent: onEvent)
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
    let drafts: SurfaceDraftBook
    let onEvent: (SurfaceEvent) -> Void

    // Every draft is SEEDED HERE, not in `onAppear`: writing a draft in
    // `onAppear` fires its `onChange`, which is how a select bound to null
    // sent its first option and a date field wrote today into state on first
    // render (SK-K12). A draft seeded in `init` changes only when the person
    // edits it or the stored value moves.
    @State private var textDraft: String
    @State private var numberDraft: String
    @State private var sliderDraft: Double
    @State private var selectDraft: String
    @State private var toggleDraft: Bool
    @State private var dateDraft: Date

    init(
        id: String, label: String?, fieldSpec: SurfaceJSONValue, value: SurfaceJSONValue,
        focusedWidgetID: FocusState<String?>.Binding, drafts: SurfaceDraftBook,
        onEvent: @escaping (SurfaceEvent) -> Void
    ) {
        self.id = id
        self.label = label
        self.fieldSpec = fieldSpec
        self.value = value
        self.focusedWidgetID = focusedWidgetID
        self.drafts = drafts
        self.onEvent = onEvent
        let options = fieldSpec.objectValue?.first?.value ?? .object([:])
        let sliderMin = options.objectValue?["min"]?.doubleValue ?? 0
        _textDraft = State(initialValue: SurfaceFieldLogic.textSeed(value))
        _numberDraft = State(initialValue: SurfaceFieldLogic.numberSeed(value))
        _sliderDraft = State(initialValue: value.doubleValue ?? sliderMin)
        _selectDraft = State(initialValue: SurfaceFieldLogic.selectSeed(value))
        _toggleDraft = State(initialValue: value.boolValue ?? false)
        _dateDraft = State(initialValue: SurfaceFieldLogic.parseDate(value) ?? Date())
    }

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

    /// Send this field's unsent draft, if it has one (SK-K3).
    private func commit() {
        guard let draft = drafts.take(id) else { return }
        onEvent(SurfaceEvent(widget: id, kind: .change, value: draft))
    }

    // MARK: text

    private var textField: some View {
        TextField(label ?? "", text: $textDraft)
            .focused(focusedWidgetID, equals: id)
            .onChange(of: textDraft) { _, text in
                drafts.stage(id, SurfaceFieldLogic.textDraft(text, stored: value))
            }
            // Return: the value, then `submit` (Rust runs `on_submit`, a
            // no-op when the spec declares none).
            .onSubmit {
                commit()
                onEvent(SurfaceEvent(widget: id, kind: .submit, value: .null))
            }
            // Tab, a click on another focusable control, Escape: the value
            // leaves with the focus.
            .onChange(of: isFocused) { was, now in
                if was && !now { commit() }
            }
            .onChange(of: value) { _, newValue in
                // Typing the person has not sent wins over a re-render; once
                // sent, the stored value is what they typed.
                guard !drafts.has(id) else { return }
                textDraft = SurfaceFieldLogic.textSeed(newValue)
            }
    }

    // MARK: number

    private var numberField: some View {
        TextField(label ?? "", text: $numberDraft)
            .focused(focusedWidgetID, equals: id)
            .onChange(of: numberDraft) { _, text in
                drafts.stage(id, SurfaceFieldLogic.numberDraft(text, stored: value))
            }
            .onSubmit {
                commit()
                onEvent(SurfaceEvent(widget: id, kind: .submit, value: .null))
            }
            .onChange(of: isFocused) { was, now in
                if was && !now { commit() }
            }
            .onChange(of: value) { _, newValue in
                guard !drafts.has(id) else { return }
                numberDraft = SurfaceFieldLogic.numberSeed(newValue)
            }
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }

    // MARK: slider

    private var sliderMin: Double { options.objectValue?["min"]?.doubleValue ?? 0 }
    private var sliderMax: Double { options.objectValue?["max"]?.doubleValue ?? 1 }
    private var sliderStep: Double { max(options.objectValue?["step"]?.doubleValue ?? 1, 0.0001) }

    private var sliderField: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
            Slider(
                value: $sliderDraft, in: sliderMin...max(sliderMax, sliderMin + sliderStep),
                step: sliderStep,
                onEditingChanged: { editing in
                    // Only a drag the person made ends in `editing == false`.
                    if !editing, sliderDraft != value.doubleValue {
                        onEvent(
                            SurfaceEvent(widget: id, kind: .change, value: .double(sliderDraft)))
                    }
                }
            )
            .focused(focusedWidgetID, equals: id)
        }
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

    private var selectField: some View {
        Picker(label ?? "", selection: $selectDraft) {
            // Nothing stored shows as nothing chosen, not as the first option.
            if !selectOptions.contains(selectDraft) {
                Text("\u{2014}").tag(selectDraft)
            }
            ForEach(selectOptions, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .focused(focusedWidgetID, equals: id)
        .onChange(of: selectDraft) { _, newValue in
            guard SurfaceFieldLogic.selectShouldEmit(newValue, stored: value) else { return }
            onEvent(SurfaceEvent(widget: id, kind: .change, value: .string(newValue)))
        }
        .onChange(of: value) { _, newValue in
            // Resync when the tree changed for a reason OTHER than this
            // picker's own edit; the resync then equals the stored value, so
            // the `onChange(of: selectDraft)` above sends nothing.
            let seed = SurfaceFieldLogic.selectSeed(newValue)
            if seed != selectDraft { selectDraft = seed }
        }
    }

    // MARK: toggle

    private var toggleField: some View {
        Toggle(label ?? "", isOn: $toggleDraft)
            .focused(focusedWidgetID, equals: id)
            .onChange(of: toggleDraft) { _, newValue in
                guard newValue != (value.boolValue ?? false) else { return }
                onEvent(SurfaceEvent(widget: id, kind: .change, value: .bool(newValue)))
            }
            .onChange(of: value) { _, newValue in
                let seed = newValue.boolValue ?? false
                if seed != toggleDraft { toggleDraft = seed }
            }
    }

    // MARK: date

    /// A calendar date (see `SurfaceFieldLogic.parseDate`): sent in the
    /// stored value's own shape, and only for a DAY the person picked.
    private var dateField: some View {
        DatePicker(label ?? "", selection: $dateDraft, displayedComponents: [.date])
            .focused(focusedWidgetID, equals: id)
            .onChange(of: dateDraft) { _, newValue in
                guard SurfaceFieldLogic.dateShouldEmit(newValue, stored: value) else { return }
                onEvent(
                    SurfaceEvent(
                        widget: id, kind: .change,
                        value: .string(SurfaceFieldLogic.dateString(newValue, like: value))))
            }
            .onChange(of: value) { _, newValue in
                guard let parsed = SurfaceFieldLogic.parseDate(newValue),
                      !Calendar.current.isDate(parsed, inSameDayAs: dateDraft)
                else { return }
                dateDraft = parsed
            }
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
