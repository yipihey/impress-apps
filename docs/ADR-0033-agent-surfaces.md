# ADR-0033 — Agent surfaces: declarative, agent-authored GUIs over the layout tree

**Status:** accepted 2026-09-22
**Builds on:** ADR-0031 (query-addressed panes, the layout tree), ADR-0019 (store scoping),
ADR-0022 (chassis), ADR-0032 (a tool's own surface shows its own domain)
**Plan:** [plan-agent-surfaces.md](plan-agent-surfaces.md)

## Context

ADR-0031 made every pane a query rendered by a view kind, and every arrangement a verb on a
`layout-service` trait. An agent can already split a window, point a pane at a query, pick a
view kind, bind a parameter to a channel and save the result as a preset — over MCP, from a
chat. What it cannot do is put anything *new* in a pane: the nine view kinds are Swift
factories, each bound to a suite domain.

Two things want that missing piece at once. First, the suite keeps gaining Rust capabilities
(plotting, statistics, scientific codes) whose only human-facing surface is a verb; a GUI
for each costs a Swift view, a Mac loop and a release. Second, the agent-native principle
says agents are participants, not tools: an agent that has computed something should be
able to show it and ask the human to act on it, visually, and then keep working with what
the human did. Today that conversation happens in prose.

We also want the layer that answers both to be able to leave the repository one day as its
own kit, so the cuts have to be right now, not later.

## Decisions

### D1 — A surface is a stored, declarative UI document rendered by the `surface` view kind

A **surface** is an `impress/ui/surface@1.0.0` record whose payload is a `SurfaceSpec`:
a small closed vocabulary of containers, widgets, data sources and actions (D3). It renders
in any pane through the new `surface` view kind: the pane's query is `item(id)` of that
kind, so surfaces obey every ADR-0031 rule (parameters, channels, roles, undo, presets)
without a special case. An agent creates one with `surface_create`, shows it with
`surface_show` (a layout verb under the hood), and can put the same surface in three panes
with three different parameter bindings.

### D2 — The core is a pure Rust function pair; the renderer is dumb

`impress-surface` owns three pure functions:

```
plan(spec, state, params)          -> Vec<SourceRequest>     // which verbs/queries to run
resolve(spec, state, params, data) -> RenderTree             // what the human sees
reduce(spec, state, event)         -> (state, Vec<Effect>)   // what the human did
```

The Swift renderer maps `RenderTree` nodes to SwiftUI one to one and holds no logic. So:
`surface_render` (a verb) returns exactly what the human sees, headlessly, which makes every
surface Tier-A testable and lets an agent inspect its own GUI without a screenshot; a
second renderer (TUI, egui, HTML, a phone) is a mapping, not a port; and the standalone
kit ships the whole behaviour of a surface in one crate with no UI framework in it.

### D3 — The vocabulary is closed and versioned, like the pane algebra

Containers: `column`, `row`, `grid`, `section`, `tabs`. Widgets: `text` (markdown),
`table`, `list`, `plot`, `image`, `field` (text, number, slider, select, toggle, date),
`button`, `status`, `log`, `kv`, `divider`, `spacer`. Data sources: a fixed value, a
state path, a pane parameter, a pane query, or the result of a service verb. Actions:
set state, call a verb, publish a selection on the pane's channel, emit a named event to
the agent, open a query in a pane, refresh a source.

References are paths, not expressions: `{{state.bins}}`, `{{param.selected}}`,
`{{source.hist.plot}}`, `{{event.value}}`. There are no operators, conditionals or loops in
a spec. Anything that computes is a verb (D4). This is the same discipline ADR-0031 D2
applied to queries, for the same reason: a spec an agent can generate reliably, a schema a
validator can reject precisely, and a document that never needs a sandbox.

### D4 — Verbs are the only way a surface computes, through one linked inventory

A source or action that names a verb calls it through the `#[impress_service]` inventory
in the host process. A new Rust capability therefore needs exactly one thing to become
GUI-able: a `*-service` crate. Nothing in Swift, nothing in the surface layer.

The inventory is linked in one place, `crates/impress-capabilities`, which `impress-mcp`,
`impress-cli` and `impress-store-ffi` all depend on, so the MCP server, the CLI and the app
binary carry the same tool set (today the first two keep separate force-link lists and the
app has only the layout service). The crate exposes feature sets: `full` for the two
binaries, `kit` for the FFI — store, layout, surface and any capability that links into the
app without a second copy of a domain core. Domain cores already shipped as their own
xcframeworks (imbib, imprint, implore) are not in `kit`; their verbs reach a surface later
through the app's own automation router, not by linking them twice.

*Amended 2026-09-23 (wave 5).* In the app that "router" is a callback: the FFI exposes a
`SharedVerbHost` the shell installs on its store, and the executor consults it after the
inventory (the inventory wins on a shared name). impress implements it over `impel-tools`,
the suite's already-linked full inventory whose `call_tool` runs the same handler
`impress-mcp` runs and reaches imbib and imprint through their own HTTP routers — so a
domain core is still linked once per app, and a verb whose app is not running fails in
the source, by name, rather than silently writing the store behind the running app.

### D5 — State and events are store records, so agents can read what the human did

Surface state (`impress/ui/surface-state@1.0.0`, one row per surface and host instance) and
the events a surface emits (`impress/ui/surface-event@1.0.0`, pruned to the last 200 per
surface) are ordinary records. `surface_wait(id, after, timeout)` long-polls them. The
loop an agent runs is: create → show → wait → update or act → wait. Both records are
Ephemeral-tier in ADR-0019 terms (device-scoped, never synced) and exist because the agent
is a participant that needs to read them, not so anyone can analyse them later. ADR-0031's
privacy decision stands: the standard build records nothing that exists only to be
analysed, and the ring is pruned for that reason.

### D6 — Liveness across processes comes from the store, not from an HTTP relay

An agent in a chat drives the suite through `impress-mcp`, a separate process writing the
same SQLite file. The app's invalidation feed (L5) only hears its own process. It now also
polls SQLite's per-connection `PRAGMA data_version` every 250 ms and, when it moves, reads
`impress/ui/*` rows modified since its high-water mark and feeds them as invalidations. A
surface written from a chat appears in the running app with no server between them; a
standalone host that runs no HTTP server gets the same. `surface_wait` uses the same poll
in the agent's process. The HTTP routes (`/api/surface/*`) stay as the automation surface
and mirror the verbs, as `/api/layout/*` does.

### D7 — The standalone cut is decided now and executed last

The kit is: `impress-service-core` + `impress-service-macros`, `impress-pane-query`,
`impress-layout`, `impress-surface`, their `*-service` crates, `impress-capabilities`, the
FFI, and the Swift packages `ImpressRustCore`, `ImpressLayout` (the host moved out of
PublicationManagerCore) and `ImpressSurface`. The rule that keeps it separable: **no kit
crate depends on `impress-core`'s domain modules.** The pane-query algebra moves out of
impress-core into `impress-pane-query`; impress-core keeps the compiler that lowers a query
onto its store and the built-in kind manifest, which is domain data. A script pins the
dependency line in CI (`scripts/check-kit-deps.sh`: `cargo tree` for each kit crate must
not reach `impress-core`, except through the service crates' store feature until the store
trait itself is generic). Moving the Swift host out of PublicationManagerCore is the last
package, after the tree has migrated the existing sections (ADR-0031 L8), so that Tom's
active work on it is not disturbed.

### D8 — The prototyping loop is five verbs and one scaffold

`surface_schema` returns the JSON schema and a worked example, so an agent in a chat can
author without reading source. `surface_validate` names every error by path. `surface_create`,
`surface_show`, `surface_wait` are the loop. `scripts/new-capability.sh <name>` generates a
`*-service` crate skeleton with one verb, a Tier-A test, an example surface and the
registration line in `impress-capabilities`; the demo capability shipped with this ADR is
its output, so the scaffold is proven by use.

## Defaults accepted without further discussion

- **One surface per pane; no nesting.** Splits, tabs and docking belong to the layout tree.
- **Sources are cached by resolved arguments** and re-run only when an argument changes, a
  store invalidation names a query, or an action refreshes them explicitly.
- **A verb result that is not JSON-serialisable is a validation error**, not a runtime one.
- **Plots carry a `plot-spec@1.0.0` payload in the render tree**, never pixels. In the suite
  the widget renders through imprint-core's existing `render_plot_svg`; a standalone host
  registers its own plot renderer against the same spec.
- **Widget focus is keyboard-first**: j/k walk widgets, Enter activates, Escape leaves the
  widget, all under `.keyboardGuarded`; a surface never steals typing from a field.
- **Unknown widget kinds degrade to a placeholder that keeps the node**, as ADR-0031 does for
  unrenderable view kinds, so a spec authored for a newer kit still renders its rest.

## Consequences

- A Rust library becomes a GUI by gaining a service trait and a JSON document. The Mac loop
  is needed once, for the renderer, not per capability.
- Agents can show, ask and wait. The human answers in the window, not in prose.
- The layer can leave: the dependency line is pinned, the renderer is a mapping, the spec is a
  schema.
- Two vocabularies to keep closed (queries and specs). The pressure to add "just one
  expression" will be constant; the answer is a verb.
