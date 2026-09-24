// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a `Commands` value
// over the layout tree (macOS) or `PaneLayoutStore`, which is AppKit-free. `Commands` is SwiftUI,
// not AppKit — iOS honours the same key equivalents where a scene has a menu
// tree, and compiles harmlessly where it does not.
//
//  PaneLayoutCommands.swift
//  PublicationManagerCore
//
//  ADR-0022 D9 finding 4, closed. The three pane toggles — ⌘0 / ⌥⌘0 / ⌃⌘S —
//  are published in a chassis-wide keyboard grammar (docs/keyboard-grammar.md).
//  In a chassis window they resize a ROLE in the layout tree; in imbib's
//  pre-chassis window they flip `PaneLayoutStore.current` (see
//  `PaneLayoutChordTarget`).
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
//  chassis window. What stays OUTSIDE it: imbib's pre-chassis View ▸ Layouts
//  menu (over `PaneLayoutStore`) and imprint's editor-window layouts (an
//  app-local `LayoutStore` over an app-local `PaneLayoutState` with different
//  fields — `showOutline`, `showComments`, `splitEditor`, … — and its own
//  `imprint.layout.*` keys). imprint's Layouts menu gives ⌃⌘N to the editor
//  layouts only while a manuscript editor window is key, and to this value
//  otherwise (plan wave 6 W5). See ADR-0022 D9.
//

import ImpressLogging
import SwiftUI

/// Which window model a chord drives.
///
/// Two, and the split is by WINDOW, never by a runtime guess: every chassis
/// app's window is the ADR-0031 layout tree (plan wave 6 W5 removed the flag
/// that made it optional), and imbib's own window is its pre-chassis
/// `ContentView`, which still draws `PaneLayoutState`. Before W5 the router
/// asked "is a tree rendering?" and fell back to `PaneLayoutState` when not —
/// so a chassis app whose tree had not opened yet flipped a Boolean nothing
/// drew, and reported nothing.
public enum PaneLayoutChordTarget: Sendable {
    /// A chassis window: the chord is a verb on `LayoutController`, and
    /// nothing else. No tree open yet → nothing happens, and the log says so.
    case layoutTree
    /// imbib's pre-chassis `ContentView` (`imbibApp.swift` only): the chord
    /// flips the `PaneLayoutState` field that window reads. Out of W5's scope
    /// by the plan's own row.
    case imbibPreChassisWindow
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

    /// Toggle `role` in the layout tree (`.layoutTree`), or apply
    /// `preChassis` to imbib's `PaneLayoutState` (`.imbibPreChassisWindow`).
    static func toggle(
        role: String,
        target: PaneLayoutChordTarget,
        preChassis: (inout PaneLayoutState) -> Void
    ) {
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
        case .imbibPreChassisWindow:
            preChassis(&PaneLayoutStore.shared.current)
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
/// Tree only (plan wave 6 W5): a chassis window's ⌃⌘N is always a layout
/// verb. imbib's pre-chassis window keeps its own View ▸ Layouts menu over
/// `PaneLayoutStore` and does not embed this.
public struct ImpressLayoutOrdinalButtons: View {

    public init() {}

    @ViewBuilder
    public var body: some View {
        ForEach(1...9, id: \.self) { ordinal in
            Button("Apply Layout \(ordinal)") {
                PaneLayoutChordRouter.applyOrdinal(ordinal)
            }
            .keyboardShortcut(
                KeyEquivalent(Character("\(ordinal)")), modifiers: [.control, .command])
        }
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
/// | Chord | Button | Tree role (chassis) | `PaneLayoutState` field (imbib's own window) |
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

    /// Which window model the chords drive. `.layoutTree` for every chassis
    /// app; only imbib's `imbibApp.swift` passes `.imbibPreChassisWindow`.
    private let target: PaneLayoutChordTarget

    public init(listTitle: String = "Toggle List", target: PaneLayoutChordTarget = .layoutTree) {
        self.listTitle = listTitle
        self.target = target
    }

    /// `@ViewBuilder`, and NO enclosing `Group`. The body is then the same
    /// `TupleView` of three `Button`s that writing them inline produced, so a
    /// menu builder sees exactly the structure it saw before the migration —
    /// three siblings, not a container it has to flatten. `Group` would also
    /// flatten in a menu; not depending on that is free.
    @ViewBuilder
    public var body: some View {
        let chords = Self.chords(listTitle: listTitle)
        let target = target
        Button(chords[0].title) {
            PaneLayoutChordRouter.toggle(role: chords[0].role, target: target, preChassis: chords[0].toggle)
        }
        .keyboardShortcut(KeyEquivalent(chords[0].key), modifiers: chords[0].modifiers)

        Button(chords[1].title) {
            PaneLayoutChordRouter.toggle(role: chords[1].role, target: target, preChassis: chords[1].toggle)
        }
        .keyboardShortcut(KeyEquivalent(chords[1].key), modifiers: chords[1].modifiers)

        Button(chords[2].title) {
            PaneLayoutChordRouter.toggle(role: chords[2].role, target: target, preChassis: chords[2].toggle)
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

    public init(listTitle: String = "Toggle List") {
        self.listTitle = listTitle
    }

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            ImpressPaneLayoutButtons(listTitle: listTitle, target: .layoutTree)
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
/// Each chord carries BOTH of its effects as data: the tree `role` it resizes
/// in a chassis window, and the `PaneLayoutState` mutation it performs in
/// imbib's pre-chassis window. The buttons above are built FROM this list, so
/// the data and the menu cannot disagree; the tree half of the effect is
/// proven by the tree's own tests plus the Tier A `resize` capability in
/// `impress-layout-service`.
public extension ImpressPaneLayoutButtons {

    /// One toggle: its menu title, its key, its modifiers, the tree role it
    /// resizes, and the `PaneLayoutState` field it flips in imbib's own window.
    struct Chord: Equatable, Sendable {
        public let title: String
        public let key: Character
        public let modifiers: EventModifiers
        /// The `impress_layout::Role` a chassis window resizes.
        public let role: String
        /// Flip this toggle on a state value — the same mutation the button
        /// performs, so the test exercises the real field and not a name.
        public let toggle: @Sendable (inout PaneLayoutState) -> Void

        public static func == (lhs: Chord, rhs: Chord) -> Bool {
            lhs.title == rhs.title && lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
                && lhs.role == rhs.role
        }
    }

    /// The published grammar, in menu order.
    static func chords(listTitle: String = "Toggle List") -> [Chord] {
        [
            Chord(title: "Toggle Detail Pane", key: "0", modifiers: .command, role: "detail") {
                $0.detailPaneVisible.toggle()
            },
            Chord(title: listTitle, key: "0", modifiers: [.command, .option], role: "list") {
                $0.listPaneVisible.toggle()
            },
            Chord(title: "Toggle Sidebar", key: "s", modifiers: [.control, .command], role: "navigator") {
                $0.sidebarVisible.toggle()
            },
        ]
    }
}
