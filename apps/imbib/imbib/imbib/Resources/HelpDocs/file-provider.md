# Files App Integration

Access your imbib papers directly from the system Files app (Finder on macOS, Files on iOS).

---

## Overview

The File Provider extension exposes your libraries as locations in the file system:

- Browse papers organized by library
- Access PDFs without opening imbib
- Share PDFs to other apps
- Quick Look preview support

---

## Enabling File Provider

### macOS

1. Open **Finder**
2. Go to **Finder > Settings > Sidebar**
3. Under "Locations", enable **imbib**

### iOS

1. Open the **Files** app
2. Tap **Browse** tab
3. Tap **...** (more) > **Edit**
4. Enable **imbib** under Locations
5. Tap **Done**

---

## Browsing Your Library

Each library appears as a folder:

```
imbib/
├── My Library/
│   ├── Einstein_1905_Relativity.pdf
│   └── Hawking_1974_BlackHoles.pdf
└── Physics Papers/
    └── ...
```

PDFs use human-readable names: `{Author}_{Year}_{Title}.pdf`

---

## Working with PDFs

### Opening
Double-click (macOS) or tap (iOS) to open in your default PDF viewer.

### Quick Look
- **macOS**: Select and press `Space`
- **iOS**: Tap and hold, select Quick Look

### Sharing
Right-click or long-press to share via AirDrop, Mail, etc.

---

## Sync Behavior

### Download Status (iOS)

PDFs may show as:
- **Cloud icon**: Not downloaded (tap to download)
- **Checkmark**: Downloaded and available offline
- **Progress circle**: Currently downloading

### Keeping Offline

On iOS, tap and hold a PDF > **Download Now** to keep it available offline.

---

## Limitations

**What's Shown:**
- PDF files attached to papers
- Organized by library

**What's Not Shown:**
- Paper metadata (title, authors)
- BibTeX entries
- Notes
- Inbox papers

**Read-Only:**
- Cannot add new PDFs directly (use imbib app)
- Cannot rename files (change metadata in imbib)
- Cannot delete files (delete papers in imbib)

---

## Troubleshooting

### imbib Not Appearing

**macOS:** Finder > Settings > Sidebar > Enable imbib

**iOS:** Files app > Browse > ... > Edit > Enable imbib

### PDFs Not Showing

1. Verify the paper has a PDF in imbib
2. Check if sync is complete
3. Restart imbib
