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

The current source IDs are recorded in
[knowledge/vw/sources.json](../knowledge/vw/sources.json). Source text is in the
`extracted_unreviewed` state. Search may guide a reviewer or provide clearly
labelled source context, but it must not be promoted into a diagnostic rule,
threshold, or procedure step without verification against the page image and
vehicle applicability.

The LLM may translate conversation into typed commands and explain results. It
must not invent facts, measurements, citations, rules, applicability, or bypass
procedure state.
