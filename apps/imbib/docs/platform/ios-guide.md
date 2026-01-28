---
layout: default
title: iOS Guide
---

# iOS Guide

imbib on iOS provides a full-featured mobile experience for managing your paper library on iPhone and iPad.

---

## iOS Navigation

### Bottom Tab Bar (iPhone)

Quick access to main areas:

| Tab | Purpose |
|-----|---------|
| Library | Your paper libraries |
| Inbox | Paper triage |
| Search | Find new papers |
| Settings | App configuration |

### Sidebar (iPad)

On iPad, the sidebar provides desktop-like navigation:
- Tap to open sidebar
- Swipe from left edge
- Same structure as macOS

### Split View (iPad)

iPad supports Split View multitasking:

1. Swipe up for Dock
2. Drag another app beside imbib
3. Resize the split as needed
4. Use Slide Over for floating window

---

## Gestures

### Swipe Actions

Swipe left or right on papers for quick actions:

**Inbox:**
| Swipe | Action |
|-------|--------|
| Right | Keep to library |
| Left | Dismiss |
| Long swipe right | Star |

**Library:**
| Swipe | Action |
|-------|--------|
| Right | Mark as read |
| Left | Delete |

### Long Press

Long-press a paper for context menu:
- Open
- Copy BibTeX
- Copy Citation
- Copy DOI
- Share
- Move to Collection
- Delete

### Pull to Refresh

Pull down on any list to refresh:
- Inbox: Fetch new papers
- Library: Sync from iCloud
- Search results: Re-run search

---

## Share Extension

### Saving Papers

From Safari or any app:

1. Navigate to a paper page
2. Tap **Share** button
3. Select **imbib**
4. Review detected metadata
5. Choose destination (Inbox or Library)
6. Tap **Save**

### Setting Up

1. Open Safari
2. Tap Share on any page
3. Tap **More** at the end of app row
4. Toggle **imbib** on
5. Drag to preferred position

[Full Share Extension Guide →](../features/share-extension)

---

## Keyboard Support (iPad)

With external keyboard attached:

### Navigation
| Shortcut | Action |
|----------|--------|
| `Cmd+1` | Go to Library |
| `Cmd+2` | Go to Inbox |
| `Cmd+F` | Search |
| `↑/↓` | Navigate papers |
| `Enter` | Open paper |

### Paper Actions
| Shortcut | Action |
|----------|--------|
| `R` | Toggle read |
| `S` | Star (in Inbox) |
| `K` | Keep (in Inbox) |
| `D` | Dismiss (in Inbox) |
| `Cmd+C` | Copy BibTeX |

### Viewing
| Shortcut | Action |
|----------|--------|
| `Space` | Next PDF page |
| `Shift+Space` | Previous page |
| `Cmd++` | Zoom in |
| `Cmd+-` | Zoom out |

Press `Cmd` and hold to see available shortcuts.

---

## Widgets

### Home Screen Widgets

Add imbib widgets:
1. Long-press Home Screen
2. Tap **+** button
3. Search "imbib"
4. Choose widget size
5. Configure options

Available widgets:
- **Inbox Count** - Papers waiting
- **Recent Papers** - Latest additions
- **Reading Progress** - Weekly stats
- **Smart Search** - Feed results

### Lock Screen Widgets (iOS 16+)

1. Long-press Lock Screen
2. Tap **Customize**
3. Tap widget area
4. Add imbib widgets

### Widget Actions

Tap widgets to:
- Open imbib to relevant view
- See paper details
- Quick triage

[Full Widgets Guide →](../features/widgets)

---

## Spotlight Integration

### Search from Spotlight

Papers are indexed for Spotlight:

1. Swipe down from Home Screen
2. Type paper title or author
3. Tap result to open in imbib

### Siri Suggestions

Siri may suggest:
- Recent papers
- Inbox when you usually check it
- Smart Searches at relevant times

---

## Siri & Shortcuts

### Voice Commands

After running shortcuts once:
- "Search imbib for papers"
- "Show my imbib inbox"
- "Add paper by DOI to imbib"

### Shortcuts App

Create custom automations:
1. Open Shortcuts app
2. Create new shortcut
3. Search for "imbib"
4. Add imbib actions

Example automations:
- Morning paper check
- Quick add from clipboard
- Weekly reading report

[Full Siri Shortcuts Guide →](../features/siri-shortcuts)

---

## PDF Viewing

### Built-in Viewer

Open PDFs directly in imbib:
- Tap PDF tab in paper detail
- Pinch to zoom
- Swipe to change pages
- Tap to show/hide controls

### External Apps

Open in preferred PDF app:
1. Long-press PDF
2. Select **Open In...**
3. Choose PDF app

### Reading Position

Your position is saved:
- Page number
- Zoom level
- Last read timestamp

Syncs across devices via iCloud.

---

## Settings

### Accessing Settings

Tap the gear icon or navigate to Settings tab.

### Key Settings

| Section | What to Configure |
|---------|-------------------|
| API Keys | ADS, OpenAlex email |
| PDF | Source priority, proxy |
| Inbox | Age limits, muting |
| Recommendations | Engine type, weights |
| iCloud Sync | Enable/configure sync |
| Appearance | Theme options |
| Import/Export | Default formats |

### iOS-Specific Settings

Settings only on iOS:
- **Background App Refresh** - For widget updates
- **Notifications** - Alert preferences
- **Cellular Data** - Download over cellular

---

## iCloud Sync

### What Syncs

Between iOS and macOS:
- All papers and metadata
- PDFs
- Collections and Smart Searches
- Reading positions
- Notes
- Inbox state
- Settings

### Sync Status

Check sync status:
1. Go to Settings → iCloud Sync
2. View last sync time
3. See pending changes
4. Force sync if needed

### Offline Access

imbib works offline:
- Downloaded papers available
- Changes queue for sync
- PDFs download when online

---

## Storage Management

### Managing Space

Check storage usage:
1. Settings → General → iPhone Storage
2. Find imbib
3. See total and document size

### Offloading PDFs

iOS can offload PDFs automatically:
- PDF metadata remains
- PDF downloads on demand
- Reading position preserved

### Clearing Cache

1. Settings (in imbib) → Advanced
2. Tap **Clear Cache**
3. Clears thumbnails and temp files
4. PDFs and data remain

---

## Handoff & Continuity

### Handoff

Continue on another device:
1. Start reading on iPhone
2. See imbib icon on Mac Dock
3. Click to continue exactly where you left off

### Universal Clipboard

Copy BibTeX on iPhone, paste on Mac:
1. Copy BibTeX in imbib (iOS)
2. Paste in any app on Mac
3. Works within a few minutes

### AirDrop

Share papers via AirDrop:
1. Long-press paper
2. Tap **Share**
3. Select AirDrop recipient
4. Sends PDF or BibTeX

---

## Troubleshooting

### App Won't Open

1. Force quit and reopen
2. Restart your device
3. Check for updates
4. Reinstall from App Store

### Sync Not Working

1. Check iCloud is signed in
2. Check Settings → iCloud Sync is enabled
3. Ensure sufficient iCloud storage
4. Try toggling sync off and on

### Share Extension Missing

1. Settings → imbib → Share Extension
2. Ensure it's enabled
3. Reinstall if needed

### Performance Issues

1. Close other apps
2. Clear cache
3. Reduce number of Smart Searches
4. Check available storage

### Notifications Not Appearing

1. Settings → Notifications → imbib
2. Enable notifications
3. Choose alert style
4. Enable sounds if desired

---

## Requirements

- iOS 17.0 or later
- iPhone 8 or later
- iPad (6th generation) or later
- 200MB storage + space for PDFs
- iCloud account (for sync, optional)

---

## iPad-Specific Features

### Multitasking

- Split View: Two apps side-by-side
- Slide Over: Floating imbib window
- Picture in Picture: Not applicable

### Apple Pencil

- Not yet supported for annotation
- Coming in future update

### Stage Manager (M1+ iPads)

- Multiple windows
- Resizable windows
- Desktop-like experience

---

## Comparison with macOS

| Feature | iOS | macOS |
|---------|-----|-------|
| Command Palette | No | Yes (`Cmd+Shift+P`) |
| Multi-window | iPad only | Full support |
| Keyboard shortcuts | External keyboard | Full set |
| Share Extension | Yes | Yes |
| Widgets | Full support | Notification Center |
| File Provider | Yes | Yes |
| PDF Annotation | Coming soon | External apps |
| Siri Shortcuts | Full support | Full support |
| Handoff | Yes | Yes |

---

## See Also

- [Widgets](../features/widgets) - Widget setup and options
- [Siri Shortcuts](../features/siri-shortcuts) - Voice and automation
- [Share Extension](../features/share-extension) - Saving papers from Safari
