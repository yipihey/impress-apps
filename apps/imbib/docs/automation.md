---
layout: default
title: Automation API
---

# Automation API

imBib provides a URL scheme API for external control, enabling integration with scripts, AI assistants, and other tools.

---

## Overview

The automation API allows external programs to:
- Search for papers
- Navigate the interface
- Control paper selection and actions
- Trigger PDF viewer commands
- Import and export data

### Security

The API is **disabled by default**. Enable it in:
**Settings → General → Enable automation API**

Optionally enable logging to debug integration issues:
**Settings → General → Log automation requests**

---

## URL Scheme

### Format

```
imbib://<command>/<subcommand>?param1=value1&param2=value2
```

### Invoking from Terminal

```bash
open "imbib://search?query=dark+matter"
```

### Invoking from AppleScript

```applescript
open location "imbib://navigate/inbox"
```

### Invoking from Python

```python
import subprocess
subprocess.run(["open", "imbib://paper/Einstein1905/open-pdf"])
```

---

## Commands Reference

### Search

Execute searches across online databases.

```
imbib://search?query=<query>&source=<source>&max=<number>
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `query` | Yes | Search query (URL-encoded) |
| `source` | No | Source ID: `ads`, `arxiv`, `crossref`, `semantic-scholar`, `openalex`, `dblp` |
| `max` | No | Maximum results (default: 50) |

**Examples:**
```
imbib://search?query=author%3A%22Smith%22%20AND%20year%3A2024
imbib://search?query=exoplanets&source=ads&max=100
imbib://search-category?category=astro-ph.EP
```

---

### Navigation

Navigate to specific views in the interface.

```
imbib://navigate/<target>
```

| Target | Description |
|--------|-------------|
| `library` | Default library |
| `inbox` | Inbox view |
| `search` | Search results |
| `pdf-tab` | PDF tab in detail |
| `bibtex-tab` | BibTeX tab in detail |
| `notes-tab` | Notes tab in detail |

**With parameters:**
```
imbib://navigate/library?id=<library-uuid>
imbib://navigate/collection?id=<collection-uuid>
imbib://navigate/smart-search?id=<smart-search-uuid>
```

---

### Focus

Move keyboard focus to interface areas.

```
imbib://focus/<target>
```

| Target | Description |
|--------|-------------|
| `sidebar` | Sidebar navigation |
| `list` | Paper list |
| `detail` | Detail view |
| `search` | Search field |

---

### Paper Actions

Actions on a specific paper identified by cite key.

```
imbib://paper/<cite-key>/<action>
```

| Action | Description |
|--------|-------------|
| `open` | Select paper in list |
| `open-pdf` | Open PDF in viewer |
| `open-notes` | Open notes tab |
| `open-references` | Show references |
| `toggle-read` | Toggle read status |
| `mark-read` | Mark as read |
| `mark-unread` | Mark as unread |
| `delete` | Delete paper |
| `copy-bibtex` | Copy BibTeX to clipboard |
| `copy-citation` | Copy formatted citation |
| `copy-identifier` | Copy DOI/arXiv ID |
| `share` | Open share sheet |

**With parameters:**
```
imbib://paper/Smith2024/archive?library=<library-uuid>
imbib://paper/Jones2023/add-to-collection?collection=<collection-uuid>
imbib://paper/Jones2023/remove-from-collection?collection=<collection-uuid>
```

---

### Selected Papers

Actions on currently selected papers in the list.

```
imbib://selected/<action>
```

| Action | Description |
|--------|-------------|
| `open` | Open selected papers |
| `toggle-read` | Toggle read status |
| `mark-read` | Mark as read |
| `mark-unread` | Mark as unread |
| `mark-all-read` | Mark all in current view as read |
| `delete` | Delete selected |
| `archive` | Archive to library |
| `copy` | Copy BibTeX |
| `cut` | Cut (for paste/move) |
| `share` | Share selected |
| `copy-citation` | Copy formatted citation |
| `copy-identifier` | Copy identifier |

---

### Library Actions

Actions on libraries.

```
imbib://library/<action>?id=<library-uuid>
```

| Action | Description |
|--------|-------------|
| `show` | Navigate to library |
| `refresh` | Refresh library contents |
| `create` | Create new library |
| `delete` | Delete library |

---

### Collection Actions

Actions on collections.

```
imbib://collection/<collection-uuid>/<action>
```

| Action | Description |
|--------|-------------|
| `show` | Navigate to collection |
| `add-selected` | Add selected papers |
| `remove-selected` | Remove selected papers |

---

### Inbox Actions

Actions for inbox triage.

```
imbib://inbox/<action>
```

| Action | Description |
|--------|-------------|
| `show` | Navigate to inbox |
| `archive` | Archive current selection |
| `dismiss` | Dismiss current selection |
| `toggle-star` | Toggle star on selection |
| `mark-read` | Mark as read |
| `mark-unread` | Mark as unread |
| `next` | Move to next item |
| `previous` | Move to previous item |
| `open` | Open current item |

---

### PDF Actions

Control the PDF viewer.

```
imbib://pdf/<action>
imbib://pdf/go-to-page?page=<number>
```

| Action | Description |
|--------|-------------|
| `page-down` | Next page |
| `page-up` | Previous page |
| `zoom-in` | Increase zoom |
| `zoom-out` | Decrease zoom |
| `actual-size` | 100% zoom |
| `fit-to-window` | Fit page in window |
| `go-to-page?page=N` | Jump to page N |

---

### App Actions

General application actions.

```
imbib://app/<action>
```

| Action | Description |
|--------|-------------|
| `refresh` | Refresh current view |
| `toggle-sidebar` | Show/hide sidebar |
| `toggle-detail-pane` | Show/hide detail |
| `toggle-unread-filter` | Toggle unread filter |
| `toggle-pdf-filter` | Toggle PDF filter |
| `show-keyboard-shortcuts` | Show shortcuts window |

---

### Import

Import BibTeX or RIS data.

```
imbib://import/bibtex?file=<path>&library=<library-uuid>
imbib://import/ris?file=<path>&library=<library-uuid>
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `file` | Yes | Path to file (URL-encoded) |
| `library` | No | Target library UUID |

---

### Export

Export library data.

```
imbib://export?library=<library-uuid>&format=<format>
```

| Format | Description |
|--------|-------------|
| `bibtex` | BibTeX format |
| `ris` | RIS format |
| `csv` | CSV format |
| `markdown` | Markdown format |
| `html` | HTML format |

---

## CLI Tool

A command-line interface is available for terminal workflows.

### Installation

The CLI is bundled with imBib. Add to your path:

```bash
alias imbib="/Applications/imBib.app/Contents/MacOS/imbib-cli"
```

### Usage

```bash
imbib <command> [arguments] [options]
```

### Commands

```bash
# Search
imbib search "dark matter" --source ads --max 100

# Navigation
imbib navigate inbox
imbib navigate library --id <uuid>
imbib focus search

# Paper actions
imbib paper Einstein1905 open-pdf
imbib paper Smith2024 toggle-read
imbib paper Jones2023 copy-bibtex

# Selected papers
imbib selected toggle-read
imbib selected delete
imbib selected copy

# Inbox
imbib inbox archive
imbib inbox next

# PDF viewer
imbib pdf page-down
imbib pdf go-to-page 42
imbib pdf zoom-in

# App
imbib app refresh
imbib app toggle-sidebar

# Import/Export
imbib import bibtex /path/to/file.bib
imbib export --format bibtex --library <uuid>

# Raw URL
imbib raw "imbib://search?query=test"
```

---

## Integration Examples

### Alfred Workflow

Create an Alfred workflow to search ADS:

1. Create new workflow
2. Add Keyword input: `ads {query}`
3. Add Run Script action:
   ```bash
   open "imbib://search?query={query}&source=ads"
   ```

### Raycast Extension

```typescript
import { open } from "@raycast/api";

export default async function Command(props: { arguments: { query: string } }) {
  await open(`imbib://search?query=${encodeURIComponent(props.arguments.query)}`);
}
```

### Shell Script: Add DOI to Library

```bash
#!/bin/bash
# add-doi.sh - Add a paper by DOI
DOI=$1
open "imbib://search?query=doi:${DOI}&source=crossref"
```

### Python: Batch Import

```python
#!/usr/bin/env python3
import subprocess
import urllib.parse

def add_paper(query, source="ads"):
    url = f"imbib://search?query={urllib.parse.quote(query)}&source={source}"
    subprocess.run(["open", url])

# Add papers from a list
papers = [
    "2024ApJ...123..456S",
    "2024MNRAS.789..012J",
]

for bibcode in papers:
    add_paper(f"bibcode:{bibcode}")
```

### AI Assistant Integration

Example system prompt for an AI assistant:

```
You can search for academic papers using imBib. To search:
- Use: open "imbib://search?query=<url-encoded-query>&source=ads"

Available sources: ads, arxiv, crossref, semantic-scholar

Example:
User: Find papers about dark matter halos from 2024
Assistant: Searching ADS...
[executes: open "imbib://search?query=dark+matter+halos+year%3A2024&source=ads"]
```

---

## Troubleshooting

### API Not Responding

1. Verify automation is enabled in Settings → General
2. Check Console.app for imBib logs
3. Enable logging in Settings for debugging

### URL Encoding Issues

All special characters must be URL-encoded:
- Space: `%20` or `+`
- Colon: `%3A`
- Quote: `%22`

Use `encodeURIComponent()` in JavaScript or `urllib.parse.quote()` in Python.

### Finding UUIDs

Library and collection UUIDs can be found:
1. Right-click item in sidebar → Copy UUID
2. Check the console log output
3. Export library metadata

---

## API Versioning

The current API version is **1.0**. Breaking changes will increment the major version.

Future versions may support:
- JSON response format
- Batch operations
- WebSocket subscriptions
