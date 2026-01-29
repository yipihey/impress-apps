---
layout: default
title: Backup & Restore
---

# Backup & Restore

Create comprehensive backups of your entire library and restore them when needed.

---

## Overview

imbib's backup system creates a complete snapshot of your library including:

- **All publications** - Full BibTeX with metadata
- **Attachments** - PDFs, images, supplementary files
- **Notes** - Your personal annotations
- **Settings** - App preferences and configuration
- **Manifest** - Checksums for integrity verification

---

## Creating a Backup

### Quick Backup

1. Go to **File > Export > Full Library Backup...**
2. Choose a destination folder
3. Wait for the backup to complete
4. A timestamped folder is created with all your data

### What's Included

The backup folder contains:

```
imbib-backup-2026-01-29T10-30-00/
├── library.bib          # All publications as BibTeX
├── Attachments/         # All linked files
│   ├── Einstein_1905_Relativity.pdf
│   ├── Hawking_1974_BlackHoles.pdf
│   └── ...
├── notes.json           # Your personal notes
├── settings.json        # App settings
└── manifest.json        # Checksums and metadata
```

### Compressed Backup

For easier storage and transfer:

1. Go to **File > Export > Compressed Library Backup...**
2. Creates a `.zip` file instead of a folder
3. Same contents, smaller file size

### Progress Tracking

During backup, you'll see:
- Current phase (Exporting BibTeX, Copying attachments, etc.)
- Progress bar with item count
- Current file being processed

---

## Backup Contents

### library.bib

Contains all publications in BibTeX format:
- Full metadata for every paper
- All BibTeX fields preserved
- Comments indicating backup date and count

### Attachments/

All linked files with their relative paths preserved:
- PDFs
- Images
- Supplementary materials
- Code files
- Any other attachments

Original folder structure within Attachments is maintained.

### notes.json

Your personal annotations:
```json
[
  {
    "citeKey": "Einstein1905",
    "note": "Foundational paper on special relativity..."
  }
]
```

### settings.json

All synced settings including:
- Display preferences
- Source priorities
- Inbox settings
- Recommendation weights

### manifest.json

Backup metadata and integrity information:
```json
{
  "version": 1,
  "createdAt": "2026-01-29T10:30:00Z",
  "appVersion": "2.1.0",
  "schemaVersion": 15,
  "publicationCount": 1234,
  "attachmentCount": 890,
  "fileChecksums": {
    "library.bib": "a1b2c3...",
    "Attachments/Einstein_1905.pdf": "d4e5f6..."
  }
}
```

---

## Restoring from Backup

### Starting a Restore

1. Go to **File > Import > Restore from Backup...**
2. Select your backup folder (or `.zip` file)
3. Review the backup preview
4. Choose restore options
5. Click **Restore**

### Restore Preview

Before restoring, you'll see:
- Backup date and app version
- Number of publications and attachments
- Number of notes
- Whether settings are included
- Any validation warnings

### Restore Options

#### Mode

| Mode | Behavior |
|------|----------|
| **Merge** | Add backup contents to existing library, skip duplicates |
| **Replace** | Clear existing library first, then restore backup |

#### Content Selection

Choose what to restore:
- **Publications** - BibTeX entries and metadata
- **Attachments** - PDFs and other files
- **Notes** - Personal annotations
- **Settings** - App preferences (optional, off by default)

### Duplicate Handling (Merge Mode)

When merging:
- Papers are matched by cite key
- Existing papers are **not** overwritten
- New papers are added
- Use Replace mode to overwrite existing data

---

## Backup Verification

### Automatic Verification

After creating a backup, imbib automatically:
1. Reads the manifest
2. Verifies all file checksums
3. Reports any issues

### Manual Verification

To verify an existing backup:

1. Go to **File > Verify Backup...**
2. Select the backup folder
3. imbib checks all files against the manifest
4. Reports missing or corrupted files

### Verification Results

| Status | Meaning |
|--------|---------|
| **Valid** | All files present and intact |
| **Missing Files** | Some files listed in manifest are missing |
| **Corrupted Files** | Checksums don't match (file changed) |

---

## Backup Strategies

### Regular Backups

Recommended schedule:
- **Weekly** for active researchers
- **Monthly** for casual users
- **Before major changes** (imports, migrations)

### Multiple Backup Locations

Store backups in multiple places:
- Local drive
- External drive
- Cloud storage (Dropbox, iCloud Drive, Google Drive)
- Network drive (NAS)

### Backup Rotation

Keep multiple backup generations:
- Last 4 weekly backups
- Last 12 monthly backups
- Delete older backups to save space

### Pre-Import Backup

Before large imports:
1. Create a backup
2. Perform the import
3. If something goes wrong, restore from backup

---

## Data Recovery

### Recovering Specific Papers

If you accidentally deleted papers:

1. Open the backup's `library.bib` in a text editor
2. Find the entries you need
3. Copy the BibTeX
4. Import into imbib via **File > Import > BibTeX Text...**

### Recovering Notes

If you lost notes:

1. Open `notes.json` in the backup
2. Find the notes by cite key
3. Manually copy to the paper's Notes tab

### Recovering Attachments

PDFs and files are plain files in `Attachments/`:
1. Navigate to the backup folder
2. Find the files you need
3. Drag back into imbib or copy manually

---

## Troubleshooting

### Backup Fails

**Disk full:**
- Clear space on destination drive
- Use compressed backup for smaller size

**Permission denied:**
- Choose a different destination
- Check folder permissions

**PDF not found:**
- The paper has a broken file link
- Backup continues, missing files are logged

### Restore Fails

**Invalid backup format:**
- Ensure you selected the correct folder
- Check that `manifest.json` exists

**Schema version mismatch:**
- Backup is from a newer imbib version
- Update imbib before restoring

**Corrupt files:**
- Run verification first
- Some files may have been modified after backup

### Large Libraries

For libraries with thousands of papers:
- Backup may take several minutes
- Progress is shown throughout
- Don't quit imbib during backup

---

## iCloud Sync vs Backup

| Feature | iCloud Sync | Backup |
|---------|-------------|--------|
| Automatic | Yes | No (manual) |
| Cross-device | Yes | No |
| Point-in-time | No (always current) | Yes |
| Offline recovery | Limited | Full |
| External storage | No | Yes |

**Recommendation:** Use both:
- iCloud for day-to-day sync
- Backups for disaster recovery and archival

---

## Settings Reference

### Backup Settings

Configure backup behavior in **Settings > Advanced**:

| Setting | Description | Default |
|---------|-------------|---------|
| Include attachments | Include PDFs and files in backup | On |
| Include notes | Include personal annotations | On |
| Compression level | ZIP compression for compressed backups | Normal |

---

## See Also

- [Data Recovery Guide](data-recovery-guide) - Recovering from data loss
- [Settings Reference](reference/settings-reference) - All settings
- [iCloud Sync](platform/ios-guide#icloud-sync) - Cross-device synchronization
