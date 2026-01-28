---
layout: default
title: Siri Shortcuts
---

# Siri Shortcuts

imbib integrates with Apple's Shortcuts app and Siri, allowing you to automate paper management with voice commands and custom workflows.

---

## Getting Started

### Enabling Siri Shortcuts

Siri Shortcuts require the Automation API to be enabled:

1. Open **Settings > General**
2. Enable **Automation API**
3. Your shortcuts will now work

### Finding imbib Shortcuts

1. Open the **Shortcuts** app
2. Tap the **+** button to create a new shortcut
3. Search for "imbib" in the actions list
4. All available intents appear under the imbib category

---

## Available Shortcuts

### Search & Discovery

#### Search Papers
Search for papers across scientific databases.

**Parameters:**
- **Query** (required): Search terms, author names, or identifiers
- **Source**: Where to search (All, My Library, arXiv, ADS, Crossref, etc.)
- **Max Results**: Limit number of results (default: 20)

**Returns:** List of papers with title, authors, year, and identifiers

**Example phrases:**
- "Search imbib for papers"
- "Find papers in imbib"

**Shortcut example:**
```
Search Papers
  Query: "dark matter halos"
  Source: NASA ADS
  Max Results: 10
For each paper in results:
  Show paper title
```

#### Search My Library
Search your local paper library.

**Parameters:**
- **Query** (required): Title, author, or cite key
- **Max Results**: Limit number of results
- **Unread Only**: Filter to only unread papers

**Returns:** Matching papers from your library

**Example phrases:**
- "Search my imbib library"
- "Find papers in my imbib library"

#### Search Online Databases
Search external sources like ADS, arXiv, and Crossref.

**Parameters:**
- **Query** (required): Search query
- **Source**: Specific database or all sources
- **Max Results**: Limit number of results

#### Search arXiv Category
Search recent papers in a specific arXiv category.

**Parameters:**
- **Category** (required): arXiv category (e.g., `astro-ph.CO`, `hep-th`, `cs.AI`)

---

### Adding Papers

#### Add Paper by DOI
Import a paper using its Digital Object Identifier.

**Parameters:**
- **DOI** (required): The DOI (e.g., `10.1038/nature12373`)

**Example phrases:**
- "Add paper by DOI to imbib"
- "Import DOI to imbib"

**Shortcut example:**
```
Ask for Input: "Enter DOI"
Add Paper by DOI
  DOI: [Input]
```

#### Add Paper by arXiv
Import a paper using its arXiv identifier.

**Parameters:**
- **arXiv ID** (required): The arXiv ID (e.g., `2401.12345` or `hep-th/9905111`)

**Example phrases:**
- "Add arXiv paper to imbib"
- "Import arXiv paper to imbib"

---

### Navigation

#### Show Inbox
Open the imbib inbox to triage new papers.

**Example phrases:**
- "Show my imbib inbox"
- "Open imbib inbox"
- "Check imbib inbox"

#### Show Library
Open your paper library.

**Example phrases:**
- "Show my imbib library"
- "Open imbib library"
- "Show my papers in imbib"

#### Show Search
Open the search view.

---

### Paper Actions

#### Mark All as Read
Mark all papers in the current view as read.

**Example phrases:**
- "Mark all papers as read in imbib"
- "Mark everything read in imbib"

#### Toggle Read Status
Toggle the read/unread status of selected papers.

#### Mark as Read / Mark as Unread
Set the read status of selected papers.

#### Copy BibTeX
Copy BibTeX entries for selected papers to the clipboard.

#### Copy Citation
Copy formatted citations for selected papers.

#### Copy Identifier
Copy DOI or arXiv ID for selected papers.

#### Keep to Library
Move selected papers from inbox to your library.

#### Delete Selected Papers
Remove selected papers from your library.

#### Share Papers
Share selected papers via the system share sheet.

---

### Utility

#### Refresh Data
Sync and refresh imbib data.

**Example phrases:**
- "Refresh imbib"
- "Sync imbib"
- "Update imbib data"

---

## Building Workflows

### Morning Paper Routine

Create a shortcut that runs each morning:

```
Show Inbox in imbib
Wait 2 seconds
Get papers from Inbox (limit: 5)
For each paper:
  Speak "New paper: [title] by [first author]"
```

### Quick Add from Clipboard

Add a paper from a DOI or arXiv ID on your clipboard:

```
Get Clipboard
If clipboard contains "10."
  Add Paper by DOI
    DOI: [Clipboard]
Otherwise if clipboard contains "arXiv" or matches "\d{4}\.\d+"
  Add Paper by arXiv
    arXiv ID: [Clipboard]
Otherwise
  Show Alert "No valid identifier found"
```

### Weekly Reading Report

Generate a summary of papers you've read:

```
Search My Library
  Query: ""
  Unread Only: false
Filter papers where date added is in last 7 days
Count items
Show Result: "You read [count] papers this week"
```

### Save Paper from Safari

When browsing a paper, use Share Sheet to trigger:

```
Receive URL from Share Sheet
Extract DOI from URL (using regex)
If DOI found:
  Add Paper by DOI
    DOI: [extracted DOI]
  Show Notification "Paper added to imbib"
```

---

## Siri Voice Commands

After running a shortcut once, Siri learns the phrase. You can also add custom phrases:

1. Open **Shortcuts** app
2. Long-press your shortcut
3. Tap **Add to Siri**
4. Record a custom phrase

### Suggested Phrases

| Shortcut | Suggested Phrase |
|----------|------------------|
| Search Papers | "Search for papers" |
| Show Inbox | "Check my reading inbox" |
| Add Paper by DOI | "Import this paper" |
| Refresh Data | "Sync my papers" |
| Mark All Read | "Clear my reading list" |

---

## Automation Examples

### Time-Based

Run daily at 8 AM to check for new papers:

```
Automation: Time of Day (8:00 AM)
Actions:
  Refresh Data in imbib
  Search Papers (your Smart Search query)
  If count > 0:
    Show Notification "[count] new papers today"
```

### Location-Based

When arriving at your office:

```
Automation: Arrive at [Office Location]
Actions:
  Show Inbox in imbib
```

### Focus Mode

When entering Reading focus mode:

```
Automation: Focus Mode turns on (Reading)
Actions:
  Show Library in imbib
```

---

## Working with Paper Data

Shortcuts can process the paper data returned by search intents:

### Paper Entity Fields

Each paper returned includes:
- **id**: Unique identifier
- **title**: Paper title
- **authors**: Author list
- **year**: Publication year
- **citeKey**: Citation key
- **doi**: DOI if available
- **arxivID**: arXiv ID if available
- **abstract**: Paper abstract
- **venue**: Journal or conference

### Filtering Results

```
Search Papers
  Query: "machine learning"
  Source: arXiv
  Max Results: 50
Filter where year equals 2024
Filter where authors contains "Smith"
Get first 5 items
```

### Exporting Data

```
Search My Library
  Query: "reviewed"
For each paper:
  Append "[citeKey]: [title]" to note
Save note to Files
```

---

## Troubleshooting

### Shortcuts Not Appearing

1. Ensure imbib is installed from the App Store (not a development build)
2. Verify iOS/macOS version is 16.0+ / 13.0+
3. Restart the Shortcuts app
4. Restart your device if needed

### "Automation Disabled" Error

Enable the automation API in imbib:
1. Open **Settings > General**
2. Toggle **Enable automation API** on

### Shortcuts Time Out

For searches with many results:
- Reduce **Max Results** parameter
- Use more specific queries
- Ensure good network connection

### Paper Not Found

If "Paper not found" errors occur:
- Verify the cite key is correct (case-sensitive)
- Check that the paper exists in your library
- Refresh the library before running the shortcut

---

## Platform Differences

| Feature | iOS | macOS |
|---------|-----|-------|
| Voice commands | Siri | Siri |
| Shortcuts app | Full support | Full support |
| Automation triggers | Time, Location, Focus, App | Time, Focus, App |
| Widget integration | Yes | Yes |
| Background execution | Limited | Full |

---

## See Also

- [Automation API](../automation) - URL scheme for scripting
- [Keyboard Shortcuts](../keyboard-shortcuts) - Quick access from keyboard
