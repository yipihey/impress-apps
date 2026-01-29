# Data Recovery Guide

This guide helps you recover your imbib library data if something goes wrong with sync or if you accidentally delete data.

## Quick Reference

| Problem | Solution |
|---------|----------|
| Sync stuck | Settings > Sync Health > Force Sync |
| Missing publications | Check other devices, wait 15 min |
| Conflicts showing | Settings > Sync Health > Resolve Conflicts |
| App won't open | Restore from automatic backup |
| Need to export | File > Export > Full Library Backup |

## If Sync Appears Stuck

### Step 1: Check Sync Health

1. Go to **Settings > Sync** (macOS) or **Settings > iCloud** (iOS)
2. Look at the **Sync Health** section
3. Check for any reported issues

### Step 2: Try Force Sync

1. In Sync Health, tap **Force Sync**
2. Wait up to 5 minutes for sync to complete
3. Watch the status indicator

### Step 3: Check iCloud Storage

1. Open **System Settings** (macOS) or **Settings** (iOS)
2. Go to **Apple ID > iCloud**
3. Check available storage
4. If full, free up space or upgrade plan

### Step 4: Check Network

- Ensure you have an internet connection
- Try disabling VPN if using one
- Switch between WiFi and cellular (iOS)

### Step 5: Wait for CloudKit

CloudKit uses eventual consistency:
- Wait 15-30 minutes for large syncs
- Changes may take longer during high traffic
- Status will update when complete

## If Data Appears Missing

### Don't Panic!

Missing data is often just a sync delay. Here's what to check:

### Check Other Devices

1. Open imbib on another device (iPhone, iPad, Mac)
2. See if the data is there
3. If yes, wait for sync to complete to your current device

### Check Recently Deleted

1. Go to **Library > Recently Deleted** (if available)
2. Look for accidentally deleted items
3. Restore if found

### Check Filters

1. Make sure no search filter is active
2. Check if a Smart Search is selected
3. Try selecting "All Publications"

### Check iCloud Sync Status

In System Settings:
1. Apple ID > iCloud
2. Look for any sync errors
3. Ensure imbib has iCloud access

## Resolving Conflicts

Conflicts occur when the same publication is edited on multiple devices simultaneously.

### View Conflicts

1. Go to **Settings > Sync Health**
2. Look for "X Unresolved Conflicts"
3. Tap to see conflict details

### Resolve Each Conflict

For each conflict:
1. Review both versions
2. Choose which values to keep
3. Or select "Merge" to keep all unique data

### After Resolution

- Conflicts will sync automatically
- Check all devices to verify

## Exporting Your Library

### Full Library Backup

Creates a complete backup including:
- All publications as BibTeX
- All PDF files
- Notes
- Settings

**macOS:**
1. **File > Export > Full Library Backup**
2. Choose save location (not iCloud!)
3. Wait for export to complete

**iOS:**
1. **Settings > Backup > Export Library**
2. Choose where to save
3. Can share via AirDrop, Files, etc.

### BibTeX Only Export

If you just need the bibliography:

**macOS:**
1. **File > Export > BibTeX**
2. Choose publications to export
3. Save the .bib file

### Verify Your Backup

After exporting:
1. Open the backup folder
2. Check `library.bib` opens in a text editor
3. Verify PDF files are present in `PDFs/` folder
4. Check `manifest.json` for file counts

## Restoring from Backup

### Using the Built-in Restore Feature

imbib provides a complete restore workflow in Settings:

**macOS:**
1. Go to **Settings > Sync > Backup**
2. Find your backup in the "Recent Backups" list
3. Click **Restore** next to the backup you want to restore
4. In the Restore Options dialog:
   - Choose **Merge** (add to existing library) or **Replace** (clear and restore)
   - Select what to restore: Publications, Attachments, Notes, Settings
5. Click **Restore** and wait for completion

**iOS:**
1. Go to **Settings > Backup**
2. Tap the backup you want to restore
3. Choose your restore options
4. Tap **Restore**

### Restore Modes

| Mode | Description | When to Use |
|------|-------------|-------------|
| **Merge** | Adds backup contents to existing library, skips duplicates by cite key | Recovering specific publications, combining libraries |
| **Replace** | Clears existing library first, then restores backup | Complete restoration, starting fresh |

### What Gets Restored

| Content | Default | Notes |
|---------|---------|-------|
| Publications | Yes | BibTeX entries from library.bib |
| Attachments | Yes | PDFs and other linked files |
| Notes | Yes | Notes attached to publications |
| Settings | No (opt-in) | App preferences - enable to restore |

### Manual Import (BibTeX Only)

If you only need to import publications without the full restore:
1. **File > Import > BibTeX File**
2. Select your backup's `library.bib` file
3. Duplicates are automatically skipped

### Restoring PDFs Separately

If you have PDFs but they weren't linked:
1. Import the BibTeX first
2. Copy PDFs to your Papers folder (located in Library/Application Support/imbib/DefaultLibrary/Papers)
3. imbib will automatically link them based on filename patterns

## Emergency Procedures

### If App Won't Open

1. Force quit the app
2. Restart your device
3. Try opening again
4. If still failing, reinstall (data preserved in iCloud)

### If iCloud Data is Corrupted

1. **Export your library first** (if possible)
2. Go to Settings > Sync
3. Select "Reset Sync Data"
4. Confirm the reset
5. Re-import from your backup

### Contact Support

If nothing else works:
1. Export whatever data you can
2. Note the error messages
3. Contact support at support@imbib.app
4. Include:
   - Device and iOS/macOS version
   - App version
   - Description of the problem
   - Any error messages

## Prevention Tips

### Regular Backups

- Export your library monthly
- Before major iOS/macOS updates
- Before traveling without internet

### Sync Best Practices

- Let sync complete before closing app
- Don't edit same publication on multiple devices simultaneously
- Keep devices updated to same app version

### Storage Management

- Archive old publications you don't need
- Keep iCloud storage under 90% full
- Regularly clean up duplicate PDFs

## Technical Details

### Where Data is Stored

| Data | Location |
|------|----------|
| Publications | Core Data + CloudKit |
| PDFs | Local Papers folder + iCloud |
| Settings | NSUbiquitousKeyValueStore |
| Backups | ~/Library/Application Support/imbib/Backups |

### Backup File Structure

```
imbib-backup-2026-01-28T12-00-00Z/
├── library.bib          # All publications as BibTeX
├── Attachments/         # All linked files (PDFs, images, etc.)
│   └── Papers/
│       └── Author_Year_Title.pdf
├── notes.json           # Publication notes
├── settings.json        # App settings
└── manifest.json        # Checksums for verification
```

### Schema Versions

| Version | Release | Changes |
|---------|---------|---------|
| 1.0 | Initial | Base schema |
| 1.1 | v2.1 | Manuscript support |
| 1.2 | v2.2 | Annotation fields |

## Getting Help

- **In-App Help**: Help menu > imbib Help
- **Support Email**: support@imbib.app
- **Community**: [GitHub Discussions](https://github.com/yipihey/impress-apps/discussions)

## Related Documentation

- [iCloud Pitfalls](icloud-pitfalls.md) - Technical details for developers
- [Features](features.md) - App feature documentation
- [Keyboard Shortcuts](keyboard-shortcuts.md) - Quick reference
