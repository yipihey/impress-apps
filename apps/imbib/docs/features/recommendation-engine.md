---
layout: default
title: Recommendation Engine
---

# Recommendation Engine

imbib includes a transparent recommendation engine that helps surface the most relevant papers in your Inbox. Unlike black-box algorithms, you can see and adjust exactly how papers are ranked.

---

## Overview

The recommendation engine scores papers based on multiple signals:

- Your reading history (what you've kept vs. dismissed)
- Author and topic preferences learned from your library
- Recency and citation metrics
- Semantic similarity to papers you've liked

When enabled, you can sort your Inbox by "Recommended" to see papers ranked by predicted relevance.

---

## Enabling Recommendations

1. Open **Settings > Recommendations**
2. Toggle **Enable recommendation training**
3. The "Recommended" sort option appears in list view sort menus

When disabled, the "Recommended" sort option is hidden. If you had "Recommended" sort active and disable training, the sort falls back to Date Added.

---

## Modes

Three modes control the overall character of recommendations:

### Focused
"Papers from authors and topics you know."

Emphasizes author affinity and topic matching. Good for deep dives in a specific area.

### Balanced (Default)
"Mix of familiar and new."

Even weights across all signals. Good for most users.

### Explorer
"Surprise me with new directions."

High citation velocity and AI similarity, low author affinity. Good for finding new research areas.

Select a mode using the segmented control at the top of Settings > Recommendations.

---

## Variety Slider

Controls how often "discovery" papers appear — papers from outside your usual reading patterns.

- **Less**: Mostly papers matching your preferences
- **More**: Frequent surprises from new areas

This maps to the serendipity frequency (1 discovery paper per N papers).

---

## Feature Weights

In Advanced Settings, you can adjust how much each of 9 signals influences rankings.

### Your Preferences

| Feature | Description | Default |
|---------|-------------|---------|
| Authors you follow | Learned preference for authors | 0.8 |
| Topics you read | Learned preference for topics | 0.6 |
| Your tags | Papers matching your tag interests | 0.5 |
| Journals you read | Learned preference for venues | 0.4 |

### Discovery

| Feature | Description | Default |
|---------|-------------|---------|
| Collaborators of your authors | Co-authors of library authors | 0.3 |
| Recently published | Newer papers score higher | 0.3 |
| Trending in the field | High citation velocity | 0.2 |
| Matches your searches | Papers matching saved smart searches | 0.6 |
| Similar to your library | AI-powered semantic similarity | 0.5 |

### Mute Filters (Always Active)

| Filter | Effect |
|--------|--------|
| Muted Author | -1.0 penalty |
| Muted Category | -0.8 penalty |
| Muted Venue | -0.6 penalty |

Mute filters are binary (on/off) and not adjustable via sliders.

### Adjusting Weights

1. Go to **Settings > Recommendations**
2. Expand **Advanced settings**
3. Use sliders to adjust each weight (0.0 to 2.0)
4. Changes apply immediately to Inbox ranking

**Tips:**
- Increase a weight to make that signal more important
- Set to 0.0 to ignore a signal entirely

---

## Anti-Filter-Bubble Features

### Serendipity Slots (Variety)

Every N papers, one "wild card" paper is inserted to expose you to new topics. Controlled via the Variety slider or the numeric stepper in Advanced settings.

- Default: 1 per 10 papers
- Range: 3 to 50

### Negative Preference Decay

Dismissed papers influence recommendations, but that influence fades over time. Each negative affinity decays by 5% per week of inactivity.

- Default decay period: 90 days
- Range: 7 to 365 days

---

## Training History

The engine learns from your actions. View and manage this training data:

1. Go to **Settings > Recommendations**
2. Click **View training history**
3. See recent keep/dismiss/star actions
4. Click **Undo** to remove a training signal

### What Trains the Engine

| Action | Signal | Strength |
|--------|--------|----------|
| Keep paper | Positive | High |
| Star paper | Positive | Very High |
| Dismiss paper | Negative | Medium |
| Time spent reading | Positive | Low |
| More Like This | Positive | Very High |
| Less Like This | Negative | Very High |

### Resetting Training

To start fresh:
1. Expand **Advanced settings** in Recommendation settings
2. Click **Reset to Defaults**
3. Weights return to defaults; training history is preserved in the training history view

---

## How Scores Are Calculated

The final score is a weighted sum:

```
Score = Σ (feature_value × feature_weight)
```

For example:
```
Authors you follow:     0.8 × 0.8 = 0.64   (author you've kept before)
Topics you read:        0.6 × 0.7 = 0.42   (in your preferred topic)
Recently published:     0.3 × 0.9 = 0.27   (published last week)
Muted Author:          -1.0 × 0.0 = 0.00   (not muted)
────────────────────────────────────────────
Total Score:     1.33
```

Papers are sorted by total score in descending order.

---

## Viewing Why a Paper Ranked

In the Inbox with "Recommended" sort:

1. Each paper shows a one-line reason (e.g., "authors you follow · recently published")
2. Click **Show Recommendation Details** to see the full breakdown
3. The breakdown shows context-specific details (which authors matched, which topics, etc.)
4. Use "More like this" / "Less like this" to train the engine directly

---

## Performance

- All recommendation processing happens on-device
- No paper data sent to external servers
- Scoring is fast and works offline
- If AI Similarity weight > 0, a local embedding index is used (built on demand)

---

## Sync Across Devices

- Weights sync via iCloud
- Training history syncs via iCloud
- Embedding index is device-local (rebuilt on each device)

---

## See Also

- [Inbox Management](inbox-management) - Managing the paper inbox
- [Smart Searches](../smart-searches) - Automated paper discovery
