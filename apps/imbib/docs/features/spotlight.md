---
layout: default
title: Spotlight Integration
---

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

Spotlight indexes the following fields for each paper:

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
| **Year** | Papers are dated by publication year |

---

## Searching with Spotlight

### macOS

1. Press **Cmd+Space** to open Spotlight
2. Type your search (title, author, etc.)
3. Look for results under the imbib section
4. Click a result to open the paper in imbib

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
| `arXiv 2401` | Papers from arXiv in January 2024 |
| `hawking black hole` | Papers by Hawking about black holes |

---

## How Indexing Works

### Automatic Indexing

Papers are indexed automatically when:

- Added to your library (import, Quick Lookup, Save from browser)
- Metadata is updated or enriched
- Synced from another device via iCloud

### Manual Reindexing

If Spotlight search isn't finding papers it should:

1. Go to **Settings > Advanced**
2. Click **Rebuild Spotlight Index**
3. Wait for indexing to complete (may take a few minutes for large libraries)

### Batch Indexing

For large imports, imbib batches Spotlight updates in groups of 100 to avoid overwhelming the system.

---

## Privacy & Security

### What Spotlight Sees

Spotlight indexes **metadata only**:
- Paper title, authors, abstract
- Identifiers (DOI, arXiv ID, bibcode)
- Publication info (journal, year)

Spotlight does **not** index:
- PDF content (full text)
- Your private notes
- Reading history or positions
- Inbox papers (until archived to library)

### Data Location

- Index data is stored in the system Spotlight index
- Controlled by macOS/iOS, not imbib
- Follows system privacy settings
- Encrypted with device encryption

### Enterprise/MDM

If your organization manages your device:
- Spotlight indexing follows MDM policies
- Index may be disabled by IT policy
- Contact your IT department for restrictions

---

## Troubleshooting

### Papers Not Appearing in Spotlight

1. **Wait for indexing** - New papers may take a few seconds to index
2. **Check sync** - Ensure iCloud sync is complete
3. **Rebuild index** - Settings > Advanced > Rebuild Spotlight Index
4. **Check system Spotlight** - Ensure imbib isn't excluded in System Settings

### Excluding imbib from Spotlight (if desired)

**macOS:**
1. System Settings > Siri & Spotlight
2. Scroll to "Search Results"
3. Uncheck imbib

**iOS:**
1. Settings > Siri & Search
2. Find imbib
3. Disable "Show App in Search" and "Show Content in Search"

### Stale Results After Delete

If deleted papers still appear:
1. The Spotlight index updates asynchronously
2. Wait a few moments and search again
3. If persistent, rebuild the Spotlight index

---

## Deep Linking

When you click a Spotlight result, imbib:

1. Receives a deep link with the paper's UUID
2. Opens directly to that paper
3. Shows the paper's detail view

The deep link format is:
```
imbib://paper/{uuid}
```

This also works from other apps that support URL schemes.

---

## Platform Differences

| Feature | macOS | iOS |
|---------|-------|-----|
| Cmd+Space search | Yes | N/A |
| Swipe-down search | N/A | Yes |
| PDF content search | Via Finder | No |
| Siri suggestions | Yes | Yes |
| App Shortcuts integration | Yes | Yes |

---

## Related Features

- **Quick Search (Cmd+Shift+O)** - Search within imbib
- **Smart Searches** - Saved queries with auto-refresh
- **Siri Shortcuts** - Voice-activated paper access

---

## See Also

- [macOS Guide](../platform/macos-guide) - Desktop-specific features
- [iOS Guide](../platform/ios-guide) - Mobile-specific features
- [Siri Shortcuts](siri-shortcuts) - Voice and automation
