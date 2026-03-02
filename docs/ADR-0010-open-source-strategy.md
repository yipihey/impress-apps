# ADR-0010: Open-Source Strategy for the Impress Rust Crates

**Status:** Accepted
**Date:** 2026-03-02
**Authors:** Tom (with architectural exploration via Claude)
**Supersedes:** ADS0003 (Open-Source Strategy, Naming Conventions, and Interface Architecture — 2026-02-26)
**Scope:** All Rust crates in `crates/` and `apps/impel-tui/`, licensing boundaries, crate naming, packaging model, dependency graph, Python bindings, MCP exposure

---

## Context

The impress suite's Rust crates have grown into a coherent library ecosystem. Where ADS0003 described an aspirational future with `im-*` naming and full crate publication, the actual state of the codebase has diverged: all crates use the `impress-*` / `*-core` naming scheme that was introduced during internal development, and there is no immediate plan to publish most of them. Three things have become clear enough to warrant a cleaner decision:

1. **The naming collision.** ADS0003 proposed renaming all internal crates from `impress-*` to `im-*` before publication. However, `im-bibtex` and `im-identifiers` have already been published to crates.io under the `im-*` namespace by a collaborator. These external published crates are separate from the internal `impress-bibtex` and `impress-identifiers` crates in this repo. Renaming the internal crates to match the published ones would create a confusing equivalence where none exists — the internals are more tightly coupled to the impress domain and not yet ready for general publication. The rename is a packaging decision, not an architectural one, and should happen only when a crate is actually published.

2. **The crate inventory is now concrete.** The repo contains 18 crates across four identifiable categories. The licensing boundary can be stated precisely against real crates, not hypothetical ones.

3. **The library-first packaging model is validated.** `scix-client` (a separate repo) ships as `lib.rs` + `main.rs` + MCP server and is in active use. The pattern works. The question now is how to apply it consistently to the impress-internal crates as they mature toward publication.

### Current Crate Inventory

```
crates/
  impress-core          — Unified item protocol: schema system, operation model, local SQLite store
  impress-domain        — Domain types (Publication, Author, Annotation, Manuscript, …)
  impress-bibtex        — BibTeX/BibLaTeX parsing and generation
  impress-identifiers   — Scholarly identifier parsing: DOI, arXiv ID, ISBN, PMID, bibcode, ORCID
  impress-tags          — Hierarchical tag namespace model, autocomplete, query
  impress-flags         — Flag/priority/workflow-state model
  impress-collab        — Shared CRDT collaboration primitives
  impress-helix         — Helix-style modal editing for terminal interfaces
  impress-llm           — Multi-provider LLM support (wraps graniet/llm)
  imbib-core            — Cross-platform core for imbib (bibliography engine)
  imprint-core          — Core for imprint (Typst manuscript authoring)
  impart-core           — Core for impart (communication: IMAP/SMTP/MIME)
  impel-core            — Core for impel (agent orchestration, event sourcing, persona system)
  impel-server          — HTTP/WebSocket server exposing impel-core as an API
  implore-core          — Core visualization engine for implore
  implore-io            — Data I/O for implore (HDF5, FITS, CSV, Parquet)
  implore-selection     — Selection grammar parser for implore
  implore-stats         — Statistical functions for implore (ECDF, CDF, …)

apps/
  impel-tui             — Terminal UI for impel (workspace member)
```

---

## Decision

### D34 — Keep `impress-*` Naming Until Publication

The current crate names (`impress-core`, `impress-bibtex`, `impress-identifiers`, etc.) are correct for this stage of development. The `im-*` renaming described in ADS0003 is deferred to the moment each crate is actually published to crates.io.

Rationale: renaming before publication imposes churn (Cargo.lock changes, import path rewrites across all dependent crates and Swift FFI bindings) without any external benefit. The `impress-*` names are already self-documenting within the monorepo. The renaming decision should be revisited per-crate when publication is imminent, at which point namespace availability, collision with the already-published `im-bibtex` / `im-identifiers`, and branding preferences can all be weighed together.

**Nothing in this ADR commits to `im-*` as the published name. That is deferred.**

### D35 — MIT-Licensed Crates: The Foundation and Service Client Layers

The following crates are declared MIT-licensed (matching the workspace `license = "MIT"`) and will be published as open source when they are sufficiently stable:

**Foundation crates** — stateless transformations, no network I/O, no item graph dependency:

| Crate | What it is |
|-------|-----------|
| `impress-bibtex` | BibTeX/BibLaTeX parsing and generation |
| `impress-identifiers` | DOI, arXiv ID, ISBN, PMID, bibcode, ORCID parsing and resolution |
| `impress-tags` | Hierarchical tag namespace model, autocomplete, query |
| `impress-flags` | Flag/priority/workflow-state model |

**Item graph and schema layer:**

| Crate | What it is |
|-------|-----------|
| `impress-core` | Unified item protocol: item types, schema registry, operation model, local SQLite store |
| `impress-domain` | Domain types shared across all app cores (Publication, Author, Annotation, Manuscript, …) |

**Service client crates** (separate repos, already the pattern from `scix-client`):

Named for the service they wrap, not for impress. MIT licensed. Each ships as Rust library + CLI + MCP server. The primary examples are:

| Crate | Service |
|-------|---------|
| `scix-client` | SciX / NASA ADS (shipped v0.3.0) |
| `crossref-client` | CrossRef (planned) |
| `openalex-client` | OpenAlex (planned) |

### D36 — Proprietary Crates: App Cores and Agent Intelligence

The following remain proprietary (closed source, not published to crates.io):

**App core crates** — these contain significant business logic specific to the commercial apps, are compiled into XCFrameworks via UniFFI and embedded directly into macOS apps, and are not useful in isolation:

| Crate | Reason |
|-------|--------|
| `imbib-core` | Full bibliography engine: full-text search (Tantivy), PDF processing (pdfium), semantic search (fastembed), SciX sync — app-specific, large binary dependencies |
| `imprint-core` | Typst rendering pipeline, CRDT-backed collaborative editing — app-specific |
| `impart-core` | IMAP/SMTP server, MIME parsing — closely tied to impart's UX model |
| `impel-core` | Persona runtime, event sourcing, agent thread management — contains proprietary orchestration intelligence |
| `impel-server` | HTTP/WebSocket API wrapping impel-core — internal infrastructure |
| `implore-core` | Visualization engine — app-specific rendering |
| `implore-io` | Scientific data I/O (HDF5, FITS, Parquet) — app-specific |
| `implore-selection` | Selection grammar parser — app-specific DSL |
| `implore-stats` | Statistical functions — app-specific |

**Infrastructure crates** (internal only):

| Crate | Reason |
|-------|--------|
| `impress-collab` | CRDT collaboration primitives for internal use — not stable enough to publish |
| `impress-helix` | Helix-style modal editing core — internal to impel-tui |
| `impress-llm` | LLM provider wrapper — depends on git-pinned upstream, not suitable for publication |

**Not-yet-built proprietary components** (referenced here for completeness):

- CloudKit sync layer — will be built on top of `impress-core`; proprietary
- Persona runtime memory and trust model — implemented within `impel-core`; proprietary
- All Swift/AppKit UI code — imbib, imprint, implore, impel, impart

The open/proprietary boundary follows one principle: **every atomic data operation is open source; orchestration, intelligence, and experience are proprietary.** Researchers who want to script against their bibliography from a terminal or notebook get `impress-core` and `impress-bibtex`. Researchers who want the full intelligent, integrated experience pay for the apps.

### D37 — Library-First Packaging Model

Every MIT crate that ships publicly follows this layout:

```
crate-name/
├── Cargo.toml
├── src/
│   ├── lib.rs        # The library — the primary artifact
│   ├── main.rs       # CLI binary: thin wrapper over lib.rs
│   └── mcp.rs        # MCP server: `serve` subcommand (optional, where useful)
├── python/           # PyO3 bindings (optional, when demand exists)
│   └── crate_name/
├── pyproject.toml    # (if python/ present)
└── README.md
```

The library is the primary artifact. The CLI and MCP server add no logic — they translate between Rust types and wire formats. This yields:

- **Consistency:** identical behavior from Rust code, shell script, or AI agent.
- **Testability:** the library is fully tested in Rust; CLI and MCP wrappers are tested only for argument parsing and output formatting.
- **Composability:** downstream Rust crates depend on the library alone, without pulling in CLI or MCP dependencies.

`scix-client` (separate repo, shipped) is the reference implementation. Any MIT crate in this list that does not yet have `main.rs` or `mcp.rs` should add them as part of its publication preparation, not before.

### Dependency Graph

The graph flows in one direction. Service clients have no `impress-*` dependencies (they are general-purpose). Foundation crates have no network or app-core dependencies. Domain libraries compose across layers. App cores sit at the top and are consumed only by Swift apps.

```
Service clients (no impress-* dependencies, separate repos)
  scix-client       ✅ shipped v0.3.0
  crossref-client   (planned)
  openalex-client   (planned)

Foundation — stateless, no network (MIT, publish when stable):
  impress-tags
  impress-flags
  impress-bibtex      → impress-domain
  impress-identifiers → impress-domain

Core domain types (MIT, publish when stable):
  impress-domain    (leaf — no workspace deps)
  impress-core      → impress-domain (optional sqlite feature)

App cores (proprietary, XCFramework targets):
  imbib-core    → impress-core, impress-domain, impress-bibtex, impress-identifiers,
                   impress-flags, impress-tags
  imprint-core  → impress-domain, impress-bibtex, impress-identifiers
  impart-core   → impress-domain
  impel-core    → impress-domain, impress-collab
  implore-core  → impress-domain, impress-collab
  implore-io    (no workspace deps)
  implore-selection (no workspace deps)
  implore-stats  (no workspace deps)
  impel-server  → impel-core

Apps (proprietary Swift/AppKit):
  imbib     → imbib-core (XCFramework) + Swift UI
  imprint   → imprint-core (XCFramework) + Swift UI
  implore   → implore-core, implore-io, implore-stats (XCFrameworks) + Swift UI
  impel     → impel-core (XCFramework) + Swift UI + persona runtime
  impart    → impart-core (XCFramework) + Swift UI
```

Key structural constraint: `impel-core` has no Rust dependency on other app cores. It communicates with other domain libraries through MCP tool calls, not through direct Rust linkage. This keeps the orchestrator decoupled from domain logic and able to orchestrate any MCP-compatible tool.

### The Role of `impress-core` in Open Source

`impress-core` is the most significant open-source component. It provides:

- **Item type registry** — the schema system for all item types (paper, manuscript, message, dataset, figure, note, code, etc.)
- **Operation model** — typed, reversible mutations with full provenance
- **Local SQLite store** — the on-disk storage engine used by all app cores (behind the `sqlite` feature flag)

What `impress-core` does NOT include, and will never include in its MIT form:

- CloudKit sync — the network sync layer stays proprietary (will be a separate closed-source crate that wraps `impress-core`)
- Impel intelligence — agent judgment and persona behavior live in `impel-core`, which is proprietary
- Swift UI code — all views are proprietary Swift

The open-source `impress-core` gives any researcher or developer the foundation to build their own research data tools on top of the same item graph that the commercial apps use. A Python notebook can import `impress-core` via PyO3 bindings, query the local SQLite database, and manipulate items — without requiring any app to be installed.

### Python Binding Strategy

PyO3 + Maturin generate Python bindings with zero separate Python code to maintain. `scix-client` validates this approach.

Python bindings are created selectively, only for crates where notebook integration is a realistic use case:

| Crate | Python value | Priority |
|-------|-------------|----------|
| `impress-core` | Query and manipulate the item graph from Jupyter | High |
| `impress-bibtex` | Parse BibTeX in data pipelines | Medium |
| `impress-identifiers` | Resolve DOIs and arXiv IDs in notebooks | Medium |
| `impress-tags` / `impress-flags` | Tag/flag manipulation in batch scripts | Low |

Python packages follow the same name as the Rust crate (underscores replacing hyphens). Module: `import impress_core`, `import impress_bibtex`. No namespace collision with the `im_bibtex` / `im_identifiers` Python packages (which correspond to the separately-published `im-bibtex` / `im-identifiers` crates).

### MCP Exposure for External Agents

The `serve` subcommand in each published crate starts an MCP server over stdio. This is the mechanism by which external AI agents (Claude Desktop, Claude Code, Cursor, Zed) access impress capabilities without installing any macOS app.

**Planned MCP servers from MIT crates:**

| Binary | MCP tools | Use case |
|--------|-----------|---------|
| `impress-core serve` | `press_query`, `press_create`, `press_link`, `press_export` | Read and write the local item graph from any agent |
| `impress-bibtex serve` | `bibtex_parse`, `bibtex_format`, `bibtex_validate` | BibTeX manipulation in agent workflows |
| `impress-identifiers serve` | `identifier_resolve`, `identifier_classify`, `identifier_parse` | DOI/arXiv resolution in agent pipelines |

An agent using Claude Desktop can install `impress-core` from crates.io, run `impress-core setup` (analogous to `scix setup`), and immediately have access to the researcher's local item graph. No app required.

### Community Contribution Model

External contributions are welcomed at every MIT layer:

| Contribution type | Example | Downstream benefit |
|------------------|---------|-------------------|
| New service client (separate repo) | `inspire-client` for HEP papers | Any agent or tool gains a new data source |
| Foundation crate fix | Better BibTeX edge-case handling in `impress-bibtex` | All downstream crates improve |
| `impress-core` schema addition | New item type for datasets | All apps gain the new type |
| Bug fix in identifier resolution | ISBN-13 check digit edge case in `impress-identifiers` | All apps and CLI users benefit |
| Journal formatting rules | MNRAS style rules (CC-BY-SA data) | Manuscript checking covers more venues |
| Typst journal templates | AAS journal template (MIT) | Publishable to Typst Universe |
| Python binding improvements | Better async support in `impress_core` | Notebook users benefit |

We do not accept external contributions to proprietary crates (`imbib-core`, `imprint-core`, `impel-core`, etc.) or to the Swift UI code. Contribution to proprietary layers requires a Contributor License Agreement and explicit invitation.

---

## Consequences

### Positive

- The naming decision eliminates immediate churn: no mass import-path rewrites before publication is actually needed.
- The MIT/proprietary boundary is now stated against real, named crates — not hypothetical layers.
- `impress-core` as an open-source item graph gives the community a genuine foundation crate, not just utility libraries. Researchers can script against their own data without buying the app.
- The library-first model (validated by `scix-client`) ensures CLI, MCP, and Python interfaces are perpetually consistent with zero extra logic.
- Foundation crates (`impress-bibtex`, `impress-identifiers`, `impress-tags`, `impress-flags`) are independently useful and can attract contributors who never use the full suite.
- The `impress-core` PyO3 bindings enable Jupyter notebook workflows against the same data that the GUI apps use — a concrete research-productivity benefit independent of the app ecosystem.

### Negative

- Keeping `impress-*` names internally means the rename-to-publish step remains as future work. It must be tracked per-crate and done carefully to avoid breaking internal dependencies during the transition.
- Publishing `impress-core` (the item graph) means competitors could build on the same data model. The value is in the integrated experience, not the schema, so this is acceptable.
- Multiple interface surfaces (CLI, MCP, Python) per published crate expand the API surface area. The thin-wrapper pattern minimizes maintenance cost, but documentation and compatibility commitments grow with each published crate.
- Distinguishing `impress-bibtex` (internal, proprietary-adjacent) from the already-published `im-bibtex` (external crate from a collaborator) may confuse contributors. Clear documentation in each crate's README must address this.

### Risks

- **Premature publication commitment.** Publishing a crate to crates.io creates semver expectations. We must not publish until the API is stable enough to warrant it. Mitigation: explicit "publication readiness" checklist per crate; default to not publishing.
- **Divergence from collaborator crates.** `im-bibtex` and `im-identifiers` are maintained externally and may evolve differently from our `impress-bibtex` and `impress-identifiers`. Mitigation: treat them as independent projects; do not attempt to merge. If we publish our versions, rename them clearly.
- **impel-core proprietary status.** Keeping the agent orchestration layer proprietary while open-sourcing the item graph may frustrate researchers who want to build their own intelligent agents on top of the same data. Mitigation: the MCP surface of `impress-core` provides a sufficient interface for external agent access without exposing persona runtime internals.

---

## Open Questions

1. **Publication order.** Which crate publishes first — `impress-domain` (the prerequisite of everything) or `impress-core` (the highest-value standalone piece)? Publishing `impress-domain` first forces us to stabilize the Publication, Author, Annotation types before publishing `impress-core`. Deferring `impress-domain` means `impress-core` can only be published as a workspace member, which is awkward. Tentative answer: publish `impress-domain` first as a very thin crate, then `impress-core`.

2. **Rename strategy at publication time.** When `impress-bibtex` is published, should it become `im-bibtex` (matching the existing collaborator crate on crates.io, risking confusion) or remain `impress-bibtex` (clear provenance, longer name)? The answer depends on whether we intend to converge with or stay separate from the collaborator crates. This decision must be made per-crate at publication time.

3. **MCP aggregation.** When multiple `impress-*` crates each run their own MCP server via `serve`, should there be a single aggregating server (e.g., `impress serve --all`) that registers all tools in one process? Or does each run independently and AI agents discover them from separate configuration entries? The `scix-client` pattern (one server per crate) is simpler but may result in many MCP server entries in Claude Desktop's config. Tentative answer: start with one-per-crate; aggregate later if user feedback indicates friction.

4. **`impel-core` publication boundary.** The event sourcing and thread management in `impel-core` are architecturally independent from the persona runtime and could in principle be extracted into a separate MIT crate. Is there a future phase where `impel-events` (event sourcing, thread state machine) is open-source while `impel-persona` (persona runtime, trust model) remains proprietary? This would give the community a reusable agent-event-sourcing library. Deferred to Phase 3.

5. **`impress-collab` and `impress-helix` long-term status.** Both are currently proprietary by default (internal-only), but neither contains inherently proprietary logic — they are utility libraries that happen not to be ready for publication. Should they be reclassified as MIT when they stabilize? Tentative answer: yes. No architectural reason to keep them proprietary; they should be promoted to the MIT column when their APIs are stable.

---

*This ADR supersedes ADS0003. The key changes from ADS0003: (1) deferred `im-*` rename to Phase 3 publication (D34); (2) licensing boundary stated against real, current crates rather than hypothetical future ones (D35, D36); (3) library-first packaging model documented as D37 and tied to the actual crate inventory; (4) Python binding strategy scoped to crates where notebook integration has real value; (5) MCP exposure described concretely against the actual crate names.*

*Developed collaboratively by Tom and Claude, building on the open-source strategy work in ADS0003 and grounded in the actual state of the `crates/` directory as of 2026-03-02.*
