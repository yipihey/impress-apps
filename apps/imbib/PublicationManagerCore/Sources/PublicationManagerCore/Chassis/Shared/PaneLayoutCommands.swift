// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a `Commands` value
// over `PaneLayoutStore`, which is itself AppKit-free. `Commands` is SwiftUI,
// not AppKit — iOS honours the same key equivalents where a scene has a menu
// tree, and compiles harmlessly where it does not.
//
//  PaneLayoutCommands.swift
//  PublicationManagerCore
//
//  ADR-0022 D9 finding 4, closed. The three pane toggles — ⌘0 / ⌥⌘0 / ⌃⌘S —
//  are CHASSIS state (`PaneLayoutStore.current`) read by every chassis section
//  view (`TabContentView`, `SectionContentView`, `MessageSectionView`,
//  `FigureSectionView`, `AgentSectionView`, `ManuscriptSectionView`) and
//  published in a chassis-wide keyboard grammar (docs/keyboard-grammar.md).
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
//  SCOPE — what this deliberately does NOT absorb: the ⌃⌘1…9 saved-layout
//  menu. imbib's drives the chassis `PaneLayoutStore`; imprint's drives an
//  app-local `LayoutStore` over an app-local `PaneLayoutState` with entirely
//  different fields (`showOutline`, `showComments`, `splitEditor`, …) and its
//  own `imprint.layout.*` defaults keys. Those two menus look identical and
//  mean different things; converging them is a decision about imprint's editor
//  layout model, not a de-duplication. See ADR-0022 D9.
//

import SwiftUI

/// Where the three universal toggles LAND, which is no longer one place.
///
/// ADR-0031 D5: "roles, not slots, are what universal chords act on". When
/// the layout tree is rendering the window, ⌃⌘S toggles whichever pane
/// carries the `navigator` role, ⌥⌘0 the `list` one and ⌘0 the `detail` one —
/// wherever the user has since moved them — and the toggle is a RESIZE of
/// that pane's share in the tree, never a Boolean beside it. With the tree
/// off (every shipped preset today) the chord flips the same
/// `PaneLayoutState` field it always did.
///
/// The routing lives here, in the ONE value that owns these three chords, so
/// the two chassis roots cannot drift the way the four hand-written copies
/// did (ADR-0022 D9 finding 4, which is why this file exists at all).
@MainActor
enum PaneLayoutChordRouter {

    /// `impress_layout::Role`'s constants, as the chords name them.
    static let navigatorRole = "navigator"
    static let listRole = "list"
    static let detailRole = "detail"

    /// Toggle `role` in the layout tree, or apply `fallback` to the live
    /// `PaneLayoutState` when no tree is rendering.
    static func toggle(role: String, otherwise fallback: (inout PaneLayoutState) -> Void) {
        #if os(macOS)
        if let controller = LayoutTreeRuntime.shared.controller {
            controller.toggleRole(role)
            return
        }
        #endif
        fallback(&PaneLayoutStore.shared.current)
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
/// Routed the way the three toggles above are: with a tree rendering the
/// window the chord is a layout verb on it, and with the tree off it is
/// imbib's `PaneLayoutStore` — the N-th saved arrangement, the meaning the
/// chord has had since ADR-0022. Nine FIXED buttons rather than a `ForEach`
/// over saved layouts, because with the tree on the first ordinals are
/// presets that no saved-layout list contains.
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

    /// ⌃⌘N. The tree resolves the ordinal itself; without a tree, the N-th
    /// saved `PaneLayoutState`, and nothing when there is none.
    static func applyOrdinal(_ ordinal: Int) {
        #if os(macOS)
        if let controller = LayoutTreeRuntime.shared.controller {
            controller.apply(.applyLayout(nameOrOrdinal: String(ordinal)))
            return
        }
        #endif
        let layouts = PaneLayoutStore.shared.layouts
        guard ordinal >= 1, ordinal <= layouts.count else { return }
        _ = PaneLayoutStore.shared.applyLayout(named: layouts[ordinal - 1].name)
    }
}

/// The three chassis pane toggles as MENU CONTENT, for a host that already owns
/// a `CommandGroup(after: .sidebar)` and wants them at a specific position in
/// it.
///
/// | Chord | Button | `PaneLayoutState` field |
/// |---|---|---|
/// | ⌘0 | Toggle Detail Pane | `detailPaneVisible` |
/// | ⌥⌘0 | Toggle List | `listPaneVisible` |
/// | ⌃⌘S | Toggle Sidebar | `sidebarVisible` |
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

    public init(listTitle: String = "Toggle List") {
        self.listTitle = listTitle
    }

    /// `@ViewBuilder`, and NO enclosing `Group`. The body is then the same
    /// `TupleView` of three `Button`s that writing them inline produced, so a
    /// menu builder sees exactly the structure it saw before the migration —
    /// three siblings, not a container it has to flatten. `Group` would also
    /// flatten in a menu; not depending on that is free.
    @ViewBuilder
    public var body: some View {
        Button("Toggle Detail Pane") {
            PaneLayoutChordRouter.toggle(role: PaneLayoutChordRouter.detailRole) {
                $0.detailPaneVisible.toggle()
            }
        }
        .keyboardShortcut("0", modifiers: .command)

        Button(listTitle) {
            PaneLayoutChordRouter.toggle(role: PaneLayoutChordRouter.listRole) {
                $0.listPaneVisible.toggle()
            }
        }
        .keyboardShortcut("0", modifiers: [.command, .option])

        Button("Toggle Sidebar") {
            PaneLayoutChordRouter.toggle(role: PaneLayoutChordRouter.navigatorRole) {
                $0.sidebarVisible.toggle()
            }
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
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
            ImpressPaneLayoutButtons(listTitle: listTitle)
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
/// `toggle` is still the `PaneLayoutState` mutation, deliberately: it is the
/// half of the chord that can be exercised without a window, a store or an
/// FFI. The layout-tree half (`PaneLayoutChordRouter`, ADR-0031 D5) is a
/// ROUTING decision taken at the button, and it is proven by the tree's own
/// tests plus the Tier A `resize` capability in `impress-layout-service`, not
/// by pretending a `PaneLayoutState` stands in for a share.
public extension ImpressPaneLayoutButtons {

    /// One toggle: its menu title, its key, its modifiers, and the
    /// `PaneLayoutState` field it flips.
    struct Chord: Equatable, Sendable {
        public let title: String
        public let key: Character
        public let modifiers: EventModifiers
        /// Flip this toggle on a state value — the same mutation the button
        /// performs, so the test exercises the real field and not a name.
        public let toggle: @Sendable (inout PaneLayoutState) -> Void

        public static func == (lhs: Chord, rhs: Chord) -> Bool {
            lhs.title == rhs.title && lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
        }
    }

    /// The published grammar, in menu order.
    static func chords(listTitle: String = "Toggle List") -> [Chord] {
        [
            Chord(title: "Toggle Detail Pane", key: "0", modifiers: .command) {
                $0.detailPaneVisible.toggle()
            },
            Chord(title: listTitle, key: "0", modifiers: [.command, .option]) {
                $0.listPaneVisible.toggle()
            },
            Chord(title: "Toggle Sidebar", key: "s", modifiers: [.control, .command]) {
                $0.sidebarVisible.toggle()
            },
        ]
    }
}
