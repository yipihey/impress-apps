# impress — agent guide

impress is a **research operating environment**: one workspace with five
facets, not five separate apps. A researcher reads papers, writes the
manuscript, plots the data, delegates to agents, and answers mail without
leaving it. Your job as an agent is to move work between those facets without
making the human click anything.

The apps run on the user's Mac (or iPhone) and expose local HTTP APIs; this
MCP server is a thin client over them. Everything is local-first — no cloud
service is involved, and the user owns the data.

## The five facets

| App | Domain | Typical tools |
|---|---|---|
| **imbib** | bibliography, papers, PDFs, annotations, notes, tags, collections | `imbib_resolve_identifier`, `imbib-search-service_full-text-search`, `imbib_search_sources`, `imbib-library-service_import-papers`, `imbib-library-service_get-publication-detail`, `imbib-library-service_export-bibtex`, `imbib-annotations-service_list-annotations` |
| **imprint** | Typst/LaTeX manuscript authoring, sections, citations, compile | `imprint-manuscript-service_list-documents`, `imprint_get_outline_v2`, `imprint-manuscript-service_get-section`, `imprint_patch_section`, `imprint_insert_citation_in_section`, `imprint-manuscript-service_compile-typst`, `imprint_get_pdf` |
| **implore** | data visualisation, datasets, figures, volume slices | `implore_list_datasets`, `implore_create_figure`, `implore_export_figure`, `implore_rg_load`, `implore_rg_control`, `implore_rg_slice_png` |
| **impel** | agent orchestration — threads, agents, escalations, review queues | `impel_create_thread`, `impel_get_next_thread`, `impel_submit_for_review`, `impel_create_escalation` |
| **impart** | communication — conversations, messages, decisions | `impart_list_conversations`, `impart_get_conversation`, `impart_record_decision` |

Plus **cross-app bridges** (`impress_*`): `impress_cite_paper`,
`impress_cite_in_section`, `impress_embed_figure`,
`impress_extract_papers_from_conversation`, `impress_search_all`,
`impress_get_item`, `impress_get_related`.

## One store, cheap cross-references

The apps share a single SQLite graph store (an app group container). A paper,
a manuscript, a figure and a conversation are all *items* in the same graph,
so cross-app references cost a lookup, not an export/import dance. Cite a
paper into a manuscript by cite key; embed a figure by id; the receiving app
resolves it. Never copy a PDF or a .bib file around by hand.

## Which search tool?

Five tools have "search" in the name. They are not interchangeable:

- **`imbib_resolve_identifier`** — *the default entry point for "find me this
  paper".* Give it a DOI, arXiv id, bibcode, URL, title, or a loose citation
  string. It checks the local library first, then external sources, and can
  import in one step. The `via` field tells you what happened
  (`local-identifier`, `local-search`, `imported-identifier`, `duplicate`,
  `local-search-ambiguous`, `external-candidates`, `not-found`). When it
  comes back ambiguous, ASK — do not pick a candidate blindly.
- **`imbib-search-service_full-text-search`** — full-text over papers the user already has.
  Use when the answer is "what do I have on X".
- **`imbib_search_sources`** — external only (ADS, arXiv, Crossref). Use when
  you know the library does not have it, or you want breadth. Costs network.
- **`store-query-service_search-all`** — cross-app search over the shared store
  (papers + manuscripts + figures + conversations + tasks + runs). Use for
  "where did I write about X", when you do not know which app holds the
  answer. Every hit carries `schema_ref`, and the per-kind cap means one noisy
  mailbox cannot crowd out the manuscripts. Follow a hit with
  `store-query-service_get-item` to read it, or
  `store-query-service_related-items` to see what it is connected to — neither
  needs to know which app owns the record.
- **`imprint-manuscript-service_search`** — within a single open document. Use to locate a
  phrase before patching it.
- **`imprint_cross_document_search`** — across all open manuscripts. Use for
  "have I already written this section elsewhere".

If `scix_*` tools are present, they are the full ADS/SciX query language
(field queries, `citations(bibcode:…)`, `references(…)`, metrics). Reach for
them for literature *analysis*; reach for imbib for the user's own library.

## Images come back inline

Visual tools return real image blocks that the user sees in the conversation —
assume nothing about the user having a file system in front of them (they are
often on a phone). Inline today:

- `imprint_get_pdf` — renders a page of the compiled PDF to PNG. Pass
  `page` to page through; the caption gives the page count.
- `implore_export_figure` (png/pdf), `implore_rg_slice_png`,
  `implore_rg_batch`.

SVG is **not** inline: MCP image content is raster and most clients will not
render `image/svg+xml`. Tools that produce SVG (`imprint_render_plot`,
`implore_plot_series`, `implore_plot_histogram`,
`implore_rg_cascade_plot`) return source text. To actually show a plot,
route it through a manuscript: `imprint_save_plot_figure` →
`imprint-manuscript-service_compile-typst` → `imprint_get_pdf`.

## Canonical workflows

1. **Find and file a paper** — `imbib_resolve_identifier` → (if ambiguous,
   ask) → `imbib-library-service_import-papers` → `imbib-library-service_add-to-collection` / `imbib-tags-service_add-tag`.
2. **Cite into a manuscript** — `imprint_get_outline_v2` to get the section
   key → `imbib_resolve_identifier` → `imprint_insert_citation_in_section`
   (pass the BibTeX so the bibliography resolves) → poll the operation →
   `imprint-manuscript-service_compile-typst` → `imprint_get_pdf` to show the result.
3. **Draft and review** — `imprint_create_section` for new prose;
   `imprint_create_comment` with `proposedText` for changes to existing
   prose (see review checkpoints below).
4. **Make and embed a figure** — `implore_create_figure` (or a plot spec via
   `imprint_save_plot_spec`) → `imprint_save_plot_figure` /
   `impress_embed_figure` → `imprint-manuscript-service_compile-typst` → `imprint_get_pdf`.

## Async operations must be polled

imprint mutations are asynchronous: the tool returns an `operationId` and a
predicted id, not a finished edit. The edit is not real until you confirm it.

    imprint_create_section(...) -> { operationId, predictedSectionId }
    imprint_wait_for_operation({ operationId }) -> { state: "completed" | "failed" | ... }

Always wait for `state === "completed"` before telling the user something
happened, and before issuing a dependent edit. `imprint_get_operation` is the
non-blocking variant. `imprint-manuscript-service_compile-typst` is likewise not instantaneous — give
it a beat before `imprint_get_pdf`. `imprint_get_pdf` serves imprint's
editor cache when it has one and otherwise compiles the Typst source on
demand, so it does not require the document to be open in the GUI; if it
reports that the build has no headless compile route, the document really does
have to be open in imprint.

## Review checkpoints — propose, do not overwrite

The human's own prose is not yours to rewrite silently. For any change to text
the user wrote:

- **Propose** with `imprint_create_comment` — `content` explains WHY,
  `proposedText` is the exact replacement, `start`/`end` are absolute
  character offsets in the source (`bodyStart` from the outline tells you
  where a section body begins), `authorAgentId` identifies you. The user
  accepts or rejects in imprint's sidebar.
- **Do not** call `imprint_patch_section`, `imprint_replace`,
  `imprint_delete_text` or `imprint_accept_suggestion` on existing prose
  unless the user explicitly asked for the edit to be applied.
- Creating *new* sections, adding citations, and importing papers are additive
  and safe to do directly.
- Destructive tools (`imbib-library-service_delete-publications-undoable`, `imprint-manuscript-service_delete-section`,
  `impel_kill_thread`) need explicit user intent. In imbib, delete means
  "move to Dismissed" — a trash, recoverable; permanent deletion only happens
  from within Dismissed.

## When an app is not running

Tools fail with a connection error and this server tries to launch the app
once, then retries. If that fails, tell the user which app to open rather than
guessing at data. `imbib_status` / `imprint_status` / `implore_get_status`
are cheap liveness checks. If `IMBIB_BASE_URL` points at the user's phone,
nothing can be launched for them — the phone has to be awake, on the tailnet,
with imbib open.

## Other resources

Three, and all are live reads of the shared store — they work with every app
closed, and they honour this server's `--store-path`:

- `impress://store/schemas` — every record kind in the store with a live item
  count and its payload field names. **Read this before browsing:** it names
  the exact `schema_ref` strings `store-query-service_list-items` takes, and
  tells you which kinds actually have rows.
- `impress://store/collections` — all four collection hierarchies (imbib
  publications, imprint manuscripts, implore figures, and the generic
  mixed-kind kernel) with nesting and member counts. These are the ids every
  `collection-service_*` tool takes; rebuild the tree from `parent_id`
  (null = root).
- `impress://memory/brief` — standing instructions, then claims, then recent
  episodes from the suite memory (ADR-0028), pre-rendered as prompt-ready
  markdown with `[impress-item:<id>]` references. The same digest
  `memory-service_memory-brief` returns; read this instead of calling that
  tool when a resource read is more convenient. Call `memory-service_recall`
  for anything narrower than this default, unscoped brief.

Then: `store-query-service_list-items` pages through one kind (or every kind,
with an empty `schema_ref`), newest first, envelopes only;
`store-query-service_get-item` opens one row of any kind — envelope plus
payload, with the payload capped at 32 KiB and a `truncated` flag when a long
`body_content` hits the cap.

The TypeScript server's `impress://imbib/*` and `impress://imprint/*`
resources were **not** carried over and will error; the equivalent data is in
the `imbib-library-service_*` and `imprint-manuscript-service_*` tools.

<!-- Ported from packages/impress-mcp/src/resources/guide.ts during the
     TypeScript retirement. Tool names were repointed at their generated
     Rust equivalents; names still in TypeScript form belong to tools that
     have not been ported yet (see docs/mcp-migration-ledger.md). -->
