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
            PaneLayoutStore.shared.current.detailPaneVisible.toggle()
        }
        .keyboardShortcut("0", modifiers: .command)

        Button(listTitle) {
            PaneLayoutStore.shared.current.listPaneVisible.toggle()
        }
        .keyboardShortcut("0", modifiers: [.command, .option])

        Button("Toggle Sidebar") {
            PaneLayoutStore.shared.current.sidebarVisible.toggle()
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
