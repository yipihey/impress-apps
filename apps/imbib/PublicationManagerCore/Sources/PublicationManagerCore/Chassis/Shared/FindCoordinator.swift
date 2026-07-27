#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  FindCoordinator.swift
//  PublicationManagerCore
//
//  Stage 1 (ADR-0021), ⌘F everywhere: every record list publishes a
//  scene-focused "focus my filter" action; the shared Commands block binds
//  ⌘F to whichever list is frontmost. ⌘⇧F (store-wide search) stays per-app
//  (imbib: global search; imprint: cross-document search window) behind
//  `GlobalSearchProviding` until the grouped-by-kind browser lands (Stage 2).
//

import SwiftUI

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
#endif
