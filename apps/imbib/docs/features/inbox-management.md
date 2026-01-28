---
layout: default
title: Inbox Management
---

# Inbox Management

The Inbox is your triage center for new papers. Papers arrive from Smart Search feeds, the Share Extension, or manual additions, and you decide which to keep, star, or dismiss.

---

## How Papers Enter the Inbox

### Smart Search Feeds

When you create a Smart Search with "Feed to Inbox" enabled:

1. The search runs on your configured schedule (hourly, daily, weekly)
2. New papers matching the query are added to Inbox
3. Papers you've already seen are not re-added
4. Duplicates are automatically detected and merged

### Share Extension

Papers can be sent to Inbox from:
- Safari or Chrome (via browser extension)
- Other apps using the Share Sheet
- PDF files shared with imbib

### Manual Addition

- Use **File > Send to Inbox** on any paper
- Right-click a paper and select **Send to Inbox**
- From search results, click the inbox icon

---

## Triage Actions

The core workflow is deciding what to do with each paper:

| Action | Shortcut | Result |
|--------|----------|--------|
| **Keep** | `K` | Add to your library, remove from Inbox |
| **Star** | `S` | Mark as important, keep in Inbox for later |
| **Dismiss** | `D` | Remove without saving (trains recommendations) |

### Keep

When you keep a paper:
1. Paper moves to your default library (or chosen library)
2. PDF download is initiated (if available)
3. Removed from Inbox
4. Positive signal sent to recommendation engine

### Star

Starring is for papers you want to read but aren't ready to file:
1. Paper stays in Inbox but is marked with a star
2. Starred papers appear in the "Starred" filter
3. You can star and later keep or dismiss

### Dismiss

Dismissing removes unwanted papers:
1. Paper is removed from Inbox
2. Not added to any library
3. Negative signal sent to recommendation engine
4. After decay period, the signal expires

---

## Sorting Options

Sort the Inbox to find papers efficiently:

| Sort | Description |
|------|-------------|
| Date Added | Newest arrivals first (default) |
| Title | Alphabetical by title |
| Authors | Alphabetical by first author |
| Year | Most recent publications first |
| Recommended | Relevance based on your preferences |

### Recommended Sort

When the recommendation engine is enabled:
1. Papers are scored based on learned preferences
2. Higher-scoring papers appear first
3. See **Settings > Recommendations** to tune weights

---

## Filtering

Reduce the Inbox to specific subsets:

| Filter | Shows |
|--------|-------|
| All | Every paper in Inbox |
| Starred | Only starred papers |
| Unread | Papers you haven't opened |
| With PDF | Papers that have PDFs attached |
| Today | Papers added today |

Combine filters by selecting multiple options.

---

## Batch Operations

Work on multiple papers at once:

1. **Select multiple papers:**
   - `Cmd+Click` to select individual papers
   - `Shift+Click` to select a range
   - `Cmd+A` to select all (in current filter)

2. **Apply action:**
   - Press `K` to keep all selected
   - Press `D` to dismiss all selected
   - Use menu or toolbar buttons

### Keyboard-Driven Triage

For fast triage without mouse:

1. Press `↓` to select first paper
2. Review the paper (detail pane updates)
3. Press `K`, `S`, or `D`
4. Selection auto-advances to next paper
5. Repeat until done

---

## Age Limits

Configure how long papers stay in Inbox:

1. Go to **Settings > Inbox**
2. Choose an age limit:

| Setting | Behavior |
|---------|----------|
| 1 week | Papers older than 7 days auto-dismiss |
| 2 weeks | Papers older than 14 days auto-dismiss |
| 1 month | Papers older than 30 days auto-dismiss |
| 3 months | Default setting |
| 6 months | Papers older than 180 days auto-dismiss |
| 1 year | Papers older than 365 days auto-dismiss |
| Unlimited | Papers stay forever until manually handled |

Auto-dismissed papers do not train the recommendation engine.

---

## Muting

Reduce noise by muting sources you're not interested in.

### Muting Authors

To stop seeing papers from a specific author:

1. Right-click a paper by that author
2. Select **Mute Author > [Author Name]**
3. Future papers by this author are auto-dismissed

### Muting Keywords

To stop seeing papers about a topic:

1. Right-click a paper with that keyword
2. Select **Mute Keyword > [Keyword]**
3. Future papers containing this keyword are auto-dismissed

### Muting Journals

To stop seeing papers from a journal:

1. Right-click a paper from that journal
2. Select **Mute Journal > [Journal Name]**
3. Future papers from this journal are auto-dismissed

### Managing Mutes

View and manage muted items:

1. Go to **Settings > Inbox**
2. See lists of muted authors, keywords, and journals
3. Click **X** to unmute an item
4. Muted items sync across devices

---

## Inbox Sources

View papers by their origin:

1. Click the **Sources** tab in Inbox
2. See a list of Smart Searches feeding the Inbox
3. Click a source to filter to papers from that feed
4. Use this to review one research area at a time

---

## Integration with Library

### Default Library

Set which library receives kept papers:

1. Go to **Settings > Libraries**
2. Set **Default Library** for Inbox
3. Kept papers go to this library automatically

### Choosing Library at Keep Time

To choose a different library:

1. Right-click the paper
2. Select **Keep to > [Library Name]**
3. Paper moves to the selected library

### Collection Assignment

You can also assign to a collection when keeping:

1. Right-click the paper
2. Select **Keep to > [Collection Name]**
3. Paper is added to library and collection

---

## Tips for Effective Triage

### Daily Routine

1. Open Inbox each morning
2. Sort by Recommended
3. Quick-scan titles and abstracts
4. Keep promising papers, dismiss the rest
5. Star papers for weekend deep-reading

### Managing Overflow

If your Inbox grows too large:

1. Use batch select (`Cmd+A`)
2. Dismiss all
3. Don't worry—dismissed papers can be re-added
4. Smart Searches will bring back truly relevant papers

### Smart Search Tuning

If you're seeing too much noise:

1. Refine your Smart Search queries
2. Add exclusion terms
3. Mute problematic authors/keywords
4. Reduce feed frequency

### Preserving Papers

If you're not sure about a paper:

1. Star it instead of dismissing
2. Come back to starred papers later
3. Starring doesn't train recommendations negatively

---

## Troubleshooting

### Papers Not Appearing

1. Check Smart Search "Feed to Inbox" is enabled
2. Verify the search query matches expected papers
3. Check if papers are being auto-dismissed (mutes, age limit)
4. Try refreshing with `Cmd+R`

### Too Many Papers

1. Reduce Smart Search frequency
2. Enable age limits
3. Use muting to filter noise
4. Narrow Smart Search queries

### Duplicate Papers

1. imbib auto-deduplicates by DOI/arXiv ID
2. If duplicates appear, report as a bug
3. Manually dismiss duplicates

### Sync Issues

1. Check iCloud is connected
2. Inbox state syncs across devices
3. Give sync time to complete (usually seconds)

---

## See Also

- [Smart Searches](../smart-searches) - Creating feeds for Inbox
- [Recommendation Engine](recommendation-engine) - How papers are ranked
- [Keyboard Shortcuts](../keyboard-shortcuts) - Triage shortcuts
