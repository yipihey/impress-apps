# reMarkable fixtures

Captured from Tom's reMarkable Paper Pro over the USB web interface on
2026-09-07 (firmware 3.x) with `cargo run -p impress-remarkable --example
usb_spike`. They pin what the tablet actually sends, not what its client
bundle suggests.

| File | What it is |
|---|---|
| `usb/root_listing.json` | `GET /documents/` verbatim: every entry carries BOTH `VisibleName` and `VissibleName` (the historical typo); `CurrentPage` is an int, `ModifiedClient` ISO 8601. |
| `usb/folder_listing.json` | `GET /documents/{folderId}` for the "Books" folder. |
| `content/pdf_document.content.json` | `.content` of an imported, unannotated PDF: `formatVersion 1`, `pages` + `redirectionPageMap`, `zoomMode bestFit`, `customZoomPageWidth/Height 1404×1872` (rM2 units even on a Paper Pro). |
| `content/notebook.content.json`, `content/notebook.metadata.json` | A 26-page notebook's `.content`/`.metadata`. |
| `rm/notebook_page_v5.rm` (+ `-metadata.json`) | One page of that notebook: `reMarkable .lines file, version=5` — old notebooks stay v5 after a firmware upgrade, so the parser needs v5 and v6. |
| `calibration/calibration.pdf` | One page with `CALIBRATION` at (100, 700) and `SCALE` at (400, 120) in PDF points, 24 pt Helvetica; the coordinate-mapping fixture once annotated on the tablet. |

## What the P0 spike established

* `POST /upload` files the document in the folder that was listed last;
  the tablet assigns the id.
* Uploading a **folder** archive (`type: CollectionType`) creates a
  *notebook document*, not a folder — there is no way to create folders
  over USB. The engine's folder strategy is therefore `checklist`.
* Uploading a **document** archive: its `id` and `parent` are ignored, its
  `visibleName` is honoured. A bare PDF upload is named after the file and
  the tablet appends `.pdf` when the name has no extension — so the engine
  wraps uploads in an archive to get exact names (`upload_format = rmdoc`).
* `GET /download/{id}/rmdoc` returns a zip of `<id>.metadata`,
  `<id>.content`, `<id>.pagedata`, `<id>/<page>.rm`,
  `<id>/<page>-metadata.json` (and the source `<id>.pdf` for imported
  documents); `GET /download/{id}/pdf` is the rendition with handwriting
  drawn in.
