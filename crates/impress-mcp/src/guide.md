# impress — agent guide

impress is a **research operating environment**: one workspace with five
facets, not five separate apps. A researcher reads papers, writes the
manuscript, plots the data, delegates to agents, and answers mail without
leaving it. Your job as an agent is to move work between those facets without
making the human click anything.

The apps run on the user's Mac (or iPhone) and expose local HTTP APIs; this
MCP server is a thin client over them and the shared store beneath them.
Everything is local-first; the user owns the data.

## How tools are named

Every capability is one generated tool named `<service>_<verb>`, e.g.
`imbib-app-service_resolve-identifier`. By default `tools/list` shows a
compact projection:

- `impress_capabilities` — the root tool. Call it — optionally with a
  `domain` — to rule the suite in or out, or list one domain's actions.
- Two dozen primary tools, flat, with full generated names
  (`store-query-service_search-all`, `imbib-library-service_search-publications`,
  `memory-service_recall`, …).
- One tool per domain — `imbib`, `imprint`, `implore`, `impart`, `vw`,
  `store`, `memory`, `docs`, `impress` — taking `{action, args}`. The action
  is the name minus the domain:
  `imbib-library-service_import-papers` is `imbib` action `library.import-papers`,
  and `implore-service_rg-load` is `implore` action `rg-load`.
  Pass `describe: true` first to get an action's argument schema.

Unlisted full names still dispatch, so every name in this guide can be
called as written — or reached through its domain tool.
(`IMPRESS_MCP_SURFACE=flat` lists everything flat.)

## The five facets

| App | Domain | Typical tools |
|---|---|---|
| **imbib** | bibliography, papers, PDFs, annotations, notes, tags, collections | `imbib-app-service_resolve-identifier`, `imbib-search-service_full-text-search`, `imbib-app-service_search-sources`, `imbib-library-service_import-papers`, `imbib-library-service_get-publication-detail`, `imbib-annotations-service_list-annotations` |
| **imprint** | Typst/LaTeX manuscript authoring, sections, citations, compile | `imprint-manuscript-service_list-documents`, `imprint-manuscript-service_list-sections`, `imprint-manuscript-service_put-section`, `imprint-manuscript-service_compile-typst`, `imprint-app-service_get-pdf` |
| **implore** | data visualisation, datasets, figures, volume slices | `implore-service_list-datasets`, `implore-service_create-figure`, `implore-service_export-figure`, `implore-service_rg-load`, `implore-service_rg-slice-png` |
| **impart** | communication — conversations, messages, decisions | `impart-service_list-conversations`, `impart-service_get-conversation`, `impart-service_record-decision` |

Plus **cross-app bridges** in the `impress` domain:
`impress-bridges-service_cite-paper`, `impress-bridges-service_cite-in-section`,
`impress-bridges-service_embed-figure`,
`impress-bridges-service_extract-papers-from-conversation`, and more.

The fifth facet, impel (agent orchestration), is driven through its own app
and HTTP API; no impel tools here.

## One store, cheap cross-references

The apps share one SQLite graph store (an app group container). A paper, a
manuscript, a figure and a conversation are all *items* in the same graph,
so a cross-app reference costs a lookup, not an export/import dance. Cite by
cite key; embed a figure by id; the receiving app resolves it. Never copy a
PDF or a .bib file around by hand.

## Which search tool?

Several tools have "search" in the name. They are not interchangeable:

- **`imbib-search-service_find-by-doi`** and its siblings (arxiv, bibcode,
  cite-key) — local, exact, app-closed-safe; check these first when you hold
  an identifier.
- **`imbib-app-service_resolve-identifier`** — the same lookup, but it can
  go and GET the paper from outside (the PDF too, with `download_pdfs`) when
  the library lacks it. Needs imbib running.
- **`imbib-search-service_full-text-search`** — over papers the user already
  has: "what do I have on X". `search_papers` is its semantic sibling over
  indexed PDFs; `get_paper_chunks` then feeds full-context RAG.
- **`imbib-app-service_search-sources`** — external only (ADS, arXiv,
  Crossref); one broad call, not several narrow ones. Results are candidates:
  `imbib-library-service_import-papers` before citing or tagging.
- **`store-query-service_search-all`** — cross-app search over the shared
  store (papers + manuscripts + figures + conversations + tasks + runs) for
  "where did I write about X", when you do not know which app holds the
  answer. Every hit carries `schema_ref`; the per-kind cap keeps one noisy
  mailbox from crowding out the manuscripts. Follow a hit with
  `store-query-service_get-item` to read it, or
  `store-query-service_related-items` for its connections — neither cares
  which app owns the record.
- **`imprint-manuscript-service_search`** — across all manuscripts; hits
  carry `document_id` and `section_key`. To pin a phrase inside one section
  before editing, run `imprint-manuscript-service_search-in-text` over the
  fetched body.

If `scix_*` tools are present, they are the full ADS/SciX query language
(field queries, `citations(bibcode:…)`, metrics). Reach for them for
literature *analysis*; for the user's own library, imbib.

## Seeing the result: paths, then pixels

No tool result can carry a PDF: compile tools return `pdf_path` plus
diagnostics. To let the user actually SEE a page, feed that path to
`render_pdf_page` (1-based `page`, clamped) for an inline PNG — the user is
often on a phone, where a path means nothing.

- **`imprint-manuscript-service_compile-typst`** — Typst *source* in;
  embedded compiler, works with imprint closed. A broken document comes back
  as `error`, not a failed call.
- **`imbib-manuscripts-service_compile-manuscript`** — a manuscript id in
  (from `imbib-manuscripts-service_list-manuscripts`); `@citeKey` references
  resolve against the imbib library, so there is no .bib file to maintain.
  Needs imbib running.
- **`imprint-app-service_get-pdf`** — compiles through the running imprint
  app and reports where the PDF landed. No page argument, no image — that is
  `render_pdf_page`'s job.

Also inline: `source-service_get-page-image` and
`source-service_get-figure-image` (stored pages and figures). SVG is
**not**: `implore-service_plot-series`, `implore-service_plot-histogram` and
`implore-service_rg-cascade-plot` return SVG source. To show a plot,
`implore-service_export-figure` to pdf and `render_pdf_page` it — or embed
and compile.

## Canonical workflows

1. **Find and file a paper** — `imbib-search-service_find-by-doi` (or
   sibling) → on a miss, `imbib-app-service_resolve-identifier` → no
   identifier at all? `imbib-app-service_search-sources`, confirm with the
   user, `imbib-library-service_import-papers` → file with
   `imbib-library-service_add-to-collection` / `imbib-tags-service_add-tag`.
2. **Cite into a manuscript** — `imbib-manuscripts-service_list-manuscripts`
   for the document id → `imbib-search-service_find-by-cite-key` to confirm
   the key → `impress-bridges-service_cite-paper` (appends `@citeKey`; the
   bibliography assembles at compile time), or
   `impress-bridges-service_cite-in-section` with a `section_key` from
   `imprint-manuscript-service_list-sections` →
   `imbib-manuscripts-service_compile-manuscript` → `render_pdf_page`.
3. **Draft and review** — `imprint-manuscript-service_put-section` for new
   sections; `imprint-app-service_create-comment` for changes to existing
   prose (see below).
4. **Make and embed a figure** — `implore-service_create-figure` (column
   names come from `implore-service_get-dataset` — look, don't guess) →
   `impress-bridges-service_embed-figure` (pdf or svg format for print) →
   `imbib-manuscripts-service_compile-manuscript` → `render_pdf_page`.

## Review checkpoints — propose, do not overwrite

The human's own prose is not yours to rewrite silently. For any change to
text the user wrote:

- **Propose** with `imprint-app-service_create-comment` — `body` explains WHY
  and gives the exact replacement; `anchor` it to a quoted snippet (an
  unanchored comment is much harder to act on). The user accepts or rejects
  in imprint's sidebar.
- **Do not** call `imprint-manuscript-service_put-section`,
  `imprint-manuscript-service_replace-in-section`,
  `imprint-app-service_replace`, `imprint-app-service_delete-text` or
  `imprint-app-service_insert-text` on existing prose unless the user
  explicitly asked for the edit to be applied. (Section writes are
  compare-and-set — protection against concurrent edits, not against you.)
- Creating *new* sections, adding citations, importing papers and tagging
  are additive and safe to do directly.
- Destructive tools (`imbib-library-service_delete-publications-undoable`,
  `imprint-manuscript-service_delete-section`) need explicit user intent. In
  imbib, delete means "move to Dismissed" — a trash, recoverable; permanent
  deletion only happens from within Dismissed.

## When an app is not running

Most tools read the shared store and work with every app closed. Four
namespaces live in the running app instead — `imbib-app-service`,
`imprint-app-service`, `implore-service`, `impart-service`. Probes run once
at server startup: a closed app's namespace is withheld from `tools/list`,
and calling in anyway gets a refusal naming the app to open — never an empty
"success". Tell the user which app to open rather than guessing at data; the
server notices only after a reconnect. `imbib-app-service_status`,
`imprint-app-service_status`, `implore-service_status` and
`impart-service_status` are cheap liveness checks. If `IMBIB_BASE_URL`
points at the user's phone, the phone has to be awake, on the tailnet, with
imbib open.

## Other resources

Three, and all are live reads of the shared store — they work with every app
closed, and they honour this server's `--store-path`:

- `impress://store/schemas` — every record kind with a live item count and
  its payload field names. **Read this before browsing:** it gives the exact
  `schema_ref` strings `store-query-service_list-items` takes, and which
  kinds actually have rows.
- `impress://store/collections` — all four collection hierarchies (imbib
  publications, imprint manuscripts, implore figures, and the generic
  mixed-kind kernel) with nesting and member counts. These are the ids the
  collection tools in the `store` domain take; rebuild the tree from
  `parent_id` (null = root).
- `impress://memory/brief` — standing instructions, then claims, then recent
  episodes from the suite memory (ADR-0028), pre-rendered as prompt-ready
  markdown with `[impress-item:<id>]` references. The same digest
  `memory-service_memory-brief` returns; call `memory-service_recall` for
  anything narrower than this unscoped default.

Then: `store-query-service_list-items` pages one kind (or every kind, with
empty `schema_ref`), newest first, envelopes only;
`store-query-service_get-item` opens one row of any kind — envelope plus
payload, capped at 32 KiB with a `truncated` flag when a long `body_content`
hits the cap.
