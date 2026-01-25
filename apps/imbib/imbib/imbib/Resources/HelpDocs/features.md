---
layout: default
title: Features
---

# Features

Comprehensive documentation of all imBib features.

---

## Libraries

### Multiple Libraries

Organize references into separate libraries for different projects:

- Each library has its own `.bib` file and `Papers/` folder
- Switch between libraries via the sidebar
- Move or copy papers between libraries

### Library Structure

Each library contains:
- **All Publications**: Every paper in the library
- **Unread**: Papers you haven't marked as read
- **Smart Searches**: Saved queries specific to this library
- **Collections**: Manual folders for organization

### Creating Libraries

1. Click **+** at the bottom of the sidebar
2. Select **New Library**
3. Choose a storage location
4. Name your library

### Library Settings

Right-click a library to access:
- Rename
- Show in Finder
- Delete (with confirmation)

---

## Search

### Unified Search Interface

Search multiple databases simultaneously from a single search bar.

### Supported Sources

| Source | Content | API Key Required |
|--------|---------|------------------|
| NASA ADS | Astronomy, physics, geoscience | Yes (free) |
| arXiv | Preprints across all fields | No |
| Crossref | Published papers via DOI | No |
| Semantic Scholar | CS, biomedicine with citations | No |
| OpenAlex | Comprehensive academic database | No |
| DBLP | Computer science venues | No |

### Query Syntax

#### Basic Search
Type keywords to search across all fields:
```
dark matter halos
```

#### Field-Specific Search

| Field | ADS Syntax | arXiv Syntax |
|-------|-----------|--------------|
| Author | `author:"Smith, John"` | `au:Smith` |
| Title | `title:exoplanet` | `ti:exoplanet` |
| Abstract | `abs:machine learning` | `abs:machine learning` |
| Year | `year:2024` | — |
| arXiv ID | `arxiv:2401.12345` | `2401.12345` |
| DOI | `doi:10.1038/...` | — |
| Bibcode | `bibcode:2024ApJ...` | — |

#### Boolean Operators

```
author:"Smith" AND title:galaxy
title:exoplanet OR title:"extrasolar planet"
author:"Jones" NOT year:2020
```

#### Date Ranges (ADS)

```
pubdate:[2020 TO 2024]
pubdate:2024-01
```

### Deduplication

When searching multiple sources, imBib automatically deduplicates results:

1. **Identifier matching**: DOI, arXiv ID, bibcode, Semantic Scholar ID
2. **Fuzzy matching**: Title + first author for papers without shared IDs

The best metadata is kept from each source.

### Search History

Recent searches are saved and accessible via:
- The search dropdown
- Keyboard: `Cmd-Shift-F` cycles through history

---

## Smart Searches

Smart Searches are saved queries that execute automatically.

### Visual Query Builder

Build queries without memorizing syntax:

1. Select source (ADS or arXiv)
2. Add conditions (Author, Title, Year, etc.)
3. Choose match type (All conditions / Any condition)
4. View the generated raw query

### Raw Query Editing

For complex queries, edit the raw query directly:

1. Expand "Raw Query" in the editor
2. Modify the query text
3. The visual builder syncs when possible

### Auto-Refresh

Smart Searches can refresh automatically:

- **Hourly**: For fast-moving fields
- **Daily**: Recommended for most use cases
- **Weekly**: For broader searches

### Inbox Integration

When "Feed to Inbox" is enabled:
1. New papers matching the search go to Inbox
2. Papers you've already seen are not re-added
3. Triage with Star/Archive/Dismiss

---

## Inbox

The Inbox is your paper triage center.

### How Papers Arrive

Papers enter your Inbox from:
- Smart Searches with "Feed to Inbox" enabled
- Share extension from Safari or other apps
- Manual "Send to Inbox" action

### Triage Actions

| Action | Shortcut | Result |
|--------|----------|--------|
| Star | `S` | Mark as important, keep in Inbox |
| Archive | `A` | Add to library, remove from Inbox |
| Dismiss | `D` | Remove without saving |

### Batch Triage

Select multiple papers and apply actions to all:
- `Cmd-A` selects all
- Actions apply to selection

---

## Collections

Collections are manual folders for organizing papers.

### Creating Collections

1. Right-click a library → **New Collection**
2. Or click **+** next to the library → **New Collection**

### Smart Collections (Coming Soon)

Rule-based collections that populate automatically:
- "All 2024 papers"
- "Papers with PDFs attached"
- "Unread papers from last month"

---

## Detail View

### Info Tab

Displays paper metadata in an email-style layout:

**Header**
- From: Authors
- Year: Publication year
- Subject: Title
- Venue: Journal or conference

**Identifiers**
- DOI (clickable)
- arXiv ID (clickable)
- ADS bibcode
- PubMed ID

**Abstract**
Full abstract with LaTeX math rendering.

**Attachments**
- List of linked files (PDFs, data, code)
- Drag files to attach
- Click to open, right-click for options

**Record Info**
- Cite key
- Entry type (article, book, etc.)
- Date added
- Read status
- Citation count (from OpenAlex)

### BibTeX Tab

View and edit the raw BibTeX entry.

**Features:**
- Syntax highlighting (entry types, fields, values)
- Real-time validation
- Error bar shows parse issues
- Edit mode with Save/Cancel

**Editing:**
1. Click **Edit**
2. Modify the BibTeX
3. Click **Save** or press `Cmd-S`

### PDF Tab

Built-in PDF viewer with full functionality.

**Controls:**
- Page navigation: Previous/Next, go to page
- Zoom: Fit width, fit page, percentage
- Search: Find text in document

**Reading Position:**
Your position is saved automatically:
- Page number
- Zoom level
- Last read timestamp

**No PDF Available:**
- **Download PDF**: Try online sources
- **Open in Browser**: Publisher authentication

### Notes Tab

Personal annotations for library papers.

- Rich text (Markdown-style)
- Saved automatically
- Not exported with BibTeX (private notes)

---

## PDF Management

### Storage Structure

PDFs are stored with human-readable names:
```
Papers/
├── Einstein_1905_SpecialRelativity.pdf
├── Hubble_1929_VelocityDistance.pdf
└── Hawking_1974_BlackHoleExplosions.pdf
```

### Filename Format

```
{FirstAuthorLastName}_{Year}_{TitleWords}.pdf
```

Special characters are sanitized for filesystem compatibility.

### PDF Sources

imBib tries sources in order based on your settings:

**Preprint First (Default):**
1. arXiv (if available)
2. Publisher via DOI

**Publisher First:**
1. Publisher via DOI
2. arXiv fallback

Configure in **Settings → PDF**.

### Library Proxy

For institutional access, configure a proxy:

1. Go to **Settings → PDF**
2. Enable "Use library proxy"
3. Select your institution or enter custom URL
4. Prefix format: `https://proxy.university.edu/login?url=`

### PDF Browser

For PDFs requiring authentication:

1. Click **Open in Browser** in PDF tab
2. Navigate publisher login in the browser window
3. imBib detects and saves the PDF automatically
4. Browser closes after successful download

---

## Import & Export

### Import Formats

| Format | Extension | Notes |
|--------|-----------|-------|
| BibTeX | `.bib` | Full support including Bdsk-File-* |
| RIS | `.ris` | EndNote, Zotero, Mendeley |
| PDF | `.pdf` | Metadata extraction attempted |

### Import Methods

**File Menu:**
- **File → Import → BibTeX File...**
- **File → Import → RIS File...**

**Drag and Drop:**
- Drop files onto the paper list
- Drop PDFs onto papers to attach

**Quick Lookup:**
- `Cmd-Shift-L` → Enter DOI/arXiv/bibcode

### Export Formats

| Format | Use Case |
|--------|----------|
| BibTeX | LaTeX workflows |
| RIS | EndNote, Zotero, Mendeley |
| Plain Text | Simple reference lists |
| Markdown | Documentation |
| HTML | Web publishing |
| CSV | Spreadsheet analysis |

### Exporting

1. Select papers (or none for all)
2. **File → Export...**
3. Choose format and options
4. Save file

---

## Settings

### General

- **Show Inbox badge**: Notification count on sidebar
- **Confirm before delete**: Safety prompt
- **Automation API**: Enable URL scheme access

### Sources

Enable/disable search sources and configure API keys:

- NASA ADS: Requires API key (free from ADS)
- Other sources: No keys needed

### PDF

- **Source priority**: Preprint first or publisher first
- **Library proxy**: Institutional access URL

### Appearance

- Follows system dark/light mode
- Accent color customization

---

## Automation API

imBib supports URL schemes for external control.

### Enabling

1. Go to **Settings → General**
2. Enable **Automation API**
3. Optionally enable logging for debugging

### URL Format

```
imbib://<command>/<subcommand>?param=value
```

### Example Commands

```
imbib://search?query=dark+matter&source=ads
imbib://navigate/inbox
imbib://paper/Einstein1905/open-pdf
imbib://selected/toggle-read
```

### CLI Tool

A command-line interface is available:

```bash
imbib search "dark matter" --source ads
imbib navigate inbox
imbib selected toggle-read
```

[Full Automation Documentation →](automation)

---

## File Attachments

### Supported Files

Attach any file type to papers:
- PDFs (primary)
- Code files (.py, .R, .jl, .ipynb)
- Data files (.csv, .fits, .hdf5)
- Archives (.tar.gz, .zip)
- Images (.png, .jpg)

### Attaching Files

**Drag and Drop:**
Drop files onto the Attachments section in Info tab.

**File Picker:**
Click **Add Files...** in Attachments section.

### BibTeX Compatibility

All attachments are exported as `Bdsk-File-*` fields:
- Compatible with BibDesk
- Preserves relative paths
- Round-trip safe

---

## Browser Extensions

Save papers directly from your browser while browsing academic sites.

### Safari Extension

Uses the native Share sheet for seamless integration:

1. Visit a paper page (ADS, arXiv, journal)
2. Click/tap the **Share** button
3. Select **imbib**
4. Review metadata and choose library
5. Click **Save**

**Installation (macOS):** System Settings → Privacy & Security → Extensions → Share Menu → Enable imbib

**Installation (iOS):** Share sheet → More → Enable imbib

### Chrome, Firefox & Edge Extension

Lightweight popup for one-click imports:

1. Visit a paper page
2. Click the **imbib** icon in toolbar
3. Review detected metadata
4. Click **Import**

**Requirements:** imbib must be running with Automation API enabled (Settings → General).

**Installation (Chrome/Edge):**
1. Go to `chrome://extensions/`
2. Enable Developer mode
3. Click "Load unpacked"
4. Select `imbib/imbibBrowserExtension/`

### Supported Sources

| Source | Recognition |
|--------|-------------|
| NASA ADS | Abstract pages (`ui.adsabs.harvard.edu/abs/...`) |
| arXiv | Abstract pages (`arxiv.org/abs/...`) |
| DOI | Resolver URLs (`doi.org/10.xxxx/...`) |
| PubMed | Article pages (`pubmed.ncbi.nlm.nih.gov/...`) |
| Journals | Embedded meta tags (Highwire, Dublin Core) |

[Full Browser Extensions Guide →](share-extension)

---

## Keyboard Shortcuts

imBib is designed for keyboard-first navigation.

[Full Keyboard Shortcuts Reference →](keyboard-shortcuts)

---

## iOS Companion App

imBib includes a full-featured iOS app for iPhone and iPad.

### Feature Parity

The iOS app shares the same core functionality as macOS:
- Full library browsing and search
- Smart Searches with auto-refresh
- Inbox triage (star, archive, dismiss)
- PDF viewing with reading position sync
- BibTeX viewing and editing
- Notes

### Sync

Your library syncs automatically between devices via iCloud:
- Papers, PDFs, and metadata
- Reading positions
- Smart Search results
- Inbox state

Changes made on any device appear everywhere within seconds.

### iOS-Specific Features

- **Share Extension**: Save papers from Safari, ADS, or arXiv directly to imBib
- **Spotlight Search**: Find papers via iOS system search
- **Widgets**: Quick access to Inbox count and recent papers
- **Handoff**: Continue reading on Mac where you left off on iPad

### Requirements

- iOS 17.0 or later
- iPhone or iPad
- iCloud account (for sync)

---

## Data & Privacy

### Local Storage

All data stays on your devices:

**macOS:**
- BibTeX files in your chosen locations
- PDFs in library `Papers/` folders
- Settings in `~/Library/Preferences/`

**iOS:**
- Data in app container
- Synced via iCloud (optional)

### No Cloud Required

imBib works fully offline. Online features:
- Search queries to ADS, arXiv, etc.
- PDF downloads from publishers
- iCloud sync (optional, for multi-device)
- Share extension (optional)

### Backup

Your library is plain files:
- Copy the library folder for backup
- Use Time Machine
- Sync via Dropbox/iCloud (folder-level)
