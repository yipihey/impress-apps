# VW knowledge packs

The checked-in bootstrap pack contains no mechanical facts, thresholds,
procedures, or rules. It exists to exercise the application safely before an
authoritative corpus is curated.

To build a real pack:

1. Import each original manual or image as an Impress artifact.
2. Record extraction runs and chunks through the generic source service.
3. Register precise, immutable-hash-pinned citations.
4. Author typed components, hypotheses, procedures, and rules referring to
   those citation UUIDs.
5. Mark executable knowledge published only after review.
6. Start the server with:

       cargo run -p vw-mcp -- \
         --knowledge-pack knowledge/vw/your-reviewed-pack.json

Pack activation fails if any citation ID is malformed, missing, not a
source-citation@1.0.0 item, or contains an invalid locator/hash. A pack ID and
version are immutable once persisted.

Synthetic mechanical rules belong only in tests. Do not use them in a pack
that may be presented to a user.

## Local corpus

`sources.json` is the checked-in catalog of admitted source bytes, authority,
rights notes, applicability boundaries, and review state. The PDFs, OCR
indexes, and `.local/vw-knowledge.sqlite` are intentionally ignored by git.

The reusable `impress-ocr` executable creates the current indexes locally with
PDFKit and Apple Vision. It checkpoints individual pages, so an interrupted run
can resume without repeating completed pages:

    swift run --package-path packages/ImpressOCR impress-ocr build \
      "/absolute/path/to/source.pdf" \
      --output .local/vw-corpus/source-vision-index \
      --dpi 220 \
      --language en-US

The `vw-knowledge-ingest` binary then validates that an OCR index covers every
PDF page and that its recorded source SHA-256 matches the actual bytes. It
creates deterministic source, extraction, citation, and content-chunk IDs and
retains any positioned text observations. An unchanged import is idempotent.

Import one indexed PDF with:

    cargo run -p vw-mcp --bin vw-knowledge-ingest -- \
      --store-path .local/vw-knowledge.sqlite \
      --source-pdf /absolute/path/to/source.pdf \
      --ocr-index /absolute/path/to/index.sqlite3 \
      --title "Source title" \
      --source-class manufacturer-manual \
      --publisher "Publisher" \
      --source-url https://example.invalid/original.pdf

The importer reads the engine, version, and profile from the index. The
`--extractor-version` option remains available only for older indexes that do
not carry their own engine metadata.

Run the searchable MCP server with:

    cargo run -p vw-mcp -- \
      --store-path .local/vw-knowledge.sqlite

The current database has 531 searchable page chunks, 531 matching page-level
citations, three extraction runs, and three source assets. Rebuild instructions
and exact source locations are maintained in
[VWImplementation.md](../../docs/VWImplementation.md).
