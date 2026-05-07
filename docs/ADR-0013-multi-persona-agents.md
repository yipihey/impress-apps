# ADR-0013: Multi-Persona Agents

**Status:** Proposed
**Date:** 2026-05-05
**Authors:** Tom (with architectural exploration via Claude)
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0003 (Operations and Provenance), ADR-0005 (Task Infrastructure and Agent Integration), ADR-0008 (FFI Bridge and Swift Integration), impel ADR-001 (Stigmergic Coordination)
**Scope:** `apps/impel/Packages/ImpelCore/Sources/ImpelCore/Persona.swift`, `apps/impel/Packages/CounselEngine/`; downstream consumers (the journal pipeline of ADR-0011, future enrichment pipelines)

---

## Context

ADR-0005 specified that impel is the execution engine for tasks defined in `impress-core` and recorded the `agent-run@1.0.0` schema for reproducibility. It did not specify *which agent* runs a given task. At the time, impel had a single agent archetype model: an `Agent` struct with an `AgentType` enum (`research`, `code`, `verification`, `adversarial`, `review`, `librarian`) and an `AgentStatus`. That model conflated capability ("what kind of agent is this?") with execution policy ("what model? what tools? what risk tolerance?").

In the months between ADR-0005 and this one, `apps/impel/Packages/ImpelCore/Sources/ImpelCore/Persona.swift` was added to the codebase. It introduced a richer abstraction — the **Persona** — that layers behavioral traits, model bindings, tool access policies, and domain expertise on top of the underlying `AgentType`. Four built-in personas exist in code: **Scout** (rapid research), **Archivist** (citation-heavy librarian), **Steward** (project coordinator), and **Counsel** (email-gateway research assistant). They are returned by a `mockPersonas()` static factory; there is no persistent registry, no persona-loading-from-disk, and no documented contract for adding new personas.

The journal pipeline (ADR-0011) depends on personas for nearly every stage of its workflow: Scout receives manuscript submissions, Archivist snapshots compiled PDFs, Counsel reviews drafts, **Artificer** drafts revisions (a persona that does not yet exist in code), and Steward enforces policy. Without an ADR codifying the persona model, ADR-0011 would be load-bearing on undocumented architecture: any change to `Persona.swift` could silently change the journal's contract.

This ADR codifies what is already in code and adds the missing Artificer persona. It defers persistence of personas as items in the graph (per ADR-0001 D1's "every entity is an item" principle) to a future ADR; for now, personas are Swift code, registered at app startup, in the same spirit as ADR-0004 D16 ("Schemas Are Rust Code, Not Database Records").

### Forces

1. **Capability vs. policy separation.** A "research" archetype can be embodied by Scout (rapid, broad, low-citation) or Counsel (balanced, methodical, email-formatted). The archetype is a capability tag; the persona is a behavior + model + tools binding.
2. **Pipeline composability.** A workflow like the journal's needs to bind specific personas to specific stages. Without persona identity stable across releases, pipelines break on every refactor.
3. **Reproducibility.** ADR-0005's `agent-run@1.0.0` records `agent_id` and `model`. If `agent_id` is a persona ID, an audit can trace exactly which behavior produced a result. If it is an opaque process identifier, reproducibility is lost.
4. **Autonomy gating.** The autonomy questions ADR-0011 raises ("which stages can run unattended? which require human confirmation?") need a per-persona policy surface, not a per-task one — confirmation ergonomics that vary by persona are easier to learn than policies that vary by task type.

---

## Decision

### D29. Persona Is the Agent Identity

The unit of agent identity in the impress suite is the **Persona**, not the underlying `AgentType` archetype. `AgentType` remains a capability tag (an answer to "what kind of work does this agent know how to do?"); `Persona` is the full identity (an answer to "which configured agent are we invoking right now?"). The `agent-run@1.0.0` schema's `agent_id` field stores a persona ID, not an `AgentType` raw value.

Concretely, the `Persona` struct in `apps/impel/Packages/ImpelCore/Sources/ImpelCore/Persona.swift` (lines 253–351) is the canonical type. Its fields:

- `id: String` — stable identifier (`"scout"`, `"archivist"`, `"counsel"`, `"steward"`, `"artificer"` for the five built-in personas). Persistent across releases.
- `name: String` — display name.
- `archetype: AgentType` — the underlying capability category from `ImpelCore.swift` (lines 104–133): `research`, `code`, `verification`, `adversarial`, `review`, `librarian`.
- `roleDescription: String` — one-line summary, shown in pickers.
- `systemPrompt: String` — the prompt prefix the agent is invoked with.
- `behavior: PersonaBehavior` — five-axis behavioral configuration (D30).
- `domain: PersonaDomain` — primary domains, methodologies, data sources.
- `model: PersonaModelConfig` — provider, model ID, temperature, max tokens, top-p (D31).
- `tools: ToolPolicySet` — per-tool access policies plus a default access level (D32).
- `builtin: Bool` — true for personas shipped with the suite; false for user-created personas.
- `sourcePath: String?` — file path if loaded from a personas directory; null for built-in.

`Persona` is `Codable` and `Sendable`. JSON serialization uses snake_case field names (e.g., `role_description`, `system_prompt`) per the existing `CodingKeys` declarations.

### D30. Behavioral Axes Are Five Continuous Variables Plus a Working Style

`PersonaBehavior` (lines 133–176) has five axes. Each is normative: pipelines and routing layers may read these to make decisions.

| Axis | Range | Meaning | Effect on routing |
|---|---|---|---|
| `verbosity` | 0.0–1.0 | Response length preference (terse → comprehensive) | Influences max-tokens default and prompt formatting |
| `riskTolerance` | 0.0–1.0 | Willingness to try novel approaches (conservative → experimental) | Used by autonomy-gate code in ADR-0011 D7 to decide whether the persona may auto-confirm or must propose-only |
| `citationDensity` | 0.0–1.0 | How heavily to cite sources (minimal → every claim) | Pipelines that produce reviews use this to score output completeness |
| `escalationTendency` | 0.0–1.0 | How readily to seek human input (autonomous → frequent escalation) | Drives the rate at which `OperationIntent::Escalation` operations are emitted |
| `workingStyle` | enum: `rapid`, `balanced`, `methodical`, `analytical` | Coarse posture | Pipelines pick personas by working style for time-sensitive vs. thorough-needed tasks |

**Why continuous variables, not categories.** The axes are read by code that adapts behavior in fine increments — for example, the autonomy-gate evaluator may auto-confirm if `riskTolerance < 0.3`, propose-only otherwise. A discrete `low/medium/high` would force evaluators to pick arbitrary thresholds at the call site rather than at the persona definition.

### D31. Model Bindings Are Per-Persona With Per-Task Overrides

`PersonaModelConfig` (lines 211–248) declares a persona's default model: provider (`"anthropic"`, `"openai"`, `"ollama"`, `"claude-cli"` per the existing usage), model ID, temperature, max tokens, top-p. The TaskOrchestrator in `apps/impel/Packages/CounselEngine/Sources/CounselEngine/TaskOrchestrator.swift` reads this when invoking the agent loop.

**Pipelines may override the model on a per-task basis.** A journal-pipeline review task that requires a different model can override Counsel's default `"claude-opus-4-7"` for one invocation. The override goes into the `TaskRequest` payload (a new `model_override: PersonaModelConfig?` field that the orchestrator merges over the persona default before invoking). The persona's stored config is unchanged; only the agent-run record reflects the override.

**Rationale for per-task override.** Personas are stable identities; model choices are not. As newer Claude models ship every six months, every persona's `model` field would otherwise need updating in lockstep. Per-task override lets pipelines opt into specific models without touching persona definitions, and lets routine tasks continue to use the persona default without explicit configuration.

### D32. Tool Access Policies Are Per-Persona, Per-Tool, With a Default Floor

`ToolPolicySet` (lines 97–128) is a list of `ToolPolicy(tool: String, access: ToolAccess, scope: [String], notes: String?)` plus a `defaultAccess: ToolAccess`. `ToolAccess` is `none | read | readWrite | full`.

**The contract:**

- `policies.first(where: { $0.tool == tool })` is the per-tool policy.
- If no per-tool policy exists, `defaultAccess` applies.
- `canAccess(tool)` returns true if the resolved access is `read` or higher.
- `canWrite(tool)` returns true if the resolved access is `readWrite` or `full`.
- `full` includes execute permissions; `readWrite` does not.

**The journal pipeline's tool needs:**

| Persona | Required tools | Required access |
|---|---|---|
| Scout | `imbib`, MCP submission tool | `imbib: readWrite`, submission tool: `full` |
| Archivist | `imbib`, `imprint` (compile only) | `imbib: full`, `imprint: read` |
| Counsel | `imbib`, `WebSearch`, `WebFetch` | `imbib: read`, web: `full` |
| Artificer | `imprint` (write source), `imbib` (read citations) | `imprint: full`, `imbib: read` |
| Steward | `imbib`, `imprint`, `impel` | `imbib: full`, `imprint: read`, `impel: full` |

These policies are the defaults. They may be tightened (never broadened) by user configuration in a future settings UI.

**`scope: [String]`.** The optional `scope` field on `ToolPolicy` constrains which resources within a tool the persona may touch — for example, `["library:Journal"]` restricts an `imbib` policy to the Journal library only. Scope strings are tool-specific and interpreted by the tool's bridge layer (e.g., the imbib bridge in CounselToolRegistry filters operations by library when scope is provided).

### D33. The Five Built-In Personas

The suite ships five built-in personas. Each is defined in code and returned by `Persona.mockPersonas()` (lines 388–514, with Artificer to be added per D34). The IDs are stable across releases: pipelines may bind to them by string ID without fear of breakage.

| ID | Archetype | Default model | Working style | Risk | Escalation | Primary use |
|---|---|---|---|---|---|---|
| `scout` | `research` | claude-sonnet, t=0.7 | rapid | 0.8 | 0.6 | Discovery, ingestion, exploratory work |
| `archivist` | `librarian` | claude-sonnet, t=0.3 | methodical | 0.1 | 0.3 | Organization, snapshotting, deduplication |
| `counsel` | `research` | claude-opus-4-7, t=0.5 | balanced | 0.3 | 0.4 | Review, summarization, email-gateway research |
| `steward` | `review` | claude-sonnet, t=0.4 | balanced | 0.2 | 0.7 | Process coordination, escalation routing |
| `artificer` | `code` (proposed) | claude-sonnet, t=0.5 | analytical | 0.2 | 0.5 | Manuscript revision drafting, response-to-reviewer composition |

**Stability guarantee.** Adding a sixth built-in persona is permitted at any time without an ADR. Removing or renaming a built-in persona requires a superseding ADR and a deprecation period of at least two minor releases, during which the old ID continues to resolve via an alias table.

### D34. Adding the Artificer Persona

The Artificer persona is required by ADR-0011 (the journal pipeline) and does not yet exist in code. This ADR specifies its definition; the implementation is mechanical (add to `mockPersonas()` and any bootstrapping registry).

```swift
Persona(
    id: "artificer",
    name: "Artificer",
    archetype: .code,
    roleDescription: "Manuscript revision and response-to-reviewer drafter",
    systemPrompt: """
        You are Artificer, the impress suite's manuscript revision drafter. \
        Given a manuscript revision and a structured review, you propose precise \
        unified-diff revisions to the source and a response-to-reviewer letter. \
        You never apply diffs autonomously. You always propose; the human or Steward confirms.
        """,
    behavior: PersonaBehavior(
        verbosity: 0.7,
        riskTolerance: 0.2,
        citationDensity: 0.7,
        escalationTendency: 0.5,
        workingStyle: .analytical,
        notes: [
            "Proposes diffs against current manuscript source; never auto-applies",
            "Composes response letters that address each reviewer comment by reference",
            "Defers to human judgment on substantive scientific changes"
        ]
    ),
    domain: PersonaDomain(
        primaryDomains: ["academic writing", "scientific argumentation"],
        methodologies: ["unified diff", "response-to-reviewer composition"],
        dataSources: []
    ),
    model: PersonaModelConfig(temperature: 0.5),
    tools: ToolPolicySet(
        policies: [
            ToolPolicy(tool: "imprint", access: .readWrite),
            ToolPolicy(tool: "imbib", access: .read)
        ],
        defaultAccess: .none
    ),
    builtin: true
)
```

**Archetype choice.** Artificer's work is text-revision craft, not novel research. The `.code` archetype fits because Artificer produces structured edits (unified diffs) more than free-form prose. A future ADR may introduce an `.editorial` archetype if multiple personas need it; for now, `.code` is the closest match and avoids inventing a new archetype for a single persona.

**Why `defaultAccess: .none` rather than `.read`.** Other personas default to `.read` to be permissive about discovering related data. Artificer's work is narrowly scoped to a specific manuscript revision; broadening tool access by default is failure-mode-prone (Artificer reading random other manuscripts and conflating their content into a revision). The explicit policy list is the entire access surface.

### D35. Persona Registration and Resolution

For Phase 0 (this ADR's scope), personas are returned by a static factory (`Persona.mockPersonas()`) and held in memory by whatever subsystem needs them. There is no persistence and no user-defined personas. The contract for callers:

- `Persona.builtIn(id: String) -> Persona?` — returns the persona for a stable ID, or nil. Callers must handle nil (an unknown ID is a programming error or a downgrade across a renamed persona).
- `Persona.allBuiltIn() -> [Persona]` — returns all five built-in personas in stable order (scout, archivist, counsel, steward, artificer).
- The `mockPersonas()` name is misleading once Artificer ships; it should be renamed to `builtInPersonas()` in the implementation. The rename is in scope for the implementation that lands ADR-0011.

For future phases (deferred to a follow-up ADR when needed):

- Personas as items in the graph (`persona@1.0.0` schema), per ADR-0001 D1.
- User-defined personas loaded from `~/Library/Application Support/com.impress.impel/personas/*.json` via `sourcePath`.
- Persona inheritance (a user-defined persona that overrides the system prompt of a built-in one).

### D36. Autonomy Gating Reads from Persona Behavior

Pipelines that need to decide "may this persona auto-act, or must it propose for human confirmation?" read `behavior.riskTolerance` and `behavior.escalationTendency`. The default rule, applied uniformly across pipelines unless overridden:

- `riskTolerance < 0.3` AND `escalationTendency >= 0.5` → propose-only mode (the persona's actions are written as proposed-change items requiring confirmation).
- Otherwise → auto-act mode (the persona's actions are applied directly, with `OperationIntent::Routine`).

The journal pipeline (ADR-0011 D7) specifies per-stage overrides on top of this default. For example, Archivist (`riskTolerance: 0.1`) would default to propose-only by this rule, but the snapshot stage explicitly sets it to auto-act when `compile-clean AND tests-pass` because the operation is mechanical and idempotent.

This is the contract between the persona model and the autonomy-policy concept ADR-0005 left implicit: the persona owns the *baseline* policy, the pipeline owns the *exception* policy.

### D37. agent-run Provenance Records Persona Identity

The `agent-run@1.0.0` schema (ADR-0005 D5) records `agent_id`. Per this ADR, `agent_id` is the persona's stable ID — `"scout"`, `"archivist"`, etc. — not an opaque process or invocation identifier.

When per-task model overrides apply (D31), the agent-run also records the overriding model in its `model` field. This means:

- `agent_id` = "counsel" tells the auditor *which persona* produced the output.
- `model` = "claude-opus-4-5" tells the auditor *which model* was actually invoked, even if Counsel's default was something else.

The combination of `agent_id` and `model` is the reproducibility key. The `prompt_hash` field continues to be the input contract; together, the three fields define what an agent-run actually was.

---

## Consequences

### Positive

- The journal pipeline (ADR-0011) and any future pipeline can bind to stable persona IDs without coupling to internal model choices, prompt wording, or tool policies.
- `agent-run@1.0.0` provenance records become semantically meaningful: an auditor can ask "which persona produced this?" and get a useful answer rather than a process ID.
- Per-task model overrides decouple persona stability from model evolution — model upgrades do not require ADR amendments.
- Tool policies are the single surface for permission management. Adding a new tool (e.g., a journal submission tool) extends every persona's policy table; no per-feature permission code is needed.
- Autonomy gating gets a uniform default rule (D36) that pipelines may override locally, eliminating the need for each pipeline to invent its own auto-vs-propose policy.

### Negative

- Five built-in personas is an architectural commitment. Adding a sixth is cheap; reorganizing into a different taxonomy later is expensive (every pipeline binding must migrate).
- Persona behavior axes are read by routing code in ways that are not type-checked. A pipeline that reads `behavior.riskTolerance` without bounds-checking will misbehave if a future persona has a value outside [0.0, 1.0]. Callers must validate at the boundary.
- The decision to defer persona persistence (D35) means user-customizable personas are out of scope for Phase 0. Researchers who want a custom persona must wait for the follow-up ADR or fork the codebase.
- Artificer adds capability the codebase has not exercised before (proposed-diff workflow). The interaction between Artificer's output and imprint's CRDT layer is unspecified and will require its own design pass during ADR-0011 implementation.

### Mitigations

- The deprecation policy in D33 (alias table for two minor releases) covers persona renaming if the taxonomy proves wrong.
- The five built-in personas all use existing `AgentType` archetypes (no new archetypes added). If a sixth persona needs `.editorial` or `.advocate`, the ADR amendment is local — the persona model itself does not change.
- Persona persistence as items can be retrofit later without disturbing the in-code defaults: the `sourcePath` field already supports it.

---

## Open Questions

1. **Where does `mockPersonas()` get called from at app startup?** The current code returns built-ins on demand; there is no central registry. The implementation that lands ADR-0011 must decide where the registry lives (`PersonaRegistry` actor in CounselEngine? a static cache?) and how callers resolve personas by ID.

2. **Per-task model overrides are not yet wired.** `TaskRequest` (in `TaskOrchestrator.swift`) does not have a `modelOverride` field. Adding it is a small change but touches the GRDB schema for `CounselTask` (the persisted form). The migration is in scope for ADR-0011 implementation.

3. **Should `Artificer` use an existing archetype or motivate `.editorial`?** This ADR uses `.code` for Artificer as the closest match. If a second editorial-craft persona appears (e.g., a "Translator" persona for cross-language manuscripts), `.editorial` becomes worth introducing. Defer until forced.

4. **Tool policy enforcement layer.** `Persona.canUse(tool:)` returns a Bool but does not enforce — callers may ignore it. A future change should make CounselToolRegistry check persona policy before exposing a tool to the agent loop. This is a small refactor that should land with ADR-0011.

5. **Personas as items in the graph.** Deferred per D35. The case for it strengthens when (a) users start defining custom personas, (b) personas need provenance/version history, or (c) cross-device persona sync becomes valuable. None apply yet.

6. **Persona behavioral axes calibration.** The numeric values for the five built-in personas (D33) are not empirically calibrated. They were chosen by inspection of the existing `mockPersonas()` definitions plus reasonable defaults for Artificer. A future ADR may adjust them based on observed pipeline behavior.

---

## References

- `apps/impel/Packages/ImpelCore/Sources/ImpelCore/Persona.swift` — `Persona`, `PersonaBehavior`, `PersonaDomain`, `PersonaModelConfig`, `ToolPolicy`, `ToolPolicySet`, `WorkingStyle`, `ToolAccess`, `mockPersonas()`
- `apps/impel/Packages/ImpelCore/Sources/ImpelCore/ImpelCore.swift` — `AgentType`, `AgentStatus`, `Agent`
- `apps/impel/Packages/CounselEngine/Sources/CounselEngine/TaskOrchestrator.swift` — `TaskRequest`, `TaskResult`, agent invocation entry points
- ADR-0001: Unified Item Architecture
- ADR-0003: Operations and Provenance — `OperationIntent::Escalation`, `OperationIntent::Routine`
- ADR-0005: Task Infrastructure — `agent-run@1.0.0`, `task@1.0.0`, the `TaskExecutor` trait
- ADR-0011: The impress Journal — primary consumer of this ADR; defines stage-by-stage persona bindings
- impel ADR-001: Stigmergic Coordination — context for why personas are pull-based, not assigned
