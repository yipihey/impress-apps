# ADR-025: Mirroring papers to a reMarkable over USB, and importing what comes back

**Status:** Accepted (supersedes ADR-019 for reMarkable)
**Date:** 2026-09-07

## Context

ADR-019 designed the reMarkable integration around the cloud API and a
Core Data model. Neither survived: reMarkable closed its document endpoints
to third-party clients (every `sync/v3` transfer call answers 410 "update
this application"), the store moved to the unified item graph, and the
Swift layer that was built against ADR-019 never worked end to end — the
"Send to E-Ink Device" button, menu item and context-menu entry posted
notifications nobody observed, the one upload path lived in a view that
was never mounted, and sync state was smuggled into undeclared payload keys
(`_remarkable_*`) that no list row could read.

Tom's tablet is a Paper Pro. The only transport it offers without a
credential or Developer mode (which erases a Paper Pro) is its **USB web
interface** at `http://10.11.99.1`. Its whole API, read from the tablet's
own client bundle and confirmed live on 2026-09-07:

| Endpoint | Behaviour |
|---|---|
| `GET /documents/`, `GET /documents/{folderId}` | One folder's entries; every entry carries the name under both `VisibleName` and the historical typo `VissibleName` |
| `POST /upload` (`.pdf`, `.epub`, `.rmdoc`) | Files the document in **whatever folder was listed last**; the tablet assigns the id |
| `GET /download/{id}/pdf` | The page images with the handwriting drawn in |
| `GET /download/{id}/rmdoc` | The raw archive: `.metadata`, `.content`, the source file, one `.rm` stroke file per page |
| create / rename / move / delete | **Do not exist** |

The P0 spike (uploading hand-built archives) settled the open questions:

* A folder archive (`type: CollectionType`) is imported as an **empty
  notebook**, not a folder. Folders can only be created on the device.
* A document archive's `id` and `parent` are ignored; its `visibleName`
  is honoured. A bare PDF upload is shown as `<file>.pdf` (the tablet
  appends the extension when the name lacks one).
* With `zoomMode: bestFit` the Paper Pro fits the page **width** into a
  frame of 1853.5 scene units (3.115 units per point for A4); stroke x is
  measured from the page's centre line and y from the top, growing down.
* Old notebooks stay `.lines` version 5 after a firmware upgrade; new
  pages are version 6.

## Decision

1. **Rust owns the integration.** The transport (`impress-remarkable::
   usb_web`), the archive and stroke formats (`rmdoc`, `rm`), the mirror
   engine (`imbib-core::eink`: planner, executor, import) and the verbs
   (`imbib-eink-service`, generating the MCP tools, CLI subcommands and
   impel tools) are Rust. Swift is a projection: list-row marker, Settings
   pane, detail section, the PDF-acquisition and connection-monitor glue
   that needs platform APIs, and Vision OCR.
2. **State is store records.** `imbib/eink-device` (one per tablet: mode,
   root folder, options, last sync) and `imbib/eink-mirror` (one per
   device × publication, parent = the publication: state, remote id and
   folder, uploaded hash, import stamps). No payload keys on the
   publication, no device-local file: the rows are what the CLI, the MCP
   server and the list rows all read, and a second Mac that plugs in the
   same tablet inherits the truth about it.
3. **Two mirror modes.** `individual` mirrors marked papers and shows a
   marker in the list (`BibliographyRow.eink_state`, computed in Rust and
   `None` otherwise); `all` mirrors every paper with a local PDF/ePUB and
   shows no marker.
4. **Folders are the user's.** Papers are filed under
   `imbib/<Library>/<Collection>/<Sub-collection>`; Settings shows the
   exact folders the tablet lacks, parents first, because only the user
   can create one (see decision 10 for what happens meanwhile).
5. **Uploads are archives.** Every paper goes up wrapped in an `.rmdoc`
   whose `visibleName` is `"{Family} {Year} – {Title}"`, so the tablet
   shows exact names; the id the tablet assigns is learned from the
   listing taken right after the upload. List → upload → list runs under
   a per-device lock.
6. **Nothing is re-sent silently.** A changed local file marks the row
   `stale`; a copy deleted on the tablet marks it `removed_on_device`;
   un-marking an uploaded paper marks it `unmarked`. Each is a visible
   state with an explicit "send again".
7. **Import is idempotent.** The rendered PDF becomes a second linked file
   (`role = eink-annotated`, replaced in place). The archive's stroke files
   become `imbib/annotation` rows on the primary file — highlights with
   their text, typed text as notes, handwriting as ink groups with a
   rendered PNG for the Vision OCR pass — with ids derived from the
   tablet's own item ids, so a re-import updates, and OCR text survives
   unchanged strokes. Notes are appended to the paper's Notes field only
   on an explicit action, once per tablet snapshot.
8. **A marked paper without a file waits.** Rows sit in `awaiting_source`
   until the running app fetches the PDF; the CLI and MCP report them.
9. **What the tablet authored comes in on request.** The sync walks the
   whole tablet, so a mirrored paper moved to another folder is followed,
   not tombstoned, and every document no mirror row accounts for is
   offered (`eink-list-unmatched`, in-tree first, with the library and
   collection its folder names resolve to). `eink-import-document` files
   a notebook as a `@misc` publication in that collection with the
   rendered PDF as its primary file (refreshed in place on later imports,
   since the linked file remembers which tablet document it is); adopts
   an existing publication when a copied PDF/ePUB hashes to one of its
   files; makes a new entry from the first page's text otherwise; or, as
   `note`, writes an `impress/artifact/note` with the typed text and
   leaves the document offered. Nothing is imported without being asked.

10. **A missing folder does not stop the paper (2026-09-08, revises 4).**
   The original rule — never upload to a fallback folder, because nothing
   can be moved afterwards — held every paper of a library called
   `ULDM State & Coherence — references` behind a folder name nobody wants
   to type on a tablet. The tablet cannot be told to make one: its bundle
   issues one `GET /documents/…` and one `POST /upload` with a single
   `file` field, and that is the entire write surface. So by default
   (`file_in_nearest_folder`, on) a paper goes into the deepest folder on
   its path that does exist, keeps `desired_path` on its mirror row, and
   says so in the Info section. The root folder is the floor: with no
   `imbib` on the tablet the paper still waits, and the row names that one
   folder to create — papers are never scattered among the user's own
   documents. Since the sync walks the whole tablet, dragging the document
   into the right folder is followed and clears `desired_path` by itself;
   nothing is re-uploaded to correct a placement. Setting
   `file_in_nearest_folder: false` restores the waiting behaviour.
11. **A failed fetch says why.** `eink-note-source-error` writes the
   reason onto an `awaiting_source` row (attempts, last attempt, message).
   Only something that can download knows — the engine never can — so
   without it the row's dead end was invisible once the log scrolled away.

## Consequences

* `_remarkable_*` payload keys, `RemarkableSyncManager`,
  `RemarkableSyncScheduler` and the unmounted reMarkable views are retired.
* `schema-refs.json` gains `imbib/eink-device` and `imbib/eink-mirror`
  (72 canonical refs). Both later took additive fields —
  `file_in_nearest_folder` on the device, `desired_path` on the mirror —
  which cost the manifest nothing.
* The engine is Tier-A tested against a scripted tablet (`tests/
  eink_end_to_end.rs`, `tests/eink_import.rs`, `tests/eink_documents.rs`);
  the formats against fixtures captured from the Paper Pro
  (`crates/impress-remarkable/tests/fixtures`). The notebook page frame
  (`PageFrame::notebook`, 1620 units for the Paper Pro screen) is the one
  geometric assumption without a fixture; only ink-row placement on a
  tablet-authored page depends on it.
* Cloud and SFTP transports remain in the crate for other devices; the
  USB path is the one imbib configures by default.
