// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
//  LayoutArrangeCommands.swift
//  PublicationManagerCore
//
//  The window's arrange menu, once, beside `ImpressLayoutOrdinalButtons`.
//  Split, close, maximize, the view-kind picker, a one-step move, and the
//  named saved layouts. Each item applies a verb that already exists, so
//  ⌥⌘Z undoes it. iOS has no layout tree: the buttons are empty there.
//
//  The four chords are ⌃⌥⌘→ / ⌃⌥⌘↓ / ⌃⌥⌘W / ⌃⌥⌘↩ (docs/keyboard-grammar.md).
//  They are data below so a test can see them; the menu is built from that
//  data. Named layouts, view kinds, and moves have no chord: ⌃⌘1–9 already
//  recalls an ordinal. Show and move are `LayoutPaneActions` for the focused
//  pane — the same list a header's secondary click renders for its own tile.
//  The header drag is the pointer form of a move.
//

import ImpressLogging
import SwiftUI

/// The four arrange chords, in menu order.
public struct LayoutArrangeChord: Equatable, Sendable {
    public let title: String
    public let key: KeyEquivalent
    public let modifiers: EventModifiers
    /// Stable token for the chord-collision scan (`rightArrow`, `w`).
    public let token: String

    public init(title: String, key: KeyEquivalent, modifiers: EventModifiers, token: String) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.token = token
    }
}

public enum LayoutArrangeChords {
    public static let splitRight = LayoutArrangeChord(
        title: "Split Right",
        key: .rightArrow,
        modifiers: [.control, .option, .command],
        token: "rightArrow")
    public static let splitBelow = LayoutArrangeChord(
        title: "Split Below",
        key: .downArrow,
        modifiers: [.control, .option, .command],
        token: "downArrow")
    public static let close = LayoutArrangeChord(
        title: "Close Pane",
        key: KeyEquivalent("w"),
        modifiers: [.control, .option, .command],
        token: "w")
    public static let maximize = LayoutArrangeChord(
        title: "Maximize Pane",
        key: .return,
        modifiers: [.control, .option, .command],
        token: "return")

    public static let all = [splitRight, splitBelow, close, maximize]

    /// `control+option+command-rightArrow`, matching the imbib menu scan's order.
    public static func collisionKey(_ chord: LayoutArrangeChord) -> String {
        var names: [String] = []
        if chord.modifiers.contains(.control) { names.append("control") }
        if chord.modifiers.contains(.option) { names.append("option") }
        if chord.modifiers.contains(.shift) { names.append("shift") }
        if chord.modifiers.contains(.command) { names.append("command") }
        return "\(names.joined(separator: "+"))-\(chord.token)"
    }
}

/// Split, close, maximize, what the focused pane shows, where it moves, and
/// the layouts saved by name. Drop it next to `ImpressLayoutOrdinalButtons`.
public struct ImpressLayoutArrangeButtons: View {
    public init() {}

    public var body: some View {
        #if os(macOS)
        LayoutArrangeMenu()
        #else
        EmptyView()
        #endif
    }
}

#if os(macOS)
/// Applies an arrange action to the key window's tree, or logs that no tree
/// is open yet. The verb is the whole effect.
@MainActor
enum LayoutArrangePerformer {
    static func perform(_ arrange: LayoutArrange) {
        apply(arrange.verb)
    }

    static func apply(_ verb: LayoutVerb) {
        guard let controller = LayoutTreeRuntime.shared.controller else {
            logWarning(
                "layout menu: \(verb.traceDescription) ignored — no layout tree is open yet",
                category: "layout")
            return
        }
        controller.apply(verb)
    }

    static func undoArrangement() {
        guard let controller = LayoutTreeRuntime.shared.controller else { return }
        controller.undoArrangement()
    }

    static func redoArrangement() {
        guard let controller = LayoutTreeRuntime.shared.controller else { return }
        controller.redoArrangement()
    }
}

/// View ▸ Open Papers. `open-list` focuses the list when the window has one,
/// and otherwise splits one in beside the sidebar. Kinds come from a
/// remaining detail pane, or from the cold-start list.
@MainActor
public enum LayoutPaperList {
    public static func open() {
        guard let controller = LayoutTreeRuntime.shared.controller else {
            logWarning("open papers: no layout tree is open yet", category: "layout")
            return
        }
        controller.apply(.openList)
    }
}

@MainActor
private struct LayoutArrangeMenu: View {
    var body: some View {
        let controller = LayoutTreeRuntime.shared.controller
        let maximized = controller?.tree?.firstWindow?.maximized != nil
        // Read so a layouts-changed notification rebuilds this menu.
        let _ = controller?.layoutsVersion

        Divider()

        Button("Undo Arrangement") { LayoutArrangePerformer.undoArrangement() }
            .keyboardShortcut("z", modifiers: [.option, .command])
            .accessibilityIdentifier("layout.menu.undo-arrangement")
        Button("Redo Arrangement") { LayoutArrangePerformer.redoArrangement() }
            .keyboardShortcut("z", modifiers: [.option, .shift, .command])
            .accessibilityIdentifier("layout.menu.redo-arrangement")

        Divider()

        Button("Open Papers") { LayoutPaperList.open() }
            .accessibilityIdentifier("layout.menu.open-papers")

        let opened = focusedActions.filter { $0.section == .open }
        if !opened.isEmpty {
            ForEach(opened) { action in
                LayoutPaneActionButton(action: action) { LayoutArrangePerformer.apply($0) }
            }
            Divider()
        }

        arrangeButton(LayoutArrangeChords.splitRight) { LayoutArrangePerformer.perform(.splitRight) }
        arrangeButton(LayoutArrangeChords.splitBelow) { LayoutArrangePerformer.perform(.splitBelow) }
        arrangeButton(LayoutArrangeChords.close) { LayoutArrangePerformer.perform(.close) }
        Button(maximized ? "Restore Pane" : "Maximize Pane") {
            LayoutArrangePerformer.perform(maximized ? .restore : .maximize)
        }
        .keyboardShortcut(LayoutArrangeChords.maximize.key, modifiers: LayoutArrangeChords.maximize.modifiers)
        .accessibilityIdentifier("layout.menu.maximize")

        Menu("Show in This Pane") {
            ForEach(focusedActions.filter { $0.section == .show }) { action in
                LayoutPaneActionButton(action: action) { LayoutArrangePerformer.apply($0) }
            }
        }
        .accessibilityIdentifier("layout.menu.show")

        Menu("Move This Pane") {
            ForEach(focusedActions.filter { $0.section == .move }) { action in
                LayoutPaneActionButton(action: action) { LayoutArrangePerformer.apply($0) }
            }
        }
        .accessibilityIdentifier("layout.menu.move")

        savedLayoutsMenu
    }

    private struct SavedLayoutItem: Identifiable {
        var id: String
        var title: String
    }

    private func arrangeButton(_ chord: LayoutArrangeChord, action: @escaping () -> Void) -> some View {
        Button(chord.title, action: action)
            .keyboardShortcut(chord.key, modifiers: chord.modifiers)
            .accessibilityIdentifier("layout.menu.\(chord.token)")
    }

    /// Show and move rows are `LayoutPaneActions` for the focused pane — the
    /// same list a header's context menu renders for its own tile.
    private var focusedActions: [LayoutPaneAction] {
        let controller = LayoutTreeRuntime.shared.controller
        return LayoutPaneActions.actions(
            targeting: .focused,
            tile: controller?.focused,
            tree: controller?.tree,
            kinds: registeredKinds,
            currentKind: focusedKind,
            currentRole: focusedRole)
    }

    private var focusedKind: String? {
        guard let controller = LayoutTreeRuntime.shared.controller,
              let focused = controller.focused,
              let tree = controller.tree
        else { return nil }
        return tree.pane(focused)?.viewKind
    }

    private var focusedRole: String? {
        guard let controller = LayoutTreeRuntime.shared.controller,
              let focused = controller.focused,
              let tree = controller.tree
        else { return nil }
        return tree.pane(focused)?.role
    }

    /// Kinds this process can actually draw, in the vocabulary's order.
    private var registeredKinds: [ViewKindID] {
        LayoutPaneActions.orderedKinds(registered: ViewKindRegistry.builtin.registeredKinds)
    }

    @ViewBuilder
    private var savedLayoutsMenu: some View {
        switch savedRows {
        case nil:
            EmptyView()
        case .some(.failure):
            Button("Saved Layouts Unavailable") {}
                .disabled(true)
        case .some(.success(let rows)) where rows.isEmpty:
            EmptyView()
        case .some(.success(let rows)):
            Menu("Saved Layouts") {
                ForEach(rows) { row in
                    Button(row.title) {
                        LayoutArrangePerformer.perform(.applySaved(row.id))
                    }
                }
                Divider()
                Menu("Delete") {
                    ForEach(rows) { row in
                        Button(row.title) {
                            LayoutArrangePerformer.perform(.deleteSaved(row.id))
                        }
                    }
                }
            }
            .accessibilityIdentifier("layout.menu.saved")
        }
    }

    /// Empty means none saved. A thrown read stays a failure — the menu says
    /// so, and `savedLayouts()` has already logged the reason.
    private var savedRows: Result<[SavedLayoutItem], Error>? {
        guard let controller = LayoutTreeRuntime.shared.controller else { return nil }
        do {
            let rows = try controller.savedLayouts()
            return .success(rows.map { row in
                let name = row.name ?? ""
                return SavedLayoutItem(id: row.id, title: name.isEmpty ? row.id : name)
            })
        } catch {
            return .failure(error)
        }
    }
}
#endif
