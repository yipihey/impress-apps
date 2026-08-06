# ADR-0025: Source-Backed Typst Presentation Storyboard

**Status:** Accepted
**Date:** 2026-08-02
**Depends on:** ADR-0016 (Throughline)
**Scope:** `crates/imprint-core`, `crates/imprint-service`, imprint's manuscript side-panel system, and the throughline anchor ledger

## Context

Typst is an excellent presentation substrate, but rearranging a talk by editing
source blocks does not provide the spatial overview of Keynote or PowerPoint.
Imprint needs a graphical storyboard without introducing a second document
model that can drift from the Typst file. It should also express the talk's
narrative structure using the throughline rather than reducing the storyboard
to a flat page sorter.

## Decision

### D1. Explicit slide blocks are the structural contract

A graphically reorderable slide is an ordinary Typst call with a stable ID:

```typst
#slide(
  id: "evidence",
  beat: "tl-result",
  title: "The evidence",
)[
  // ordinary Typst content
]
```

- `id` is required, non-empty, and unique within the source. It is durable
  identity and must not be regenerated when the slide moves.
- `beat` is optional and names a stable `<tl-…>` paragraph label in the
  document's throughline. An empty value means unassigned.
- `title` is optional display metadata. It does not define identity.
- The project's theme remains free to define the `slide` function and all
  rendering details. Imprint owns only this small call-site convention.

The parser deliberately rejects malformed blocks and duplicate IDs. It ignores
lookalikes in comments and strings and handles nested Typst delimiters. When it
cannot prove a safe structural edit, the storyboard becomes read-only and shows
the diagnostic instead of guessing.

### D2. Typst source is the only slide-order authority

Graphical reordering moves complete `#slide(…)[…]` source spans. There is no
parallel order array, page database, or generated ordering metadata. Undo,
autosave, git diffs, compilation, CLI use, and agent use therefore observe the
same change immediately.

The preamble and suffix stay byte-for-byte intact. Inter-slide whitespace and
comments travel with the preceding slide block. Compiled SVG pages are display
projections matched to slide blocks by source order; a page-count mismatch is
shown as a transient compile diagnostic and never changes the source model.

### D3. The throughline supplies the storyboard's narrative lanes

Slides are grouped under throughline paragraphs in narrative order. Dropping a
slide into a lane performs one source-buffer mutation that both moves the block
and sets its `beat`. Dropping into **Unassigned** clears the association.
Unknown labels remain visible as repairable lanes, so a renamed throughline
label never makes slides disappear.

Dragging a throughline lane before another lane does two related operations:

1. moves the labeled paragraph in `throughline.typ`; and
2. moves that lane's slide blocks as a stable group in `main.typ`.

The throughline remains authoritative for narrative order under ADR-0016. A
lane move therefore records order drift as `throughline-ahead`, entering the
existing human review workflow rather than silently rewriting anchored
manuscript sections.

### D4. Accepted narrative order is part of the anchor baseline

The version-1 anchor ledger gains an additive, backward-compatible field:

```json
"narrative_order": {
  "tl-claim": 0,
  "tl-result": 1
}
```

Content-hash drift and order drift are independently derived. Either makes the
throughline side ahead. Legacy ledgers without this field do not report false
drift; their current order is baselined at the next explicit human anchor,
accepted sync, or reorder action.

### D5. The same structural operations are agent-native

`ImprintManuscriptService` exposes three generated capabilities:

- `presentation_outline(source)` returns stable slide metadata and spans;
- `reorder_presentation_slide(source, slide_id, before_slide_id)` returns the
  complete updated source; an empty target moves to the end; and
- `set_presentation_slide_beat(source, slide_id, beat)` assigns or clears the
  throughline association.

These methods are declared once with `#[impress_method]`, so MCP, CLI, and impel
receive the same capability and validation as the native storyboard. No agent
scrapes thumbnails or edits an app-specific ordering store.

### D6. The interaction remains keyboard-complete

Slide cards are focusable buttons that jump to the source block. Each card has
named **Move earlier** and **Move later** actions in addition to drag and drop.
The side panel participates in the existing manuscript panel keyboard and
accessibility model; it introduces no unguarded character shortcuts or modal
dialog.

## Consequences

- A presentation theme must emit one compiled page per explicit slide block
  for thumbnail-to-slide parity.
- Existing free-form Typst decks remain editable and compilable but are not
  graphically reorderable until their pages adopt stable slide blocks.
- Source diffs remain meaningful and portable outside Imprint.
- Throughline-less decks still get a flat Unassigned storyboard and can adopt a
  throughline later without migration.

