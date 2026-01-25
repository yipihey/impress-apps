---
layout: default
title: Browser Extensions
---

# Browser Extensions

Save papers to imbib directly from your web browser while browsing academic sites.

---

## Overview

imbib provides two ways to capture papers from your browser:

| Method | Browsers | Features |
|--------|----------|----------|
| **Safari Extension** | Safari (macOS/iOS) | Native Share sheet, library selection, duplicate detection |
| **Browser Extension** | Chrome, Firefox, Edge | Lightweight popup, one-click import |

Both methods extract metadata from academic pages and send papers directly to your imbib library.

---

## Safari Extension

The Safari Extension integrates with macOS and iOS Share sheets for seamless paper capture.

### Installation (macOS)

1. Open **System Settings**
2. Go to **Privacy & Security** → **Extensions** → **Share Menu**
3. Find **imbib** and enable it
4. The extension appears in Safari's Share menu

If imbib doesn't appear:
- Ensure imbib has been launched at least once
- Check that imbib is in `/Applications`
- Try restarting Safari

### Installation (iOS)

1. Open Safari and navigate to any webpage
2. Tap the **Share** button
3. Scroll the app row and tap **More**
4. Enable **imbib** in the list
5. Tap **Done**

### Using the Safari Extension

**From Safari (macOS):**

1. Navigate to a paper page (ADS, arXiv, journal, etc.)
2. Click the **Share** button in the toolbar (or **File → Share**)
3. Select **imbib**
4. Review the extracted metadata
5. Choose a destination library (optional)
6. Click **Save**

**From Safari (iOS):**

1. Navigate to a paper page
2. Tap the **Share** button
3. Tap **imbib** in the app row
4. Review the metadata
5. Tap **Save**

### Safari Extension Features

- **Library Selection**: Choose which library to save to
- **Duplicate Detection**: Shows if paper is already in your library
- **Offline Queue**: Papers are queued if you're offline and sync later
- **Background Import**: Metadata is fetched and enriched automatically

---

## Chrome, Firefox & Edge Extensions

The browser extension provides a lightweight popup for importing papers from Chromium-based browsers and Firefox.

### Installation (Chrome / Edge)

**From Source (Developer Mode):**

1. Download or clone the imbib repository
2. Open Chrome and go to `chrome://extensions/` (or `edge://extensions/`)
3. Enable **Developer mode** (toggle in top right)
4. Click **Load unpacked**
5. Select the folder: `imbib/imbibBrowserExtension/`
6. Pin the extension to your toolbar for easy access

**From Chrome Web Store:** *(Coming soon)*

### Installation (Firefox)

**From Source (Temporary):**

1. Open Firefox and go to `about:debugging#/runtime/this-firefox`
2. Click **Load Temporary Add-on**
3. Navigate to `imbib/imbibBrowserExtension/`
4. Select `manifest.json`

Note: Temporary add-ons are removed when Firefox restarts. For permanent installation, use the Firefox Add-ons store.

**From Firefox Add-ons:** *(Coming soon)*

### Using the Browser Extension

1. Navigate to a paper page (arXiv, ADS, PubMed, DOI, or any journal)
2. Click the **imbib** icon in your browser toolbar
3. The popup shows the detected paper metadata
4. Click **Import** to add to your library

The imbib app must be running to receive imports.

### Browser Extension Features

- **Automatic Detection**: Recognizes arXiv, ADS, PubMed, DOI pages
- **Embedded Metadata**: Falls back to page meta tags for other sites
- **One-Click Import**: Simple popup with Import button
- **Visual Feedback**: Shows success confirmation after import

### Requirements

- **imbib app must be running** on your Mac
- **Automation API must be enabled**: Settings → General → Enable automation API

The browser extension communicates with imbib via URL schemes (`imbib://import?...`), which requires the Automation API to be enabled.

---

## Supported Sites

Both extensions recognize papers from these sources:

| Source | URL Pattern | What's Extracted |
|--------|-------------|------------------|
| **NASA ADS** | `ui.adsabs.harvard.edu/abs/...` | Bibcode, title, authors, abstract, DOI, arXiv ID |
| **arXiv** | `arxiv.org/abs/...` | arXiv ID, title, authors, abstract, categories |
| **DOI** | `doi.org/10.xxxx/...` | DOI, resolved metadata |
| **PubMed** | `pubmed.ncbi.nlm.nih.gov/...` | PMID, title, authors, abstract, DOI |
| **Journals** | Various publisher sites | Embedded meta tags (Highwire, Dublin Core, Open Graph) |

### Page Type Detection

The extensions handle different page types:

- **Abstract pages**: Full metadata extraction
- **PDF pages**: Redirects to abstract page (arXiv)
- **Search results**: Shows message to click on a paper
- **Other pages**: Attempts embedded metadata extraction

---

## What Happens After Import

1. **Metadata Extraction**: The extension extracts available metadata from the page
2. **URL Scheme**: Data is sent to imbib via `imbib://import?...`
3. **Deduplication**: imbib checks for existing papers with same DOI/arXiv/bibcode
4. **Library Addition**: Paper is added to your default library
5. **Enrichment**: Background enrichment fetches additional metadata and PDF URLs
6. **PDF Queue**: Paper is queued for PDF download if available

---

## Tips

### Quick Access (iOS)

Move imbib to the front of your Share sheet:
1. Tap Share
2. Hold and drag the imbib icon left
3. It stays in that position

### Pin the Browser Extension

In Chrome/Edge, pin the extension for easy access:
1. Click the puzzle piece icon (Extensions)
2. Find imbib
3. Click the pin icon

### Batch Saving

Save multiple papers efficiently:
1. Open each paper in a new tab
2. Use the extension on each tab
3. Papers import in parallel

### Reload After Installing

Browser extensions inject content scripts on page load. After installing:
- **Reload** any open academic pages before using the extension
- Or open new tabs to visit papers

---

## Troubleshooting

### Extension Not Appearing (Safari)

**macOS:**
- Ensure imbib is in `/Applications`, not `~/Downloads`
- Launch imbib at least once
- Check System Settings → Extensions → Share Menu
- Restart Safari

**iOS:**
- Ensure imbib is installed (not just in TestFlight)
- Tap **More** in the Share sheet and enable imbib
- Restart Safari

### "No bibliographic data found" (Chrome/Firefox/Edge)

- **Reload the page** after installing the extension
- Make sure you're on an abstract page, not a PDF or search results
- Check the browser console (F12) for errors
- Verify the content script loaded: look for `imbib content script loaded`

### Import Not Working (Chrome/Firefox/Edge)

1. **Is imbib running?** The app must be open to receive imports
2. **Is Automation API enabled?** Go to imbib Settings → General → Enable automation API
3. **Check the URL scheme**: Try manually in Terminal:
   ```bash
   open "imbib://import?sourceType=arxiv&arxivID=2401.00001&title=Test"
   ```

### "URL Not Recognized"

The extension works best with:
- ADS abstract pages
- arXiv abstract pages
- DOI resolver URLs

For other pages, try:
- Navigate to the abstract page instead of PDF
- Use Quick Lookup in imbib with the DOI (`Cmd-Shift-L`)

### Paper Not Importing

If metadata isn't found:
- The paper may not be indexed by ADS/Crossref
- Try sharing the DOI resolver URL directly
- Import manually via Quick Lookup

### Duplicate Papers

imbib deduplicates by DOI, arXiv ID, and bibcode. If you see duplicates:
- The same paper may have different identifiers
- Check if it's the same paper with different metadata

---

## Building Extension Packages

To build distribution packages for the browser extension:

```bash
cd imbib/imbibBrowserExtension
./build-extensions.sh
```

This creates:
- `build/imbib-chrome.zip` - For Chrome Web Store and Edge Add-ons
- `build/imbib-firefox.zip` - For Firefox Add-ons

---

## Comparison: Safari vs Browser Extension

| Feature | Safari Extension | Chrome/Firefox/Edge |
|---------|------------------|---------------------|
| Library selection | Yes | No (uses default) |
| Duplicate detection | Yes | No |
| Import confirmation | Yes (native response) | Assumed success |
| Works offline | Yes (queues papers) | No (needs app running) |
| Native feel | Yes (Share sheet) | Popup window |
| Installation | System Settings | Developer mode or store |

The Safari extension offers more features because it uses native App Groups communication. The browser extension uses URL schemes which are fire-and-forget.

---

## Privacy

Both extensions:
- Only process pages you explicitly interact with
- Send queries to ADS/Crossref to fetch metadata
- Do not track browsing history
- Do not collect analytics
- Store no data externally

All data stays on your device (and iCloud if sync is enabled).
