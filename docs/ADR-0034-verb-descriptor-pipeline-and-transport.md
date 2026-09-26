# ADR-0034 — One verb descriptor, one invoker pipeline, a verb lifecycle and one transport

**Status:** PROPOSED 2026-09-26
**Builds on:** ADR-0033 (one linked inventory; verbs are the only way a surface computes), ADR-0024
(one inventory, two renderings; its D3 and D7 land here), wave 7 (codes, `strict_args`, `wire_version`,
the actor on layout and surface verbs)
**Plan:** [plan-verb-pipeline-and-transport.md](plan-verb-pipeline-and-transport.md) — measurements,
findings, work packages. **Followed by:** [ADR-0035](ADR-0035-generated-verb-surfaces-and-docs.md),
which generates GUIs, reference docs and profiles from the descriptor this record defines and cannot
start before P1/P2 here have landed.

## Context

One `#[impress_method]` generates the MCP tool, the CLI subcommand and impel's tool. A critique of the
pattern (2026-09-26) found it sound but held by vigilance rather than construction, and the plan's
measurements agree: the generated invoker does one optional thing (a strict argument check, on by two of
38 services) and nine entry paths call the handler themselves while two bypass the invoker entirely;
reachability has three rules; the actor is a request field an MCP client can set to `"human"`; one
path in eleven writes an audit record; nothing has a span. Nothing says which caller may run which
verb, and the apps' automation servers answer `Access-Control-Allow-Origin: *` and admit any loopback
caller without a token, with no `Host` check. Verbs have no version, deprecation or alias, and the
only planned rename (ADR-0024 D7) has nothing to land on. Fifty-three verbs take seconds and none
reports progress or takes a cancel; MCP's serial loop blocks for their duration. Four hand-written
adapters (7,645 lines) forward 200 methods to 160 hand-written Swift routes, eight of them dead. The
descriptor's `&'static` fields and `fn`-pointer handler make a runtime-registered verb impossible.

## Decisions

### D1 — One `VerbDescriptor`; `McpToolDescriptor` and `CliSubcommand` are projections of it

The descriptor carries name, description, group, surface, input and output schema, safety class
(`read-only | mutating | destructive | external`, plus `idempotent`, `long_running`, `needs_app`),
examples, `since`, `deprecated`, an optional budget, its source (linked, alias, provider) and a
handler that may capture state. Derived fields are derived (output schema from the return type, group
from the crate, `needs_app` from the backend slot); declared fields are declared once per service with
per-method exceptions; every field has a test over the linked inventory that fails when it is missing
or disagrees with the committed safety table. The two existing descriptor types stay as projections so
their thirty readers compile.

### D2 — The invoker is an ordered pipeline, seated in one place, applied to every path

`Pipeline::invoke(descriptor, Call)` in `impress-service-core` runs: identity → strict args →
reachability → policy → span → invoke → envelope → audit → (later) undo. Every path that runs a verb —
MCP flat and grouped, the CLI, the surface runtime and its HTTP mirror, the FFI verb host and the FFI
layout `apply`, impel-tools, mcp-host, impress-ai-tools, the app-side route and a runtime provider —
calls it, and a test that enumerates the call sites fails when one does not. The chain is hand-rolled
(a vector of layers over `(descriptor, Call) -> Future<Result>`), not tower: it must wrap two non-HTTP
bypasses and the store's own entry points that carry no request type, and it replaces the inline
bearer/allowlist code that two servers already hand-roll. Ordering rule: nothing that can refuse runs
after a side effect; identity before policy; the span encloses invoke and envelope; audit records the
final code. Measured cost of the span layer is ≤ 5 µs per verb.

### D3 — Caller identity comes from the transport; policy decides; review is a surface

A caller is `Person` (a UniFFI call from the app), `Agent(name)` (MCP, the CLI, Python), `App(id)`
(the app-side route with its token) or `Provider(id)` — established by the pipeline from where the call
came, never from an argument. The `actor` field on the layout verbs becomes derived. Policy maps
`(identity, safety class, verb)` to allow, review or deny; a destructive or external verb from an agent
is queued as the verb's review surface (ADR-0035 D2's generated form with its review step) and answers
`review-pending` with the surface id; the person's confirmation re-enters the pipeline as `Person`.
That is the mechanism behind "human review points are explicit", and it never halts the window.

### D4 — The automation servers close the loopback and CORS hole first, independent of the rest

No wildcard origin; a per-launch loopback token required on every non-GET; a `Host` check; every app
builds its server configuration from the shared settings section; no mutation on GET; impress-ai-http
on its documented port; impel-server no longer fails open. This is work package P0 and lands alone,
before anything makes the inventory more discoverable.

### D5 — Verbs have a lifecycle: `since`, `deprecated`, aliases, and a rename pass for stored documents

An alias is a descriptor whose source names its target; the pipeline resolves it, and the span and
audit count calls under the old name so removal is a measured decision. A rename pass in the layout and
surface services rewrites stored `verb` and `view_kind` strings from the alias table, flagged and
ledgered as the task-schema migration is, leaving an edited row alone as the preset upgrade does. The
four hand-written MCP tools are the first aliases (ADR-0024 D7). Measured today: zero stored surfaces,
sixty panes in re-seedable rows — the cheapest this will ever be, and it lands before ADR-0035 G4 makes
every name public.

### D6 — A long-running verb returns a job on the task kernel; progress is an event ring

A `long_running` verb answers in milliseconds with a `task@1.0.0` handle; progress is a per-job
`task-event@1.0.0` ring with the surface ring's cursor semantics (`seq`, bounded, `gap`, wait with the
cursor unchanged on timeout); `job_events`, `job_wait`, `job_cancel` (a `cancel_requested` flag
executors poll; running → cancelled is already legal) and `job_result` are verbs, so MCP, the CLI, a
surface `status` widget and the profiler all see the same job. With no daemon for the kind, the
pipeline runs the job inline under `spawn_blocking` and writes the same rows.

### D7 — One transport to the running apps, and the same transport for providers

`POST /api/verb/<name>` on every app, JSON in, the verb's own result out, refusals in the wave-7
envelope — what `/api/layout/verb` and `/api/surface/*` already are. One Rust client (`impress-app-transport`:
one probe rule, one port table, one bearer, `traceparent`), used by the pipeline's invoke step when a
verb's app is running and the verb is not linked locally; a per-app UniFFI target so the app dispatches
the route through the same pipeline in-process. The four `*-service-http` crates, `impress-app-client`
and the 160 mirrored Swift arms are deleted; the eight dead routes, the four probe loops and the
kit/full inventory split go with them. A runtime provider speaks the same transport in reverse:
it registers its descriptors (validated by the same tests the linked inventory passes) and answers
`/verb/<name>`; the registry sits behind `descriptors()`/`find()` so there is still one inventory, the
linked set wins a name collision, a departed provider's verbs are marked unavailable rather than
removed, and a provider's safety claim is a floor — effective class `external` until the person trusts
the provider.

### D8 — Python is one generic binding over the transport; the macro's shim claim is deleted

`impress.list_verbs()` and `impress.call(verb, args)` in a pyo3 crate over `impress-app-transport`,
identity `Agent("python")`, through the same pipeline. No per-method shims.

### D9 — A rule is a type where it can be; scripts keep what construction cannot

Schema refs become constants generated from `schema-refs.json` behind a `SchemaRef` newtype with no
public constructor, and the script keeps the Swift half; the macro refuses an undocumented method and a
service with no safety or since; workspace lints and a `disallowed-types` rule stop the newtype being
bypassed; the two prose-only definitions of done get golden tests; `check-kit-deps` folds into the
standalone check. The Swift package allowlists, the TypeScript backstop and the gate's sharding stay
scripts.

## Alternatives rejected

- **tower layers for the pipeline.** Right for an axum route, wrong for the FFI's `apply`, the surface
  HTTP mirror and the store entry points, which carry no request type; a hand-rolled chain covers all
  twelve seats with one shape.
- **A separate policy service or a permissions file per app.** Policy is a pure function of identity
  and the descriptor's safety class; anything else is a second place to describe a verb.
- **Trusting the `actor` argument.** It is what exists and it is a claim; the plan shows an MCP client
  claiming to be the person today.
- **Per-adapter fixes for the dead routes.** Eight one-line fixes leave the class of failure (a second
  and third definition of each capability) intact; the transport removes the class.
- **A job model on the surface event ring or on impress-ai's task progress.** The ring has no handle,
  lifecycle or cancel; the AI progress is AI-specific with one preview and no cancel; the kernel has
  both and lacks only progress and in-flight cancel.
- **Removing verbs instead of aliasing.** Zero stored documents today does not mean zero tomorrow;
  ADR-0035 stores a surface per verb.
- **Per-method Python shims.** ~433 signatures to keep in step for a need one function serves.
- **Leaving the loopback/CORS exposure to the catalogue's wave.** It is live now.

## Consequences

- Every interface — MCP, CLI, surface, FFI, impel, Python, a Julia provider — runs the same chain; a
  concern is added once. The two bypasses are gone, so the GUI's verbs are validated, attributed and
  audited like an agent's.
- A caller's identity is a fact the pipeline established; an agent cannot act as the person, and a
  destructive verb from an agent is a review surface, not a modal and not a silent write.
- Verb names can change; stored documents follow.
- Long verbs stop blocking MCP; progress and cancel have one shape everywhere.
- 7,645 lines of adapter and 160 Swift route arms are deleted; three inventories become one; the
  macro's claims match its code.
- New record kinds (`task-event@1.0.0`, `provider@1.0.0`), a result-shape change for 53 verbs, an
  argument change for 24 layout verbs, and a token on every local non-GET are the ask-first items the
  plan lists; each has a decision in its § Decisions needed.
- The pipeline is also the thin-shim opportunity for build cost: once every concern lives in one
  chain, the per-verb generated code shrinks to an args struct, a schema fn and a call, and the plan's
  build-cost budget (its § Build cost, a follow-up measurement) is checked in CI against that shape.
- ADR-0035 builds on this: its generator reads D1's descriptor, its safety-in-the-GUI is D3's review
  surface, its profiling rides D2's span layer, and its catalogue waits for D5.
