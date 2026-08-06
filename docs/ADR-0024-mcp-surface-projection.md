# ADR-0024: MCP Surface Projection — one inventory, two renderings

**Status:** Accepted — **S0–S2 implemented (2026-08-02)**; S3–S4 outstanding
**Date:** 2026-08-02
**Depends on:** ADR-0021 (record-kind descriptors — declared, not coded), ADR-0022 (collection kernel, docs-import service), `docs/mcp-migration-ledger.md` (the TypeScript retirement and why one definition is non-negotiable)

## Context

`crates/impress-mcp` answers `tools/list` with every `#[impress_service]` method
registered in the binary. Measured 2026-08-02 by driving the server over stdio
and sizing the response:

| Surface | Tools | Schema bytes | Tokens | Namespaces |
|---|---|---|---|---|
| As exposed (imprint running; imbib, implore, impart closed) | 222 | 120,414 | ~30,103 | 26 |
| Full inventory (`IMPRESS_MCP_LIST_ALL=1`) | 268 | 140,234 | ~35,058 | 29 |

Distribution is heavily skewed:

| Tools | Tokens | Description share | Namespace |
|---:|---:|---:|---|
| 43 | 4,647 | 18% | `imbib-library-service` |
| 10 | 3,233 | **54%** | `docs-import-service` |
| 18 | 2,323 | 32% | `impress-bridges-service` |
| 14 | 1,945 | 21% | `imprint-manuscript-service` |
| 4 | 1,123 | **68%** | `store-query-service` |

Every client pays this on **every request**, before the user types anything.
For a cloud frontier model that is affordable. For the local-model work
underway — a 30B-class model served from oMLX with a finite window — it is
both a context cost and an accuracy cost: a 222-entry menu measurably degrades
tool selection, independent of the tokens it burns.

Two servers in the same working set show what the ceiling should look like.
`lilook` exposes **5 tools in 678 tokens** and reaches its full capability
through `lilook_doc` → `lilook_capabilities` → `lilook_describe` → `lilook_edit`.
`scix` exposes **12 tools in 1,852 tokens**, collapsing ~15 library operations
into two action-dispatch tools with `action` enums. The pattern that fixes this
is already proven inside the toolset; it was never applied to the largest server.

Four tools also predate the codegen and break the namespace convention:
`search_papers`, `get_paper_chunks`, `list_indexed_papers` and the raster tool
land in bogus namespaces `search`/`get`/`list`/`render`. Because
`reachability::required_app` keys on the `split_once('_')` prefix, these are
structurally ungateable.

### The constraint

CLAUDE.md forbids a hand-written MCP server. One `#[impress_method]` generates
the MCP tool, the CLI subcommand and impel's agent tool together, and the
TypeScript server was retired (229 tools, 24,958 lines) precisely because a
second hand-maintained definition drifted from the generated one — eleven tools
were re-added by hand that already existed in the inventory.

Any fix must therefore not introduce a second definition of any capability.

## Decisions

### D1 — Grouping is a projection, not a second definition

`McpToolDescriptor` remains exactly one entry per `#[impress_method]`, and stays
the single source of truth for the CLI, impel and the parity tests. What changes
is only how `impress-mcp` *renders* that inventory into the MCP wire format.

A new `crates/impress-mcp/src/surface.rs` folds `inventory_tool_definitions()`
into a grouped shape. It reads the same descriptors, derives the namespace from
the existing `name` field, and emits a smaller tool list. No capability is
declared twice; a grouped tool is a *view*, and a view cannot drift from its
source.

This is the property that distinguishes this ADR from the TypeScript server:
that server was a second **authority**, this is a second **rendering**.

### D2 — The surface is hybrid: primary tools flat, everything else grouped

Pure grouping was considered and rejected. It reaches ~3–4k tokens, but every
call then costs a `describe` round trip before the model knows its arguments —
and on a local model an extra round trip is exactly where reliability is lost.

The surface is therefore two-part:

- **Primary tools** — roughly 15 cross-cutting entry points, exposed flat with
  full input schemas, callable with no preamble.
- **Domain tools** — one per domain (`imbib`, `imprint`, `implore`, `impart`,
  `impel`, `store`, `collection`, `docs`), each carrying an `action` enum over
  its remaining methods, a free-form `args` object, and a `describe` action
  returning the exact schema for one action.
- **One root tool**, `impress_capabilities`, which names the domains, says what
  each owns, and — the part that matters — says when impress is *not* the right
  instrument. An agent should be able to rule the whole suite out in one read.

Target: **~6–8k tokens**, against ~30k today.

### D3 — Primary is declared on the method, not listed in the server

A hard-coded list of hot tool names inside `impress-mcp` would be a second place
to keep in step — the exact failure this ADR exists to avoid. Following
ADR-0021 D3, the classification is data on the method:

```rust
#[impress_method(surface = "primary")]
async fn search_all(&self, args: SearchAllArgs) -> Result<Value>;
```

`surface` defaults to `"grouped"`, so the attribute is additive and every
existing method keeps compiling untouched. `McpToolDescriptor` gains a
`surface: Surface` field carrying it through to the renderer.

If the macro change is deferred, the fallback is a declared table in
`surface.rs` **plus** a parity test asserting every name in it resolves to a
live descriptor — a table that cannot silently name a tool that no longer
exists. The macro form is preferred; the table is the cheaper first step.

### D4 — Dispatch resolves to the existing name, and nothing else changes

A grouped call arrives as `{domain, action, args}`. The renderer reassembles
`"<namespace>_<action>"` and hands it to the existing `call_inventory_tool`.
There is no second dispatch path, no second error surface, and
`unavailable_reason` keeps producing the message it produces today.

### D5 — Reachability governs the projection, not the other way round

`reachability::is_available` continues to decide what exists. A domain tool
appears only if at least one of its methods is currently available, and its
`action` enum lists only the available ones. A closed app removes actions from
an enum rather than leaving callable-looking entries that fail — the same
argument `reachability.rs` already makes: an advertised tool the model cannot
call is worse than an absent one.

`IMPRESS_MCP_LIST_ALL=1` keeps meaning "show the true inventory", and continues
to bypass both the gate and the projection.

### D6 — The flat projection is retained and remains the default for impel

`IMPRESS_MCP_SURFACE=grouped|flat`, defaulting to `grouped` for MCP clients and
`flat` where the full per-method surface is wanted. impel spawns this binary at
app launch and consumes the full capability surface deliberately — CLAUDE.md's
"every tool exposes its full capability surface to impel" is a design principle,
not an accident, and this ADR does not narrow it.

`tests/mcp_surface_parity.rs` gains a case per projection, plus the invariant
that binds them: **every descriptor reachable in `flat` is reachable in
`grouped`**, as either a primary tool or a domain action. The projection may
re-shape the surface; it may not lose a capability.

### D7 — The legacy four get a real namespace

`search_papers`, `get_paper_chunks`, `list_indexed_papers` and the raster tool
move under a proper namespace (`imbib-semantic-service_*`), which makes them
gateable by the mechanism that already exists rather than permanently exempt.
They are pre-codegen hand-written tools; this is the point at which that stops
being invisible.

### D8 — Descriptions get a budget

`docs-import-service` spends 54% of its bytes on prose and `store-query-service`
68%. Since a description is a doc comment on the trait method, the budget
belongs where the doc comment is: a lint in the workspace gate warning above
~400 characters. The first line should say what the tool does; the rest belongs
in the ADR or the ledger, not in every `tools/list` response forever.

## Work packages

| WP | Scope | Gate | Status |
|---|---|---|---|
| **S0** | `scripts/mcp-surface-size.py` — drive any MCP server over stdio, report tools/bytes/tokens by namespace | Reproduces the numbers in this ADR | **done** |
| **S1** | `surface.rs`: grouped renderer + `IMPRESS_MCP_SURFACE` switch, table-based primary list | `grouped` under 8k tokens, measured by S0 | **done** |
| **S2** | Parity test: both projections, plus the no-capability-lost invariant | `cargo test -p impress-mcp` | **done** |
| **S3** | `#[impress_method(surface = ...)]` in `impress-service-macros`; retire the table | Workspace clippy gate clean | outstanding |
| **S4** | D7 renaming + D8 description lint | Namespace convention holds for every tool | outstanding |

S1 and S2 are the load-bearing pair; S3 and S4 are follow-ups that can land
separately.

### Measured result (2026-08-02, `scripts/mcp-surface-size.py --compare`)

| Projection | Tools | Chars | Tokens |
|---|---:|---:|---:|
| `flat` | 222 | 120,858 | ~30,214 |
| `grouped` | 23 | 21,020 | ~5,255 |

**Grouped costs 17% of flat — 24,959 tokens saved per request.** The 23 are the
root tool, the four pre-codegen tools still flat (D7), the 13 primaries, and
five domain tools; `implore` and `impart` are absent because those apps were
closed, which is `reachability` behaving as designed.

The domain enums are large — `imbib` carries 103 actions, `imprint` 44 — which
is the D2 tradeoff showing up in the numbers, and why the Risks entry on
unbounded enums is not hypothetical.

Verification beyond the token count: `grouped_surface_via_stdio` calls one
non-primary capability both ways against the shipped binary and asserts the two
`structuredContent` payloads are equal. A projection that lists correctly but
dispatches wrong would pass every in-process test in the module.

## Risks

**The `describe` round trip.** Any capability behind a domain tool costs one
extra call before its schema is known. D2's primary set is the mitigation, and
it is only as good as the choice of which ~15 tools are primary. That choice
should be revisited from real transcripts once the surface ships, not fixed by
intuition now.

**`action` enums grow unbounded.** `imbib-library-service` alone has 43 methods;
an enum that large is itself a selection problem. That namespace likely needs
sub-grouping on its own terms, which this ADR does not attempt.

**Two projections mean two behaviours to reason about.** D6's shared invariant
is what keeps this from becoming the drift it is meant to prevent — if that test
is ever weakened, the argument in D1 no longer holds.

**Measured on one machine, one moment.** The 222/268 split reflects which apps
happened to be running. Any regression gate must use `IMPRESS_MCP_LIST_ALL=1`
so it does not depend on what was open.
