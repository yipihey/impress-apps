---
layout: default
title: FAQ
---

# FAQ & Troubleshooting

Common questions and solutions for imBib.

---

## General

### What is imBib?

imBib is a reference manager for macOS designed for researchers who use BibTeX. It combines local library management with unified search across academic databases like NASA ADS, arXiv, Crossref, and more.

### Is imBib free?

Yes. imBib is free and open source under the MIT license.

### Does imBib require an internet connection?

No. Your library works fully offline. Internet is needed only for:
- Searching online databases
- Downloading PDFs from publishers
- (Optional) Syncing via iCloud

### What happened to my data from the previous version?

imBib stores data in standard formats:
- **BibTeX**: Your `.bib` files are plain text
- **PDFs**: Stored with readable names in `Papers/` folders
- **Settings**: In `~/Library/Preferences/`

If upgrading from a beta, your data should migrate automatically. If not, import your `.bib` files manually.

---

## Libraries & Files

### Where are my papers stored?

Each library consists of:
```
YourLibrary/
├── library.bib      # BibTeX references
└── Papers/          # PDFs and attachments
    ├── Einstein_1905_Special.pdf
    └── Hawking_1974_BlackHole.pdf
```

The location is whatever folder you chose when creating the library.

### Can I use my existing BibDesk library?

Yes. imBib is fully compatible with BibDesk:
- Import your `.bib` file directly
- `Bdsk-File-*` fields are preserved
- Existing PDF links work without modification

### Can papers belong to multiple libraries?

Yes. Papers can be added to multiple libraries simultaneously. Use right-click → "Add to Library" or drag to a library in the sidebar.

### Can papers belong to multiple collections?

Yes. Collections are like email labels—a paper can be in many collections at once.

### How do I move papers between libraries?

Right-click the paper → "Add to Library" → select target. The paper is now in both libraries. To remove from the original, right-click → "Remove from Library".

### What file formats can I attach?

Any file type:
- PDFs (primary)
- Code (.py, .R, .jl, .ipynb)
- Data (.csv, .fits, .hdf5)
- Archives (.tar.gz, .zip)
- Images (.png, .jpg)

All attachments are stored as `Bdsk-File-*` fields for BibDesk compatibility.

---

## Search & Import

### How do I get an ADS API key?

1. Create a free account at [NASA ADS](https://ui.adsabs.harvard.edu/)
2. Go to Account → Settings → API Token
3. Copy the token
4. Paste in imBib: Settings → Sources → NASA ADS → API Key

### Why are some search results duplicated?

imBib deduplicates across sources automatically. If you see duplicates:
- The sources may have different metadata (no shared DOI/arXiv)
- Check if one result has a PDF and the other doesn't

### Can I search by arXiv ID directly?

Yes. In the search field, enter:
- `arxiv:2401.12345` for ADS
- Just `2401.12345` for arXiv source

Or use Quick Lookup (`Cmd-Shift-L`) and paste the full arXiv URL.

### How do I import from Zotero/Mendeley?

Export from Zotero/Mendeley as:
- **BibTeX** (.bib): File → Import → BibTeX File
- **RIS** (.ris): File → Import → RIS File

Both formats are fully supported.

### Why does Quick Lookup fail for some DOIs?

Some DOIs are:
- Not indexed by Crossref yet (very new papers)
- From publishers not in Crossref (some books)
- Malformed or mistyped

Try searching by title instead.

---

## PDFs

### How do I download PDFs automatically?

imBib tries to download PDFs automatically from:
1. arXiv (for preprints)
2. Publisher sites (via DOI)

Configure priority in Settings → PDF → Source Priority.

### Why can't imBib download a specific PDF?

Common reasons:
- **Paywalled**: Requires institutional access
- **No open access**: No arXiv version exists
- **Embargo**: Recently published, not yet available

Use "Open in Browser" to authenticate through your institution.

### How does the PDF browser work?

1. Click "Open in Browser" in the PDF tab
2. Navigate to the publisher and log in
3. imBib detects when a PDF starts downloading
4. The PDF is automatically saved and linked

Your login cookies persist, so subsequent downloads may work without re-authentication.

### How do I set up my library proxy?

1. Go to Settings → PDF
2. Enable "Use library proxy"
3. Select your institution or enter custom URL
4. Format: `https://proxy.university.edu/login?url=`

The proxy URL is prepended to publisher URLs.

### Can I view PDFs in an external app?

Yes. `Cmd-Shift-O` opens the PDF in your default PDF viewer (Preview, PDF Expert, etc.).

---

## Smart Searches

### What's the difference between Smart Search and regular search?

| Regular Search | Smart Search |
|----------------|--------------|
| One-time query | Saved query |
| Results disappear | Results persist |
| Manual refresh | Auto-refresh option |
| No inbox integration | Can feed to Inbox |

### How often do Smart Searches refresh?

If auto-refresh is enabled:
- **Hourly**: Every 60 minutes while app is open
- **Daily**: Once per day (recommended)
- **Weekly**: Once per week

Refresh happens in the background.

### Why aren't new papers appearing in my Inbox?

Check that:
1. Smart Search has "Feed to Inbox" enabled
2. Auto-refresh is enabled
3. New papers match the query
4. Papers aren't already in your library (duplicates are filtered)

### Can I manually refresh a Smart Search?

Yes. Select the Smart Search and press `Cmd-R` or click the refresh button in the toolbar.

---

## BibTeX

### How do I edit a BibTeX entry?

1. Select the paper
2. Go to the BibTeX tab
3. Click "Edit"
4. Modify the entry
5. Click "Save" or press `Cmd-S`

### What if I make a syntax error?

The editor validates as you type. Errors appear in a bar below the editor. Save is disabled until errors are fixed.

### Are custom BibTeX fields preserved?

Yes. imBib preserves all fields, including:
- Custom fields you add
- Unknown fields from imported files
- `Bdsk-*` fields for BibDesk compatibility

This ensures round-trip fidelity.

### How are cite keys generated?

Default format: `{LastName}{Year}{FirstTitleWord}`

Example: `Einstein1905Electrodynamics`

Edit cite keys manually in the BibTeX tab if needed.

---

## Sync & Backup

### How do I back up my library?

Your library is plain files. Back up options:
1. **Time Machine**: Automatic
2. **Manual**: Copy the library folder
3. **Cloud sync**: Put library folder in Dropbox/iCloud Drive

### Does imBib sync between Macs?

Currently, sync between devices requires:
1. Storing your library in a cloud folder (Dropbox, iCloud, etc.)
2. Opening the same library from each Mac

Native CloudKit sync is planned for a future release.

### Is there an iOS version?

Not yet. An iOS companion app is in development.

---

## Troubleshooting

### imBib won't open (unsigned app)

For beta builds:
1. Right-click the app in Finder
2. Select "Open"
3. Click "Open" in the security dialog

This only needs to be done once.

### Search returns no results

1. Check your internet connection
2. Verify ADS API key is valid (Settings → Sources)
3. Try a simpler query
4. Check if the source is enabled

### PDF viewer shows blank page

Possible causes:
- Corrupted PDF: Re-download or delete and re-attach
- Very large PDF: May take time to render
- DRM-protected: Some publisher PDFs are protected

### Paper list is slow with many entries

For libraries with 10,000+ papers:
1. Use collections to organize
2. Filter by unread or with PDFs
3. Consider splitting into multiple libraries

### Changes aren't saving

Check:
1. Disk isn't full
2. Library folder is writable
3. No file locking (Dropbox sync issue)

Try: Restart imBib, or export and re-import the library.

### Console shows errors

Open the console (`Cmd-Opt-C`) to see logs. Common issues:
- **Network timeout**: ADS/arXiv may be slow
- **Parse error**: Malformed BibTeX in imported file
- **Core Data error**: Usually recoverable, restart app

---

## Feature Requests

### How do I request a feature?

[Open an issue on GitHub](https://github.com/yipihey/imbib/issues) with:
- Clear description of the feature
- Use case / why it's needed
- Any relevant examples

### Planned features

See the [GitHub project board](https://github.com/yipihey/imbib/projects) for roadmap items:
- CloudKit sync
- iOS app
- PDF annotations
- Custom keyboard shortcuts
- CSL citation formatting

---

## Getting Help

### Where can I report bugs?

[GitHub Issues](https://github.com/yipihey/imbib/issues)

Include:
- macOS version
- imBib version
- Steps to reproduce
- Console logs if relevant

### Is there a discussion forum?

Use [GitHub Discussions](https://github.com/yipihey/imbib/discussions) for:
- Questions
- Feature discussions
- Workflow tips

### How can I contribute?

imBib is open source. Contributions welcome:
- Bug fixes
- Documentation improvements
- New source plugins
- Translations

See [CONTRIBUTING.md](https://github.com/yipihey/imbib/blob/main/CONTRIBUTING.md) for guidelines.
