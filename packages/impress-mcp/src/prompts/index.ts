/**
 * MCP prompts for the impress suite.
 *
 * Prompts are parameterized workflows that users can invoke by name from an
 * MCP-capable client (Claude Desktop "Use prompt", Cursor `/`, etc.). Each
 * prompt describes a high-value cross-app workflow and tells the agent
 * exactly which tools to call and in what order.
 *
 * Keep these prompts tight — they compete with the user's actual question
 * for model attention. Prefer terse imperative language over prose.
 */

import type { Prompt, PromptMessage } from "@modelcontextprotocol/sdk/types.js";

// MARK: - Prompt definitions

export const IMPRESS_PROMPTS: Prompt[] = [
  {
    name: "cite-this",
    description:
      "Search imbib for the best-matching paper for a passage and insert a citation at a specific section. Cascades to external sources (ADS / arXiv / Crossref) if the library doesn't have it.",
    arguments: [
      { name: "topic", description: "What to cite — a claim, passage, DOI, arXiv id, or title.", required: true },
      { name: "documentId", description: "imprint document UUID (from imprint_list_documents or imprint_status).", required: true },
      { name: "sectionKey", description: "Stable section UUID from imprint_get_outline_v2, or integer index.", required: true },
      { name: "libraryId", description: "imbib library UUID to add new papers to (optional).", required: false },
    ],
  },
  {
    name: "draft-section",
    description:
      "Create a new section in an open imprint document from an outline. Agent writes the draft and stubs citations it'd like you to review.",
    arguments: [
      { name: "documentId", description: "imprint document UUID.", required: true },
      { name: "title", description: "Section heading (e.g., 'Methods', 'Related work').", required: true },
      { name: "outline", description: "Bullet-list of the points the section should cover.", required: true },
      { name: "position", description: "'end' (default), 'before:{sectionKey}', or 'after:{sectionKey}'.", required: false },
    ],
  },
  {
    name: "review-draft",
    description:
      "Read the current document section-by-section and leave suggestion comments the author can Accept or Reject. Agent uses imprint_create_comment with `proposedText`; does NOT apply edits directly.",
    arguments: [
      { name: "documentId", description: "imprint document UUID.", required: true },
      { name: "focus", description: "Optional topic to focus the review on — 'clarity', 'citations', 'math', 'structure'.", required: false },
      { name: "agentId", description: "Stable identifier for this agent (e.g., 'claude-desktop:opus-4.7'). Badges suggestions distinctly in imprint's sidebar.", required: false },
    ],
  },
  {
    name: "research-and-cite",
    description:
      "Given a topic, search external sources via imbib, import the best N papers, and write an annotated-bibliography section at the end of the document.",
    arguments: [
      { name: "topic", description: "Research topic or question.", required: true },
      { name: "documentId", description: "imprint document UUID.", required: true },
      { name: "maxPapers", description: "How many papers to import (default 5).", required: false },
      { name: "libraryId", description: "imbib library UUID to add papers to (optional).", required: false },
    ],
  },
  {
    name: "new-manuscript",
    description:
      "Create a new imprint document with stub sections (Abstract / Introduction / Methods / Results / Discussion) and optionally link it to an imbib library for references.",
    arguments: [
      { name: "title", description: "Manuscript title.", required: true },
      { name: "topic", description: "What the manuscript is about — used for the stub Abstract and to seed a research library.", required: true },
      { name: "format", description: "'typst' (default) or 'latex'.", required: false },
    ],
  },
  {
    name: "summarize-cited",
    description:
      "Collect notes and annotations for every cite key used in an imprint document, then synthesize a 'background' summary section.",
    arguments: [
      { name: "documentId", description: "imprint document UUID.", required: true },
      { name: "style", description: "'paragraph' (default) or 'bullets'.", required: false },
    ],
  },
];

// MARK: - Prompt rendering

export function renderPrompt(name: string, args: Record<string, string> | undefined): PromptMessage[] {
  const a = args ?? {};
  switch (name) {
    case "cite-this":
      return asUser(`Resolve and insert a citation for the passage below into section \`${a.sectionKey}\` of document \`${a.documentId}\`.

Passage / claim / identifier:
${a.topic}

Procedure (call these tools in order):
1. imbib_resolve_identifier({ query: "${escape(a.topic)}", library: ${a.libraryId ? `"${a.libraryId}"` : "undefined"} })
2. If \`via\` is "local-identifier", "local-search", "imported-identifier", or "duplicate" → take \`paper.citeKey\` and \`paper.bibtex\` and call:
     imprint_insert_citation_in_section({ documentId: "${a.documentId}", sectionKey: "${a.sectionKey}", citeKey: paper.citeKey, bibtex: paper.bibtex })
   Then imprint_wait_for_operation on the returned operationId and confirm state === "completed".
3. If \`via\` is "local-search-ambiguous" or "external-candidates" → present the candidates to the user. Do not pick one blindly. Ask which paper they mean before calling addPapers + insert_citation.
4. If \`via\` is "not-found" → tell the user, suggest they paste a DOI or arXiv id.

Respond with a one-paragraph summary of what happened, including the cite key that was inserted.`);

    case "draft-section":
      return asUser(`Draft a new section for imprint document \`${a.documentId}\`.

Section title: ${a.title}
Position: ${a.position ?? "end"}
Points to cover:
${a.outline}

Procedure:
1. Call imprint_get_outline_v2({ documentId: "${a.documentId}" }) to see the existing structure.
2. Draft the body as clean Typst. Use subheadings (\`== Subtitle\`) only if the outline has multiple distinct points. Leave placeholder citations as @TODO-keyword tokens — do NOT invent real cite keys.
3. Call imprint_create_section({ documentId: "${a.documentId}", title: "${escape(a.title)}", body: <your draft>, position: "${a.position ?? "end"}" }).
4. Poll the operationId with imprint_wait_for_operation until state === "completed".
5. Respond with the predictedSectionId and a 2-sentence summary of what you drafted.

Do NOT edit other sections in the document.`);

    case "review-draft":
      return asUser(`Review imprint document \`${a.documentId}\` as suggestions, without applying edits.

${a.focus ? `Focus: ${a.focus}.` : "General review — clarity, citations, structure, and anything obviously wrong."}

Procedure:
1. imprint_get_outline_v2({ documentId: "${a.documentId}" }) → pick the sections that actually have body content.
2. For each section, imprint_get_section({ documentId: "${a.documentId}", sectionKey: <id> }) to read its body.
3. Where you have a concrete text improvement, call imprint_create_comment with:
   - documentId: "${a.documentId}"
   - content: a one-sentence explanation of WHY this change helps
   - start, end: character offsets of the phrase/sentence to replace (values are absolute offsets in the source; bodyStart from the outline tells you where this section's body starts)
   - proposedText: the exact replacement text
   - authorAgentId: "${a.agentId ?? "anonymous-agent"}"
4. Where you have a question or observation without a concrete fix, create a comment WITHOUT proposedText.
5. Do NOT call imprint_patch_section, imprint_replace, imprint_accept_suggestion, or any other mutation tool. The human reviewer accepts/rejects suggestions in imprint's CommentsSidebarView.

End with a short summary: how many suggestions vs. open questions, and one sentence per section reviewed.`);

    case "research-and-cite":
      return asUser(`Research the topic below and write an annotated bibliography in imprint document \`${a.documentId}\`.

Topic: ${a.topic}
Max papers: ${a.maxPapers ?? "5"}

Procedure:
1. imbib_search_sources({ query: "${escape(a.topic)}", limit: ${a.maxPapers ?? "5"}, sources: "arxiv,ads,crossref" }).
2. For each returned candidate, imbib_add_papers({ identifiers: [candidate.identifier], library: ${a.libraryId ? `"${a.libraryId}"` : "undefined"} }) — skip any that come back as duplicates.
3. For each imported paper, imbib_get_paper({ citeKey }) to get full metadata + BibTeX.
4. Build an annotated-bibliography section body: one paragraph per paper, each ending with its @citeKey reference in Typst syntax.
5. imprint_create_section({ documentId: "${a.documentId}", title: "Annotated Bibliography", body: <draft>, position: "end" }).
6. For each cite key you used, also call imprint_add_citation({ id: "${a.documentId}", citeKey, bibtex }) so the .bib file picks them up.
7. Wait for operations to complete. Respond with the list of cite keys and a one-sentence take on the most interesting paper.`);

    case "new-manuscript":
      return asUser(`Create a new imprint manuscript titled "${a.title}" about: ${a.topic}.

Format: ${a.format ?? "typst"}

Procedure:
1. imprint_create_document({ title: "${escape(a.title)}" }) → note the returned documentId.
2. Add stub sections with a single-sentence placeholder body each, using imprint_create_section. Always 'end' position, level 1. In order:
   - "Abstract" — one sentence about the problem and approach
   - "Introduction"
   - "Methods"
   - "Results"
   - "Discussion"
   - "References"
3. (Optional) imbib_create_library({ name: "References: ${escape(a.title)}" }) and store the returned library id in the Abstract section as a \`// imbib-library: <uuid>\` HTML comment the user can find later.
4. imprint_wait_for_operation on each returned operationId to ensure all sections exist before responding.
5. Respond with the new documentId, the list of created section IDs, and the linked library UUID if any.`);

    case "summarize-cited":
      return asUser(`Synthesize background notes from every paper cited in imprint document \`${a.documentId}\`.

Style: ${a.style ?? "paragraph"}

Procedure:
1. imprint_get_bibliography({ id: "${a.documentId}" }) → the list of cite keys in use.
2. For each cite key:
   - imbib_get_paper({ citeKey }) — title, authors, year, abstract
   - imbib_get_notes({ citeKey }) — any markdown notes the user has taken
   - imbib_list_annotations({ citeKey }) — the user's highlights/quotes
3. Compose a "Background" section body synthesizing the above. In ${a.style === "bullets" ? "bullet form — one bullet per paper, quoting notable annotations" : "flowing prose — cite each paper with @citeKey, drawing connections between them"}.
4. imprint_create_section({ documentId: "${a.documentId}", title: "Background", body: <draft>, position: "after:<introductionSectionId>" if the document has an Introduction else "end" }).
5. Confirm completion via imprint_wait_for_operation. Respond with the new section id and a 2-sentence overview.`);

    default:
      return asUser(`Unknown prompt: ${name}`);
  }
}

// MARK: - Helpers

function asUser(text: string): PromptMessage[] {
  return [{ role: "user", content: { type: "text", text } }];
}

/** Minimal escaping for values we interpolate into prompt templates. */
function escape(s: string | undefined): string {
  if (!s) return "";
  return s.replace(/"/g, '\\"').replace(/\n/g, " ");
}
