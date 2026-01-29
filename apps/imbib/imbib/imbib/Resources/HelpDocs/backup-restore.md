# Backup & Restore

Create comprehensive backups of your entire library and restore them when needed.

---

## Overview

imbib's backup system creates a complete snapshot of your library including:

- **All publications** - Full BibTeX with metadata
- **Attachments** - PDFs, images, supplementary files
- **Notes** - Your personal annotations
- **Settings** - App preferences
- **Manifest** - Checksums for integrity verification

---

## Creating a Backup

1. Go to **File > Export > Full Library Backup...**
2. Choose a destination folder
3. Wait for the backup to complete

The backup folder contains:

```
imbib-backup-2026-01-29/
├── library.bib          # All publications
├── Attachments/         # All linked files
├── notes.json           # Your notes
├── settings.json        # App settings
└── manifest.json        # Integrity data
```

### Compressed Backup

For easier storage: **File > Export > Compressed Library Backup...**

Creates a `.zip` file with the same contents.

---

## Restoring from Backup

1. Go to **File > Import > Restore from Backup...**
2. Select your backup folder (or `.zip`)
3. Review the backup preview
4. Choose restore options
5. Click **Restore**

### Restore Modes

| Mode | Behavior |
|------|----------|
| **Merge** | Add backup contents, skip duplicates |
| **Replace** | Clear library first, then restore |

### What to Restore

Choose independently:
- Publications (BibTeX entries)
- Attachments (PDFs and files)
- Notes (personal annotations)
- Settings (app preferences) - off by default

---

## Backup Verification

To verify a backup's integrity:

1. Go to **File > Verify Backup...**
2. Select the backup folder
3. imbib checks all files against the manifest

Reports any missing or corrupted files.

---

## Backup Strategies

### Recommended Schedule

- **Weekly** for active researchers
- **Monthly** for casual users
- **Before major changes** (large imports)

### Multiple Locations

Store backups in:
- Local drive
- External drive
- Cloud storage (Dropbox, iCloud Drive)

---

## Data Recovery

### Recovering Specific Papers

1. Open backup's `library.bib` in a text editor
2. Find and copy the BibTeX entries
3. Import via **File > Import > BibTeX Text...**

### Recovering Notes

1. Open `notes.json` in the backup
2. Find notes by cite key
3. Copy to the paper's Notes tab

### Recovering Files

Files in `Attachments/` are plain files - copy directly or drag into imbib.

---

## iCloud Sync vs Backup

| Feature | iCloud Sync | Backup |
|---------|-------------|--------|
| Automatic | Yes | No (manual) |
| Cross-device | Yes | No |
| Point-in-time | No | Yes |
| External storage | No | Yes |

**Use both:** iCloud for daily sync, backups for disaster recovery.
