---
layout: default
title: Command Palette
---

# Command Palette

The Command Palette provides quick access to all imbib commands from a single keyboard-driven interface. Instead of navigating menus or remembering shortcuts, type what you want to do.

---

## Opening the Command Palette

**macOS:** Press `Cmd+Shift+P` (or `Cmd+K`)

A centered modal appears with a search field and list of available commands.

---

## Using the Palette

### Searching

Start typing to filter commands:
- Type "search" to find search-related commands
- Type "pdf" for PDF viewer commands
- Type "inbox" for inbox actions

The list updates as you type, showing matching commands.

### Navigating

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move selection up/down |
| `Enter` | Execute selected command |
| `Escape` | Close palette |
| Mouse hover | Select command |
| Mouse click | Execute command |

### Command Display

Each command shows:
- **Category badge** (e.g., Navigation, Papers, PDF)
- **Command title** describing the action
- **Keyboard shortcut** if one exists

---

## Command Categories

### Navigation

Move between different views in the app:

| Command | Shortcut | Description |
|---------|----------|-------------|
| Go to Inbox | `Cmd+1` | Open the Inbox |
| Go to Library | `Cmd+2` | Open current library |
| Go to Search | `Cmd+3` | Open search view |
| Focus Sidebar | `Cmd+Opt+S` | Move focus to sidebar |
| Focus List | `Cmd+Opt+L` | Move focus to paper list |
| Focus Detail | `Cmd+Opt+D` | Move focus to detail view |
| Toggle Sidebar | `Cmd+Ctrl+S` | Show/hide sidebar |

### Search

| Command | Shortcut | Description |
|---------|----------|-------------|
| Search | `Cmd+F` | Focus search field |
| Search ADS | | Search NASA ADS |
| Search arXiv | | Search arXiv preprints |
| Search Crossref | | Search Crossref |
| Search OpenAlex | | Search OpenAlex |
| New Smart Search | | Create a Smart Search |

### Papers

| Command | Shortcut | Description |
|---------|----------|-------------|
| Open Paper | `Enter` | Open selected paper |
| Toggle Read | `R` | Mark as read/unread |
| Copy BibTeX | `Cmd+Shift+C` | Copy BibTeX to clipboard |
| Copy Citation | | Copy formatted citation |
| Copy DOI | | Copy DOI to clipboard |
| Show in Finder | | Reveal PDF in Finder |
| Delete Paper | `Backspace` | Delete selected papers |
| Refresh Metadata | | Fetch updated metadata |

### Inbox

| Command | Shortcut | Description |
|---------|----------|-------------|
| Keep Paper | `K` | Add to library |
| Dismiss Paper | `D` | Remove from inbox |
| Star Paper | `S` | Toggle star status |
| Archive All | | Archive all inbox papers |
| Mark All Read | | Mark all as read |

### PDF

| Command | Shortcut | Description |
|---------|----------|-------------|
| Next Page | `Space` | Go to next page |
| Previous Page | `Shift+Space` | Go to previous page |
| Go to Page | `Cmd+G` | Jump to specific page |
| Zoom In | `Cmd++` | Increase zoom |
| Zoom Out | `Cmd+-` | Decrease zoom |
| Fit to Window | `Cmd+0` | Fit page in window |
| Actual Size | `Cmd+1` | 100% zoom |
| Find in PDF | `Cmd+F` | Search PDF text |

### Window

| Command | Shortcut | Description |
|---------|----------|-------------|
| New Window | `Cmd+N` | Open new window |
| Open Help | `Cmd+?` | Open help browser |
| Open Settings | `Cmd+,` | Open preferences |
| Toggle Full Screen | `Cmd+Ctrl+F` | Enter/exit full screen |
| Minimize | `Cmd+M` | Minimize window |

### Import/Export

| Command | Shortcut | Description |
|---------|----------|-------------|
| Import BibTeX | `Cmd+I` | Import .bib file |
| Import RIS | | Import .ris file |
| Export Library | `Cmd+E` | Export current library |
| Add by DOI | `Cmd+Shift+D` | Import paper by DOI |
| Add by arXiv | `Cmd+Shift+A` | Import paper by arXiv ID |

---

## Tips for Power Users

### Fuzzy Matching

The search is forgiving:
- "opn pdf" matches "Open PDF"
- "tog read" matches "Toggle Read Status"
- Abbreviations often work: "bib" → "Copy BibTeX"

### Quick Execution

If only one command matches your search, press `Enter` immediately to execute it.

### Learning Shortcuts

Use the Command Palette to discover shortcuts:
1. Open palette with `Cmd+Shift+P`
2. Type the action you want
3. Note the shortcut displayed
4. Use the shortcut directly next time

### Recent Commands

Frequently-used commands may appear higher in results (based on your usage patterns).

---

## Customization

### Keyboard Shortcut for Palette

The default `Cmd+Shift+P` can be changed:

1. Go to **System Settings > Keyboard > Keyboard Shortcuts**
2. Select **App Shortcuts**
3. Click **+** to add a new shortcut
4. Application: imbib
5. Menu Title: "Command Palette"
6. Enter your preferred shortcut

### Adding to Touch Bar

On MacBooks with Touch Bar:

1. Go to **View > Customize Touch Bar**
2. Drag the Command Palette icon to Touch Bar
3. Tap to open palette

---

## Comparison with Other Access Methods

| Method | Best For |
|--------|----------|
| Command Palette | When you know what you want but not where it is |
| Menu Bar | Discovering available features |
| Keyboard Shortcuts | Frequently-used actions (faster) |
| Right-Click Menu | Context-specific actions |
| Toolbar | Visible, one-click access |

---

## Platform Availability

| Feature | macOS | iOS |
|---------|-------|-----|
| Command Palette | Yes (`Cmd+Shift+P`) | No |
| Alternative | — | Use Spotlight, share sheet, or swipe actions |

On iOS, similar quick access is available through:
- Search field in the navigation bar
- Swipe actions on papers
- Context menus (long-press)

---

## See Also

- [Keyboard Shortcuts](../keyboard-shortcuts) - All keyboard shortcuts
- [Siri Shortcuts](siri-shortcuts) - Voice and automation commands
- [macOS Guide](../platform/macos-guide) - macOS-specific features
