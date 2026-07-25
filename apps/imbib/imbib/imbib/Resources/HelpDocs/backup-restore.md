# Backup & Restore

Take a complete, point-in-time snapshot of your library, and put it back when
something goes wrong.

---

## Overview

A backup is a single file: an exact copy of the whole impress store at the
moment you took it. That is everything the suite keeps —

- **Papers** — full metadata, cite keys, identifiers
- **Tags, flags, read state, collections and smart searches**
- **Manuscripts and their sections** (imprint's data lives in the same store)
- **Annotations, notes, comments and captured artifacts**
- **Links to your PDFs** — the paths, not the PDF files themselves

Because it is a snapshot rather than an export, nothing is lost in
translation: restoring returns the library to exactly the state it was in.

The file is an ordinary SQLite database. You can open it years from now with
any SQLite tool, on any computer, with no impress software installed:

```
sqlite3 imbib-backup-20260725-110555.impressbackup "SELECT COUNT(*) FROM items"
```

A small `.json` file is written next to it recording when the backup was
taken, what version made it, how many records it holds and a SHA-256 digest of
the file.

> **PDFs are not inside the backup.** The store keeps links to your PDF files;
> back up the folder holding them separately.

---

## Creating a Backup

**Settings › Sync › Backup › Back Up Now.**

The snapshot is taken while you keep working — imbib, imprint and impel can
all be running and writing. You get a consistent picture of the instant the
backup began, never a half-written mixture.

Backups are listed in the same pane with their date, record count and size.
The folder button opens them in Finder, so you can copy them to an external
drive or cloud folder.

Take one **before anything large or irreversible**: a big import, a
deduplication pass, mass re-tagging.

---

## Restoring from a Backup

**Settings › Sync › Backup**, then **Restore** next to a backup — or the
undo-arrow button to pick a backup file from elsewhere on disk.

Before anything changes, imbib:

1. **Checks the backup.** Integrity check, required tables, and a digest match
   against its manifest. A truncated, corrupt or altered file is refused
   outright — never half-applied.
2. **Snapshots your current library** into a `Safety` folder beside your
   backups, so the restore itself is reversible.

Then the whole store is replaced.

> **Restore replaces everything**, including imprint manuscripts and impel
> tasks. Anything added since the backup was taken is gone (recoverable from
> the automatic safety snapshot).

**Quit and reopen imbib afterwards** — and any running imprint or impel. They
hold their data in memory and would otherwise keep showing records from the
library you just replaced.

---

## Restoring and iCloud Sync

**Turn iCloud sync off before restoring.** The Restore buttons are disabled
while sync is on, and the pane says why.

Sync resolves conflicts by keeping the most recently changed copy of each
record. A restored record carries its *old* timestamp, so your other devices
would consider their copies newer and quietly overwrite the restore — you
would watch the old library come back.

The safe order is:

1. Turn sync off in **Settings › Sync**, on **every** device.
2. Restore.
3. Relaunch imbib.
4. Turn sync back on, on this device first, and let it settle before enabling
   the others.

When a restore happens, imbib clears its pending sync bookkeeping so the
rewound library is never pushed at your other devices on its own.

---

## Backup Strategies

- **Weekly** for active researchers, **monthly** for casual use
- **Always before** a large import or a bulk edit
- Keep copies in more than one place — local disk, external drive, cloud
  folder. A backup stored only on the machine it protects is not a backup.
- Old backups can be deleted from the Settings pane; each one is a full copy,
  so they are roughly the size of your library.

---

## iCloud Sync vs Backup

| | iCloud Sync | Backup |
|---|---|---|
| Automatic | Yes | No — you take it |
| Cross-device | Yes | No |
| Point-in-time recovery | No | Yes |
| Survives a mistaken deletion | No — the deletion syncs too | Yes |
| Stored outside the app | No | Yes |

**Use both.** Sync keeps your devices in step; backups are what you reach for
when something was deleted, mangled or imported wrong.

---

## For Agents & Scripts

The whole surface is available over the automation API (port 23120) and as MCP
tools — `imbib_create_backup`, `imbib_list_backups`, `imbib_inspect_backup`,
`imbib_restore_backup`, `imbib_delete_backup`.

```bash
curl -X POST http://localhost:23120/api/backups \
  -H 'Content-Type: application/json' \
  -d '{"label":"before bulk import"}'

curl 'http://localhost:23120/api/backups'
```

`POST /api/backups/restore` is destructive and refuses with `409
sync_enabled` while sync is on.
