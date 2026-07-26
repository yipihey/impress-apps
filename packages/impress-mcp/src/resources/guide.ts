/**
 * `impress://guide` — the orientation document for a fresh agent.
 *
 * Without it, an agent connecting to this server sees ~200 tool names and no
 * map: nothing says what impress is, that the apps share one store, which of
 * the five overlapping search tools to reach for, or that mutations are
 * asynchronous and must be polled. That knowledge used to live only in the
 * heads of people who had read the Swift code.
 *
 * This resource is STATIC — it never touches an app's HTTP API, so it is
 * available even when every app is closed. That matters: "no apps running" is
 * exactly the moment an agent most needs to know what it is looking at.
 */

import type { Resource } from "@modelcontextprotocol/sdk/types.js";

export const GUIDE_URI = "impress://guide";

export const GUIDE_RESOURCE: Resource = {
  uri: GUIDE_URI,
  mimeType: "text/markdown",
  name: "impress: agent guide",
  description:
    "Read this first. What impress is, what each app does, which search tool to use when, how async operations and review checkpoints work.",
};

export const GUIDE_MARKDOWN = `# impress — agent guide

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
| **imbib** | bibliography, papers, PDFs, annotations, notes, tags, collections | \`imbib_resolve_identifier\`, \`imbib_search_library\`, \`imbib_search_sources\`, \`imbib_add_papers\`, \`imbib_get_paper\`, \`imbib_export_bibtex\`, \`imbib_list_annotations\` |
| **imprint** | Typst/LaTeX manuscript authoring, sections, citations, compile | \`imprint_list_documents\`, \`imprint_get_outline_v2\`, \`imprint_get_section\`, \`imprint_patch_section\`, \`imprint_insert_citation_in_section\`, \`imprint_compile\`, \`imprint_get_pdf\` |
| **implore** | data visualisation, datasets, figures, volume slices | \`implore_list_datasets\`, \`implore_create_figure\`, \`implore_export_figure\`, \`implore_rg_load\`, \`implore_rg_control\`, \`implore_rg_slice_png\` |
| **impel** | agent orchestration — threads, agents, escalations, review queues | \`impel_create_thread\`, \`impel_get_next_thread\`, \`impel_submit_for_review\`, \`impel_create_escalation\` |
| **impart** | communication — conversations, messages, decisions | \`impart_list_conversations\`, \`impart_get_conversation\`, \`impart_record_decision\` |

Plus **cross-app bridges** (\`impress_*\`): \`impress_cite_paper\`,
\`impress_cite_in_section\`, \`impress_embed_figure\`,
\`impress_extract_papers_from_conversation\`, \`impress_search_all\`,
\`impress_get_item\`, \`impress_get_related\`.

## One store, cheap cross-references

The apps share a single SQLite graph store (an app group container). A paper,
a manuscript, a figure and a conversation are all *items* in the same graph,
so cross-app references cost a lookup, not an export/import dance. Cite a
paper into a manuscript by cite key; embed a figure by id; the receiving app
resolves it. Never copy a PDF or a .bib file around by hand.

## Which search tool?

Five tools have "search" in the name. They are not interchangeable:

- **\`imbib_resolve_identifier\`** — *the default entry point for "find me this
  paper".* Give it a DOI, arXiv id, bibcode, URL, title, or a loose citation
  string. It checks the local library first, then external sources, and can
  import in one step. The \`via\` field tells you what happened
  (\`local-identifier\`, \`local-search\`, \`imported-identifier\`, \`duplicate\`,
  \`local-search-ambiguous\`, \`external-candidates\`, \`not-found\`). When it
  comes back ambiguous, ASK — do not pick a candidate blindly.
- **\`imbib_search_library\`** — full-text over papers the user already has.
  Use when the answer is "what do I have on X".
- **\`imbib_search_sources\`** — external only (ADS, arXiv, Crossref). Use when
  you know the library does not have it, or you want breadth. Costs network.
- **\`impress_search_all\`** — cross-app search over the shared store (papers +
  manuscripts + figures + conversations). Use for "where did I write about X",
  when you do not know which app holds the answer.
- **\`imprint_search\`** — within a single open document. Use to locate a
  phrase before patching it.
- **\`imprint_cross_document_search\`** — across all open manuscripts. Use for
  "have I already written this section elsewhere".

If \`scix_*\` tools are present, they are the full ADS/SciX query language
(field queries, \`citations(bibcode:…)\`, \`references(…)\`, metrics). Reach for
them for literature *analysis*; reach for imbib for the user's own library.

## Images come back inline

Visual tools return real image blocks that the user sees in the conversation —
assume nothing about the user having a file system in front of them (they are
often on a phone). Inline today:

- \`imprint_get_pdf\` — renders a page of the compiled PDF to PNG. Pass
  \`page\` to page through; the caption gives the page count.
- \`implore_export_figure\` (png/pdf), \`implore_rg_slice_png\`,
  \`implore_rg_batch\`.

SVG is **not** inline: MCP image content is raster and most clients will not
render \`image/svg+xml\`. Tools that produce SVG (\`imprint_render_plot\`,
\`implore_plot_series\`, \`implore_plot_histogram\`,
\`implore_rg_cascade_plot\`) return source text. To actually show a plot,
route it through a manuscript: \`imprint_save_plot_figure\` →
\`imprint_compile\` → \`imprint_get_pdf\`.

## Canonical workflows

1. **Find and file a paper** — \`imbib_resolve_identifier\` → (if ambiguous,
   ask) → \`imbib_add_papers\` → \`imbib_add_to_collection\` / \`imbib_add_tag\`.
2. **Cite into a manuscript** — \`imprint_get_outline_v2\` to get the section
   key → \`imbib_resolve_identifier\` → \`imprint_insert_citation_in_section\`
   (pass the BibTeX so the bibliography resolves) → poll the operation →
   \`imprint_compile\` → \`imprint_get_pdf\` to show the result.
3. **Draft and review** — \`imprint_create_section\` for new prose;
   \`imprint_create_comment\` with \`proposedText\` for changes to existing
   prose (see review checkpoints below).
4. **Make and embed a figure** — \`implore_create_figure\` (or a plot spec via
   \`imprint_save_plot_spec\`) → \`imprint_save_plot_figure\` /
   \`impress_embed_figure\` → \`imprint_compile\` → \`imprint_get_pdf\`.

## Async operations must be polled

imprint mutations are asynchronous: the tool returns an \`operationId\` and a
predicted id, not a finished edit. The edit is not real until you confirm it.

    imprint_create_section(...) -> { operationId, predictedSectionId }
    imprint_wait_for_operation({ operationId }) -> { state: "completed" | "failed" | ... }

Always wait for \`state === "completed"\` before telling the user something
happened, and before issuing a dependent edit. \`imprint_get_operation\` is the
non-blocking variant. \`imprint_compile\` is likewise not instantaneous — give
it a beat before \`imprint_get_pdf\`. \`imprint_get_pdf\` serves imprint's
editor cache when it has one and otherwise compiles the Typst source on
demand, so it does not require the document to be open in the GUI; if it
reports that the build has no headless compile route, the document really does
have to be open in imprint.

## Review checkpoints — propose, do not overwrite

The human's own prose is not yours to rewrite silently. For any change to text
the user wrote:

- **Propose** with \`imprint_create_comment\` — \`content\` explains WHY,
  \`proposedText\` is the exact replacement, \`start\`/\`end\` are absolute
  character offsets in the source (\`bodyStart\` from the outline tells you
  where a section body begins), \`authorAgentId\` identifies you. The user
  accepts or rejects in imprint's sidebar.
- **Do not** call \`imprint_patch_section\`, \`imprint_replace\`,
  \`imprint_delete_text\` or \`imprint_accept_suggestion\` on existing prose
  unless the user explicitly asked for the edit to be applied.
- Creating *new* sections, adding citations, and importing papers are additive
  and safe to do directly.
- Destructive tools (\`imbib_delete_papers\`, \`imprint_delete_section\`,
  \`impel_kill_thread\`) need explicit user intent. In imbib, delete means
  "move to Dismissed" — a trash, recoverable; permanent deletion only happens
  from within Dismissed.

## When an app is not running

Tools fail with a connection error and this server tries to launch the app
once, then retries. If that fails, tell the user which app to open rather than
guessing at data. \`imbib_status\` / \`imprint_status\` / \`implore_get_status\`
are cheap liveness checks. If \`IMBIB_BASE_URL\` points at the user's phone,
nothing can be launched for them — the phone has to be awake, on the tailnet,
with imbib open.

## Other resources

- \`impress://imbib/library\`, \`impress://imbib/collections\` — library summary.
- \`impress://imbib/papers/{citeKey}\` — full JSON for one paper (readable by
  URI even though it is not enumerated in the resource list).
- \`impress://imprint/documents\`, \`impress://imprint/documents/{id}\` — open
  manuscripts and their Typst source.
`;

export class GuideResource {
  list(): Resource[] {
    return [GUIDE_RESOURCE];
  }

  read(uri: string): { contents: Array<{ uri: string; mimeType: string; text: string }> } {
    return {
      contents: [{ uri, mimeType: "text/markdown", text: GUIDE_MARKDOWN }],
    };
  }
}
