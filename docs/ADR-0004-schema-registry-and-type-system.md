# ADR-0004: Schema Registry and Type System

**Status:** Proposed
**Date:** 2026-03-02
**Authors:** Tom (with architectural exploration via Claude)
**Supersedes:** ADR-0001 §"Schema System" (the informal schema stub in the Unified Item Architecture decision)
**Scope:** `impress-core` Rust crate, all apps that register or validate items

---

## Context

ADR-0001 introduced the concept of a schema registry in a single paragraph. It named `Schema`, `SchemaRef`, and `payload_fields` but left every consequential question open: what is a `SchemaRef` syntactically, how are schemas registered, who enforces them, how does the type system handle schema evolution, and what role do schemas play in FTS indexing and cross-tool interoperability?

Those questions must be answered before Phase 1 ships. The imbib migration is the first workload that writes real items to the store, and every item written carries a `schema` field. If schema semantics are vague at write time, we will face a schema migration on top of a data migration — a compounding risk that ADR-0001's guardrails section explicitly warned against.

This ADR also formalizes a distinction that emerged from implementation: there are **built-in schemas** (the ten types listed below, defined in `impress-core` and registered by the core library itself) and **domain-specific schemas** (registered by apps at startup for artifact subtypes and extensions). The boundary matters for versioning, validation, and future "schemas as items" capability.

### What Was Already Decided (Not Reopened Here)

- The `Schema` struct and `SchemaRegistry` are implemented in `crates/impress-core/src/schema.rs` and `crates/impress-core/src/registry.rs`. The implementation is the ground truth.
- Item envelopes are immutable after creation (ADR-0002, D1). Schema is an envelope field; it cannot change after item creation.
- Operation items (ADR-0002) carry their own schema reference (`operation@1.0.0`); this ADR documents that schema among the ten built-in types.

### Forces

1. **Validation must be cheap.** The item store receives high-frequency writes from agent runs. Schema validation runs on every `append()`. It must be an in-process hash lookup plus field iteration, not a database query.

2. **FTS must know which fields to index.** SQLite FTS5 content is built at write time. The schema is the only place that captures which fields contribute searchable text.

3. **Evolution is inevitable.** Schemas will add fields. Items written under older schema versions must remain readable. The compatibility contract must be stated and enforced.

4. **Inheritance enables specialization without duplication.** `email-message` shares most fields with `chat-message`. Duplicating field lists across schema definitions invites drift. Single-inheritance resolves this.

5. **"Schemas as items" is attractive but premature.** Storing schema definitions as items in the graph would allow schema history, provenance, and agent-readable introspection. It is also a bootstrapping problem: to write a schema item you need a schema for schema items. Defer to Phase 4.

---

## Decision

### D16. Schemas Are Rust Code, Not Database Records

Each schema is a `Schema` struct constructed in Rust and registered via `SchemaRegistry::register()` at app startup. There is no schema definition file format (no TOML, no JSON schema files on disk). The authoritative representation is the Rust source in `crates/impress-core/src/schema.rs` and `crates/impress-core/src/schemas/`.

**Why.** Rust code has type safety, compile-time guarantees, and test coverage. A file-based registry introduces a parse step and a missing-file failure mode. Given that all schemas currently ship with the application binary, the added flexibility of file-based schemas is not yet needed. This decision is revisited if third-party schema authorship becomes a requirement.

**What this means in practice:**

- Each built-in schema is a `fn *_schema() -> Schema` function in `impress-core`.
- `register_all_schemas(registry: &mut SchemaRegistry)` is called once at process start.
- Domain-specific schemas (artifact subtypes, app extensions) are registered by the app's startup sequence, after the core schemas.
- `SchemaRegistry` enforces uniqueness: `register()` returns `RegistryError::AlreadyRegistered` if the ID is already present.

### D17. The `SchemaRef` Format Is `name@semver`

A `SchemaRef` is a `String` with the format `name@major.minor.patch`. Examples:

```
bibliography-entry@1.0.0
chat-message@1.0.0
email-message@1.0.0
operation@1.0.0
```

The `name` component uses kebab-case. The `version` component is a full semver triple. The `@` separator is mandatory.

**Stored in item envelopes.** The `schema` field on every `Item` holds the full `SchemaRef` including version, for example `"bibliography-entry@1.0.0"`. This means the exact schema version that was current when the item was written is durable in the item record. Future readers can detect version mismatches.

**Current implementation note.** The `SchemaRegistry` keys items by `schema.id` (the name without version) and the `Item.schema` field currently stores the name without the `@version` suffix in the running code. The `@semver` suffix convention is the target format for items persisted to SQLite. Apps writing items must always append the current schema version. The registry lookup on read strips the version suffix to locate the schema definition.

### D18. Schema Evolution Is Additive-Only

The compatibility rules for schema changes between versions:

| Change | Allowed? | Notes |
|---|---|---|
| Add optional field | Yes | New readers populate; old readers ignore |
| Add required field with default | Yes | Old items that lack the field use the schema default |
| Remove field | No | Old items still carry the field; code must continue to handle it gracefully |
| Change field type | No | Breaking change; requires a new schema name |
| Rename field | No | Equivalent to remove + add; treat as breaking |
| Change `required: true` to `required: false` | Yes | Looser constraint; backward compatible |
| Change `required: false` to `required: true` | No | Old items may not have the field; breaking |

**Forward compatibility.** Old readers encountering an item written under a newer schema version must tolerate unknown fields silently. Unknown fields are preserved in the payload and round-trip through the store without modification.

**Backward compatibility.** New schema versions must validate items written under prior versions. Since evolution is additive-only, older items simply lack new optional fields — which is valid by definition.

**Version bump policy.** Any additive change bumps the minor version (`1.0.0` → `1.1.0`). The major version is reserved for schema renames or forks (which produce a new schema ID, not a new version of the old one).

### D19. "Schemas as Items" Is Deferred to Phase 4

It is architecturally desirable for schema definitions to themselves be items in the graph — this would give them provenance, allow agents to introspect the type system, and enable schema history. This is explicitly deferred.

**Why deferred.** The bootstrapping problem is real: the item type that represents a schema definition must itself have a schema. In Phase 4, when the graph is mature, this can be implemented as a fixed-point (`schema-definition@1.0.0` is an item whose schema is `schema-definition@1.0.0`). Before Phase 4, this adds complexity without enabling any concrete feature that Phase 0–2 requires.

**What "deferred" means concretely.** The `SchemaRegistry` is not persisted to the database. The registry is rebuilt from Rust code on every app launch. Items carry their `schema_ref` string, but there is no item in the store with the schema's own `id`.

### Raw Payload Access is an Anti-Pattern

Accessing `payload["title"]` directly outside the adapter layer is brittle against schema evolution and obscures intent. If a field name changes or gains validation constraints, every raw access site must be found and updated — an error-prone process that the type system cannot help with.

**The correct pattern** is schema-specific typed accessors. On the Rust side, each schema module exposes functions that take `&Item` and return typed values (e.g., `bibliography::title(&item) -> Option<&str>`). On the Swift side, each app defines typed wrapper structs over `Item` with computed properties. Raw `payload[...]` access is permitted only inside these typed accessor boundaries.

This rule applies equally to Rust code in `impress-core` and to Swift code in the app layer. The accessor is the schema contract; bypassing it creates implicit coupling to the payload key names that the registry cannot track or validate.

---

## The Schema Taxonomy

Schemas are divided into two categories:

**Built-in schemas** are defined in `impress-core`, registered by the core library, and stable across all impress apps. They represent the universal item types that the unified architecture is built on.

**Domain-specific schemas** (such as the artifact subtypes in `crates/impress-core/src/schemas/artifact.rs`) are defined in `impress-core` but represent app-specific extensions. They use namespaced IDs (e.g., `impress/artifact/presentation`) to avoid collision with built-in names.

---

## The 10 Built-In Schemas

These ten schemas are the foundational types of the impress item graph. All apps understand them. All are registered at startup before any domain-specific schemas.

---

### `bibliography-entry@1.0.0`

The primary item type for imbib. Represents any entry in a reference database: article, book, preprint, thesis, conference paper, etc.

```
Required: cite_key (String), entry_type (String), title (String)
Optional: authors ([String]), year (Int), journal (String),
          doi (String), arxiv_id (String), bibcode (String),
          abstract (String), keywords ([String]),
          linked_files ([{hash, filename, url}])
FTS: title + authors + abstract + keywords
Typical edges: Cites (other bibliography entries), Attaches (PDF items)
```

`entry_type` follows BibTeX vocabulary: `article`, `book`, `inproceedings`, `phdthesis`, `misc`, etc. `linked_files` is an array of objects, each describing one attached file (PDF, supplemental, etc.) by content hash, display filename, and optional retrieval URL. `bibcode` is the NASA ADS identifier, used for SciX sync.

---

### `annotation@1.0.0`

A highlighted or anchored annotation on a readable item. Created by imbib's PDF reader and imprint's manuscript editor.

```
Required: text (String), selection_start (Int), selection_end (Int)
Optional: page (Int), quote (String), color (String)
FTS: text + quote
Typical edges: Annotates (bibliography-entry or manuscript-section)
```

`selection_start` and `selection_end` are character offsets within the item's rendered text (for manuscript sections) or within the PDF's extracted text layer (for bibliography entries). `quote` is the verbatim selected text; `text` is the user's annotation comment. The `Annotates` edge connects the annotation to its target; the annotation does not embed the target's ID in its payload.

---

### `chat-message@1.0.0`

A single message in a real-time or asynchronous conversation channel. The base type for human-to-human and human-to-agent short-form communication in impart and impel.

```
Required: body (String)
Optional: subject (String), format (String — "markdown" | "plain")
FTS: body + subject
Typical edges: InResponseTo (other chat-message), Attaches (any)
```

`format` defaults to `"plain"` if absent. Agents writing progress messages use this schema. The `InResponseTo` edge builds conversation threads without requiring a dedicated `thread_id` envelope field.

---

### `email-message@1.0.0`

An email message, either received from an external MTA or composed within impart. Inherits the conversational threading model of `chat-message` and extends it with email-specific envelope fields.

```
Required: subject (String), body (String), from (String)
Optional: to ([String]), cc ([String]), message_id (String)
FTS: subject + body + from
Typical edges: InResponseTo (other email-message), Attaches (any)
```

This schema **inherits from `chat-message@1.0.0`**. The registry's `collect_fields()` traversal merges parent fields into the child, so validation of an `email-message` item checks all fields from both schemas. `message_id` is the RFC 5322 `Message-ID` header, preserved for deduplication and threading when importing from mbox.

The `from` field holds a display-friendly string (e.g., `"Ada Lovelace <ada@example.com>"`). Structured parsing of the address is the responsibility of the application layer.

---

### `task@1.0.0`

A unit of work — either human-assigned or agent-generated. Used by impel's `TaskOrchestrator` to track the lifecycle of all delegated work.

```
Required: title (String), state (String — "pending" | "running" | "done" | "failed" | "cancelled")
Optional: description (String), assigned_to (String), due_at (Int),
          output_schema (String), error (String)
FTS: title + description
Typical edges: DependsOn (other task), ProducedBy (agent-run), OperatesOn (any)
```

`state` is a closed enum expressed as a string for forward compatibility. `assigned_to` is an actor ID (human or agent). `due_at` is a Unix timestamp in seconds. `output_schema` is a `SchemaRef` string indicating the expected schema of items produced by this task — agents use this to validate their own output before submission. `error` is populated when `state` is `"failed"`.

---

### `agent-run@1.0.0`

A record of a single execution of an AI agent: its inputs, identity, model used, and outcome summary. Created by impel when an agent completes a run.

```
Required: agent_id (String), model (String), prompt_hash (String)
Optional: result_summary (String), token_count (Int), duration_ms (Int)
FTS: result_summary
Typical edges: ProducedBy (task), DerivedFrom (any — inputs to the run)
```

`prompt_hash` is a SHA-256 hex digest of the full prompt sent to the model, enabling exact deduplication and reproducibility audits. `model` holds the fully-qualified model ID (e.g., `claude-opus-4-6`). `DerivedFrom` edges connect the run to every item that was passed as context, forming a complete provenance graph for the agent's output.

---

### `manuscript-section@1.0.0`

A section of a manuscript being authored in imprint. May represent anything from a paragraph to a top-level chapter depending on the document structure.

```
Required: title (String), body (String), section_type (String — "introduction" | "methods" | etc.)
Optional: word_count (Int), version (String)
FTS: title + body
Typical edges: Contains (annotation), Cites (bibliography-entry), Visualizes (figure)
```

`body` stores Typst source text. `section_type` uses academic paper conventions (`abstract`, `introduction`, `methods`, `results`, `discussion`, `conclusion`, `appendix`) but is not an enforced enum — imprint may add domain-specific types (e.g., `"background"`, `"theory"`). `word_count` is maintained by imprint as a denormalized cache; it is not normative. `version` tracks the Typst document version string from which this section was extracted.

---

### `figure@1.0.0`

A visualization or image produced by implore or referenced in a manuscript. Stores metadata about the figure's content and derivation, not the pixel data.

```
Required: title (String), format (String — "svg" | "png" | "pdf")
Optional: caption (String), data_hash (String), script_hash (String)
FTS: title + caption
Typical edges: Visualizes (bibliography-entry or dataset), DerivedFrom (dataset)
```

`data_hash` is a SHA-256 digest of the rendered figure file, enabling cache invalidation and change detection. `script_hash` is a digest of the plotting script or implore configuration that produced the figure — this enables exact reproducibility: the same script + same data = the same figure. Both hashes are optional because figures may be imported rather than generated.

---

### `dataset@1.0.0`

Metadata for a tabular or structured dataset used in analysis. The payload describes the dataset's structure; the actual data is referenced via `Attaches` edges to file items.

```
Required: name (String), format (String)
Optional: row_count (Int), column_count (Int), schema_json (String)
FTS: name
Typical edges: Attaches (content file)
```

`format` is a MIME type or common format name: `text/csv`, `application/parquet`, `application/json`, `application/hdf5`, etc. `schema_json` is a serialized column schema (column names, types, nullable flags) as a JSON string — the application layer owns the schema format (e.g., Apache Arrow schema, Frictionless Data). Keeping it as an opaque string here avoids coupling `impress-core` to any particular schema format.

---

### `operation@1.0.0`

An internal schema used exclusively by the operation item layer defined in ADR-0002. Operation items are not FTS indexed and are not shown in user-facing views. They form the provenance and audit trail over the item graph.

```
Required: op_type (String), target_id (String)
Optional: patch (String — JSON Patch RFC 6902), snapshot (String — JSON),
          intent (String — "routine" | "hypothesis" | "anomaly" | "editorial" | "correction" | "escalation"),
          undo_info (String — JSON)
FTS: (none — operation items not FTS indexed)
Typical edges: OperatesOn (any — the target item)
```

`op_type` is a closed vocabulary maintained in `crates/impress-core/src/operation.rs`: `SetTag`, `RemoveTag`, `SetFlag`, `ClearFlag`, `SetPriority`, `SetVisibility`, `SetRead`, `SetStarred`. The `patch` field carries a JSON Patch (RFC 6902) document when the operation makes a content change. `snapshot` is an optional pre-operation state capture for undo. `intent` characterizes the semantic nature of the change for attention routing (see ADR-0001 §Attention Routing).

---

## Schema Inheritance

The `Schema` struct has an `inherits: Option<SchemaRef>` field. When set, the `SchemaRegistry` traverses the parent chain via `collect_fields()` to build the complete field set for validation. Child fields with the same name as parent fields override the parent's definition.

The current implementation supports single inheritance only (one parent). Multiple inheritance is not needed for the ten built-in schemas and is explicitly not supported.

**Current inheritance relationship:**

```
chat-message@1.0.0
    └── email-message@1.0.0  (adds subject, from, to, cc, message_id)
```

No other built-in schemas inherit from each other. The `bibliography-entry`, `annotation`, `task`, `agent-run`, `manuscript-section`, `figure`, `dataset`, and `operation` schemas are all root schemas.

**How inheritance is used in practice.** If imprint adds a `preprint` schema that specializes `bibliography-entry` with an `arxiv_id` required field, it registers `preprint@1.0.0` with `inherits: Some("bibliography-entry".into())`. The registry validates preprint items against the merged field set. No change to the core library is needed.

---

## Registration at App Startup

The startup sequence for any impress app is:

1. `SchemaRegistry::new()` — creates an empty registry.
2. `register_core_schemas(&mut registry)` — registers the ten built-in schemas. This function is provided by `impress-core` and called first, always.
3. `register_artifact_schemas(&mut registry)` — registers domain-specific artifact schemas (defined in `crates/impress-core/src/schemas/artifact.rs`).
4. App-specific registrations — any additional schemas the individual app needs.
5. The registry is passed to the `ItemStore` implementation and held for the lifetime of the process.

`SchemaRegistry::register()` panics with `expect()` on duplicate registration during startup. This is intentional: a duplicate schema ID at startup indicates a programming error (two Rust modules registering the same ID), not a runtime condition to recover from.

The registry is immutable after startup. There is no runtime schema deregistration or hot-reload path.

---

## Consequences

### Positive

- **Zero-cost validation.** Schema lookup is a `HashMap` get by ID; field traversal is a small Vec iteration. No I/O, no SQL, no allocation beyond the error Vec on failure.
- **FTS accuracy.** Because the schema explicitly lists FTS-contributing fields, the search index is precise. Adding a field to a schema automatically extends full-text search without changes to the indexer.
- **Inheritance reduces drift.** `email-message` inherits `chat-message` fields in code. If `chat-message` adds a field in a future version, the inherited field appears in `email-message` automatically after both schema versions are updated together.
- **Evolution is safe by construction.** Additive-only rules mean that existing items never become invalid as schemas evolve. Old items simply have fewer optional fields populated.
- **Startup is deterministic.** Schemas are compiled into the binary. There is no parse step, no missing-file edge case, and no schema-not-found failure at runtime (only at registration, which panics early).

### Negative

- **No runtime extensibility.** Third parties cannot ship schema definitions without modifying `impress-core` or depending on it as a library. This is acceptable for Phase 0–2 but limits Phase 4 ambitions.
- **Schema changes require a rebuild.** A field addition requires a code change, a rebuild, and a release. There is no live schema editing. Acceptable for a researcher-focused desktop app; would not be acceptable for a hosted multi-tenant service.
- **Major version breaks require migration tooling.** The additive-only rule prevents breaking changes within a major version but does not eliminate the need for migration tooling if a breaking change is truly required. That tooling does not yet exist.
- **Inheritance is shallow.** Single-level inheritance is enough for the current schemas, but deep hierarchies would require careful design of `collect_fields()` traversal and field override semantics. The current implementation is not designed for deep chains.

---

## Open Questions

1. **Where does `register_core_schemas` live?** The ten built-in schemas are documented here but their Rust `fn *_schema() -> Schema` constructors are not yet all present in `impress-core`. The `bibliography-entry` schema exists as a test fixture in `registry.rs`. The remaining nine need to be moved into a canonical `schemas/core.rs` module alongside the existing `schemas/artifact.rs`.

2. **How does the registry handle the `@version` suffix in `item.schema`?** The current `SchemaRegistry` keys on the full ID string without a version suffix. Items should store `bibliography-entry@1.0.0` in their `schema` field; the registry lookup should strip the version and key on the name alone. The stripping logic and mismatch handling (item on v1.1.0, registry only knows v1.0.0, or vice versa) need to be implemented.

3. **What happens when an item's schema version is ahead of the registry?** A reader running an older binary may encounter items written under a schema version it does not know. The current `validate()` implementation returns `RegistryError::NotFound`. The correct behavior is to tolerate unknown versions of known schemas (by stripping the version and using the registered definition) and to surface unknown schema *names* as a recoverable warning, not a hard error.

4. **FTS field extraction is not yet wired.** The schema records which fields contribute to FTS, but there is no `SchemaAccessor` trait or method that the SQLite store calls to extract the text. This extraction logic needs to be implemented before FTS on the unified store is functional.

5. **Artifact schemas use a namespaced ID format (`impress/artifact/presentation`).** The built-in schemas use flat IDs (`bibliography-entry`). Should built-in schemas also be namespaced (e.g., `impress/bibliography-entry`)? Namespacing prevents collision with third-party schemas but changes the wire format and all existing test fixtures. Decide before Phase 1 writes to SQLite.

6. **`email-message` inheritance wiring.** The `email-message` schema's `inherits` field must point to `chat-message` (without a version suffix under the current registry keying scheme). This linkage is documented here but not yet present in a canonical schema constructor for `email-message`. It needs to exist before impart writes items.

---

## References

- `crates/impress-core/src/schema.rs` — `Schema`, `FieldDef`, `FieldType`, `SchemaRef` definitions
- `crates/impress-core/src/registry.rs` — `SchemaRegistry`, `validate()`, `collect_fields()`, `ValidationError`
- `crates/impress-core/src/schemas/artifact.rs` — domain-specific artifact schema registrations (8 types)
- `crates/impress-core/src/item.rs` — `Item`, `Value` — the envelope that carries `schema: SchemaRef`
- ADR-0001 §"Schema System" — the stub this ADR supersedes
- ADR-0002 §"Every Modification Is an Item" — context for `operation@1.0.0`
- RFC 6902 — JSON Patch specification (referenced by `operation.patch` field)
