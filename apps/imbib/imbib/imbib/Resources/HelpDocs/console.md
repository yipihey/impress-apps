# Console Window

The Console provides a debug log viewer for troubleshooting and understanding imbib's behavior.

---

## Overview

The Console window shows real-time log messages including:

- **Debug** - Detailed internal operations
- **Info** - Normal operations
- **Warning** - Potential issues
- **Error** - Failures

---

## Opening the Console

Press **Cmd+Shift+C** or go to **Window > Console**.

---

## Console Interface

### Toolbar

| Control | Description |
|---------|-------------|
| **Debug/Info/Warn/Error** | Toggle log levels |
| **Filter field** | Search within messages |
| **Auto-scroll** | Jump to new messages |
| **Copy** | Copy selected entries |
| **Clear** | Remove all entries |
| **Export** | Save log to file |

### Log Entry Format

```
HH:MM:SS  [LEVEL]  [category]  Message
```

Example:
```
10:30:45  [INFO]   [search]    Searching ADS for "dark matter"
10:30:46  [INFO]   [search]    Found 42 results
```

---

## Filtering Logs

### By Level

Click level buttons to show/hide:
- Toggle **Debug** off to reduce noise
- Show only **Error** to focus on problems

### By Text

Type in Filter to search messages and categories.

---

## Troubleshooting with Console

### Search Issues
Filter for `search` or source name, then perform your search.

### Sync Problems
Filter for `sync` or `cloudkit`, then trigger a sync.

### PDF Downloads
Filter for `pdf` or `download`, then attempt download.

---

## Exporting Logs

For bug reports:

1. Clear the log
2. Reproduce the issue
3. Click **Export**
4. Attach to your bug report

---

## Log Categories

| Category | Content |
|----------|---------|
| `search` | Online searches |
| `sync` | iCloud sync |
| `pdf` | PDF operations |
| `enrichment` | Metadata enrichment |
| `import` | BibTeX/RIS import |
| `spotlight` | Spotlight indexing |
| `backup` | Backup operations |

---

## Privacy

Logs may contain file paths and search queries but never contain API keys, passwords, or note contents.

Review logs before sharing for support.
