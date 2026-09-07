# ADR-0029: Rust-Owned AI Provider Registry and Device-Local Preferences

**Status:** Proposed — R0/R1 (types, catalogue, clients) implemented 2026-09-03; later
phases promote this line as they land
**Date:** 2026-09-03
**Depends on:** ADR-0008 (FFI bridge; its note on async UniFFI is answered here), ADR-0024
(MCP surface projection), ADR-0026 (provenance-first AI infrastructure)
**Supersedes:** ADR-0026 D1's "the existing `impress-llm` crate remains temporarily" clause

## Context

Local inference on this laptop runs through oMLX (`127.0.0.1:8000`, launched by oMLX.app).
Before this ADR the suite talked to it twice: `crates/impress-ai::OmlxClient` (used by
`impel-taskd`, `impress-ai-server` and the generated `impress-ai-service` verbs) and a
Swift `OpenAICompatibleProvider` in `packages/ImpressAI` (used by every app's Settings ›
AI pane and every inline AI feature). The two drifted — the Swift picker listed bare ids
and let oMLX's `MarkItDown` helper pseudo-model be selected as the chat model, which is
the stored selection this work found on the development Mac. Cloud providers were
duplicated the same way (Swift HTTP clients for Anthropic/OpenAI/Google/OpenRouter/Ollama
next to a half-featured `impress-llm` crate), and the "which provider" question had four
unreconciled answers: Swift `SharedDefaults`, `IMPRESS_OMLX_*` environment variables in
the daemons, `IMPEL_LLM_*` variables in the enrichment/memory/throughline executors, and
impel's `counselModel` default.

The suite's rule (CLAUDE.md, "Rust-first logic") is that capability lives in Rust and
Swift is the GUI. The user restated it for this work: *all functionality in Rust; Swift
is only the GUI layer.*

## Decision

### D1. One device-local preferences file, owned by `impress-ai`

`<workspace>/ai/preferences.json` (beside the worker heartbeat in `workspace/runtime`)
records the selected provider and model, per-provider non-secret endpoint overrides,
whether oMLX may be started on demand, and the per-task-category model assignments.
`impress_ai::preferences::PreferencesStore` is its only writer: temp file + `fsync` +
rename, a `flock` around read-modify-write, and a fingerprint-guarded reader. The file is
versioned; a newer or corrupt file is an error, never a silent reset.

It is deliberately *not* a store record and never syncs: which laptop runs oMLX is a fact
about the device, not the researcher, and a phone must be able to point at a laptop over
Tailscale without inheriting the laptop's choice. `schema-refs.json` is unchanged.

Precedence for daemons: `IMPRESS_AI_PROVIDER`/`IMPRESS_AI_MODEL` beat the file's
selection; `IMPRESS_<PROVIDER>_URL` beats the file's endpoints. With no file present every
consumer behaves exactly as before (the file-absence gate), so the Rust phases can land
ahead of any Swift change.

### D2. A static catalogue, one port, one client per wire protocol

`impress_ai::catalogue::CATALOGUE` declares the eight providers once — id, category
(local/cloud/aggregator/native), execution host (Rust or *foreign*), transport, secret
credential *fields* (never values), default endpoint, capabilities, static model table
and discovery mode — in the order used for fallback resolution: `omlx`, `ollama`,
`openai-compatible`, `apple-on-device`, `anthropic`, `openai`, `google`, `openrouter`.

Every Rust-executed provider implements the existing `InferenceProvider` port, widened
with `descriptor()`, `health()` and a default `complete()` folded from `stream()`. Two
clients cover every wire format: `OpenAiCompatibleClient` with a `Dialect` (oMLX, generic,
OpenAI, OpenRouter, Google's OpenAI-compatible endpoint, Ollama's `/v1` surface) and
`AnthropicClient` for the Messages API. The dialect decides paths, headers, which sampling
parameters a model accepts (newer Claude generations and OpenAI reasoning models reject
`temperature`), the thinking spelling, and how discovery is shaped (oMLX merges
`/v1/models`, `/v1/models/status` and `/health`; helpers stay listed but flagged).
`OmlxClient` remains as a thin compatibility wrapper.

### D3. One resolution rule

`AiRegistry::resolve` is synchronous and network-free:

```
provider = explicit ?? category primary ?? selected (even if unreachable) ??
           first Ready in CATALOGUE order ?? NotConfigured
model    = explicit ?? selected.model ?? category model ?? catalogue default ??
           discovered default (oMLX /health.default_model, else first loaded) ?? Invalid
```

A selected provider is never silently replaced when it is down: the call surfaces the
error so auto-start or "Test Connection" can act. Helper pseudo-models are rejected at
selection time. Conversations resolve once at creation and store the provider; ad-hoc
completions resolve per call. The origin (`explicit|category|selected|first_ready`) is
returned and recorded.

### D4. Secrets stay in the platform keychain; Rust holds them in memory only

`CredentialSource` is layered: the environment, then values the GUI pushed from its
keychain into `InMemoryCredentials` over the FFI (apps), or the same keychain items read
through `/usr/bin/security` by account (daemons). `Secret` redacts itself in `Debug`; a
credential's fingerprint keys the client cache so a rotated key yields a fresh client
without the value being stored anywhere. Nothing secret enters the preferences file, the
store, run provenance or logs.

### D5. Swift is a projection; Apple on-device is the one foreign executor

`packages/ImpressAI` keeps its public `AIProvider`/request/response types so callers do
not change, but every provider becomes a thin adapter over the UniFFI registry
(`SharedAiRegistry`, with an async pull-based `AiChatStream` for tokens). The single
exception is `apple-on-device`: FoundationModels is a platform framework, so Rust lists
and selects it (host `foreign`) and Swift executes it, reporting availability back.

### D6. The generated surface grows with the registry

`ImpressAiService` gains `list_providers`, `ai_preferences`, `select_model`,
`set_provider_endpoint`, `provider_health`, and `list_models` takes an optional
provider — the same verbs reach MCP, the `impress` CLI and impel's tool inventory from
one definition, per the agent-drivable rule. `impress-llm` is retired once the impel
executors read their tier from the `agent.*` task categories.

## Consequences

- Six apps and two daemons agree on one selection and one endpoint table; changing the
  model in any Settings › AI pane changes it for all of them.
- Model pickers can show what oMLX reports (loaded, context, vision, server default) and
  can no longer offer a helper pseudo-model.
- Background executors keep their deterministic fallbacks and never inherit the
  interactive selection: a cloud model picked for chat cannot silently create daemon spend.
- Landing order: types + catalogue + clients → preferences + registry → verbs + daemons →
  UniFFI surface → Swift bridge → Swift cut-over → settings UI → per-app panes →
  retirements. Each step is inert without the next and revertible on its own.

## Implementation notes (Swift side, 2026-09-03)

- `packages/ImpressAI` reaches the registry through one file,
  `Bridge/RustAIBridge.swift`, compiled behind the `IMPRESS_RUST_AI` define that
  `Package.swift` sets once `ImpressRustCore` is a *declared* dependency. It is a
  define rather than `canImport`: inside an app build every sibling package links the
  framework, so `canImport(ImpressRustCore)` is true even when the bindings predate the
  registry, and the bridge would then fail to compile. Without the define the class is an
  "unavailable" stub and the manager registers on-device models only.
- `AIProviderManager` is the projection: `registerBuiltInProviders()` turns the catalogue
  into one `RustBridgedAIProvider` per Rust-hosted entry plus the Apple executor, reads
  the preferences, runs the one-time SharedDefaults import, and pushes keychain secrets into
  Rust memory. A registry that *refuses* a selection (helper model, unknown provider) is
  distinguished from one that is *unavailable*: refusals are logged and dropped, never kept
  as an in-memory fallback.
- Cross-app change propagation is the file itself: every pane re-reads the preferences
  (`preferencesChangedSince` is a stat) when it opens or the app activates, and the manager
  posts an in-process `impressAIPreferencesDidChange`. No Darwin notification was added —
  the suite has no "current app" identity helper to post from, and the pane-open re-read is
  what the acceptance criteria require.
- The old Swift HTTP providers stay in the tree, unregistered, until the retire step;
  `AITextCompletionService` and imprint's three-case `AIProvider` enum (which mapped every
  other selection to "Apple") are gone; impel's hidden `counselModel` default is removed by
  the migration and the orchestrator follows the suite selection.
- Every app declares `.ai` for macOS only in this change; iOS keeps its previous surface
  until the keychain-group fallback is verified on a simulator.

## Acceptance criteria

1. `cargo test -p impress-ai -- --ignored live_omlx` lists the running oMLX's models with
   kinds, context windows and the helper flag, from the Rust client alone.
2. Selecting a model through the MCP/CLI verbs is visible in every app's pane and in both
   daemons after a restart, with the three-point trace (mutation/save/display) in the
   Console.
3. `MarkItDown` cannot be selected through any surface.
4. Agent-run provenance names the resolved provider, endpoint identity and origin.
5. `schema-refs.json` is unchanged; `./scripts/check-schema-refs.sh` still reports 70
   canonical refs.
