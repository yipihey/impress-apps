---
layout: default
title: Handoff
---

# Handoff

Continue reading papers seamlessly across your Mac, iPad, and iPhone using Apple's Handoff technology.

---

## Overview

When you're reading a PDF in imbib on one device, you can pick up exactly where you left off on another device. Handoff preserves:

- **Current page** - Jump directly to the page you were reading
- **Zoom level** - Maintain your preferred zoom setting
- **Paper context** - Opens the same paper automatically

---

## Requirements

Handoff requires:

- **Same Apple ID** - Signed in to iCloud on all devices
- **Bluetooth enabled** - Devices must be within Bluetooth range
- **Wi-Fi enabled** - Both devices on the same network (or personal hotspot)
- **Handoff enabled** - In System Settings / Settings

### Enabling Handoff

**macOS:**
1. Open **System Settings**
2. Go to **General > AirDrop & Handoff**
3. Enable **Allow Handoff between this Mac and your iCloud devices**

**iOS/iPadOS:**
1. Open **Settings**
2. Go to **General > AirPlay & Handoff**
3. Enable **Handoff**

---

## Using Handoff

### Starting a Reading Session

1. Open a paper in imbib
2. Navigate to the PDF tab
3. Begin reading normally

imbib automatically broadcasts your reading activity to nearby devices.

### Continuing on Another Device

**On Mac:**
1. Look for the imbib icon in the Dock (far left side)
2. Click to continue reading
3. The PDF opens to the exact page and zoom level

**On iPhone/iPad:**
1. Look for the imbib icon on the Lock Screen (bottom left) or App Switcher
2. Swipe up on the icon or tap it
3. The PDF opens to your last position

### Activity Types

imbib supports two Handoff activity types:

| Activity | What Transfers |
|----------|----------------|
| **Reading PDF** | Paper, page number, zoom level |
| **Viewing Paper** | Paper selection (for papers without PDFs) |

---

## Common Workflows

### Deep Reading on iPad, Quick Reference on Mac

1. Read papers in depth on iPad with Apple Pencil
2. When you need to cite, continue on Mac
3. Page position transfers automatically

### Commute Reading

1. Start reading on Mac before leaving
2. Continue on iPhone during commute
3. Resume on Mac when you arrive

### Paper Review Across Devices

1. Review a submission on your large monitor
2. Take notes on iPad with Apple Pencil
3. Handoff keeps both sessions synchronized

---

## Troubleshooting

### Handoff Icon Not Appearing

1. **Check Bluetooth** - Both devices need Bluetooth enabled
2. **Check Wi-Fi** - Both devices should be on the same network
3. **Verify Apple ID** - Sign in to the same iCloud account on both devices
4. **Restart Handoff** - Toggle Handoff off and on in Settings
5. **Sign out of iCloud** - Sign out and back in on both devices

### Wrong Page/Position

If the page number doesn't match:
1. Ensure you've scrolled to or clicked on the target page
2. Wait a moment for the position to sync
3. Changes are batched to avoid network congestion

### Handoff Works for Other Apps But Not imbib

1. **Check imbib is running** - The app must be open (not just in background on iOS)
2. **Verify PDF is open** - Navigate to the PDF tab specifically
3. **Try force-quitting imbib** - Restart the app on both devices

---

## Privacy

Handoff data stays within your Apple ecosystem:

- **Apple-to-Apple** - Data travels through iCloud infrastructure
- **Encrypted** - End-to-end encrypted between your devices
- **No third parties** - imbib doesn't send Handoff data to external servers
- **Minimal data** - Only paper ID, page, and zoom level are transferred

---

## Limitations

- **Requires same iCloud account** - Cannot hand off to family members' devices
- **Proximity required** - Devices must be within Bluetooth range (~30 feet)
- **PDF must be available** - The PDF must be downloaded on both devices (via iCloud sync)
- **Reading position only** - Annotations and notes sync via iCloud, not Handoff

---

## Related Features

- **iCloud Sync** - Full library synchronization across devices
- **Reading Position Sync** - Long-term position persistence (separate from Handoff)
- **Universal Clipboard** - Copy BibTeX on one device, paste on another

---

## See Also

- [iOS Guide](../platform/ios-guide) - iOS-specific features
- [macOS Guide](../platform/macos-guide) - macOS-specific features
- [Features](../features) - All imbib features
