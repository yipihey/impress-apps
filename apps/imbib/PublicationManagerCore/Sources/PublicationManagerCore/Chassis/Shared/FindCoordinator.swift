// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): notification names,
// a `FocusedValueKey` and two `Commands` blocks. `Commands` is SwiftUI, not
// AppKit — iOS honours the same key equivalents.
//
//  FindCoordinator.swift
//  PublicationManagerCore
//
//  Stage 1 (ADR-0021), ⌘F everywhere: every record list publishes a
//  scene-focused "focus my filter" action; the shared Commands block binds
//  ⌘F to whichever list is frontmost. ⌘⇧F (store-wide search) stays per-app
//  (imbib: global search; imprint: cross-document search window) behind
//  `GlobalSearchProviding`.
//
//  WP G4 (ADR-0022 D6) closed the gap for shells that never had a ⌘⇧F:
//  `ImpressStoreSearchCommands` binds it to the chassis's builtin
//  `store-search` surface. Apps that ALREADY own ⌘⇧F (imbib: focus filter;
//  imprint: cross-document search; impart: Forward Message) must NOT insert
//  it — their existing binding is the documented one and stays untouched. See
//  docs/keyboard-grammar.md.
//

import SwiftUI

public extension NSNotification.Name {
    /// Select the chassis's builtin store-search surface in the frontmost
    /// chassis window (⌘⇧F where the shell has nothing else bound).
    /// `TabContentView` observes it.
    static let openStoreSearch = NSNotification.Name("impress.openStoreSearch")
    /// Put the caret in the store-search field — posted right after
    /// `openStoreSearch` so a second ⌘⇧F re-focuses an already-open surface.
    static let focusStoreSearch = NSNotification.Name("impress.focusStoreSearch")
}

public struct ListFilterFocusActionKey: FocusedValueKey {
    public typealias Value = () -> Void
}

public extension FocusedValues {
    /// Focus the frontmost record list's filter field (⌘F target).
    var listFilterFocusAction: (() -> Void)? {
        get { self[ListFilterFocusActionKey.self] }
        set { self[ListFilterFocusActionKey.self] = newValue }
    }
}

/// Store-wide typed search entry point, supplied per app shell.
public protocol GlobalSearchProviding {
    @MainActor func openGlobalSearch()
}

/// Shared Find commands: ⌘F focuses the frontmost list's filter. Apps insert
/// this into their menu tree (imprint does; imbib keeps its existing
/// ContentView-owned ⌘F global-search semantics until the Stage-2 parity
/// decision).
public struct ImpressFindCommands: Commands {
    @FocusedValue(\.listFilterFocusAction) private var focusFilter

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in List") {
                focusFilter?()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(focusFilter == nil)
        }
    }
}

/// ⌘⇧F → the chassis's builtin "Search Everything" surface.
///
/// Insert this into the menu tree of any app whose shell does NOT already
/// bind ⌘⇧F (implore, impel). Apps that do (imbib, imprint, impart) keep
/// theirs; the surface is still reachable from the sidebar node, which every
/// app has.
public struct ImpressStoreSearchCommands: Commands {

    /// Set false to contribute the menu item WITHOUT the chord — for an app
    /// whose ⌘⇧F is already spoken for but that still wants the menu entry.
    private let bindsShortcut: Bool

    public init(bindsShortcut: Bool = true) {
        self.bindsShortcut = bindsShortcut
    }

    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            // macOS-only ISLAND, same reasoning as `CustomSurfaceRegistry.builtin`
            // and `RecordTriageNewTagPrompt`: the surface this opens
            // (`StoreSearchSurface`) is the one AppKit-linking builtin, so on iOS
            // `CustomSurfaceRegistry.builtin` is empty and the chord would open
            // nothing. Omit the affordance rather than ship a dead menu item;
            // this un-gates the day a UIKit-clean grouped-search surface exists.
            #if os(macOS)
            Button(StoreSearchSurface.surfaceTitle) {
                NotificationCenter.default.post(name: .openStoreSearch, object: nil)
                NotificationCenter.default.post(name: .focusStoreSearch, object: nil)
            }
            .modifier(StoreSearchShortcut(enabled: bindsShortcut))
            #endif
        }
    }
}

/// Applies ⌘⇧F only when the host app asked for it (`buttonStyle`-shaped so
/// the Button stays one expression inside the CommandGroup builder).
private struct StoreSearchShortcut: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut("f", modifiers: [.command, .shift])
        } else {
            content
        }
    }
}
