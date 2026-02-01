---
layout: default
title: Multi-Monitor Support
---

# Multi-Monitor Support

imbib provides powerful multi-monitor support on macOS, allowing you to spread your research workflow across multiple displays. View a PDF on one screen while taking notes or browsing your library on another.

---

## Quick Start

1. Connect a second display
2. Select a paper in imbib
3. Press **Shift+P** to open the PDF on your secondary display
4. The main window stays on your primary display

That's it! The PDF opens maximized on your secondary monitor while you continue working in the main window.

---

## Detachable Tabs

Any detail tab can be "popped out" to a separate window:

| Tab | Shortcut | Window Behavior |
|-----|----------|-----------------|
| **PDF** | **Shift+P** | Maximized on secondary display |
| **Notes** | **Shift+N** | Standard size, centered |
| **BibTeX** | **Shift+B** | Standard size, centered |
| **Info** | **Shift+I** | Standard size, centered |

### How to Detach

**Keyboard (Recommended):**
- Press the shortcut for the tab you want to detach
- Window opens on secondary display (if available)

**Menu:**
- **Window > Open PDF in Fullscreen** (or Notes/BibTeX/Info)

**Tip:** If you don't have a secondary display, detached windows open on your primary display in a sensible position.

---

## Window Placement

### Automatic Placement

imbib intelligently places detached windows:

| Scenario | PDF Placement | Other Tabs |
|----------|---------------|------------|
| Secondary display connected | Maximized on secondary | Centered on secondary |
| Single display | Right half of screen | Floating, standard size |

### Manual Positioning

After detaching:
1. Drag the window to your preferred position
2. Resize as needed
3. Your position is saved automatically
4. Next time you detach the same tab, it restores to your saved position

### Position Memory

Window positions are remembered per:
- Publication (cite key)
- Tab type (PDF, Notes, etc.)
- Screen configuration

If you disconnect your secondary display, imbib:
1. Detects the change automatically
2. Migrates windows to your remaining display
3. Arranges them in a tiled layout to avoid overlap

---

## Keyboard Shortcuts

### Detaching Tabs

| Action | Shortcut |
|--------|----------|
| Open PDF in Fullscreen | **Shift+P** |
| Open Notes in Fullscreen | **Shift+N** |
| Open BibTeX in Fullscreen | **Shift+B** |
| Open Info in Fullscreen | **Shift+I** |

### Window Management

| Action | Shortcut |
|--------|----------|
| Flip Window Positions | **Shift+F** |
| Close Detached Windows | **Option+Shift+Cmd+W** |

### Flip Window Positions

Press **Shift+F** to swap the positions of your main window and detached window. This is useful when you want to quickly switch which display has the PDF vs. the library browser.

**Example workflow:**
1. Main window on left display, PDF on right
2. Press **Shift+F**
3. Main window moves to right, PDF moves to left

---

## Synchronized State

Detached windows stay synchronized with the main window:

### PDF Position
- Page number syncs across windows
- Zoom level syncs
- Scroll position syncs
- Reading position is saved when you close

### Notes
- Edits in detached window immediately appear in main window
- Edits in main window immediately appear in detached window
- Auto-save works in both locations

### BibTeX
- Changes sync instantly
- Validation runs in both windows

### Publication Selection
- Changing papers in main window doesn't close detached windows
- Each detached window is tied to a specific publication
- You can have multiple publications' PDFs open simultaneously

---

## Common Workflows

### Reading with Notes

**Setup:**
1. Main window on primary display (library browser)
2. Press **Shift+P** to open PDF on secondary display
3. Press **Shift+N** to open Notes (same display as PDF, tiled)

**Workflow:**
- Read PDF and take notes simultaneously
- Browse for other papers in main window
- Notes auto-save as you type

### Paper Comparison

**Setup:**
1. Select first paper, press **Shift+P**
2. Select second paper, press **Shift+P**
3. You now have two PDFs open

**Workflow:**
- Compare methods or results
- Each PDF remembers its own reading position
- Close windows individually when done

### Citation Checking

**Setup:**
1. Main window on primary display
2. Press **Shift+P** for the PDF you're reading
3. Press **Shift+I** for the Info tab (shows references)

**Workflow:**
- Read the paper
- Check references in the Info panel
- Click references to navigate to them in your library

### Focus Reading

**Setup:**
1. Main window minimized or on separate Space
2. Press **Shift+P** for fullscreen PDF

**Workflow:**
- Distraction-free reading
- Use PDF shortcuts (Cmd++/-, Cmd+G for go to page)
- Press **Shift+F** to quickly access your library

---

## Window Menu Commands

All multi-monitor actions are available in the Window menu:

| Command | Description |
|---------|-------------|
| Open PDF in Fullscreen | Detach PDF tab |
| Open Notes in Fullscreen | Detach Notes tab |
| Open BibTeX in Fullscreen | Detach BibTeX tab |
| Open Info in Fullscreen | Detach Info tab |
| Flip Window Positions | Swap main and detached |
| Close Detached Windows | Close all detached for current paper |

---

## State Persistence

### What's Saved

imbib remembers:
- Which windows were open (by publication and tab)
- Window positions and sizes
- Screen assignments

### When It's Restored

On app launch:
- If the publication still exists in your library
- If the same screen configuration is detected
- Windows restore to their saved positions

### Clearing Saved State

To reset window positions:
1. Close all detached windows
2. Quit imbib
3. Relaunch

Or in Settings > Advanced > Reset Window State.

---

## Display Configuration Changes

imbib handles display changes gracefully:

### Connecting a Display
- Existing detached windows stay where they are
- New detachments prefer the secondary display

### Disconnecting a Display
- Windows on the disconnected display migrate to remaining display
- Windows are tiled to avoid complete overlap
- Positions are adjusted to fit the available space

### Resolution Changes
- Windows are constrained to remain fully visible
- Oversized windows are resized to fit

---

## Tips and Tricks

### Quick PDF Reference
Keep a reference PDF open while browsing:
1. Open the reference paper's PDF (**Shift+P**)
2. Browse other papers in the main window
3. The reference stays visible

### Fullscreen per Display
macOS allows fullscreen on each display:
1. Detach a tab to secondary display
2. Click the green fullscreen button
3. The detached window goes fullscreen on that display
4. Main window can also go fullscreen on primary

### Mission Control Organization
Use Spaces for organization:
1. Create a "Research" Space
2. Move main imbib window there
3. Detached windows can be on the same or different Spaces

### Quick Tab Switching
Even with detached windows, main window tab shortcuts work:
- **Cmd+4** - Info tab in main window
- **Cmd+5** - BibTeX tab in main window
- **Cmd+6** - PDF tab in main window
- **Cmd+7** - Notes tab in main window

---

## Troubleshooting

### Window Opens on Wrong Display

**Solution:**
1. Drag the window to the correct display
2. imbib will remember this position
3. Future detachments will use your preferred display

### Window Too Large/Small

**Solution:**
1. Resize the window manually
2. Position is saved automatically
3. Or: Settings > Advanced > Reset Window State

### Detached Window Doesn't Sync

**Check:**
1. Ensure you haven't changed to a different publication in main window
2. The detached window shows which publication it's displaying in the title bar
3. Try closing and re-opening the detached window

### Windows Overlap After Display Disconnect

**Expected behavior:** Windows tile when a display disconnects

**If overlapping:**
1. Manually reposition windows
2. Or: Close all and re-detach

---

## Platform Notes

### macOS Only

Multi-monitor support is a macOS-only feature. iOS uses a single-window paradigm consistent with iPadOS design guidelines.

### Requirements

- macOS 14.0 (Sonoma) or later
- Any number of displays supported
- Works with built-in, external, and virtual displays

### Performance

- Each PDF viewer uses its own memory allocation
- Multiple PDFs = multiple memory usage
- Close unused windows to free memory

---

## See Also

- [Keyboard Shortcuts](keyboard-shortcuts) - All shortcuts including window management
- [macOS Guide](platform/macos-guide) - macOS-specific features
- [PDF Viewer](features#pdf-management) - PDF viewing features
