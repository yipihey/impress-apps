# Cognitive Architecture for Research Software

**Working draft — toward a position paper**  
**Date:** 2026-02-08  
**Authors:** Tom Abel (with architectural exploration via Claude)

---

## Abstract

Research software is organized around application functions — bibliography management, manuscript writing, data visualization, communication — forcing researchers to switch between tools that do not share data or context. This paper describes an alternative: organize research software around a shared graph of typed research artifacts, where applications are just views. The key observation is that this does not require learning a new mental model. A bibliography entry already has the structure of an email — authors (To), title (Subject), abstract (Body), and attachments (.pdf, .bib). An agent anomaly report has the same structure. So does a manuscript review. If you want to treat the whole system as an email client, you can. If you prefer a chat interface, or a custom dashboard, those are views over the same data.

We draw on a lineage of software architecture patterns (MVC, event sourcing, CRDTs, entity-component-system, Zettelkasten) and on recent cognitive science findings about how differently people actually think. We discuss what happens when hundreds of AI agents join the research effort: the right response is not to publish more but to build an internal scholarly culture — local journals, substantial reviews, living state-of-the-question documents — that compresses agent output into understanding while keeping the full record for reproducibility. Because every research product in the system is typed, attributed, and provenanced, the same platform that supports research also enables principled experiments on the efficacy of human-AI collaboration — turning anecdotes about agent usefulness into structured, reproducible evidence. We ground this in the experience of building the impress research suite, and we take seriously the projects that tried similar things and failed.

**Scope.** This is a position paper, not a systems paper. We report on an architecture under active development (the impress suite), of which one application (imbib, a bibliography manager) is implemented and in daily use. The unified item architecture, agent-scale compression workflow, and measurement framework are at varying stages: some are prototyped, others are design-stage. We aim to present the motivating ideas and architectural decisions clearly enough to evaluate, while being explicit about what is built, what is hypothesized, and what is open.

---

## 1. The Problem: Application-Centric Research Software

A researcher reads a paper, notices something relevant to a manuscript, checks a plot, reviews agent logs, tweaks code, and kicks off a new simulation — all pursuing a single line of thought. Every application switch interrupts that thought. The cost of task-switching is well documented (Mark, Gonzalez & Harris, 2005; Altmann & Trafton, 2002), but the deeper problem is structural: the applications impose a taxonomy of research activity — reading, writing, analyzing, communicating — that does not match how the researcher actually thinks.

This gets worse with AI agents. A weekend parameter sweep can produce thousands of items. The researcher needs summaries, not raw output; anomalies, not progress logs; decision points, not routine confirmations. Current communication tools treat all messages as equal. Current research tools have no concept of agent output at all.

The separation of concerns in research software should not follow application function but cognitive function: what do I know, what needs my attention, how does this connect, and how does this particular mind process it best.

---

## 2. Familiar Mental Models, Not New Ones

A common worry about unified architectures is that they replace several simple things with one complicated thing. The opposite should be the goal: reduce the number of mental models a user needs, not increase them.

The observation that makes this work: research artifacts already share a common structure. Consider email. An email has a sender, recipients, a subject line, a body, and attachments. Now consider:

- **A published paper.** Authors (From/To), title (Subject), abstract (Body), attachments: the .pdf and .bib file. The journal is the mailing list.
- **An agent anomaly report.** The agent (From), the project team (To), "L2 norm divergence at level 8" (Subject), the analysis (Body), convergence plots attached.
- **A manuscript review.** Reviewer (From), authors (To), "Review of Abel et al." (Subject), the review text (Body), annotated PDF attached.
- **A bibliography entry.** The original authors (From), yourself (To — you chose to track it), the paper title (Subject), your reading notes (Body), the PDF attached.
- **An internal methods note.** Author (From), the research group (To), the technique name (Subject), the write-up (Body), code and test results attached.

The structure is always: who made it, who should see it, what is it about, what does it say, and what is attached. That is an email. It is also a chat message with metadata. It is also a card in a dashboard. These are views, not different kinds of data.

A researcher who is comfortable with email already has the right mental model. They can interact with the system through something that looks like a mail client — threaded conversations, folders (tag hierarchies), filters (attention rules), attachments (referenced items). The system does not ask them to learn "items" and "typed references." It asks them to use email. The architecture supports richer interactions for those who want them, but does not require them.

### 2.1 Where the Analogy Breaks

The email metaphor is a default onboarding view, not the core model. It is important to separate three layers:

**Artifact metadata** — who authored it, when, what type, what schema version, what tags. This is intrinsic to the item.

**Notification/attention metadata** — who should see it, how urgently, in what view. This is a function of subscriptions, routing rules, and user configuration — not a property of the item itself. When we say a bibliography entry has "To = yourself," that is a rendering convenience in the email view, not an attribute stored on the item. The item's `visibility` and `tags` determine who *can* see it; the attention router determines who *does* see it and when.

**UI metaphor** — email, chat, dashboard, manuscript editor. These are view configurations that select, group, sort, and render items differently. The same item appears in all applicable views.

Some item types do not fit naturally into the email frame. A simulation parameter sweep is a directed acyclic graph of runs, not a message. A dataset is a large binary with structured metadata, not a body with attachments. A code commit has diffs, not prose. These items still participate in the shared item graph — they have typed references (`ProducedBy`, `DerivedFrom`, `Visualizes`), they appear in search, and they carry provenance. But they need specialized renderers: a workflow DAG view, a data browser, a diff viewer. The email view shows them as stubs with metadata ("Parameter sweep completed — 847 runs, 3 anomalies — click to open in workflow view"), which is often sufficient for awareness. The specialized view is there when you need detail.

The discipline is: every item must be *representable* in the email view (it has an author, a title/subject, a summary, and references to related items), but it need not be *fully renderable* there. The email view is the universal minimum, not the universal maximum.

### 2.2 The Minimal Core

The architecture rests on a small set of concrete structures. We specify these here so the proposal can be evaluated against specific design choices rather than a vague notion of "typed items."

**Item envelope.** Every item in the graph has:

```
Item {
    id:             UUID            // stable across sync
    schema:         SchemaRef       // e.g., "bibliography-entry/v2", "agent-anomaly-report/v1"
    schema_version: SemVer
    author:         ActorId         // human or agent identifier
    author_kind:    Human | Agent | System
    created_at:     Timestamp
    modified_at:    Timestamp
    payload:        typed content   // schema-specific fields (see examples below)
    refs:           TypedRef[]      // edges to other items
    tags:           TagPath[]       // initial classification (subsequent changes via overlay items)
    visibility:     Private | Shared(ProjectId) | Public  // initial (changes via overlay items)
    origin:         InstanceId      // which installation created this item
    attestation:    Option<Signature>  // cryptographic attestation of authorship
}
```

**Typed edges.** A minimal set of edge types, each with defined semantics:

| Edge Type | Meaning | Example |
|---|---|---|
| `Cites` | Intellectual dependency | Review cites a paper |
| `Discusses` | Commentary relationship | Chat message discusses a figure |
| `DerivedFrom` | Computational lineage | Figure derived from simulation run |
| `ProducedBy` | Agent/process attribution | Anomaly report produced by sweep agent |
| `Supersedes` | Correction/replacement | Revised review supersedes earlier draft |
| `Annotates` | Overlay commentary | Personal note annotates a shared paper |
| `InResponseTo` | Conversational threading | Reply in response to a question |
| `Attaches` | Binary association | PDF attached to bibliography entry |
| `DependsOn` | Prospective workflow constraint | Convergence analysis depends on parameter sweep completing |

Additional domain-specific edge types can be registered, but these nine cover the core use cases. Every edge can carry optional metadata (e.g., page number for a citation, confidence score for an agent-generated link). Note that `DependsOn` is the only prospective edge — it expresses a workflow constraint rather than a retrospective relationship. After execution, a `DerivedFrom` edge is typically added alongside it to record what actually happened.

**Schema examples.** Three concrete schemas illustrate the range:

*raw-agent-log (v1):* `{ run_id, agent_config_ref, step_number, log_level, message, metrics: Map<String, f64>, wall_time_ms }`. Expected edges: `ProducedBy → agent-run-item`. Default renderer: DigestRenderer (collapsible log stream).

*internal-review (v1):* `{ title, body_markdown, scope_tag, status: Draft|InReview|Accepted, reviewer_notes }`. Expected edges: `Cites → [reviewed items]`, `Discusses → [project items]`. Default renderer: RichTextRenderer.

*external-publication (v1):* `{ title, authors[], abstract, doi, venue, submitted_date, status }`. Expected edges: `Cites → [bibliography entries]`, `DerivedFrom → [state-of-the-question]`, `Attaches → [pdf, supplementary]`. Default renderer: TreeBrowserRenderer (bibliography view) or RichTextRenderer (reading view).

**Schema evolution.** Schemas are versioned with semver. Rules: (i) adding optional fields is a minor version bump and always backward-compatible, (ii) removing or renaming required fields is a major bump and requires a migration function registered with the schema, (iii) items store their schema version and are deserialized through version-aware readers that upcast old items lazily on read. This follows established event-sourcing practice (Young, 2010).

**Large binaries.** Datasets, simulation outputs, and PDFs are not stored inline in item payloads. They are content-addressed blobs in a separate store, referenced via `Attaches` edges whose metadata includes content hash (SHA-256), byte size, and MIME type. Integrity is verified on retrieval. The item graph stores metadata and references; the blob store handles bytes. This separation keeps the item graph fast to query and replicate while allowing large files to sync lazily.

**Operations as overlay items (full provenance for sub-item changes).** The item envelope above records who created an item and when. But research involves many finer-grained operations: adding a tag, toggling a flag, editing a manuscript paragraph, changing an item's visibility, writing the prompt that launched an agent. These must also be attributable and dateable.

The principle: *every modification is itself an item*. Rather than mutating fields on existing items (which would lose the who/when/why of the change), modifications are recorded as lightweight overlay items that reference their target:

```
OperationItem {
    id:          UUID
    schema:      "tag-assignment/v1"    // or flag-toggle/v1, visibility-change/v1, etc.
    author:      ActorId
    author_kind: Human | Agent | System
    created_at:  Timestamp
    priority:    Priority               // how important is this operation
    payload: {
        action: Add | Remove,
        tag: "project-aurora/to-review",
        intent: Hypothesis,             // structured: why this was done
        reason: "may explain level-8 anomaly"  // free-text elaboration
    }
    refs:        [{ type: Annotates, target: <target_item_id> }]
}
```

Every operation carries both a structured `intent` (one of: Routine, Hypothesis, Anomaly, Editorial, Correction, Escalation) and the envelope's `priority` field. These compose: an Anomaly + Urgent flag toggle means "critical finding, needs attention now"; a Routine + Background tag cleanup means "housekeeping, don't interrupt." The attention router filters on both dimensions (see ADR-0002 for the full routing matrix).

This pattern applies consistently:

| Operation | Schema | Payload | Provenance captured |
|---|---|---|---|
| Add/remove tag | `tag-operation` | action, tag, intent | Who, when, which tag, and *why* |
| Toggle flag | `flag-operation` | flag, state, intent | Who flagged it, when, why |
| Edit manuscript | `patch` | content diff, intent | Who edited, what changed, when, why |
| Significant revision | new item + `Supersedes` | full new content | Complete version history |
| Change visibility | `visibility-change` | old → new, authority, intent | Who promoted/restricted, when, under what authority |
| Agent prompt | `agent-prompt` | prompt text, config, intent | Who wrote it, what it instructed, when |
| Status transition | `status-transition` | old → new status, intent | Editorial workflow step, by whom |

An item's *current state* — its effective tags, flags, visibility — is a computed projection: replay all operation items targeting it. This is standard event sourcing applied consistently to all modifications. The Salsa incremental computation framework (Sec 3.6) maintains materialized indices so that queries like "all items tagged X" remain fast despite being computed from operation streams.

The cost is more items in the graph. The benefit is complete provenance: "who added this tag, and when?" is always answerable. So is "show me the state of this item's tags as of last Tuesday," "which agent set this flag and with what intent," and "who changed the visibility of this item from Private to Shared." For reproducibility and audit, this is essential. For attention routing, it means every operation is simultaneously a provenance record and a signal that the router can act on.

Note that the `tags` and `visibility` fields in the item envelope above represent the *initial* state at creation time. All subsequent modifications are overlays. This keeps the envelope immutable while allowing the effective state to evolve.

**Mapping to PROV-O and RO-Crate.** The item graph maps onto W3C PROV-O as follows: items with `author_kind = Human` are `prov:Agent`s; items with `author_kind = Agent` are also `prov:Agent`s (software agents); items representing research products are `prov:Entity`; agent runs, editorial workflows, and operation items (tag assignments, edits, visibility changes) are `prov:Activity`. The `ProducedBy` edge maps to `prov:wasGeneratedBy`; `DerivedFrom` maps to `prov:wasDerivedFrom`; `author` maps to `prov:wasAttributedTo`; operation items map to `prov:wasInfluencedBy` on their target. A project bundle (the portable export format) can be emitted as an RO-Crate: the manifest maps to `ro-crate-metadata.json`, items map to data entities with PROV-O annotations, and the tag hierarchy maps to contextual entities. This is a one-way export — the item graph is richer than what RO-Crate captures — but it ensures interoperability with the broader research packaging ecosystem.

---

## 3. Architectural Lineage

The architecture draws on several well-established patterns. This section documents debts and records what each community learned the hard way.

### 3.1 MVC and DCI

Reenskaug's original MVC (1979) was about bridging the gap between the user's mental model and the computer's representation — not about web application layers, which is the diluted version that came later. The Model was supposed to capture how the user thinks about their information. Views make it visible. Controllers translate intent into operations.

For research software, the model should capture research activity — papers, data, code, discussions, agent reasoning, and the connections between them. Not the database schema of any particular application. Reenskaug's later DCI work adds: the same data plays different roles in different contexts. A bibliography entry is a citation source when you are writing, a discovery lead when you are exploring, and validation evidence when you are reviewing agent output.

**What went wrong in practice:** The model usually degenerates into a thin database wrapper. To be useful here, it must represent research activity, not data storage.

### 3.2 Event Sourcing and CQRS

If items are stored as immutable facts ("this message was sent," "this figure was produced"), the system is event-sourced. Different views over the same data — a chat view and an email view over the same messages — are textbook CQRS.

Event sourcing gives time-travel: "show me the state of this project six months ago" is just "replay items up to that timestamp." For reproducibility, this is very useful.

**What went wrong in practice:** Schema evolution — addressed in Sec 2.2 above. Retroactive corrections need compensating events (a `Supersedes` edge), not mutations.

### 3.3 Immutable Databases and Datalog

Datomic's idea — a database as an accumulation of immutable facts with queries against consistent snapshots — fits a typed item graph well. Items accumulate, annotations are overlays, nothing is overwritten.

**What went wrong in practice:** Excision (removing data for legal or privacy reasons) is a real need that pure immutability does not handle — see Sec 6. Datalog is worth evaluating for the query language; it handles graph traversal and temporal queries more naturally than SQL.

### 3.4 CRDTs and Local-First Software

The Ink & Switch "Local-First Software" manifesto (2019) maps well onto research software: work on your device, sync across devices, network optional, data sovereignty, archival in open formats. The key lesson: the unit of collaboration should be the data structure, not the application. Items sync, not apps.

**What went wrong in practice:** Merge semantics must be chosen per data type. Garbage collection of CRDT tombstones is unsolved at scale. Trust and access control in peer-to-peer systems remain immature.

**Our deployment model (near-term).** We do not assume pure peer-to-peer replication. The near-term architecture is local-first clients with a coordinating sync server per research group or institution. Each client holds a full replica of the item graph for projects it participates in; the server handles sync, backup, and cross-client consistency. This is similar to how Git works: local-first with a shared remote.

CRDTs are used for specific item types where concurrent editing is expected: collaborative text fields (sequence CRDTs), tag sets (add-wins set CRDTs), and reference edges (add-only sets with compensating `Supersedes` events for retractions). For item creation and metadata, last-writer-wins with vector clocks is sufficient — research items are mostly append-only and rarely edited concurrently.

Provenance integrity is maintained by optional cryptographic attestation: each item can carry an author signature over its content hash, verified during sync. This does not prevent a malicious client from forging items (that requires trust in the client software), but it detects tampering during transit and provides non-repudiation for audit.

Cross-institution collaboration uses project bundles (Sec 5) for initial exchange and shared project spaces with sync mediated by an agreed-upon server. True peer-to-peer federation (e.g., via Matrix) is a longer-term goal, not a near-term requirement.

### 3.5 Entity-Component-System

ECS from game engines is the most structurally precise analog: entities are IDs, components are typed data bags, systems operate on entities with specific component patterns. In our terms: items are entities, payloads are components, views are systems. This architecture scales to millions of entities.

**What went wrong in practice:** Not much — ECS is well proven. The relevant lesson is positive: adding a new component type does not require modifying existing entities or systems. That is the basis for extensibility.

### 3.6 Incremental Computation (Salsa)

Views must stay current as the item graph changes at high throughput. The Salsa framework (used in rust-analyzer) caches computation results and incrementally updates only what is affected by new inputs. Written in Rust, designed for this problem, battle-tested.

**What went wrong in practice:** Dependency tracking must be automatic. Manual declarations will be wrong.

**Scale targets.** The system should handle O(10⁶) items per project with view updates in <100ms after a new item arrives. Salsa's incremental recomputation is centralized per client (each client maintains its own materialized views). The sync server does not render views.

### 3.7 Zettelkasten

Luhmann's card index — atomic notes with explicit links, emergent structure from the link graph — maps onto a typed item graph with references. Luhmann described his system as a "communication partner" that surprised him by surfacing connections he had not seen. That is the aspiration for a graph coherence service.

**What went wrong in practice:** Graph visualization does not scale. Connections should be surfaced as a prioritized list with explanations, not as a visual graph that becomes unreadable above a few hundred nodes.

### 3.8 Actor Model

Agents that fire-and-forget messages, suspend on human-in-the-loop decisions, and inherit project context — this is structurally an actor system. The Erlang/OTP lesson applies: "let it crash." Agents can fail without corrupting shared state because output is append-only. Backpressure matters when agents produce faster than the system can index and render.

---

## 4. How People Actually Think

Recent cognitive science has found that the variation in human inner experience is much wider than most people assume — and hidden, because each person tends to believe everyone else thinks the way they do.

### 4.1 The Dimensions

Lupyan et al. (2023) document hidden variation along multiple dimensions.

**Visual imagery** ranges from hyperphantasia (vivid mental images) to aphantasia (no voluntary imagery at all), affecting roughly 1–4% of the population with a broad spectrum in between (Zeman et al., 2015; Zeman, 2025). Within aphantasia itself, Delem et al. (2025) found distinct spatial and verbal subtypes.

**Inner speech** ranges from near-constant to absent. Nedergaard & Lupyan (2024) coined "anendophasia" for the absence of inner speech and showed measurable consequences: reduced verbal working memory, difficulty with phonological tasks. People with anendophasia compensate with alternative strategies that often mask these differences in daily life.

**Cognitive style** is at least three-dimensional: object imagery (vivid pictures), spatial imagery (schematic layouts and relations), and verbal processing. Kozhevnikov et al. (2005) showed that object visualizers tend to process images holistically while spatial visualizers tend to process part-by-part — with consequences for how they read plots and diagrams. Höffler et al. (2017) confirmed this with eye tracking, showing measurably different gaze behaviors.

Hurlburt's Descriptive Experience Sampling work found five frequent phenomena of inner experience — inner speech, inner seeing, unsymbolized thinking, feelings, sensory awareness — each in roughly 25% of sampled moments, but with large individual variation (Heavey & Hurlburt, 2008).

### 4.2 Consequences for Software Design

This goes beyond classical accessibility (screen readers, captioning, motor accommodation), which addresses well-understood categories. The phenomenal diversity research points at a broader design space.

A researcher with aphantasia and strong verbal processing is likely to get more from a text summary of agent results than from a thumbnail dashboard. A spatial thinker may prefer the graph neighborhood view. A researcher with strong inner speech may find an audio digest of overnight activity useful; one with anendophasia may not. What counts as a "clear" presentation varies — it depends on how the person's mind works.

We call this observation *cognitive pluralism* as a design principle: rather than building one interface that works adequately for everyone (the universal design aspiration, which has limits), support multiple presentations of the same data, each suited to a different cognitive style.

**Concrete UI implications.** The view framework addresses this through:

- **Default renderers per schema, overridable per user.** A bibliography entry defaults to TreeBrowserRenderer but can be switched to a card grid (object-visual), a text list (verbal), or a timeline (spatial). The override is a user-level setting, not a per-session choice.
- **Progressive disclosure.** The email view is the simplest entry point. Users who want richer interaction discover specialized views through contextual links ("open in workflow view," "show graph neighborhood"). Complexity is available but not imposed.
- **Configurable summary modalities.** Digests can be rendered as text, structured tables, or audio narration. The choice is stored in user preferences.
- **Layout vs. linear.** Dashboard (spatial arrangement of panels) vs. timeline (chronological stream) vs. threaded list (conversational). These correspond roughly to spatial, temporal, and verbal processing preferences.

**How preferences are captured.** Initially, explicit settings: the user chooses a default view style and summary format during onboarding. Over time, interaction signals (which views are used most, whether digests are expanded or skipped, how long items are viewed) could inform adaptive defaults, but this is speculative and not in scope for the initial implementation.

---

## 5. Collaboration as Context Sharing

Research collaboration at its best means sharing not just results but context — the papers read, the approaches tried, the agent reasoning chains, the evolving understanding.

### 5.1 Onboarding

A PI brings a new postdoc up to speed. The PI tags relevant items into a project, creates a reading-order guide and a state-of-play summary, and exports a **project bundle** — a portable snapshot with the full reference graph intact. Figures link to the code that produced them. The draft cites the papers. Agent threads show complete reasoning chains, including dead ends.

The postdoc does not receive a folder of files. She receives a structure of understanding. She can read why an agent's approach was abandoned without a meeting.

### 5.2 Merging Independent Work

Two researchers with their own investigation histories realize their work connects. Each exports a project manifest — a metadata skeleton with item types, tag structures, and external identifiers (DOIs, bibcodes), but no private content. Graph overlap analysis identifies shared foundations, complementary areas, and convergent explorations (same question, different paths).

After selective contribution and reconciliation, the merged graph has three layers: each researcher's history and the shared growth space. The reconciliation log — matching decisions, conceptual links — is itself part of the scholarly record.

This scenario applies equally to a single researcher's own work over time: parallel explorations years apart, agent runs that unknowingly retrace earlier approaches, forgotten dead ends that turn out to be relevant.

### 5.3 Unrecognized Convergence

The useful framing is not deduplication but *unrecognized convergence*. Do not delete a 2019 exploration because a 2022 exploration covers similar ground. Link them, so that a 2026 revisit sees the full connected history.

**Graph coherence service.** A background process maintains an index of structural signatures over the item graph: reference neighborhoods (which items cite/discuss overlapping sets), tag path patterns, external identifier overlaps, and optionally embedding-based similarity of item payloads.

When a trigger occurs — a new item arrives, a collaboration begins, the user explicitly requests it — the service checks for items that are structurally related but not yet explicitly connected. Output: a `coherence-suggestion` item with references to the two candidate items and a transparency payload explaining why they may be related (e.g., "these two agent runs cite 4 common papers and explore adjacent parameter ranges but have no direct link"). The user confirms (creating a typed edge), dismisses (suppressing future suggestions for this pair), or defers.

**Scale strategy.** Structural signatures are maintained incrementally (updated when items are added, not recomputed from scratch). For a graph of O(10⁶) items, the index occupies O(100 MB) in memory. Suggestion generation is triggered asynchronously and does not block UI interaction.

For a researcher with years of accumulated work, the coherence service may surface the most useful connections in the system.

---

## 6. Security, Privacy, and Governance

The emphasis on immutable, append-only records and rich provenance creates real tension with security and privacy requirements. This section states the threat model and intended mechanisms.

### 6.1 Threat Model

The primary threats in a research setting are:

- **Accidental exposure** of embargoed results, student evaluations, reviewer identities, or credentials captured in agent logs.
- **Legal/institutional requirements** for deletion (GDPR right to erasure, IRB data retention limits, export control).
- **Unauthorized access** to items across project/visibility boundaries during sync or collaboration.
- **Tampering** with provenance records (e.g., altering authorship or timestamps).

The system does *not* attempt to defend against a compromised local client (if your machine is owned, your data is compromised regardless). It defends against accidental leakage, unauthorized sync, and transit-level tampering.

### 6.2 Access Control

Access is governed at two levels:

**Visibility (item-level).** Every item has a visibility field: `Private` (this instance only), `Shared(ProjectId)` (syncs with project participants), or `Public` (exportable in bundles, publishable). Visibility can be upgraded (contribute a private item to a shared project) but downgrade requires a new `Supersedes` item that replaces the shared version with a tombstone, preserving the audit trail.

**Project-level ACLs.** Each shared project has a participant list with roles (Owner, Editor, Viewer). The sync server enforces these during replication: an Editor can push new items; a Viewer can only pull. Role changes are themselves items in the graph, providing an audit trail.

**Encryption.** Item payloads in shared projects are encrypted at rest on the sync server with per-project keys. Key distribution uses a straightforward approach: project owners distribute keys to participants via a key-agreement protocol during project invitation. This is not novel cryptography — it is standard practice applied to the item store.

### 6.3 Excision

Immutability is the default but not absolute. When legal or institutional requirements demand deletion:

1. A `RedactionEvent` item is created, referencing the target item, the reason, and the authority.
2. The target item's payload is cryptographically erased (overwritten with random bytes). The item envelope (id, schema, timestamps, author, visibility) is preserved as a tombstone.
3. Edges referencing the redacted item remain, pointing to the tombstone. Provenance chains are broken at that point — downstream items show "derived from [redacted item]" rather than losing the reference entirely.
4. The redaction event itself is part of the audit trail: who ordered the deletion, when, under what authority.

This trades completeness of the provenance record for legal compliance, which is the right trade-off. The system makes the break visible rather than pretending the item never existed. What is clearly an open problem: how redaction interacts with replicas that have already synced the item. The current approach is that the redaction event propagates via sync, and clients are expected to honor it. A malicious client could retain the data. This is a known limitation shared by essentially all distributed systems.

### 6.4 Agent-Specific Concerns

Agent logs can inadvertently capture sensitive data: API keys, file paths, credentials, copyrighted text from web scraping. The architecture mitigates this with:

- **Schema-level sanitization rules.** Agent log schemas can declare fields that are scrubbed before storage (e.g., environment variables, authorization headers).
- **Visibility defaults.** Agent output defaults to `Private` until explicitly promoted. A review that synthesizes agent output can reference the private items without making them directly accessible.

These are partial mitigations, not complete solutions. The agent deployment configuration must also enforce sanitization at the source. This is an operational discipline, not purely an architectural one.

---

## 7. Research at Agent Scale: Internal Journals, Not More Papers

### 7.1 The Volume Problem

A research group in computational astrophysics deploys 200 agents over a weekend: parameter sweeps across resolution hierarchies for adaptive mesh refinement (AMR) convergence studies, literature surveys across ADS and arXiv, code variations implementing alternative numerical limiters, cross-validation between different AMR codes. By Monday morning there are roughly 100,000 items: progress logs, intermediate results, code patches, anomaly reports, convergence plots, failed approaches with reasoning chains.

No one can or should read 100,000 items. But the anomaly at item 47,832 might be the most important finding of the month. The question is how to compress intelligently while keeping the full record accessible.

### 7.2 The Wrong Response

The default trajectory of AI in research is more output: more papers, more analyses, more supplementary material. This makes the literature harder to navigate — a problem already serious in many fields and certain to get worse as AI-generated manuscripts multiply.

A research group that simply forwards agent output, whether to journals or to its own members, is using agents as a fire hose pointed at human attention.

### 7.3 Internal Scholarly Culture

We argue that a research group at agent scale benefits from the same institutions the broader scientific community developed to manage knowledge growth — but running internally, at higher frequency, with full access to the underlying item graph.

**Internal reviews.** When an agent cluster finishes a parameter sweep, a human (or a review agent supervised by a human) writes a review that synthesizes the findings, evaluates the methodology, identifies what matters, explains the dead ends, and recommends next steps. This review cites the agent items it draws from. Group members read the review, not the 5,000 progress logs behind it. But when they want to check a specific claim — "the L2 norm diverges above refinement level 8" — the citation chain takes them to the exact run, parameters, and timestep.

**Internal journals.** The group maintains internal publication venues with editorial standards. A weekly digest summarizes agent activity across all projects. Methods notes document techniques that worked (or instructively failed). State-of-the-question documents are living review articles per project, updated as results come in, with sections linked to the agent runs and discussions that produced the current understanding.

**The review as intellectual work.** The automated digest collapses logs mechanically: "cluster X completed, Y anomalies, Z failures." The human review adds what machines cannot yet reliably provide: "the level-8 anomaly is probably a boundary condition artifact, cf. Chen (2024) on the piecewise parabolic method (PPM) solver — run the same parameters with Dirichlet boundaries before drawing conclusions about convergence." Writing the review is how the researcher develops understanding of what the agents found.

### 7.4 A Hierarchy of Compression

Agent scale inverts the traditional bottleneck. Before agents, production (running simulations, reading papers) is slow and consumption (reading each other's work) is relatively easy. With agents, production is cheap and consumption is the constraint.

The internal scholarly culture converts cheap production into understanding through compression:

1. **Raw items** — full agent output. Stored with provenance. Rarely read directly.
2. **Digests** — automated summaries with anomaly highlights. Read daily by the responsible group member.
3. **Reviews** — human-authored syntheses with judgment and context. Read by the group.
4. **State-of-the-question** — living review articles per project. Read by everyone including outside collaborators.
5. **External publications** — traditional papers, distilled from the internal record, accompanied by project bundles for reproducibility.

Each level compresses roughly tenfold. 100,000 agent items become perhaps 50 digests, 10 reviews, 2 state updates, and eventually contribute to 1 paper. The item graph preserves the provenance chain from paper to raw agent log.

### 7.5 End-to-End Scenario: From Agent Run to Published Claim

To make the workflow concrete, here is a single path through the hierarchy with explicit item types and transitions:

1. **Agent runs.** 50 agents run AMR convergence tests across refinement levels 4–12 with three numerical limiters. Each produces `raw-agent-log` items (schema: run config, metrics per timestep, wall time) and `agent-result` items (schema: summary statistics, convergence plots, anomaly flags). Total: ~15,000 raw logs, ~150 result summaries.

2. **Automated digest.** The attention router matches the `Anomaly` priority flag on 7 result items. The DigestRenderer groups them by limiter and refinement level, producing 3 `automated-digest` items (schema: anomaly count, affected runs, thumbnails of divergent plots). These appear in the responsible postdoc's morning view with `Badge` attention level. **Input/output of attention router:** item type `agent-result` + priority `Anomaly` + tag `project-aurora/amr-convergence/*` + subscriber role `postdoc-amr` → attention level `Badge`, destination: postdoc's inbox in email view and project dashboard.

3. **Internal review.** The postdoc investigates the 7 anomalies, traces 5 to known boundary condition issues (following `DerivedFrom` chains to the run configurations), and identifies 2 as genuinely interesting: the Van Leer limiter diverges above level 10 in a way not predicted by theory. She writes an `internal-review` item (schema: title, markdown body, status=Draft, scope tag) that cites the 7 anomaly items, the 2 interesting run items, and 3 bibliography entries from imbib. She submits it for review.

4. **Editorial workflow.** The review's status transitions: `Draft → InReview` (triggers `Notify` to PI via attention router). PI reads, adds comments as `Annotates` items, requests a comparison run with PPM. Status: `InReview → Revision`. Postdoc runs the comparison (new agent items), updates the review, resubmits. `Revision → Accepted`.

5. **State-of-the-question update.** The accepted review is cited by the living `state-of-the-question` document for the AMR convergence project. A new section is added: "Van Leer limiter anomaly at high refinement levels." The section links to the review, which links to the runs, which link to the raw logs.

6. **External publication.** Six months later, the anomaly is understood and forms Figure 4 of a submitted paper. The paper's project bundle includes the state-of-the-question document, the relevant reviews, and references to the raw agent data (available on request or via institutional repository). A referee can trace Figure 4 through the review to the specific agent runs.

### 7.6 Social and Incentive Considerations

The internal journal works only if people actually write the reviews. This is a real challenge.

**Who does the work.** Review writing rotates among group members by project area. The PI reviews the reviews. This is not additional work on top of research — it replaces informal status updates, Slack summaries, and group meeting presentations. The review is the status update, in a form that persists and is citable.

**Avoiding duplication with external peer review.** Internal reviews are explicitly reusable: sections of the state-of-the-question document become sections of the eventual paper. The internal review of the Van Leer anomaly, revised and expanded, *is* the first draft of the methods section. Writing for the internal journal is writing toward publication, not away from it.

**Quality signals.** Reviews carry status (Draft, InReview, Accepted) and are attributed. Over time, the graph records whose reviews were most cited by subsequent work and which reviews led to productive directions. This is lightweight bibliometrics applied internally.

**Time cost.** Writing a review of a weekend agent run takes a few hours. Reading 5,000 raw logs to get the same understanding takes much longer, or more likely does not happen at all. The review is faster than the alternative, not slower.

### 7.7 Against the Flood

This is deliberately counter to the prevailing trend of using AI to increase publication volume. We think the right response to agent-scale research is to publish *fewer* papers, backed by *more* systematic exploration, and to make that exploration reproducible by sharing the item graph. The internal journal is where understanding happens. It prevents agent-scale research from becoming agent-scale noise. This is a hypothesis, not a proven claim. We discuss evaluation in Sec 10.

---

## 8. Measuring Human-AI Research Collaboration

### 8.1 Why the Item Graph Enables Measurement

Every research product in the system — whether produced by a human, an agent, or a collaboration — is a typed, attributed, timestamped item with a full provenance chain. Agent output is structurally identical to human output: same item protocol, same reference types, same schema system. But the `author_kind` field and `ProducedBy` edges make attribution unambiguous at any point in the graph.

This means you can ask concrete questions and get answers from graph queries:

- Of the references cited in the final paper, what fraction trace through agent-produced items? Through human reviews? Through both?
- When an agent flagged an anomaly, how long until a human reviewed it? How often did the human confirm vs. dismiss? What was the false positive rate by agent configuration?
- How many agent exploration branches were abandoned, and at what stage?
- What is the compression ratio at each level of the hierarchy, and how does it vary by project?
- Who added the tag that routed an anomaly to the right reviewer, and how long after the agent flagged it? (Answerable because tag assignments are provenanced operation items — Sec 2.2.)

These are not hypothetical metrics. They are queries over data the system already stores for its primary purpose.

### 8.2 Controlled Experiments on Agent Configuration

Because agents write items through the same channel with the same schema, you can run the same research question with different agent configurations and compare results.

**Example: literature survey depth.** Deploy 30 agents with breadth-first search (follow all citation chains to depth 2) and 30 with a focused strategy (follow only chains matching a relevance classifier). Both produce items with the same schema. After human review, compare: which strategy surfaced more items that made it into the state-of-the-question document? Which had a higher false positive rate? Which cost more compute per useful item? **Design:** within-group comparison, randomized assignment of survey subtopics to strategies, human reviewer blinded to strategy where feasible.

**Example: human-in-the-loop frequency.** Run a parameter sweep with agents configured to `AwaitHumanResponse` at every anomaly vs. agents that batch anomalies into a daily digest. Measure: time to identify the critical finding, total human attention time, number of unnecessary interruptions. **Design:** between-project comparison (different parameter sweeps of comparable difficulty), or within-project with A/B assignment of parameter subregions to strategies.

**Example: review vs. no review.** For one project branch, have humans write internal reviews before proceeding. For another, work directly from automated digests. Compare after six months: error rate in claims reaching publication stage, time spent correcting misunderstandings, postdoc comprehension (measured by quiz or interview). **Design:** between-project, with difficulty-matched project pairs. This is harder to control rigorously; we expect the first evidence to be observational.

### 8.3 Attribution Granularity

Attribution is at the item level, not the word or line level. When a human edits an agent-generated draft, the result is a new item that `Supersedes` the agent draft and has `author_kind = Human` with a `DerivedFrom` edge to the agent's version. Mixed-authorship items are represented as chains: agent draft → human revision → agent expansion → human final. Each step is a distinct item with clear attribution. This is coarser than character-level tracking but sufficient for the research questions above and avoids the complexity of real-time co-editing attribution.

### 8.4 Ethics of Agent Attribution

The provenance system supports but does not enforce ethical norms around agent use. What it provides: every item records whether it was produced by a human or an agent, and the full derivation chain is available for audit. A reader of an external publication can inspect the project bundle and see exactly which claims were agent-originated, which were human-reviewed, and where human judgment was applied.

What remains outside the platform's scope: policies on authorship credit (whether agents are listed as authors or acknowledged), institutional norms on disclosure (some venues may require explicit statements about AI involvement), and accountability (who is responsible when an agent-originated claim turns out to be wrong). The architecture makes these questions answerable but does not prescribe the answers. Research groups and institutions will need their own policies.

### 8.5 Toward a Science of Agentic Research

There is currently no good empirical basis for decisions about AI agent deployment in research. How many agents per researcher? What tasks benefit most from agent exploration vs. human intuition? These are important questions answered mostly by anecdote today.

This architecture does not answer them. But it creates infrastructure for answering them rigorously. Every research group running on this platform generates, as a byproduct of doing their actual work, a structured, machine-readable record of how human-AI collaboration played out on real problems. Across groups and over time, that data could inform the design of better agent systems and better research practices.

---

## 9. The Impress Suite and Impress Mode

**Terminology.** The *impress suite* is a set of six applications for research: *imbib* (bibliography management), *imprint* (manuscript writing with Typst), *implore* (data visualization), *impel* (AI agent orchestration), *implement* (coding environment), and *impart* (messaging/communication). Each is a macOS application with a Rust core and Swift UI. They share a common item store (Sec 2.2).

*Impress mode* is a planned unified workspace where the application boundaries dissolve: a single window with a focus context, a configurable layout of renderers from any domain, unified search, and a unified command palette. It is the target state, not the current state.

The individual applications are constrained views over the shared item graph. Impress mode removes those constraints: one workspace, one focus context (the current research question), one layout.

```
Focus: "AMR convergence properties"
    
    ┌─────────────────┬──────────────────┬───────────────┐
    │ Manuscript       │ Related figures   │ Discussion    │
    │                  │                   │               │
    │ Section 3:       │ Fig 4: Conv. plot │ Agent: "Found │
    │ Convergence...   │ Fig 5: Error dist │  anomaly at   │
    │                  │                   │  level 6"     │
    ├─────────────────┼──────────────────┤               │
    │ Bibliography     │ Recommendations   │ PI: "Check    │
    │                  │                   │  boundary     │
    │ • Smith 2024     │ ⚡ Your 2022 AMR  │  conditions"  │
    │ • Chen 2025      │   exploration     │               │
    │                  │   shares 4 refs   │               │
    └─────────────────┴──────────────────┴───────────────┘
```

Switching focus updates all panels. The researcher is not in "the bibliography app" — they are working on a question, and the environment shows them what is relevant.

Or they ignore all of this and use it as an email client. That works too.

This requires: one item store, one event bus, one attention router, composable renderers, fast graph neighborhood queries. If the architecture is right, impress mode emerges naturally. If it has to be forced, the architecture was wrong.

---

## 10. Implementation Status and Positioning

### 10.1 What Is Built, What Is Not

**Implemented and in daily use.** Imbib — a bibliography manager with a Rust core (BibTeX/RIS import, ADS/CrossRef integration, PDF management), hierarchical tag system, user-defined flags, reading notes, and a recommendation engine that explains its suggestions. It runs on macOS with a Swift UI. Imbib's tag hierarchy and flagging system are the concrete starting points from which the shared `TagPath` and `FlagSet` types in impress-core are being generalized.

**Prototyped.** The unified item protocol (Sec 2.2) as a Rust crate, with `Item`, `TypedReference`, `Schema`, and the `ItemStore` trait. Currently being tested by migrating imbib's data model onto it.

**Design-stage.** Impart (messaging/communication), the attention routing system, the view framework's declarative template format, the agent append channel, the graph coherence service, the internal journal workflow, and impress mode.

**Not yet started.** Cross-institution sync, the coherence service's structural signature indexing, the measurement framework described in Sec 8, and the deployment of agent swarms in production research.

**What we know from imbib.** The tag hierarchy, flag system, and recommendation engine have been used daily for bibliography management for [duration]. Approximate scale: [N] bibliography entries, [M] tags, [K] reading notes. The recommendation engine surfaces relevant papers with transparency explanations. Lessons: (i) users want to understand *why* something is recommended, not just that it is; (ii) the tag hierarchy needs to be freely editable, not locked to a controlled vocabulary; (iii) the flagging system is used more than expected for personal workflow (marking papers as "to-read," "to-cite," "disagree-with"). These observations directly informed the schema and view designs in this paper.

[Note: specific numbers and duration to be filled in from imbib usage data.]

### 10.2 Evaluation Plan

The claims in Sections 5–8 are hypotheses. The key ones and how we intend to test them:

**H1: The unified item model reduces context-switching cost.** Test: time-and-motion study comparing task completion (read paper → annotate → discuss → update manuscript) in impress vs. separate applications. Baseline: current workflow with imbib + separate tools.

**H2: The compression hierarchy improves group understanding at agent scale.** Test: within-group comparison of error rates and onboarding time on project branches with and without internal review workflows. First evidence will be observational.

**H3: Typed provenance enables meaningful measurement of human-AI collaboration.** Test: demonstrate that the graph queries described in Sec 8.1 can be executed on real project data and produce interpretable results. This is a feasibility test, not a controlled experiment.

**H4: Cognitive-pluralism view selection improves individual researcher effectiveness.** Test: A/B comparison of default vs. user-selected view configurations on information retrieval tasks. This requires multiple users and is a later-stage evaluation.

### 10.3 Positioning Relative to Adjacent Tools

Several categories of existing tools address parts of this design space. The positioning:

**Electronic lab notebooks (ELNs)** (Benchling, Labfolder, RSpace) focus on experimental record-keeping: protocol execution, structured data entry, regulatory compliance. They are strong on data capture and audit trails but weak on cross-artifact navigation, agent integration, and view pluralism. The item graph subsumes the ELN's structured records as one schema among many.

**Computational notebooks** (Jupyter, Observable, Mathematica) combine code, narrative, and visualization. They are excellent for exploratory analysis but poor at collaboration, provenance across sessions, and integration with non-computational artifacts. A notebook execution could be an item type in the graph, with `DerivedFrom` edges to its input data and `ProducedBy` edges to the code that generated it.

**Workflow engines** (Snakemake, Nextflow, Galaxy) manage computational pipelines with explicit dependency graphs. They solve execution reproducibility but not the broader research context: why this pipeline was designed, which literature motivated it, what the results mean. A workflow DAG could map onto a set of items with `DerivedFrom` edges, and the workflow's provenance record could be imported as items.

**Research packaging** (RO-Crate, PROV-O, BagIt) focuses on portable, self-describing bundles of research outputs. Project bundles in the impress architecture can be exported as RO-Crate (Sec 2.2). The difference: RO-Crate packages completed outputs; the item graph captures the ongoing process, including dead ends, internal reviews, and agent reasoning chains.

**Local-first knowledge tools** (Obsidian, Logseq, Roam) implement Zettelkasten-style linked notes with local storage. They are strong on note-linking and personal knowledge management but do not support typed schemas, agent output at scale, structured collaboration, or domain-specific renderers.

**Key differentiators.** (i) The typed item graph as a shared substrate across all research activities, not just note-taking or computation. (ii) Cognitive-pluralism-driven view framework that adapts presentation to the user, not just the data type. (iii) The internal scholarly culture as a structured response to agent-scale output, with explicit compression hierarchy and editorial workflow. (iv) The measurement agenda: typed provenance enabling quantitative study of human-AI research collaboration as a byproduct of normal use.

**Integration, not replacement.** The architecture is designed to import from and export to existing tools: BibTeX/RIS from reference managers, RO-Crate for research packaging, mbox for email-format exchange, Git for code artifacts. The goal is not to replace everything at once but to provide a connective substrate that existing tools can feed into and draw from.

---

## 11. What Went Wrong Before

The ambition to unify applications has been tried before and has a poor track record. We take these failures seriously.

### 11.1 Chandler (OSAF, 2002–2008)

Mitch Kapor spent $8M and seven years building a "unified representation for the storage of tasks and information." Documented in Rosenberg's *Dreaming in Code* (2007). Shipped a barely functional preview after five years. Was still asking "who is this for?" at year seven.

The problem: Chandler tried to unify email, calendar, tasks, and notes without strong opinions about any of them. The architecture consumed all available effort. Nothing concrete got good enough to use.

### 11.2 OpenDoc (Apple, 1992–1997)

Component-based documents where any "part" could embed any other. Killed by Jobs in 1997 as "a technology looking for a problem." Performance was terrible, no one owned the overall experience, and developers had to rethink everything for uncertain adoption.

The lesson: if every component is independent, who makes the whole coherent?

### 11.3 The Pattern

CORBA (specification grew to thousands of pages; REST won). The Semantic Web (technically elegant; practically unusable). Xanadu (50 years of design; the Web shipped 5% of the vision and changed the world). Enterprise JavaBeans (over-engineered; Spring killed it). Eclipse RCP (everything is a plugin; VS Code ate its lunch).

Consistently: systems that try to be maximally general lose to systems that are opinionated about a specific use case.

### 11.4 Why We Might Survive This

We are building for a specific domain (computational astrophysics), for specific users (initially ourselves), with concrete types (bibliography entries, agent messages, not abstract "items"). The typed references — `Cites`, `Discusses`, `ProducedBy` — encode domain knowledge. We have a working application (imbib) to migrate as a proving ground.

But the vision described in this paper encompasses all research, all collaboration patterns, all cognitive styles. That is the scope of a career. The discipline is: build for one research group first. Generalize only when a second concrete user forces it. Write concrete types first, extract the protocol second. Ship imbib on the new architecture. Ship impart. Only then ask whether the broader vision holds up.

---

## 12. Synthesis

Traditional software architecture separates concerns along technical boundaries: data, logic, presentation. Research does not respect those boundaries. A single thought — "this convergence criterion might be wrong" — touches the bibliography, the code, the data, the manuscript, and the communication channel at once.

The architecture described here separates concerns along cognitive boundaries instead:

| Cognitive Concern | Architectural Component | Prior Art |
|---|---|---|
| "What do I know?" | Unified item graph | MVC, Datomic, Zettelkasten |
| "What's happening?" | Event bus, agent channel | Event Sourcing, Actor Model |
| "What should I see?" | View framework, renderers | CQRS, ECS, DCI |
| "What needs my attention?" | Attention router | Incremental computation, Supervision trees |
| "How does this connect?" | Reference graph, coherence service | Graph databases, CRDTs, Zettelkasten |
| "Who am I working with?" | Shared projects, bundles | Local-first software |
| "Can I trust this record?" | Provenance chains, attestation, excision | Event Sourcing, Datomic, PROV-O |
| "How does this mind work best?" | View personalization, cognitive profiles | Phenomenal diversity research |
| "What did the agents find?" | Internal reviews, digests, journals | Scholarly publishing |
| "How well is this working?" | Typed provenance, graph queries | Experimental design, reproducibility |

None of these patterns are new. The observation is that they compose well when organized around how researchers work rather than how programmers build. The practical entry point is simple: it looks like email, or chat, or a dashboard — whatever the researcher already knows. The unified architecture underneath is there when they need it. And because the architecture records not just results but the full process of how those results were reached, it turns every research project into a potential case study in human-AI collaboration — creating the empirical foundation for understanding how to do this well.

---

## References

### Architectural Lineage

- Reenskaug, T. (1979). "Thing-Model-View-Editor" — original MVC note, Xerox PARC
- Reenskaug, T. & Coplien, J. (2009). "The DCI Architecture: A New Vision of Object-Oriented Programming"
- Young, G. (2010). "CQRS Documents"; see also "Versioning in an Event Sourced System"
- Hickey, R. (2012). "The Value of Values" (Strange Loop) and Datomic architecture
- Kleppmann, M. et al. (2019). "Local-First Software: You Own Your Data, in Spite of the Cloud" (Ink & Switch)
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*
- Overwatch GDC Talk (2017) and ECS literature; Rust ECS ecosystem: bevy_ecs, hecs, legion
- Hammer, M. et al. (2014). "Adapton: Composable, Demand-Driven Incremental Computation"
- Salsa framework (rust-lang/salsa) — incremental computation in Rust, used in rust-analyzer
- Armstrong, J. (2003). *Making Reliable Distributed Systems in the Presence of Software Errors*
- Luhmann, N. — Zettelkasten; see Schmidt, J. (2016). "Niklas Luhmann's Card Index"
- Hewitt, C., Bishop, P. & Steiger, R. (1973). "A Universal Modular ACTOR Formalism"

### Cognitive Diversity and Phenomenal Variation

- Lupyan, G., Uchiyama, R., Thompson, B. & Casasanto, D. (2023). "Hidden Differences in Phenomenal Experience." *Cognitive Science*, 47(1), e13239
- Nedergaard, J. S. K. & Lupyan, G. (2024). "Not Everybody Has an Inner Voice: Behavioral Consequences of Anendophasia." *Psychological Science*, 35(7), 780–797
- Zeman, A., Dewar, M. & Della Sala, S. (2015). "Lives Without Imagery — Congenital Aphantasia." *Cortex*, 73, 378–380
- Zeman, A. (2025). "A Decade of Aphantasia Research." *Neuropsychologia*
- Nanay, B. (2025). "Varieties of Aphantasia." *Trends in Cognitive Sciences*, 29(11), 965–966
- Delem, M. et al. (2025). "Unsupervised Clustering Reveals Spatial and Verbal Cognitive Profiles in Aphantasia." *Neuropsychologia*, 219, 109279
- Hayes, S. J., Miles, G. E. & Evans, S.-A. (2026). "'Unseen Strategies': Aphantasia and Cognitive Strategies in Memory." *New Ideas in Psychology*, 80, 101215
- Kozhevnikov, M., Kosslyn, S. & Shephard, J. (2005). "Spatial Versus Object Visualizers." *Memory & Cognition*, 33(4), 710–726
- Höffler, T. N. et al. (2017). "More Evidence for Three Types of Cognitive Style." *Applied Cognitive Psychology*, 31(1), 56–69
- Steichen, B. & Fu, B. (2020). "Cognitive Style and Information Visualization." *Frontiers in Computer Science*, 2, 562290
- Heavey, C. L. & Hurlburt, R. T. (2008). "The Phenomena of Inner Experience." *Consciousness and Cognition*, 17(3), 798–810
- Hurlburt, R. T. & Akhter, S. A. (2008). "Unsymbolized Thinking." *Consciousness and Cognition*, 17(4), 1364–1374
- Hurlburt, R. T. (2011). *Investigating Pristine Inner Experience.* Cambridge University Press
- Heavey, C. L. et al. (2019). "Nevada Inner Experience Questionnaire." *Frontiers in Psychology*, 9, 2615
- Roebuck, H. & Lupyan, G. (2020). "The Internal Representations Questionnaire." *Behavior Research Methods*, 52, 2053–2070

### Interruption and Context Switching

- Mark, G., Gonzalez, V. M. & Harris, J. (2005). "No Task Left Behind? Examining the Nature of Fragmented Work." *CHI 2005*
- Altmann, E. M. & Trafton, J. G. (2002). "Memory for Goals: An Activation-Based Model." *Cognitive Science*, 26(1), 39–83

### Cautionary Case Studies

- Rosenberg, S. (2007). *Dreaming in Code: Two Dozen Programmers, Three Years, 4,732 Bugs, and One Quest for Transcendent Software* — Chandler/OSAF
- Wikipedia: OpenDoc — history and technical analysis of Apple's component document framework

### Standards and Research Packaging

- RFC 4155 — mbox format specification
- RO-Crate specification (researchobject.github.io/ro-crate) — portable research context packaging
- PROV-O (W3C, 2013) — provenance ontology
- W3C Verifiable Credentials — provenance manifest integrity
- Soiland-Reyes, S. et al. (2022). "Packaging Research Artefacts with RO-Crate." *Data Science*, 5(2), 97–138
