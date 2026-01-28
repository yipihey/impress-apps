---
layout: default
title: Files App Integration
---

# Files App Integration

imbib integrates with the system Files app (Finder on macOS, Files on iOS), allowing you to browse and manage your paper PDFs directly from the file system.

---

## Overview

The File Provider extension exposes your imbib libraries as locations in the Files app:

- Browse papers organized by library
- Access PDFs without opening imbib
- Use any PDF viewer to open papers
- Share PDFs to other apps
- Quick Look preview support

---

## Enabling File Provider

### macOS

1. Open **Finder**
2. Go to **Finder > Settings > Sidebar**
3. Under "Locations", enable **imbib**
4. imbib appears in Finder sidebar

### iOS

1. Open the **Files** app
2. Tap **Browse** tab
3. Tap **...** (more) in the top right
4. Select **Edit**
5. Enable **imbib** under Locations
6. Tap **Done**

imbib now appears as a location in Files.

---

## Browsing Your Library

### Folder Structure

When you open imbib in Files, you see:

```
imbib/
├── My Library/
│   ├── Einstein_1905_Relativity.pdf
│   ├── Hawking_1974_BlackHoles.pdf
│   └── ...
├── Physics Papers/
│   └── ...
└── Reading List/
    └── ...
```

Each library appears as a folder containing its PDFs.

### PDF Naming

PDFs use the human-readable naming format:
```
{FirstAuthor}_{Year}_{TitleWords}.pdf
```

This makes papers easy to find and identify.

---

## Working with PDFs

### Opening a Paper

1. Navigate to the PDF in Files/Finder
2. Double-click (macOS) or tap (iOS) to open
3. Opens in your default PDF viewer
4. Reading position is not tracked when opened externally

### Quick Look Preview

**macOS:** Select a PDF and press `Space` for Quick Look

**iOS:** Tap and hold, then select **Quick Look**

### Sharing PDFs

**macOS:**
1. Right-click the PDF
2. Select **Share**
3. Choose destination (AirDrop, Mail, Messages, etc.)

**iOS:**
1. Tap and hold the PDF
2. Select **Share**
3. Choose destination

### Copying to Other Apps

Drag PDFs from Files to:
- Email attachments
- Cloud storage (Dropbox, Google Drive)
- Note-taking apps
- Reference managers

---

## Syncing Behavior

### How Sync Works

1. PDFs are stored in your local library folders
2. Changes sync via iCloud (if enabled)
3. File Provider shows the synced state
4. Downloads happen on-demand on iOS

### Download Status (iOS)

On iOS, PDFs may show as:
- **Cloud icon**: Not downloaded yet (tap to download)
- **Checkmark**: Downloaded and available offline
- **Progress circle**: Currently downloading

### Keeping PDFs Offline

**iOS:**
1. Navigate to a PDF
2. Tap and hold
3. Select **Download Now**
4. Or enable automatic downloads in Settings

---

## Limitations

### What File Provider Shows

- PDF files attached to papers
- Organized by library
- Human-readable filenames

### What File Provider Doesn't Show

- Paper metadata (title, authors, abstract)
- BibTeX entries
- Notes
- Smart Searches
- Inbox papers (until kept to library)

### Read-Only Access

The File Provider is currently read-only:
- Cannot add new PDFs directly
- Cannot rename files (use imbib to change metadata)
- Cannot delete files (delete papers in imbib instead)

To add papers, use:
- imbib app directly
- Share Extension from browser
- Siri Shortcuts

---

## Use Cases

### Quick PDF Access

When you just need to view or share a PDF:
1. Open Files/Finder
2. Navigate to imbib > Your Library
3. Open or share the PDF directly

### External Annotation

Use your preferred PDF annotation app:
1. Open the PDF from Files
2. Annotate in that app
3. Save changes
4. Changes sync back to imbib's storage

### Backup

PDFs are stored as regular files:
1. Navigate to library folder
2. Select all PDFs
3. Copy to backup location
4. PDFs are plain files, no special format

### Spotlight Search (macOS)

PDFs are indexed by Spotlight:
1. Press `Cmd+Space`
2. Type paper title or author
3. PDF appears in Spotlight results
4. Click to open

---

## Troubleshooting

### imbib Not Appearing in Sidebar

**macOS:**
1. Check System Settings > Privacy & Security > Files and Folders
2. Ensure imbib has file access
3. Restart Finder: `killall Finder`

**iOS:**
1. Check Settings > Files > imbib
2. Ensure imbib has file access
3. Force quit and reopen Files app

### PDFs Not Showing

1. Verify the paper has a PDF attached in imbib
2. Check if sync is complete
3. Try refreshing the file list
4. Restart imbib

### Sync Issues

1. Check iCloud is connected
2. Verify sufficient iCloud storage
3. Wait for sync to complete
4. Check imbib's sync status indicator

### Access Denied Errors

1. Check file permissions
2. Ensure imbib is not sandboxed incorrectly
3. Try re-enabling the File Provider extension
4. Restart your device

---

## Privacy & Security

### Local Storage

PDFs are stored on your device in:
- **macOS**: Library folder you chose when creating the library
- **iOS**: App's container (synced via iCloud)

### No Cloud Required

The File Provider works fully offline. PDFs are:
- Stored locally first
- Synced via iCloud only if enabled
- Never sent to third-party servers

### Encryption

PDFs are protected by:
- Device encryption (FileVault/iOS encryption)
- iCloud encryption in transit and at rest
- No additional imbib-specific encryption

---

## Platform Differences

| Feature | macOS | iOS |
|---------|-------|-----|
| Finder/Files location | Yes | Yes |
| Quick Look | Yes | Yes |
| Spotlight indexing | Yes | No |
| External PDF apps | Yes | Yes |
| Offline access | Always | On-demand |
| Drag and drop | Full | Limited |

---

## See Also

- [PDF Management](../features#pdf-management) - How imbib handles PDFs
- [Syncing](../syncing) - iCloud sync details
- [macOS Guide](../platform/macos-guide) - macOS-specific features
- [iOS Guide](../platform/ios-guide) - iOS-specific features
