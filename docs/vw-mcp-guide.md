# VW diagnostic MCP guide

This server exposes typed semantic operations, not database access.

1. Call get-capabilities to inspect the active knowledge pack. The bootstrap
   pack deliberately has no mechanical rules until cited material is curated.
2. Call create-session with the exact vehicle configuration and a UUID
   command_id. Retrying that UUID returns the original session.
3. Record only user- or instrument-supplied observations and measurements.
   Measurements require units, acquisition context, and the current
   expected_revision.
4. Call evaluate-session or recommend-next-test. Results are deterministic,
   version-pinned, ordinal priorities—not probabilities.
5. Before starting a procedure, show every hazard and pass the explicitly
   acknowledged hazard IDs. Record only the current step.
6. Stop when vehicle configuration, source support, prerequisites, or safety
   conditions are incomplete.

## Source retrieval

Call `source-service_search-content-chunks` with a natural-language query, an
optional source item UUID, and a result limit. It returns compact OCR excerpts,
page labels, extraction lineage, and page-level citation UUIDs—not raw database
rows or whole manual pages. Resolve a chosen UUID with
`source-service_get-content-chunk` to read that one complete OCR page and its
normalized positioned text observations. Resolve its citation UUID with
`source-service_get-citation` before presenting it as evidence.

Search hits, chunks, and citations report compact `figures` and
`page_image_available` evidence metadata. Image bytes are never embedded in
search results. Call `source-service_get-figure-image` with a citation UUID and
printed figure label when the figure itself is useful; the result contains an
MCP image block plus source title, page label/index, immutable hashes, crop
coordinates, caption, and extraction lineage. Call
`source-service_get-page-image` for the complete cited page or surrounding
context. Page labels are resolved through stored source evidence and may differ
from physical page order.

During ingestion, a conservative shared Rust detector identifies anchored
figure/table captions from OCR geometry, then requires supporting rendered-page
pixels before storing a crop. It scores both sides of the caption, penalizes
OCR-heavy prose, refines the boundary to visible ink, and records its version,
confidence signals, geometry, and ambiguity warnings in a separate extraction
run. It does not infer a crop from OCR text order alone. Manually curated
regions remain provenance-preserving corrections and take precedence over an
automatic region for the same page and label.

Only a stored extracted or manually curated figure region is cropped. If the
signals remain weak or ambiguous, `get-figure-image` says so and returns the
complete cited page as an explicitly marked `page_fallback`; it never silently
guesses a figure boundary. Diagnostic mode can only read images. Adding or
correcting a figure region requires the server's curation profile.

The optional local validation script
`crates/vw-mcp/scripts/validate-local-figures.sh` exercises service-manual
figures 4-3, 4-4, and 4-5 by their page citations, plus complete PDF page 467,
through MCP stdio. This also avoids ambiguity when a manual reuses a figure
label in another chapter. It reads the user's local manual asset and never
writes or redistributes manual page images.

The current source IDs are recorded in
[knowledge/vw/sources.json](../knowledge/vw/sources.json). Source text is in the
`extracted_unreviewed` state. Search may guide a reviewer or provide clearly
labelled source context, but it must not be promoted into a diagnostic rule,
threshold, or procedure step without verification against the page image and
vehicle applicability.

The LLM may translate conversation into typed commands and explain results. It
must not invent facts, measurements, citations, rules, applicability, or bypass
procedure state.
