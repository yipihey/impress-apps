---
layout: default
title: macOS Guide
---

# macOS Guide

imbib on macOS provides a full-featured desktop experience with power user features not available on iOS.

---

## macOS-Exclusive Features

### Command Palette

Access any command instantly with `Cmd+Shift+P`:

1. Press `Cmd+Shift+P` to open
2. Type to filter commands
3. Use arrow keys to navigate
4. Press `Enter` to execute

The palette shows:
- Command name
- Keyboard shortcut (if any)
- Category badge

[Full Command Palette Guide →](../features/command-palette)

### Global Search Palette

Quick paper lookup with `Cmd+Shift+O`:

1. Press `Cmd+Shift+O`
2. Type paper title, author, or cite key
3. Select from results
4. Paper opens immediately

### Multi-Window Support

Open papers in separate windows:

1. Double-click a paper to open in new window
2. Or right-click → **Open in New Window**
3. Each window shows a single paper's detail view
4. Windows persist across sessions

**Window arrangements:**
- Tile papers side-by-side for comparison
- Keep reference paper open while browsing
- Use Spaces/Mission Control for organization

### Multi-Monitor Support

Spread your research workflow across multiple displays:

**Detachable Tabs:**
| Tab | Shortcut | Placement |
|-----|----------|-----------|
| PDF | **Shift+P** | Maximized on secondary |
| Notes | **Shift+N** | Centered on secondary |
| BibTeX | **Shift+B** | Centered on secondary |
| Info | **Shift+I** | Centered on secondary |

**Key Features:**
- Intelligent window placement on secondary displays
- **Shift+F** flips/swaps main and detached window positions
- Window positions persist across sessions
- Synchronized state between windows (PDF page, notes edits)
- Automatic migration when displays disconnect

[Full Multi-Monitor Guide →](../multi-monitor)

### Menu Bar

Complete access via the menu bar:

| Menu | Key Features |
|------|--------------|
| File | Import, Export, New Library |
| Edit | Copy BibTeX, Find, Preferences |
| View | Toggle sidebar, Filter options |
| Paper | Read status, Open PDF, Citations |
| Window | New window, Tile, Minimize |
| Help | Documentation, Shortcuts |

### Keyboard Shortcuts

macOS has the full keyboard shortcut set:

**Navigation:**
- `Cmd+1/2/3` - Focus sidebar/list/detail
- `Cmd+4/5/6/7` - Switch detail tabs

**Papers:**
- `Cmd+C` - Copy BibTeX
- `Cmd+Shift+C` - Copy citation
- `R` - Toggle read status

**PDF:**
- `Cmd++/-` - Zoom in/out
- `Cmd+G` - Go to page
- `Cmd+F` - Find in PDF

[Full Keyboard Shortcuts →](../keyboard-shortcuts)

---

## Desktop Integration

### Finder Integration

Access your papers from Finder:

1. Enable File Provider in System Settings
2. imbib appears in Finder sidebar
3. Browse PDFs with human-readable names
4. Use Quick Look with Space bar

### Spotlight Search

Papers are indexed by Spotlight for instant access:

1. Press `Cmd+Space`
2. Type paper title, author, DOI, or arXiv ID
3. Click to open in imbib

**What's Indexed:**
- Title and authors
- Abstract (keywords)
- Identifiers (DOI, arXiv ID, bibcode, cite key)
- Journal name

**Rebuilding Index:** Settings > Advanced > Rebuild Spotlight Index

[Full Spotlight Guide →](../features/spotlight)

### Quick Look

Preview PDFs without opening:

1. Select a PDF in Finder
2. Press `Space`
3. Full preview with navigation
4. Press `Space` to close

### Services Menu

Right-click integration:

1. Select text containing DOI
2. Right-click → Services → **Add to imbib**
3. Paper imports automatically

### Drag and Drop

Rich drag and drop support:

**Drop onto imbib:**
- PDF files → Attach to selected paper
- BibTeX files → Import papers
- URLs → Import from DOI/arXiv
- Text → Search for papers

**Drag from imbib:**
- Papers → BibTeX text
- PDFs → Files for sharing
- Citations → Formatted text

---

## Sidebar

The sidebar provides full navigation:

### Structure

```
Inbox (3)
─────────────
My Library
├── All Publications
├── Unread (5)
├── Smart Searches
│   ├── arXiv Daily
│   └── ADS Citations
└── Collections
    ├── Review Papers
    └── To Read
─────────────
Research Papers
└── ...
```

### Actions

- **Right-click library** → Rename, Show in Finder, Delete
- **Right-click collection** → Rename, Delete, Smart collection rules
- **Right-click Smart Search** → Edit, Run now, Feed settings

### Keyboard Navigation

- `↑/↓` - Move selection
- `←/→` - Collapse/expand
- `Enter` - Open selected
- `Space` - Quick Look (on collections)

---

## Detail View

### Resizable Panes

Drag dividers to resize:
- Sidebar width
- List/Detail split
- PDF zoom level

Sizes persist across sessions.

### Tabs

Switch with keyboard or clicks:
| Tab | Shortcut | Contents |
|-----|----------|----------|
| Info | `Cmd+4` | Metadata, abstract, attachments |
| BibTeX | `Cmd+5` | Raw BibTeX with syntax highlighting |
| PDF | `Cmd+6` | Integrated PDF viewer |
| Notes | `Cmd+7` | Personal annotations |

### PDF Viewer

Full-featured viewer:
- Thumbnail navigation
- Annotations (coming soon)
- Continuous scrolling
- Dark mode support
- Search within PDF

---

## Preferences (Settings)

Open with `Cmd+,`:

### Tabs

| Tab | Settings |
|-----|----------|
| General | Default behaviors, automation |
| Appearance | Theme, accent color |
| Viewing | List display options |
| Notes | Editor settings, modal editing |
| Sources | API keys for ADS, etc. |
| PDF | Source priority, library proxy |
| Enrichment | Metadata sources |
| Inbox | Age limits, muting |
| Recommendations | Engine settings, weights |
| Sync | iCloud options |
| Import | File format options |
| Shortcuts | Keyboard shortcut reference |
| Advanced | Developer tools |

---

## Console Window

Access debug logs for troubleshooting:

1. Press **Cmd+Shift+C** to open the Console
2. Filter by log level (Debug, Info, Warning, Error)
3. Search within messages
4. Export logs for bug reports

**Common Uses:**
- Diagnose search failures
- Debug sync issues
- Track PDF download problems
- Monitor background operations

[Full Console Guide →](../features/console)

---

## Automation

### URL Scheme

Execute commands from Terminal:
```bash
open "imbib://search?query=dark+matter"
```

### AppleScript

```applescript
tell application "imbib"
    activate
    open location "imbib://navigate/inbox"
end tell
```

### CLI Tool

Full command-line interface:
```bash
imbib search "author:Smith year:2024"
imbib navigate inbox
imbib selected copy-bibtex
```

### Alfred/Raycast

Create workflows for quick access:
1. Keyword trigger
2. Run Script action with URL scheme
3. Launch imbib to specific view

[Full Automation Guide →](../automation)

---

## Touch Bar (Legacy MacBooks)

On MacBooks with Touch Bar:

1. View → Customize Touch Bar
2. Drag imbib controls to Touch Bar
3. Available controls:
   - Search
   - Read/Unread toggle
   - Star
   - PDF navigation

---

## Performance

### Large Libraries

macOS handles large libraries efficiently:
- 10,000+ papers supported
- Virtual scrolling in list
- Background PDF indexing
- Lazy loading

### Memory Management

- PDFs loaded on demand
- Thumbnails cached
- Automatic memory cleanup

### Background Operations

- PDF downloads continue in background
- Smart Search refresh runs automatically
- iCloud sync is continuous

---

## Troubleshooting

### App Won't Launch

1. Check System Settings → Privacy → Full Disk Access
2. Try `killall imbib` in Terminal
3. Delete `~/Library/Caches/com.imbib.imbib`
4. Reinstall from App Store

### Sync Issues

1. Check iCloud status in menu bar
2. Sign out and back into iCloud
3. Check Console.app for sync errors

### Performance Problems

1. Reduce Smart Search frequency
2. Limit PDF auto-download
3. Check Activity Monitor for issues
4. Clear cache: Settings → Advanced → Clear Cache

### Keyboard Shortcuts Not Working

1. Check for conflicts in System Settings → Keyboard
2. Ensure correct keyboard layout
3. Reset to defaults in Settings → Shortcuts

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
- 4GB RAM minimum (8GB recommended)
- 500MB storage + space for PDFs
- iCloud account (for sync, optional)

---

## See Also

- [Keyboard Shortcuts](../keyboard-shortcuts) - Complete shortcut reference
- [Command Palette](../features/command-palette) - Power user command access
- [Automation API](../automation) - Scripting and integration
