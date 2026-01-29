# Spotlight Integration

Find your papers instantly using macOS and iOS system Spotlight search.

---

## Overview

imbib indexes your entire library for Spotlight, allowing you to:

- Search papers from anywhere on your Mac (Cmd+Space)
- Find papers on iOS via swipe-down search
- Jump directly to papers without opening imbib first
- Search by title, author, keywords, or identifiers

---

## What Gets Indexed

| Field | Example Search |
|-------|----------------|
| **Title** | "dark matter halos" |
| **Authors** | "Einstein" or "Hawking, Stephen" |
| **Abstract** | Keywords from the abstract |
| **Cite key** | "Einstein1905" |
| **DOI** | "10.1038/nature12345" |
| **arXiv ID** | "2401.12345" |
| **Bibcode** | "2024ApJ..." |
| **Journal** | "Nature" or "ApJ" |

---

## Searching with Spotlight

### macOS

1. Press **Cmd+Space** to open Spotlight
2. Type your search (title, author, etc.)
3. Look for results under the imbib section
4. Click a result to open the paper

### iOS

1. Swipe down from the middle of the Home Screen
2. Type your search
3. Tap an imbib result to open it

### Search Examples

| Query | Finds |
|-------|-------|
| `dark matter` | Papers with "dark matter" in title/abstract |
| `Einstein 1905` | Papers by Einstein from 1905 |
| `10.1038/nature` | Papers with this DOI prefix |
| `hawking black hole` | Papers by Hawking about black holes |

---

## How Indexing Works

Papers are indexed automatically when:

- Added to your library
- Metadata is updated or enriched
- Synced from another device via iCloud

### Manual Reindexing

If Spotlight search isn't finding papers:

1. Go to **Settings > Advanced**
2. Click **Rebuild Spotlight Index**
3. Wait for indexing to complete

---

## Privacy

Spotlight indexes **metadata only**:
- Paper title, authors, abstract
- Identifiers (DOI, arXiv ID, bibcode)

Spotlight does **not** index:
- PDF content (full text)
- Your private notes
- Reading history

---

## Troubleshooting

### Papers Not Appearing

1. **Wait for indexing** - New papers may take a few seconds
2. **Check sync** - Ensure iCloud sync is complete
3. **Rebuild index** - Settings > Advanced > Rebuild Spotlight Index

### Excluding from Spotlight

**macOS:** System Settings > Siri & Spotlight > Uncheck imbib

**iOS:** Settings > Siri & Search > imbib > Disable search options
