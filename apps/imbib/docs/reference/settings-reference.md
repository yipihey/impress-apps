---
layout: default
title: Settings Reference
---

# Settings Reference

Complete reference for all imbib settings, organized by category.

---

## General

### Automation API

| Setting | Description | Default |
|---------|-------------|---------|
| Enable automation API | Allow external control via `imbib://` URL scheme | Off |
| Log automation requests | Write requests to console for debugging | Off |

When enabled, scripts and other apps can control imbib via URL scheme commands.

[Automation API Documentation →](../automation)

---

## Appearance

### Theme

| Setting | Options | Default |
|---------|---------|---------|
| Appearance | System, Light, Dark | System |
| Accent Color | System default, Blue, Purple, etc. | System |

### Icon Style

| Setting | Description | Default |
|---------|-------------|---------|
| Sidebar icons | Show icons next to sidebar items | On |
| Monochrome icons | Use single color for all icons | Off |

---

## Viewing (List View)

### Field Visibility

Control which fields appear in the paper list:

| Setting | Description | Default |
|---------|-------------|---------|
| Show Year | Publication year | On |
| Show Title | Paper title | On |
| Show Venue | Journal or conference | On |
| Show Citation Count | Number of citations | Off |
| Show Unread Indicator | Blue dot for unread | On |
| Show Attachment Indicator | Paperclip for PDFs | On |
| Show arXiv Categories | Category tags | Off |

### Abstract Preview

| Setting | Range | Default |
|---------|-------|---------|
| Abstract Lines | 0-5 | 2 |

Set to 0 to hide abstract preview entirely.

### Row Density

| Setting | Description |
|---------|-------------|
| Compact | Minimal spacing, more papers visible |
| Standard | Default spacing |
| Comfortable | More spacing, easier reading |

---

## Notes

### Editor Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Font Size | Note editor font size | System default |
| Line Spacing | Space between lines | Normal |
| Spell Check | Enable spell checking | On |

### Modal Editing (Power Users)

| Setting | Description | Default |
|---------|-------------|---------|
| Enable Modal Editing | Use Vim/Helix-style editing | Off |
| Mode | Vim, Helix | Helix |
| Show Mode Indicator | Display current mode | On |

### Notes Panel Position

| Setting | Options (macOS) |
|---------|-----------------|
| Position | Below PDF, Right of PDF, Left of PDF |

---

## Sources (API Keys)

Configure credentials for online sources:

### NASA ADS

| Setting | Description | Required |
|---------|-------------|----------|
| API Key | Your ADS API token | Yes |

Get a free key at: [ui.adsabs.harvard.edu](https://ui.adsabs.harvard.edu/)

### OpenAlex

| Setting | Description | Required |
|---------|-------------|----------|
| Email | Your email for higher rate limits | No (optional) |

Adding email increases rate limit from 10/sec to 100K/day.

### Semantic Scholar

| Setting | Description | Required |
|---------|-------------|----------|
| API Key | Optional API key for higher limits | No |

### Other Sources

arXiv, Crossref, DBLP, and PubMed require no API keys.

---

## PDF

### Source Priority

| Setting | Behavior |
|---------|----------|
| Preprint First | Try arXiv before publisher (faster, usually free) |
| Publisher First | Try DOI/publisher before arXiv |

### Library Proxy

| Setting | Description | Default |
|---------|-------------|---------|
| Enable Proxy | Route publisher requests through proxy | Off |
| Proxy URL | Your institution's proxy URL | — |

**Preset institutions:** Common university proxies are pre-configured.

**Custom format:** `https://proxy.university.edu/login?url=`

### Auto-Download

| Setting | Description | Default |
|---------|-------------|---------|
| Auto-download PDFs | Download PDF when paper is added | On |
| Download over cellular | Allow PDF downloads on cellular (iOS) | Off |

---

## Enrichment

### Citation Sources

Enable/disable sources for fetching additional metadata:

| Source | Data Provided | Default |
|--------|---------------|---------|
| Crossref | DOI metadata, references | On |
| OpenAlex | Citations, OA status, affiliations | On |
| Semantic Scholar | Citations, references, embeddings | On |
| ADS | Astronomy-specific metadata | On |

### Enrichment Behavior

| Setting | Description | Default |
|---------|-------------|---------|
| Auto-enrich on add | Fetch metadata when papers are added | On |
| Update existing | Overwrite existing metadata | Off |
| Fetch references | Download reference lists | Off |
| Fetch citations | Download citing papers | Off |

---

## Inbox

### Age Limit

How long papers stay in Inbox before auto-dismissing:

| Setting | Duration |
|---------|----------|
| 1 week | 7 days |
| 2 weeks | 14 days |
| 1 month | 30 days |
| **3 months** | 90 days (default) |
| 6 months | 180 days |
| 1 year | 365 days |
| Unlimited | Never auto-dismiss |

Age is based on when the paper was added to Inbox, not publication date.

### Keep Destination

| Setting | Description |
|---------|-------------|
| Auto | Create/use "Keep" library |
| [Library Name] | Specific library |

### Muting

Mute sources to hide matching papers:

| Mute Type | Effect |
|-----------|--------|
| Author | Hide papers by this author |
| DOI | Hide this specific paper |
| Bibcode | Hide this specific paper (ADS) |
| Venue | Hide papers from this journal |
| arXiv Category | Hide papers from this category |

---

## Recommendations

### Enable/Disable

| Setting | Description | Default |
|---------|-------------|---------|
| Enable recommendations | Add "Recommended" sort option to Inbox | Off |

### Engine Type

| Engine | Description |
|--------|-------------|
| **Weighted** | Transparent formula with adjustable weights (default) |
| Semantic | AI-powered similarity using embeddings |
| Hybrid | Combines weighted and semantic |

Semantic and Hybrid require building a similarity index.

### Discovery & Diversity

| Setting | Range | Default |
|---------|-------|---------|
| Serendipity frequency | 1 per 3-50 papers | 1 per 10 |
| Negative preference decay | 7-365 days | 90 days |

### Feature Weights

Adjust importance of each signal (0.0 to 2.0, or -2.0 to 0.0 for penalties):

**Content Signals:**
- Author Match
- Keyword Match
- Topic Match
- Journal Match
- Abstract Similarity

**Behavioral Signals:**
- Keep History
- Star History
- Citation Overlap
- Author Network

**Metadata Signals:**
- Recency
- Citation Count
- Open Access

**Penalty Signals:**
- Dismiss History
- Muted Authors
- Muted Keywords

### Presets

Quick configurations:

| Preset | Focus |
|--------|-------|
| Focused | Deep dive in specific area |
| Balanced | Default mix |
| Exploratory | Discovery and serendipity |
| Research | Citations and literature review |

[Full Recommendation Engine Guide →](../features/recommendation-engine)

---

## Sync (iCloud)

### Enable/Disable

| Setting | Description | Default |
|---------|-------------|---------|
| Enable iCloud Sync | Sync data across devices | On |

### What Syncs

- Papers and metadata
- PDFs
- Collections and Smart Searches
- Reading positions
- Notes
- Inbox state
- Settings

### Sync Controls

| Setting | Description |
|---------|-------------|
| Sync PDFs | Include PDFs in sync (uses iCloud storage) |
| Sync over cellular | Allow sync on cellular (iOS) |
| Force sync now | Manually trigger sync |

### Conflict Resolution

| Setting | Behavior |
|---------|----------|
| Most recent wins | Latest edit takes precedence |
| Merge | Combine changes where possible |

---

## Import/Export

### Import Settings

| Setting | Options | Default |
|---------|---------|---------|
| Duplicate handling | Ask, Skip, Import as new | Ask |
| Default import library | [Library name] | Default library |

### Export Settings

| Setting | Description |
|---------|-------------|
| Default format | BibTeX, RIS, CSV, etc. |
| Include PDFs | Bundle PDFs with export |
| Include notes | Include private notes |

### BibTeX Options

| Setting | Description | Default |
|---------|-------------|---------|
| Preserve Bdsk-File fields | Keep BibDesk file references | On |
| Normalize entries | Clean up formatting | Off |
| Sort entries | Alphabetical by cite key | Off |

---

## Keyboard Shortcuts

### Customization (macOS)

Currently, shortcuts cannot be customized in-app. Use System Settings → Keyboard → App Shortcuts to override specific menu items.

### Shortcut Display

| Setting | Description |
|---------|-------------|
| Show in menus | Display shortcuts in menu items |
| Show in tooltips | Display shortcuts on hover |

---

## Advanced

### Developer Options

| Setting | Description | Default |
|---------|-------------|---------|
| Show console | Access debug console | Button |
| Show developer docs | Include architecture docs in Help | Off |

### Cache Management

| Setting | Description |
|---------|-------------|
| Clear cache | Remove thumbnails and temp files |
| Clear search index | Rebuild full-text index |
| Reset to defaults | Reset all settings (preserves data) |

### Reset

| Setting | Description |
|---------|-------------|
| Reset to First Run | Delete all data and start fresh |

**Warning:** This deletes all libraries, papers, and settings. API keys are preserved.

---

## Settings Sync

Most settings sync across devices via iCloud:

**Synced:**
- All recommendation weights
- Inbox age limits
- Muted items
- Display preferences
- Default libraries

**Not Synced (Device-Local):**
- API keys (in Keychain)
- Semantic search index
- Cache
- Window positions

---

## Platform Differences

| Setting | macOS | iOS |
|---------|-------|-----|
| Notes panel position | Configurable | Fixed |
| Touch Bar | Available | N/A |
| Keyboard shortcuts | Full | External keyboard |
| File Provider location | Finder sidebar | Files app |
| Background refresh | Always | iOS-controlled |

---

## Default Values Reset

To reset a specific setting category:
1. Go to that settings section
2. Look for "Reset to Defaults" button
3. Confirm the reset

To reset all settings:
1. Settings → Advanced
2. Reset to Defaults
3. Confirm (data is preserved, only settings reset)

---

## See Also

- [Getting Started](../getting-started) - Initial setup
- [Keyboard Shortcuts](../keyboard-shortcuts) - All shortcuts
- [macOS Guide](../platform/macos-guide) - macOS-specific settings
- [iOS Guide](../platform/ios-guide) - iOS-specific settings
