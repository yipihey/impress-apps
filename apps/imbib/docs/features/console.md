---
layout: default
title: Console Window
---

# Console Window

The Console provides a debug log viewer for troubleshooting and understanding imbib's behavior.

---

## Overview

The Console window shows real-time log messages from imbib, including:

- **Debug** - Detailed internal operations
- **Info** - Normal operations and milestones
- **Warning** - Potential issues that didn't cause failures
- **Error** - Failures and exceptions

---

## Opening the Console

### Keyboard Shortcut

Press **Cmd+Shift+C** to toggle the Console window.

### Menu Access

Go to **Window > Console** or **Help > Show Console**.

### Settings Access

1. Go to **Settings > Advanced**
2. Click **Show Console**

---

## Console Interface

### Toolbar

The toolbar provides filtering and actions:

| Control | Description |
|---------|-------------|
| **Debug/Info/Warn/Error** | Toggle log levels on/off |
| **Filter field** | Search within log messages |
| **Auto-scroll** | Jump to new messages automatically |
| **Copy** | Copy selected entries to clipboard |
| **Clear** | Remove all log entries |
| **Export** | Save log to file |

### Log Entry Format

Each log entry shows:

```
HH:MM:SS  [LEVEL]  [category]  Message text
```

For example:
```
10:30:45  [INFO]   [search]    Searching ADS for "dark matter"
10:30:46  [DEBUG]  [network]   Request completed in 234ms
10:30:46  [INFO]   [search]    Found 42 results
```

### Level Colors

| Level | Color | Meaning |
|-------|-------|---------|
| Debug | Gray | Verbose internal details |
| Info | Blue | Normal operations |
| Warning | Orange | Potential issues |
| Error | Red | Failures |

---

## Filtering Logs

### By Level

Click the level buttons to show/hide:
- Toggle **Debug** off to hide verbose messages
- Show only **Error** to focus on problems
- Show all levels for complete picture

### By Text

Type in the Filter field to search:
- Matches message text
- Matches category
- Case-insensitive

### Examples

| Filter | Shows |
|--------|-------|
| `search` | All search-related messages |
| `error` | Messages containing "error" |
| `sync` | iCloud sync messages |
| `pdf` | PDF download/display messages |

---

## Using the Console for Troubleshooting

### Diagnosing Search Issues

1. Open Console
2. Filter for `search` or the source name (`ads`, `arxiv`)
3. Perform your search
4. Look for errors or unexpected behavior

### Debugging Sync Problems

1. Open Console
2. Filter for `sync` or `cloudkit`
3. Trigger a sync
4. Look for errors or conflict messages

### PDF Download Issues

1. Open Console
2. Filter for `pdf` or `download`
3. Attempt to download the PDF
4. Check for network errors or access issues

### Enrichment Problems

1. Open Console
2. Filter for `enrichment`
3. Watch the enrichment process
4. Identify failing sources

---

## Exporting Logs

### For Bug Reports

When reporting issues:

1. Open Console before reproducing the bug
2. Clear the log (**Clear** button)
3. Reproduce the issue
4. Click **Export**
5. Save as `imbib-log-{date}.txt`
6. Attach to your bug report

### Export Format

Exported logs are plain text:
```
imbib Debug Log
Exported: 2026-01-29T10:30:00Z
App Version: 2.1.0

10:30:45 [INFO] [startup] imbib launched
10:30:45 [DEBUG] [database] Loading library...
...
```

### Copying Selected Entries

1. Click to select entries (Shift-click for range)
2. Press **Cmd+C** or click **Copy**
3. Paste into email, GitHub issue, etc.

---

## Log Categories

Common log categories:

| Category | Content |
|----------|---------|
| `startup` | App launch and initialization |
| `database` | Core Data operations |
| `search` | Online searches |
| `sync` | iCloud synchronization |
| `cloudkit` | CloudKit operations |
| `pdf` | PDF download and display |
| `enrichment` | Metadata enrichment |
| `import` | BibTeX/RIS import |
| `export` | Export operations |
| `spotlight` | Spotlight indexing |
| `handoff` | Handoff activity |
| `backup` | Backup and restore |

---

## Performance Considerations

### Log Volume

- **Debug** level generates many messages
- Keep Debug disabled during normal use
- Enable only when troubleshooting

### Memory Usage

- Logs are kept in memory
- Very long sessions may accumulate many entries
- Use **Clear** periodically or restart the Console

### Auto-Scroll

- Auto-scroll keeps the view at the bottom
- Disable to examine older entries
- Re-enable to follow new messages

---

## Privacy

### What's Logged

Logs may contain:
- File paths (paper titles visible)
- Search queries
- API endpoints (not keys)
- Error messages

Logs do **not** contain:
- API keys or passwords
- Full paper content
- Note contents
- Personal information

### Before Sharing

When sharing logs for support:
- Review for any sensitive queries
- Redact if necessary
- Logs don't contain authentication data

---

## Settings

### Console Settings

In **Settings > Advanced**:

| Setting | Description | Default |
|---------|-------------|---------|
| Enable verbose logging | Include Debug level in Console | Off |

### Automation Logging

In **Settings > General**:

| Setting | Description | Default |
|---------|-------------|---------|
| Log automation requests | Log URL scheme commands | Off |

---

## See Also

- [Troubleshooting](../platform/macos-guide#troubleshooting) - Common issues
- [Settings Reference](../reference/settings-reference#advanced) - Advanced settings
- [Automation API](../automation) - URL scheme debugging
