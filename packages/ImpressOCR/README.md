# ImpressOCR

`ImpressOCR` is the reusable Apple-platform OCR adapter for Impress. It keeps
Vision and PDFKit details on the Swift side while emitting an engine-neutral,
reproducible index that the Rust source service can import.

## Responsibilities

- recognize a `CGImage` on-device with Apple Vision;
- render selected PDF pages with PDFKit at a recorded DPI;
- retain line text, confidence, and normalized lower-left-origin geometry;
- optionally recognize document structure with `RecognizeDocumentsRequest`;
- checkpoint every completed page as JSON for resumable long runs;
- build a portable SQLite/FTS5 index and extraction manifest;
- pin the source SHA-256, engine revision, OS version, languages, and settings.

The package does not define domain facts, citations, diagnostic rules, or
knowledge-pack publication policy. Those remain in the Rust source and domain
layers.

```mermaid
flowchart LR
    PDF[PDF or image] --> R[PDFKit page renderer]
    R --> V[Apple Vision]
    V --> C[Resumable page JSON]
    C --> I[Portable SQLite and FTS index]
    I --> S[Impress source service]
    S --> D[Domain knowledge and MCP]
```

## Library use

Use `AppleVisionOCR` for an existing `CGImage`, or `PDFOCRProcessor` for PDF
pages. Text mode is the production default because it provides stable
line-oriented observations and confidence. Document mode is available on the
package's macOS/iOS 26 deployment target for structural experiments.

`RemarkableOCRService` in PublicationManagerCore delegates to this package, so
Imbib and expert-system ingestion share one native Vision adapter.

## Command-line index build

From the repository root:

    swift run --package-path packages/ImpressOCR impress-ocr build \
      "/absolute/path/to/manual.pdf" \
      --output .local/manual-vision-index \
      --dpi 220 \
      --language en-US

Useful options include `--pages 1-10,462`, `--mode text|document`,
`--level accurate|fast`, repeatable `--custom-word`, and `--force`. The default
is one worker. Higher concurrency is opt-in because Vision framework behavior
varies with document shape and available memory; resumable page files contain
the blast radius of an interrupted run.

The output directory contains:

- `run.json`: compatible-run identity used to protect the page cache;
- `pages/NNNNNN.json`: one `OCRPageResult` per completed zero-based page;
- `index.sqlite3`: `pages`, `metadata`, and `pages_fts` tables;
- `manifest.json`: source coverage and exact extraction identity.

The database's `layout_json` contains the observations imported into
`ContentChunk.regions`. Consumers should use the chunk body for retrieval and
the observations for source review or page overlays; OCR geometry is evidence,
not a semantic table or figure model.

## Verification

    swift test --disable-sandbox --package-path packages/ImpressOCR

Vision's system service may be unavailable inside a restricted process
sandbox, so the test command explicitly disables SwiftPM's sandbox while the
OCR itself remains local and on-device.
