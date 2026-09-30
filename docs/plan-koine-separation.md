# Koine: the name, and the cut that is still in this repository

The layer's name is **koine**. The crate `koine` re-exports the pure grammar
(`impress-layout`, `impress-pane-query`, `impress-surface`, `impress-verb-surface`).
`koine-tui` is a text performance of `RenderTree`. The repository does not
split until the three conditions below are all true, and two of them still
have a remainder.

ADR-0033 D7 decided the standalone line and scheduled the move for last.
`scripts/check-kit-standalone.sh` is that decision as a command. This plan is
the work that makes the move a release of a contract rather than a copy of
`impress-core`.

## K0 — the name

Done. Call the layer koine. The existing crate paths stay, so UniFFI, the
Swift packages and every `use impress_surface::` keep working. A rename of
those crates is part of the repository cut, not a precondition of it.

## K1 — layout and surface state go through a store trait

Done in this change. `AttributedStore` (`crates/impress-core/src/store.rs`)
is `ItemStore` plus the attributed operation and the compare-and-swap.
`SqliteItemStore` implements it. `LayoutStore<S: AttributedStore>` and
`SurfaceStore<S: AttributedStore>` default `S` to `SqliteItemStore`, so every
existing caller is unchanged and a second backend can host the same rows.

### K1b — the types leave `impress-core`

Not done. This is what lets `impress-core` stay in impress-apps when koine
leaves. Today the trait's arguments (`Item`, `ItemQuery`, `OperationSpec`,
`GuardedWrite`) are still types this crate owns, and every store-tier kit
crate may depend on `impress-core` with features `sqlite`, `schema`, `collab`
(the kit manifest). The cut is:

1. Move `item`, `query`, `operation`, `store` (the traits and the error), and
   the schema-ref constants the layout and surface rows name, into a crate
   below both `impress-core` and the kit. `impress-core` keeps `SqliteItemStore`
   and the SQL compiler.
2. Point `LayoutStore` and `SurfaceStore` at that crate. Drop `impress-core`
   from their `Cargo.toml`.
3. Repeat for the other store-tier kit crates (`impress-layout-service`'s
   presets, `impress-workflow-service`, `impress-store-service`,
   `impress-ai`, `impress-store-ffi`) or leave them on this side of the cut.
   Koine the grammar is the pure rows in the kit manifest (`koine`,
   `koine-tui`, `impress-surface`, `impress-layout`, `impress-pane-query`,
   `impress-verb-surface`). The services that persist are the host's.
4. `check-kit-deps.sh --strict` then fails a pure crate that reaches
   `impress-core`. The standalone scratch workspace stops copying
   `impress-core`.

Until step 4, leaving still vendors `impress-core`. Do not open the other
repository before that.

## K2 — every app hosts the kit

Done for the window. imbib's `ContentView` is the chrome (sheets, search,
onboarding, startup dedup) and its content is
`ChassisRootView(configuration: .imbib, adoptedModels:)`, using the app's
own view models. ⌘0 / ⌥⌘0 / ⌃⌘S and ⌃⌘1–9 are the tree's chords. h/l are the
tree's focus. `/api/layout`, `/api/layout/apply` and `/api/layout/save` are
no longer registered; the tree's routes are `/api/layout/tree`,
`/api/layout/verb` and `/api/layout/op`.

`PaneLayoutStore` remains the appearance mirror (app appearance, PDF dark
mode). It is not the window's pane model.

iOS imbib is still `IOSContentView`. That shell is outside this cut; the kit
packages this plan talks about are the macOS window.

## K3 — one non-Swift frontend renders the same tree

Done as a mapping. `koine-tui` renders a `RenderTree` to lines and turns
j/k/Enter into an `Event`. It does not call verbs and it does not interpret
the event. `reduce` does. A terminal *program* — a tty loop that plans,
resolves, renders, and dispatches — is the next host of this mapping, the
way `ImpressSurface` is the SwiftUI host of the same tree. The mapping is
the frontend the contract required; the program is an app.

## What is still not the repository

Do not create the koine repository until K1b is done. The mechanical copy is
already the standalone check, and running it as a second repo while
`impress-core` is vendored puts the database in the UI library.
