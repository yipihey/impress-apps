// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a `Commands` value
// over the layout tree (macOS) or a host window's `HostWindowPanes`, which is
// AppKit-free. `Commands` is SwiftUI,
// not AppKit — iOS honours the same key equivalents where a scene has a menu
// tree, and compiles harmlessly where it does not.
//
//  PaneLayoutCommands.swift
//  PublicationManagerCore
//
//  ADR-0022 D9 finding 4, closed. The three pane toggles — ⌘0 / ⌥⌘0 / ⌃⌘S —
//  are published in a chassis-wide keyboard grammar (docs/keyboard-grammar.md).
//  In every window they resize a ROLE in the layout tree. imbib's window
//  hosts that tree too (`ContentView` is the chrome around `ChassisRootView`).
//  `PaneLayoutChordTarget.imbibPreChassisWindow` remains for the pane-model
//  unit test; no app passes it.
//  What they did NOT have was a chassis `Commands` value, so imbib, imprint,
//  impart and finally impress each re-typed the same three buttons — the
//  fourth adopter retyping is what turned a duplication into a finding.
//
//  The four copies had already drifted in four cosmetic axes (button order,
//  `[.option, .command]` vs `[.command, .option]`, `.command` vs `[.command]`,
//  and one label). None of those changed BEHAVIOUR, which is precisely the
//  point: nothing was watching, so nothing failed when they diverged. They are
//  reconciled here, once, in the order three of the four apps already used.
//
//  Shipped beside `ImpressFindCommands` / `ImpressStoreSearchCommands` and in
//  their shape: a `public struct: Commands` with a `public init()`, no
//  environment injection, no host parameter beyond the one label below.
//
//  ⌃⌘1…9 is `ImpressLayoutOrdinalButtons` below: the tree's ordinals, in every
//  window, imbib's View ▸ Layouts included. What stays OUTSIDE it: imprint's
//  editor-window layouts (an app-local `LayoutStore` with different fields —
//  `showOutline`, `showComments`, `splitEditor`, … — and its own
//  `imprint.layout.*` keys). imprint's Layouts menu gives ⌃⌘N to the editor
//  layouts only while a manuscript editor window is key, and to this value
//  otherwise (plan wave 6 W5). See ADR-0022 D9.
//

import ImpressKeyboard
import ImpressLogging
import SwiftUI

/// Which window model a chord drives.
///
/// Two, and the split is by WINDOW, never by a runtime guess. Every app's
/// window is the ADR-0031 layout tree, imbib's included. The pre-chassis
/// case stays so the pane-model mapping still has a unit test; no app
/// passes it. Before W5 the router asked "is a tree rendering?" and fell
/// back to that model when not — so a window whose tree had not opened yet
/// flipped a Boolean nothing was drawing.
public enum PaneLayoutChordTarget: Sendable {
    /// A chassis window: the chord is a verb on `LayoutController`, and
    /// nothing else. No tree open yet → nothing happens, and the log says so.
    case layoutTree
    /// The pane-model mapping, kept for its unit test. No app passes it:
    /// imbib's window is the layout tree.
    case imbibPreChassisWindow(any HostWindowPanes)
}

/// Where the three universal toggles and ⌃⌘1–9 land.
///
/// ADR-0031 D5: "roles, not slots, are what universal chords act on". In a
/// chassis window ⌃⌘S toggles whichever pane carries the `navigator` role,
/// ⌥⌘0 the `list` one and ⌘0 the `detail` one — wherever the user has since
/// moved them — and the toggle is a RESIZE of that pane's share in the tree,
/// never a Boolean beside it.
///
/// The routing lives here, in the ONE value that owns these chords, so the
/// hosts cannot drift the way the four hand-written copies did (ADR-0022 D9
/// finding 4, which is why this file exists at all).
@MainActor
enum PaneLayoutChordRouter {

    /// `impress_layout::Role`'s constants, as the chords name them.
    static let navigatorRole = "navigator"
    static let listRole = "list"
    static let detailRole = "detail"

    /// Toggle `role` in the layout tree (`.layoutTree`), or the matching
    /// pane of imbib's own window (`.imbibPreChassisWindow`).
    static func toggle(role: String, target: PaneLayoutChordTarget) {
        switch target {
        case .layoutTree:
            #if os(macOS)
            if let controller = LayoutTreeRuntime.shared.controller {
                controller.toggleRole(role)
                return
            }
            #endif
            logWarning(
                "chord: toggle \(role) ignored — no layout tree is open in this window yet",
                category: "layout")
        case .imbibPreChassisWindow(let panes):
            toggle(role: role, in: panes)
        }
    }

    /// The role → pane mapping of a host window: ⌘0 the detail, ⌥⌘0 the
    /// list, ⌃⌘S the sidebar.
    static func toggle(role: String, in panes: any HostWindowPanes) {
        switch role {
        case detailRole: panes.detailPaneVisible.toggle()
        case listRole: panes.listPaneVisible.toggle()
        case navigatorRole: panes.sidebarVisible.toggle()
        default:
            logWarning("chord: no pane of the host window carries role \(role)", category: "layout")
        }
    }
}

/// ⌃⌘1–9 — "apply layout N" — as MENU CONTENT (ADR-0031 D10, work package L7's
/// Swift half).
///
/// The ordinal spans the SAME union `list_presets` numbers: this app's presets
/// first, then its saved layouts — so ⌃⌘1 is the app's default arrangement on
/// a machine that has never saved a layout and on one that has saved nine, and
/// a layout saved by `save-layout` takes the next free number. Resolution is
/// Rust's (`impress-layout-service`'s `apply_layout(ordinal:)`, reached through
/// `SharedLayout.applyLayout(nameOrOrdinal:)`, which reads a positive integer
/// as the ordinal); nothing here knows which name N carries, and the titles say
/// so.
///
/// Tree only: ⌃⌘N is a layout verb in every window, imbib's View ▸ Layouts
/// included.
public struct ImpressLayoutOrdinalButtons: View {
    private let appID: String?

    /// Pass the host app id when its ordinals are seeded in the keymap.
    /// The default preserves the existing universal chassis chord.
    public init(appID: String? = nil) {
        self.appID = appID
    }

    @ViewBuilder
    public var body: some View {
        ForEach(1...9, id: \.self) { ordinal in
            Button("Apply Layout \(ordinal)") {
                PaneLayoutChordRouter.applyOrdinal(ordinal)
            }
            .keyboardShortcut(
                appID.flatMap { KeymapRegistry.shared.shortcut(for: "\($0).layout.chassis_\(ordinal)") }
                    ?? KeyboardShortcut(KeyEquivalent(Character("\(ordinal)")), modifiers: [.control, .command]))
        }
    }
}

/// Menu actions on the live layout tree that are not one of the three pane chords.
@MainActor
public enum LayoutTreeCommands {
    /// Save the key window's live tree under `name`. False when no tree is open.
    @discardableResult
    public static func saveCurrentLayout(named name: String) -> Bool {
        #if os(macOS)
        guard let controller = LayoutTreeRuntime.shared.controller else { return false }
        return controller.apply(.saveLayout(name: name, purpose: nil))
        #else
        _ = name
        return false
        #endif
    }
}

extension PaneLayoutChordRouter {

    /// ⌃⌘N. The tree resolves the ordinal itself; with no tree open yet,
    /// nothing happens and the log says so.
    static func applyOrdinal(_ ordinal: Int) {
        #if os(macOS)
        if let controller = LayoutTreeRuntime.shared.controller {
            logInfo("chord: apply layout \(ordinal) → layout tree", category: "layout")
            controller.apply(.applyLayout(nameOrOrdinal: String(ordinal)))
            return
        }
        #endif
        logWarning(
            "chord: apply layout \(ordinal) ignored — no layout tree is open in this window yet",
            category: "layout")
    }
}

/// The three chassis pane toggles as MENU CONTENT, for a host that already owns
/// a `CommandGroup(after: .sidebar)` and wants them at a specific position in
/// it.
///
/// | Chord | Button | Tree role (chassis) | `HostWindowPanes` field (imbib's own window) |
/// |---|---|---|---|
/// | ⌘0 | Toggle Detail Pane | `detail` | `detailPaneVisible` |
/// | ⌥⌘0 | Toggle List | `list` | `listPaneVisible` |
/// | ⌃⌘S | Toggle Sidebar | `navigator` | `sidebarVisible` |
///
/// TWO SHAPES, and the reason is menu ORDER rather than taste. Three of the four
/// apps that hand-wrote these buttons wrote them in the MIDDLE of a larger
/// `CommandGroup(after: .sidebar)` — imbib's sits between "Show BibTeX Tab" and
/// the Layouts menu, with four more items after it. A `Commands` value can only
/// contribute a WHOLE group, so migrating those apps onto one would have moved
/// the toggles to the end of the View menu: chords identical, menu visibly
/// rearranged, and a rearrangement nothing would have flagged. This type is
/// what those three drop in place, so their menus are byte-identical after the
/// migration. `ImpressPaneLayoutCommands` below wraps it for a host with no
/// group of its own.
public struct ImpressPaneLayoutButtons: View {

    /// The list-toggle button's title.
    ///
    /// Parameterised for ONE caller and reluctantly: imprint's copy says
    /// "Toggle Manuscript List" where the other three say "Toggle List". The
    /// field it drives is not manuscript-specific — `listPaneVisible` is the
    /// middle column of every chassis route, which is why imbib renamed its own
    /// copy away from that spelling — but silently relabelling a live menu
    /// entry is a UX decision, not a refactor side effect (the same reasoning
    /// that kept `createCollection` off the kernel in ADR-0022 C2). Default is
    /// the majority spelling; imprint passes its own until someone decides.
    private let listTitle: String
    private let appID: String

    /// Which window model the chords drive. The default is `.layoutTree`.
    /// `.imbibPreChassisWindow` is the pane-model unit test; no app passes it.
    private let target: PaneLayoutChordTarget

    public init(
        listTitle: String = "Toggle List",
        target: PaneLayoutChordTarget = .layoutTree,
        appID: String = "imbib"
    ) {
        self.listTitle = listTitle
        self.target = target
        self.appID = appID
    }

    /// `@ViewBuilder`, and NO enclosing `Group`. The body is then the same
    /// `TupleView` of three `Button`s that writing them inline produced, so a
    /// menu builder sees exactly the structure it saw before the migration —
    /// three siblings, not a container it has to flatten. `Group` would also
    /// flatten in a menu; not depending on that is free.
    @ViewBuilder
    public var body: some View {
        let chords = Self.chords(listTitle: listTitle, appID: appID)
        let target = target
        Button(chords[0].title) {
            PaneLayoutChordRouter.toggle(role: chords[0].role, target: target)
        }
        .keyboardShortcut(KeyEquivalent(chords[0].key), modifiers: chords[0].modifiers)

        Button(chords[1].title) {
            PaneLayoutChordRouter.toggle(role: chords[1].role, target: target)
        }
        .keyboardShortcut(KeyEquivalent(chords[1].key), modifiers: chords[1].modifiers)

        Button(chords[2].title) {
            PaneLayoutChordRouter.toggle(role: chords[2].role, target: target)
        }
        .keyboardShortcut(KeyEquivalent(chords[2].key), modifiers: chords[2].modifiers)
    }
}

/// The three chassis pane toggles as a standalone `Commands` value, in the
/// shape of `ImpressFindCommands` / `ImpressStoreSearchCommands`.
///
/// Insert it into the app's `.commands { }` builder as a bare
/// `ImpressPaneLayoutCommands()`. It contributes a `CommandGroup(after:
/// .sidebar)`, which is where all four hand-written copies lived. A host that
/// already has such a group should embed `ImpressPaneLayoutButtons` instead —
/// see its doc comment for why.
public struct ImpressPaneLayoutCommands: Commands {

    private let listTitle: String
    private let appID: String

    public init(listTitle: String = "Toggle List", appID: String = "imbib") {
        self.listTitle = listTitle
        self.appID = appID
    }

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            ImpressPaneLayoutButtons(listTitle: listTitle, target: .layoutTree, appID: appID)
        }
    }
}

/// The chords this value binds, as data — so a test can pin them against
/// docs/keyboard-grammar.md without instantiating a `Commands` tree (SwiftUI
/// offers no way to enumerate a built `Commands` body, which is exactly why
/// four hand-written copies could drift unnoticed).
///
/// Anything that changes here changes the published grammar, and
/// `PaneLayoutCommandsTests` fails until the doc row moves with it.
///
/// Each chord carries its effect as data: the tree `role` it resizes in a
/// chassis window, which `PaneLayoutChordRouter.toggle(role:in:)` maps to a
/// pane of imbib's pre-chassis window. The buttons above are built FROM this
/// list, so the data and the menu cannot disagree; the tree half of the effect
/// is proven by the tree's own tests plus the Tier A `resize` capability in
/// `impress-layout-service`.
public extension ImpressPaneLayoutButtons {

    /// One toggle: its menu title, its key, its modifiers and the tree role
    /// it resizes.
    struct Chord: Equatable, Sendable {
        public let title: String
        public let key: Character
        public let modifiers: EventModifiers
        /// The `impress_layout::Role` a chassis window resizes.
        public let role: String
    }

    /// The published grammar, in menu order. R2b: the key and modifiers are
    /// read from the selected app's keymap registry rows rather than written
    /// here. The default is imbib for existing callers; imprint supplies its
    /// own app id so these rows have the right ownership and scope.
    /// The literal fallback is the pre-registry chord, used only if the
    /// registry has no entry (defensive; the registry always does).
    static func chords(listTitle: String = "Toggle List", appID: String = "imbib") -> [Chord] {
        [
            Chord(
                title: "Toggle Detail Pane",
                key: Self.key("\(appID).pane.toggle_detail", fallback: "0"),
                modifiers: Self.modifiers("\(appID).pane.toggle_detail", fallback: .command),
                role: "detail"),
            Chord(
                title: listTitle,
                key: Self.key("\(appID).pane.toggle_list", fallback: "0"),
                modifiers: Self.modifiers("\(appID).pane.toggle_list", fallback: [.command, .option]),
                role: "list"),
            Chord(
                title: "Toggle Sidebar",
                key: Self.key("\(appID).pane.toggle_sidebar", fallback: "s"),
                modifiers: Self.modifiers("\(appID).pane.toggle_sidebar", fallback: [.control, .command]),
                role: "navigator"),
        ]
    }

    private static func key(_ commandID: String, fallback: Character) -> Character {
        guard let shortcut = KeymapRegistry.shared.shortcut(for: commandID) else { return fallback }
        return shortcut.key.character
    }

    private static func modifiers(_ commandID: String, fallback: EventModifiers) -> EventModifiers {
        KeymapRegistry.shared.shortcut(for: commandID)?.modifiers ?? fallback
    }
}
