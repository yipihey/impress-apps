---
layout: default
title: Getting Started
---

# Getting Started

This guide walks you through setting up imBib and importing your first papers.

---

## Installation

1. Download the latest `.dmg` from [GitHub Releases](https://github.com/yipihey/imbib/releases)
2. Open the DMG and drag imBib to Applications
3. Right-click the app and select "Open" (required for unsigned beta builds)
4. Grant file access when prompted (needed for library storage)

---

## Creating Your First Library

On first launch, imBib prompts you to create a library.

1. Click **Create Library**
2. Choose a folder for your library files
3. Enter a name (e.g., "Research", "Thesis", "Collaboration")
4. Click **Create**

imBib creates:
- A `.bib` file for your references
- A `Papers/` folder for PDFs and attachments

### Importing an Existing BibTeX Library

If you have an existing `.bib` file (from BibDesk, JabRef, or another manager):

1. Go to **File → Import → BibTeX File...**
2. Select your `.bib` file
3. Review the import preview
4. Click **Import**

Existing PDF links (including BibDesk's `Bdsk-File-*` fields) are preserved.

---

## The Interface

imBib uses a three-column layout:

```
┌──────────────┬─────────────────┬──────────────────────┐
│   Sidebar    │   Paper List    │   Detail View        │
│              │                 │                      │
│ • Inbox      │ Author, Title   │ Info / BibTeX / PDF  │
│ • Libraries  │ Year, Venue     │                      │
│ • Searches   │                 │                      │
└──────────────┴─────────────────┴──────────────────────┘
```

### Sidebar Sections

- **Inbox**: Papers from Smart Searches awaiting triage
- **Libraries**: Your reference libraries, each with:
  - All Publications
  - Unread papers
  - Smart Searches
  - Collections
- **SciX Libraries**: (Coming soon) NASA ADS private libraries
- **Search**: Ad-hoc searches and Smart Searches

### Paper List

Shows papers for the selected sidebar item. Features:
- Sort by title, author, year, date added, or read status
- Filter to unread only
- Multi-select with Shift/Cmd-click
- Drag to reorder or move between collections

### Detail View

Four tabs for the selected paper:
- **Info**: Authors, abstract, identifiers, attachments
- **BibTeX**: Raw entry with syntax highlighting
- **PDF**: Built-in viewer or download options
- **Notes**: Your annotations (library papers only)

---

## Searching for Papers

### Quick Search

1. Click the search field or press `Cmd-F`
2. Type your query (author names, keywords, arXiv IDs)
3. Press Enter to search

Results appear from enabled sources (ADS and arXiv by default).

### Advanced Search

Use field prefixes for precise queries:

| Prefix | Example | Matches |
|--------|---------|---------|
| `author:` | `author:"Einstein, A"` | Papers by Einstein |
| `title:` | `title:relativity` | Relativity in title |
| `year:` | `year:2024` | Papers from 2024 |
| `bibcode:` | `bibcode:2024ApJ...` | Specific ADS bibcode |
| `arxiv:` | `arxiv:2401.12345` | Specific arXiv paper |

Combine with AND/OR:
```
author:"Smith" AND year:2024
title:exoplanet OR title:planet
```

### Search Sources

Configure which databases to search in **Settings → Sources**:

| Source | Content | Notes |
|--------|---------|-------|
| **NASA ADS** | Astronomy, physics, arXiv | Requires free API key |
| **arXiv** | Preprints (all fields) | No key needed |
| **Crossref** | Published papers (all fields) | No key needed |
| **Semantic Scholar** | CS, biomedicine | No key needed |
| **OpenAlex** | All fields | No key needed |
| **DBLP** | Computer science | No key needed |

---

## Importing Papers

### From Search Results

1. Search for a paper
2. Click the paper in results
3. Click **Add to Library** or press `Cmd-Shift-I`
4. Choose the destination library

### By Identifier

1. Press `Cmd-Shift-L` (Quick Lookup)
2. Enter a DOI, arXiv ID, or bibcode
3. imBib fetches metadata and adds the paper

### From Files

Drag and drop onto imBib:
- `.bib` files: Parsed and imported
- `.ris` files: Converted to BibTeX and imported
- `.pdf` files: Metadata extracted if possible, or create blank entry

### From Safari (Share Extension)

Save papers while browsing:
1. Navigate to a paper page (ADS, arXiv, DOI, journal)
2. Click the **Share** button
3. Select **imBib**
4. Choose a destination library and save

[Full Share Extension Guide →](share-extension)

---

## Attaching PDFs

### Download from Source

For papers with available PDFs:
1. Select the paper
2. Go to the **PDF** tab
3. Click **Download PDF**

imBib tries arXiv first, then publisher sources.

### Manual Attachment

1. Select a paper
2. Drag a PDF onto the Info tab
3. Or click **Add Files...** in the Attachments section

PDFs are copied to your library's `Papers/` folder with readable names:
```
Einstein_1905_SpecialRelativity.pdf
```

### Publisher Authentication

Some PDFs require institutional access:
1. Click **Open in Browser** in the PDF tab
2. Log in through your institution
3. imBib detects and saves the PDF automatically

---

## Smart Searches

Smart Searches are saved queries that update automatically.

### Creating a Smart Search

1. Go to **File → New Smart Search** or click **+** in the sidebar
2. Enter a name (e.g., "Dark Matter 2024")
3. Build your query using the visual builder or raw text
4. Select sources to search
5. Click **Save**

### Inbox Feeding

Smart Searches can feed new papers to your Inbox:

1. Edit the Smart Search
2. Enable **Feed to Inbox**
3. Enable **Auto-Refresh** and set interval (hourly, daily, weekly)

New papers matching your search appear in Inbox for triage.

### Inbox Triage

Process Inbox papers efficiently:
- **Star** (`S`): Mark as important
- **Archive** (`A`): Move to library, out of Inbox
- **Dismiss** (`D`): Remove without adding to library

---

## Collections

Collections are manual folders within a library.

### Creating a Collection

1. Right-click a library in the sidebar
2. Select **New Collection**
3. Enter a name
4. Press Enter

### Adding Papers to Collections

- Drag papers from the list to a collection
- Or right-click papers → **Add to Collection**

Papers can belong to multiple collections.

---

## Keyboard Navigation

imBib is fully keyboard-driven. Essential shortcuts:

| Action | Shortcut |
|--------|----------|
| Search | `Cmd-F` |
| Quick Lookup | `Cmd-Shift-L` |
| Next paper | `↓` or `J` |
| Previous paper | `↑` or `K` |
| Open PDF | `Cmd-O` |
| Toggle read | `R` |
| Add to library | `Cmd-Shift-I` |

[Full Keyboard Shortcuts →](keyboard-shortcuts)

---

## Next Steps

- [Explore all features](features)
- [Learn keyboard shortcuts](keyboard-shortcuts)
- [Set up automation](automation)
- [Read the FAQ](faq)
