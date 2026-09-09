---
layout: default
title: E-Ink Device Integration
---

# E-Ink Device Integration

imbib mirrors papers to a reMarkable over its USB cable and brings back what you wrote on them: the annotated pages, the highlights with their text, typed notes, and handwriting (recognised on your Mac). Supernote and Kindle Scribe keep their folder- and email-based paths.

---

## reMarkable over USB

The reMarkable's USB web interface is the one route that works with current firmware without a cloud account or developer mode. It can list folders, upload documents and download them; it cannot create folders, rename, move or delete. imbib is built on exactly that.

### Setup

1. On the tablet: **Settings › Storage › USB web interface** → on. Plug it in.
2. In imbib: **Settings › E-Ink** → **Add reMarkable (USB)**. The connection dot turns green when the tablet answers at `10.11.99.1`.
3. On the tablet, create a folder named **imbib** at the top level. That is the one folder imbib needs you to make: the USB interface has no way to create folders, and imbib will not scatter papers among your own documents. Sub-folders are optional — see *Where papers land*.

If the dot stays grey while the cable is in, macOS may have reset the app's Local Network permission after an update: **System Settings › Privacy & Security › Local Network** → imbib off and on again.

### Two ways to choose what goes over

| Mode | What is mirrored | What the list shows |
|------|------------------|---------------------|
| **Only papers I choose** | papers you mark | a marker beside the star: queued / awaiting PDF / awaiting folder / on tablet / stale / removed on tablet / failed |
| **Mirror everything with a PDF or ePUB** | every paper that has a local PDF or ePUB | nothing extra |

In the individual mode, mark a paper with **`e`** in the list, **Control+Command+E**, the context menu (**Mirror to reMarkable**), or the swipe action on iOS. Marking a paper that has no PDF yet makes imbib fetch one (publisher, arXiv, ADS) and send it as soon as it arrives; until then the marker reads *awaiting PDF*. ePUBs are sent when attached; imbib does not fetch them.

### Where papers land

`imbib / <Library> / <Collection> / <Sub-collection>` on the tablet mirrors your sidebar. A paper filed in several collections goes to the first in alphabetical order (the tablet cannot hold aliases). Uncollected papers go to `imbib / <Library>`; the Inbox is left out unless you switch it on. Documents are named `Family Year – Title`.

A folder the tablet does not have is not a dead end. The paper goes into the deepest folder on its path that does exist — usually `imbib` itself — and the Info tab says where it belongs. Make that folder on the tablet whenever you like and drag the document in: the next sync notices the move and stops mentioning it. The pane's **missing-folders checklist** lists every folder still missing, parents first, and **Check again** re-reads the tablet.

The one thing that does stop a paper is a missing **imbib** folder, since the alternative would be dropping papers in among your own documents. The row then says exactly that, and the counters call it *awaiting folder*. If you would rather papers wait for their exact folder every time, turn off **File in the nearest folder that exists** in the E-Ink pane.

### Nothing is re-sent silently

- A PDF you replace locally marks the tablet copy **stale**; **Update on tablet** (Info tab) sends the new one.
- A copy you delete on the tablet shows as **removed on tablet**; **Send again** re-uploads it.
- Removing the mark keeps the copy on the tablet (nothing can delete over USB); the checklist tells you what to remove by hand.

### Sync

Syncs run when the tablet is plugged in, when you mark papers, when a fetched PDF arrives, and when you press **Sync now** — never in the first 90 seconds after launch unless you ask. Every step is logged under the `eink` category in the console.

---

## What comes back

Annotate on the tablet: highlight with the text-snapping highlighter, type with the keyboard, write with the pen. On the next sync (or **Paper › Import reMarkable Annotations**) imbib pulls each changed document back:

| On the tablet | In imbib |
|---------------|----------|
| The page with your handwriting drawn in | a second file, **reMarkable — annotated**, beside the original in the Files list (the original stays the one that opens) |
| Text-snapping highlight | a highlight annotation on the original PDF with the highlighted text |
| Typed text | a note annotation with the text |
| Handwriting | an ink annotation with a rendering; handwriting recognition runs on your Mac afterwards and fills in the text with a confidence |

Everything appears in the **Notes tab › reMarkable** section and in search. **Append reMarkable notes** adds one dated block of highlights and notes to the paper's Notes field; it never happens on its own, and the same tablet snapshot is not appended twice.

### Notebooks and documents you added on the tablet

**Paper › Import from reMarkable…** lists what the tablet holds that imbib did not put there:

- A **notebook inside an imbib collection folder** becomes a publication in that collection, with the rendered pages as its PDF and your typed text and handwriting as annotations. Write more later: the next sync refreshes it.
- A **PDF or ePUB copied in by hand** whose bytes match a file already in your library is adopted by that paper — the copy becomes its mirrored one, and its annotations come in.
- Anything else becomes a new entry (from the first page's text, or the tablet's name) in the library you choose, or a **note** in the research capture store.

---

## Supernote and Kindle Scribe

| Device | Sync method | Capabilities |
|--------|-------------|--------------|
| **Supernote** | Folder sync (Dropbox or USB mount) | upload PDFs, read `.note` and `.mark` annotation files |
| **Kindle Scribe** | USB, or Send-to-Kindle email (upload only) | upload PDFs, extract annotations embedded in the PDF |

Add them under **Settings › E-Ink**; the folder and email settings are unchanged.

---

## Agents and the command line

Everything above is also a verb. From the terminal (`imbib eink-status`, `eink-mark`, `eink-sync`, `eink-plan`, `eink-folder-checklist`, `eink-import`, `eink-list-unmatched`, `eink-import-document`, `eink-list-annotations`, `eink-search-annotations`, `eink-append-notes`, …) and as MCP tools (`imbib-eink-service_eink-*`), working against the shared store with the app closed — a headless sync uploads and imports just the same. The one thing only the running app can do is fetch a missing PDF; the CLI reports those papers as *awaiting source*.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Grey dot, cable in | USB web interface off, or Local Network permission reset | turn the interface on in the tablet's Storage settings; toggle imbib under Privacy & Security › Local Network |
| *Awaiting folder* | there is no **imbib** folder on the tablet (nothing else holds a paper back) | create it on the tablet, then **Check again** |
| *Filed in a parent folder* | the collection's folder is missing, so the paper went to the nearest one | create the folder from the checklist and drag the document in — the next sync follows it |
| *Awaiting PDF* | no local PDF and none found online — the Info tab gives the reason the last attempt failed | attach one by hand (drop it on the paper); the next sync sends it |
| A paper shows as `Name.pdf` on the tablet | the device is set to bare uploads | keep **Upload format: archive** (the default) |
| No handwriting text | recognition has not run yet | it runs after each import and 90 s after launch; **Import annotations now** re-triggers it |
| Dot went grey on its own | the tablet went to sleep or the cable came out | nothing to do — imbib checks less and less often (up to every five minutes) and comes back the instant the cable is plugged in, which it notices immediately |
| A sync stopped partway | the tablet slept mid-pass | the pass ends within a few seconds rather than hanging; press **Sync now** once it is awake, and anything not sent is still marked |

---

## See Also

- [Features Overview](features) - Complete feature list
- [Getting Started](getting-started) - Initial setup guide
- [Keyboard Shortcuts](keyboard-shortcuts) - All shortcuts
