---
layout: default
title: Share Extension
---

# Share Extension

The imbib Share Extension lets you save papers from Safari, Chrome, and other apps directly to your library or inbox.

---

## Overview

When browsing paper pages on arXiv, ADS, journals, or any site with paper metadata, use the Share Extension to:

- Import papers with one tap
- Automatically extract metadata (title, authors, DOI, abstract)
- Download PDFs when available
- Choose destination library or send to Inbox

---

## Enabling the Extension

### iOS

1. Open Safari and navigate to any paper page
2. Tap the **Share** button (square with arrow)
3. Scroll the app row and tap **More**
4. Find **imbib** and toggle it **on**
5. Optionally drag imbib higher for easier access
6. Tap **Done**

### macOS

1. Open Safari and navigate to any paper page
2. Click the **Share** button in toolbar (or **File > Share**)
3. Select **More...**
4. Find **imbib** in the Extensions list
5. Check the box to enable
6. Click **Done**

---

## Using the Extension

### From Safari

1. Navigate to a paper page (ADS, arXiv, journal, DOI resolver)
2. Click/tap the **Share** button
3. Select **imbib**
4. Review the extracted metadata
5. Choose destination:
   - **Inbox**: For later triage
   - **Library**: Add to specific library
6. Tap **Save**

### From Other Apps

The extension works with any app that shares URLs:

- Chrome, Firefox, Edge
- PDF viewers
- Mail (sharing paper links)
- Notes
- Reference emails

Just share the URL to imbib using the standard share sheet.

---

## Metadata Extraction

The extension automatically detects papers from:

### Supported Sources

| Source | Detection Method |
|--------|------------------|
| NASA ADS | URL pattern (`ui.adsabs.harvard.edu/abs/...`) |
| arXiv | URL pattern (`arxiv.org/abs/...`) |
| DOI.org | DOI resolution (`doi.org/10.xxxx/...`) |
| PubMed | URL pattern (`pubmed.ncbi.nlm.nih.gov/...`) |
| Journals | Highwire meta tags |
| General | Dublin Core, Open Graph, schema.org |

### Extracted Fields

Depending on the source, the extension captures:

- Title
- Authors
- Abstract
- Publication year
- Journal/venue
- DOI
- arXiv ID
- PDF URL

### Enrichment

After saving, imbib can fetch additional metadata:
- Missing fields from other sources
- Citation counts
- Full abstract
- Related papers

---

## PDF Handling

### Automatic Download

When the extension detects a PDF URL:
1. PDF download starts automatically
2. Progress appears in the extension sheet
3. PDF attaches to the paper record

### Manual PDF Later

If no PDF is found initially:
1. Save the paper metadata first
2. Open the paper in imbib
3. Use **Download PDF** to fetch later
4. Or drag a PDF onto the paper

### Institutional Access

For paywalled PDFs:
1. Ensure you're logged into your institution
2. Share from the authenticated page
3. Or configure library proxy in **Settings > PDF**

---

## Browser-Specific Extensions

### Chrome Extension

For enhanced Chrome integration:

1. Download the extension from `imbib/imbibBrowserExtension/`
2. Open `chrome://extensions/`
3. Enable **Developer mode**
4. Click **Load unpacked**
5. Select the extension folder

**Features:**
- Toolbar icon shows import status
- One-click import without share sheet
- Keyboard shortcut support

### Firefox Extension

1. Open `about:debugging#/runtime/this-firefox`
2. Click **Load Temporary Add-on**
3. Select the extension's `manifest.json`

### Edge Extension

Same process as Chrome—Edge supports Chrome extensions.

### Requirements

Browser extensions require:
- imbib running on the same machine
- Automation API enabled in Settings

---

## Sharing PDFs

### From Files App

1. Find a PDF in Files
2. Share to imbib
3. Metadata is extracted from PDF content
4. Paper is created with the PDF attached

### From Mail Attachments

1. Long-press (iOS) or right-click (macOS) the PDF attachment
2. Select **Share**
3. Choose imbib
4. Metadata extraction is attempted

### From Other PDF Apps

Any app that shares PDFs can send to imbib:
- PDF Expert
- Preview
- GoodNotes
- Notability

---

## Customization

### Default Destination

Set where papers go by default:

1. Open imbib **Settings > Import**
2. Choose default destination:
   - **Ask each time**: Always show chooser
   - **Inbox**: Send to inbox for triage
   - **Library [name]**: Specific library

### Auto-Import Options

Configure automatic behavior:

| Setting | Description |
|---------|-------------|
| Auto-download PDF | Start PDF download immediately |
| Enrich after import | Fetch additional metadata |
| Mark as unread | Set read status on import |
| Deduplicate | Check for existing copies |

---

## Troubleshooting

### Extension Not Appearing

**iOS:**
1. Check it's enabled in Share settings
2. Try sharing from Safari first
3. Restart your device
4. Reinstall imbib

**macOS:**
1. Check Extensions in System Settings
2. Verify imbib has necessary permissions
3. Restart Safari

### "No Paper Detected"

1. Ensure you're on a paper page (not search results)
2. Try the abstract page, not the PDF
3. Check if the site is supported
4. Report unsupported sites for future support

### Metadata Incorrect

1. Review and edit before saving
2. Report extraction issues
3. Edit in imbib after import
4. Refresh metadata from imbib

### PDF Not Downloading

1. Check internet connection
2. Verify the PDF isn't paywalled
3. Configure library proxy if needed
4. Download manually in imbib later

### Extension Times Out

1. Ensure good network connection
2. Try with a simpler page
3. Use "Save without PDF" option
4. Import metadata only, add PDF later

---

## Privacy

### What Data is Accessed

The extension:
- Reads the current page URL
- Reads page HTML for metadata
- Sends extracted data to imbib app
- Does not send data to external servers

### Permissions

The extension requires:
- "Read current page" to extract metadata
- "Communicate with imbib" to save papers

No tracking, analytics, or external connections.

---

## Platform Comparison

| Feature | iOS Safari | macOS Safari | Chrome |
|---------|------------|--------------|--------|
| Share sheet | Yes | Yes | Yes |
| Toolbar icon | No | No | Yes |
| Keyboard shortcut | No | No | Yes |
| Background import | No | Yes | Yes |
| Multiple tabs | No | Yes | Yes |

---

## See Also

- [Getting Started](../getting-started) - First steps with imbib
- [Automation API](../automation) - URL scheme for scripting
- [Siri Shortcuts](siri-shortcuts) - Voice and automation commands
