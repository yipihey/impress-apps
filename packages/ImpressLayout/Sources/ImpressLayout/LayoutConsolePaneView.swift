#if os(macOS)
// Kit file (ImpressLayout) — macOS-only. ADR-0031 D1/D5.
//
//  LayoutConsolePaneView.swift
//  ImpressLayout
//
//  The `console` view kind: the app's own log, in a pane.
//
//  ## It is the console, not a second one
//
//  Every impress app already has an in-app console, `ImpressLogging`'s
//  `ConsoleView` (⌘⇧C). A `console` pane is that view, unchanged, over the
//  same `LogStore.shared` — so what a pane shows and what the window shows
//  cannot disagree, and a line logged anywhere in the app appears in both.
//  Nothing here reads, filters or formats log entries.
//
//  ## Why the kit registers it, not the chassis
//
//  `docs/kit-manifest.md` allows ImpressLayout exactly ImpressRustCore,
//  ImpressSurface, ImpressKeyboard, ImpressLogging and ImpressTheme.
//  `ConsoleView` is ImpressLogging's, which the kit already depends on for
//  its three-point trace; it knows no record kind and no store. So the
//  factory needs nothing the kit does not already have, and a host that
//  registers nothing (`apps/kit-demo`) gets a real console pane rather than
//  a placeholder — the same reason `surface` is a kit kind. Putting it in
//  PublicationManagerCore would have made every non-chassis host re-register
//  a view that has no chassis in it.
//
//  ## Scoping: the console's own two controls, seeded from `view_state`
//
//  `PaneSpec.view_state` is opaque to the tree and owned by the view kind
//  (ADR-0031 D1). A `console` pane reads two keys from it, and they are the
//  two controls `ConsoleView` already has — no new filter language:
//
//      { "search": "layout", "levels": ["info", "warning", "error"] }
//
//  * `search` starts the search field. `LogStore.filteredEntries` matches it
//    against the message OR the category, so a category name is the
//    console's category filter.
//  * `levels` starts the level toggles (`LogLevel` raw values); absent means
//    all four, as the window opens.
//
//  The pane's query is ignored: a log is not store items. A changed
//  `view_state` rebuilds the console with the new seed; the user's edits in
//  the field are view state of the moment and are not written back.
//

import ImpressLogging
import SwiftUI

/// What a `console` pane's `view_state` asks the console to start with.
/// A pure value, so a test can prove the reading without a pane or the FFI.
public struct LayoutConsoleScope: Hashable, Sendable {
    public var search: String
    /// `nil` = every level (the console's own default).
    public var levels: Set<LogLevel>?

    public init(search: String = "", levels: Set<LogLevel>? = nil) {
        self.search = search
        self.levels = levels
    }

    /// Read `search` and `levels` out of a pane's `view_state`. Anything
    /// else — a missing object, a non-string search, an unknown level name —
    /// is ignored, never an error: a pane degrades to the unscoped console.
    public init(viewState: LayoutJSONValue?) {
        let object = viewState?.objectValue ?? [:]
        let search = object["search"]?.stringValue ?? ""
        var levels: Set<LogLevel>?
        if let names = object["levels"]?.arrayValue {
            let parsed = Set(names.compactMap { $0.stringValue.flatMap(LogLevel.init(rawValue:)) })
            levels = parsed.isEmpty ? nil : parsed
        }
        self.init(search: search, levels: levels)
    }

    /// How the pane names its scope in the log: `all` or `search 'x', levels a,b`.
    public var summary: String {
        var parts: [String] = []
        if !search.isEmpty { parts.append("search '\(search)'") }
        if let levels {
            let ordered = LogLevel.allCases.filter(levels.contains).map(\.rawValue)
            parts.append("levels \(ordered.joined(separator: ","))")
        }
        return parts.isEmpty ? "all" : parts.joined(separator: ", ")
    }
}

/// The `console` view kind: `ConsoleView`, embedded, seeded from the pane's
/// `view_state`, under the toolbar band the tree measured for it.
@MainActor
public struct LayoutConsolePaneView: View {

    let context: PaneContext

    @Environment(\.layoutToolbarBand) private var toolbarBand

    public init(context: PaneContext) {
        self.context = context
    }

    private var scope: LayoutConsoleScope {
        LayoutConsoleScope(viewState: context.spec?.viewState)
    }

    public var body: some View {
        let scope = scope
        ConsoleView(
            appName: context.controller.appID,
            search: scope.search,
            levels: scope.levels,
            isEmbedded: true
        )
        // `ConsoleView` owns its field and toggles as `@State`, seeded once;
        // a new seed from the tree has to be a new view. Not session-bearing
        // (the console holds no document), so an identity here is harmless.
        .id(scope)
        .padding(.top, toolbarBand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { logScope(scope) }
        .onChange(of: scope) { _, scope in logScope(scope) }
    }

    /// The pane is otherwise invisible from outside the window: this line is
    /// what `?category=layout` (and Tier B) read, like `pane N info:`.
    private func logScope(_ scope: LayoutConsoleScope) {
        logInfo(
            "pane \(context.tile) console: \(context.controller.appID) log, \(scope.summary)",
            category: "layout")
    }
}

#endif
