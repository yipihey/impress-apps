---
layout: default
title: Widgets
---

# Widgets

imbib provides Home Screen and Lock Screen widgets to keep you connected to your paper library at a glance.

---

## Available Widgets

### Inbox Count

Shows the number of papers waiting in your Inbox.

**Sizes:** Small, Medium

**Information displayed:**
- Total inbox count
- Starred papers count
- Unread papers count

**Tap action:** Opens imbib Inbox

### Recent Papers

Shows recently added papers from your library.

**Sizes:** Medium, Large

**Information displayed:**
- Paper titles
- First author names
- Publication year

**Tap action:** Opens the tapped paper in imbib

### Reading Progress

Track your reading across libraries.

**Sizes:** Small, Medium

**Information displayed:**
- Papers read this week/month
- Reading streak (consecutive days)
- Progress toward your goal (if set)

**Tap action:** Opens library with reading stats

### Quick Search

Search your library directly from the widget.

**Sizes:** Medium

**Features:**
- Search field
- Recent search suggestions
- Source selector (Library, ADS, arXiv)

**Tap action:** Opens imbib with search query

### Smart Search Results

Shows papers from a specific Smart Search.

**Sizes:** Medium, Large

**Configuration:**
- Select which Smart Search to display
- Choose number of papers (3, 5, or 10)

**Tap action:** Opens the Smart Search in imbib

---

## Adding Widgets

### iOS Home Screen

1. Long-press on your Home Screen
2. Tap the **+** button (top left)
3. Search for "imbib"
4. Select a widget
5. Choose widget size
6. Tap **Add Widget**
7. Position the widget
8. Tap **Done**

### iOS Lock Screen

1. Long-press on your Lock Screen
2. Tap **Customize**
3. Select the Lock Screen
4. Tap the widget area (below time)
5. Tap **+** to add widgets
6. Select imbib widgets
7. Tap **Done**

### macOS Notification Center

1. Click the date/time in menu bar
2. Scroll to bottom of Notification Center
3. Click **Edit Widgets**
4. Find imbib in the list
5. Click **+** on desired widgets
6. Drag to reorder
7. Click **Done**

### macOS Desktop (Sonoma+)

1. Right-click on desktop
2. Select **Edit Widgets**
3. Find imbib widgets
4. Click **+** or drag to desktop
5. Click **Done**

---

## Configuring Widgets

### Widget Settings

After adding a widget:

1. Long-press the widget
2. Select **Edit Widget** (iOS) or **Edit "imbib"** (macOS)
3. Configure options:
   - Which library to display
   - Which Smart Search to use
   - Number of items to show
   - Time period for statistics

### Available Options

| Widget | Options |
|--------|---------|
| Inbox Count | None (always shows total) |
| Recent Papers | Library selection, count (3/5/10) |
| Reading Progress | Time period (week/month/year), goal |
| Quick Search | Default source |
| Smart Search | Smart Search selection, count |

---

## Widget Refresh

### Automatic Refresh

Widgets update automatically:
- When you open imbib
- When data changes (new papers, reading activity)
- Periodically in the background (iOS limits this)

### Manual Refresh

iOS doesn't support manual widget refresh, but you can:
1. Open imbib briefly
2. Widget updates when app syncs

### Background Updates

Enable background app refresh for timely updates:
1. Go to **Settings > General > Background App Refresh**
2. Ensure imbib is enabled
3. Widgets receive updates more frequently

---

## Widget Sizes

### Small (iOS)

Best for: Inbox count, Reading progress

Space for: Single metric or small stat

### Medium

Best for: All widgets

Space for: 3-5 papers or multiple stats

### Large

Best for: Recent Papers, Smart Search Results

Space for: 5-10 papers with more detail

### Lock Screen (iOS)

Best for: Inbox count

Space for: Single number or icon

---

## Interactive Widgets (iOS 17+)

Some widgets support interaction without opening the app:

### Inbox Widget

- Tap inbox count to open Inbox
- Long-press for quick actions

### Quick Search Widget

- Type search query directly in widget
- Tap recent search to execute
- Results open in app

---

## Troubleshooting

### Widget Not Updating

1. Open imbib to trigger sync
2. Check Background App Refresh is enabled
3. Force restart widget: remove and re-add
4. Check iCloud connectivity

### Widget Shows Old Data

1. Tap widget to open app
2. Let app sync
3. Return to Home Screen
4. Widget should update

### Widget Not Appearing in List

1. Ensure imbib is installed (not beta/TestFlight for production widgets)
2. Force quit and reopen the Widgets panel
3. Restart your device
4. Check for app updates

### Widget Shows "Unable to Load"

1. Open imbib and ensure it works
2. Check for available storage space
3. Remove and re-add the widget
4. Sign out and back into iCloud

### Lock Screen Widget Not Showing

1. Verify iOS 16+ is installed
2. Check Lock Screen widget area has space
3. Some widgets only work in certain sizes

---

## Tips

### Widget Stacks (iOS)

Stack multiple imbib widgets:
1. Add a second imbib widget
2. Drag it onto the first widget
3. Creates a stack you can swipe through
4. Use Smart Stack for automatic switching

### StandBy Mode (iOS 17+)

Use widgets in StandBy:
1. Charge iPhone horizontally
2. Add imbib widgets to StandBy view
3. See paper updates while charging

### Widget Suggestions

iOS may suggest imbib widgets based on usage:
- Regular readers may see suggestions
- Accept suggestions for auto-placement
- Decline to hide from suggestions

---

## Privacy

### Widget Data

Widgets display:
- Paper counts (not titles on Lock Screen)
- Paper titles (on Home Screen only)
- No sensitive content on Lock Screen

### Widget Permissions

Widgets use the same data access as the app:
- No additional permissions needed
- No network calls from widget directly
- Data comes from shared app storage

---

## Platform Comparison

| Feature | iOS | macOS |
|---------|-----|-------|
| Home Screen widgets | Yes | Desktop (Sonoma+) |
| Lock Screen widgets | Yes (iOS 16+) | No |
| Notification Center | No | Yes |
| Interactive widgets | Yes (iOS 17+) | Limited |
| Widget stacks | Yes | No |
| StandBy mode | Yes (iOS 17+) | No |

---

## See Also

- [iOS Guide](../platform/ios-guide) - iOS-specific features
- [macOS Guide](../platform/macos-guide) - macOS-specific features
- [Inbox Management](inbox-management) - Managing the inbox
- [Smart Searches](../smart-searches) - Creating Smart Search feeds
