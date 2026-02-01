---
layout: default
title: E-Ink Device Integration
---

# E-Ink Device Integration

imbib integrates with popular E-Ink devices for distraction-free reading and annotation of your papers. Read on your favorite device, annotate with a stylus, and sync everything back to your library.

---

## Supported Devices

| Device | Sync Methods | Capabilities |
|--------|-------------|--------------|
| **reMarkable** | Cloud API, Local Folder, Dropbox | Upload PDFs, download annotations, bidirectional sync |
| **Supernote** | Folder Sync (Dropbox/USB) | Upload PDFs, download annotations from `.note` and `.mark` files |
| **Kindle Scribe** | USB, Email (Send to Kindle) | Upload PDFs, extract annotations from PDFs |

---

## Setup

### Adding a Device

1. Open **Settings > E-Ink Devices**
2. Click **Add Device**
3. Select your device type (reMarkable, Supernote, or Kindle Scribe)
4. Choose a sync method:
   - **Cloud API** (reMarkable only): Direct sync via reMarkable's cloud service
   - **Folder Sync**: Monitor a local folder (Dropbox, USB mount, etc.)
   - **USB**: Direct connection to device storage
   - **Email**: Send-to-Kindle email address

### reMarkable Cloud Setup

1. Select **Cloud API** as the sync method
2. Click **Connect**
3. A device code will appear - enter this at [my.remarkable.com](https://my.remarkable.com/device/browser/connect)
4. Once authenticated, your device will show as connected

### Folder Sync Setup (reMarkable, Supernote)

1. Select **Folder Sync** as the sync method
2. Click **Choose Folder** and select your sync folder:
   - For Dropbox: `~/Dropbox/Apps/reMarkable` or `~/Dropbox/Supernote`
   - For USB: Mount your device and select its document folder
3. imbib will monitor this folder for changes

### Kindle Scribe Setup

**USB Method:**
1. Connect your Kindle Scribe via USB
2. Select **USB** as the sync method
3. Choose the Kindle's documents folder

**Email Method:**
1. Select **Email** as the sync method
2. Enter your Send-to-Kindle email address (found in Kindle settings)
3. Note: This is upload-only; annotations must be synced via USB

---

## Sending Papers to Your Device

### From the PDF Tab

When viewing a paper with a PDF:
1. Click the **E-Ink device button** (rectangle icon) in the top-right corner
2. The PDF will be uploaded to your configured device

### From the Context Menu

Right-click any paper in your library:
1. Select **Send to E-Ink Device**
2. If the paper doesn't have a PDF, imbib will download it first

### From the Paper Menu

1. Select one or more papers
2. Choose **Paper > Send to E-Ink Device** (or press **Control+Command+E**)

### Batch Sending

Select multiple papers and use the context menu or Paper menu to send them all at once.

---

## Annotation Sync

imbib can import your handwritten annotations, highlights, and notes from your E-Ink device.

### Automatic Import

With **Auto-sync** enabled (Settings > E-Ink Devices):
- imbib periodically checks for new annotations
- Configurable intervals: 15 min, 30 min, 1 hour, 4 hours, daily

### Manual Sync

1. Go to **Paper > Sync E-Ink Annotations**
2. Or use the sync button in Settings > E-Ink Devices

### Annotation Types

| Type | Description | Processing |
|------|-------------|-----------|
| **Highlights** | Text highlights | Extracted with position and color |
| **Handwritten Notes** | Stylus strokes | Rendered as images, optional OCR |
| **Text Notes** | Typed annotations | Imported as text |

### OCR for Handwriting

Enable **OCR for handwriting** in Settings > E-Ink Devices to convert handwritten notes to searchable text. Uses Apple's Vision framework for recognition.

---

## Organization on Device

### Folder Structure

imbib organizes papers on your device using this structure:

```
imbib/                    (root folder, configurable)
├── Reading Queue/        (papers from Inbox, optional)
├── Collection A/         (mirrors imbib collection)
├── Collection B/
└── Uncategorized/        (papers not in collections)
```

### Settings

- **Root folder name**: Default is "imbib" - change in Settings > E-Ink Devices
- **Create folders by collection**: Mirrors your imbib collections on the device
- **Reading Queue folder**: Automatically syncs Inbox papers for triage reading

---

## Conflict Resolution

When the same paper is modified on both imbib and your device:

| Strategy | Behavior |
|----------|----------|
| **Prefer Device** | Keep the device version (default) |
| **Prefer Local** | Keep the imbib version |
| **Keep Both** | Merge annotations from both versions |
| **Ask Each Time** | Prompt for each conflict |

Configure in **Settings > E-Ink Devices > Conflict resolution**.

---

## Annotation Import Modes

| Mode | Behavior |
|------|----------|
| **Auto Import** | Automatically add annotations to papers |
| **Review First** | Queue annotations for manual review |
| **Manual** | Only import when explicitly requested |

---

## Troubleshooting

### Device Not Connecting

**reMarkable Cloud:**
- Ensure you're signed into your reMarkable account
- Try disconnecting and reconnecting
- Check your internet connection

**Folder Sync:**
- Verify the folder path is correct
- Ensure imbib has file access permissions
- Check that the folder exists and is accessible

### Annotations Not Syncing

- Ensure auto-sync is enabled or manually trigger a sync
- Check that annotation import is enabled for the types you want
- Verify the paper was originally sent from imbib (annotation linking requires this)

### PDF Upload Fails

- Check device storage space
- Verify network connectivity (for cloud sync)
- Try restarting the sync

### OCR Not Working

- OCR requires macOS 11+ / iOS 14+
- Ensure "Enable OCR" is turned on in settings
- Handwriting must be reasonably legible for accurate recognition

---

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Send to E-Ink Device | **Control+Command+E** |
| Sync E-Ink Annotations | (via Paper menu) |

---

## Privacy & Security

- **reMarkable Cloud**: Uses OAuth device code flow; credentials stored in Keychain
- **Folder Sync**: All data stays local; no cloud transmission
- **USB**: Direct device connection; no network access needed
- **Kindle Email**: Uses Amazon's Send-to-Kindle service

imbib never stores your device passwords in plain text. All credentials are stored securely in the system Keychain.

---

## Device-Specific Notes

### reMarkable

- Supports `.rm` file format for stroke data
- Annotations include pressure sensitivity and pen type
- Multiple sync backends: Cloud, Local folder, Dropbox bridge

### Supernote

- Reads `.note` notebooks and `.mark` annotation files
- Folder-based sync only (no cloud API available yet)
- Supports Supernote's layer-based annotation system

### Kindle Scribe

- Annotations embedded directly in PDF files
- Email method is upload-only
- USB method required for full bidirectional sync

---

## See Also

- [Features Overview](features) - Complete feature list
- [Getting Started](getting-started) - Initial setup guide
- [Keyboard Shortcuts](keyboard-shortcuts) - All shortcuts
