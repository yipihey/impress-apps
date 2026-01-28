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
2. Toggle **Enable recommendation sorting**
3. Papers in Inbox can now be sorted by relevance

Once enabled, the "Recommended" sort option appears in the Inbox toolbar.

---

## Engine Types

imbib offers three recommendation algorithms, each with different tradeoffs:

### Weighted Features (Default)

A transparent, interpretable scoring formula.

**How it works:**
- Calculates a score from weighted features (author match, topic match, recency, etc.)
- You can see and adjust each weight
- Fast, works offline

**Best for:**
- Users who want full control
- Understanding why papers are ranked
- Low-resource devices

### Semantic Similarity

AI-powered similarity matching using embeddings.

**How it works:**
- Converts paper abstracts to vector embeddings
- Finds papers similar to ones you've liked
- Discovers connections across different terminology

**Best for:**
- Finding papers outside your usual keywords
- Interdisciplinary research
- When you trust the AI recommendations

**Requirements:**
- Building a similarity index (one-time, may be slow for large libraries)
- More memory usage

### Hybrid

Combines weighted features with semantic similarity.

**How it works:**
- Uses weighted features as the base score
- Adds semantic similarity as a signal
- Balances interpretability with discovery

**Best for:**
- Best of both worlds
- Users who want transparency plus AI assistance

---

## Building the Similarity Index

For Semantic and Hybrid modes, you need to build an embedding index:

1. Go to **Settings > Recommendations**
2. Select **Semantic** or **Hybrid** engine type
3. Click **Build Similarity Index**
4. Wait for indexing to complete (progress shown)

The index is stored locally and persists across app launches. Rebuild if you add many new papers to your library.

---

## Feature Weights

In Weighted and Hybrid modes, you can adjust how much each signal influences rankings.

### Content Signals

| Feature | Description | Default |
|---------|-------------|---------|
| Author Match | Paper by authors you've kept before | 0.8 |
| Keyword Match | Contains keywords from papers you like | 0.6 |
| Topic Match | In research areas you frequently read | 0.7 |
| Journal Match | From journals you prefer | 0.4 |
| Abstract Similarity | Text similarity to liked papers | 0.5 |

### Behavioral Signals

| Feature | Description | Default |
|---------|-------------|---------|
| Keep History | Based on papers you've kept | 0.9 |
| Star History | Based on papers you've starred | 1.0 |
| Citation Overlap | Cites or cited by your papers | 0.6 |
| Author Network | By collaborators of preferred authors | 0.3 |

### Metadata Signals

| Feature | Description | Default |
|---------|-------------|---------|
| Recency | Newer papers score higher | 0.5 |
| Citation Count | Well-cited papers score higher | 0.3 |
| Open Access | Prefer papers with free PDFs | 0.1 |

### Penalty Signals (Negative Weights)

| Feature | Description | Default |
|---------|-------------|---------|
| Dismiss History | Papers similar to dismissed ones | -0.7 |
| Muted Authors | Papers by muted authors | -1.0 |
| Muted Keywords | Papers with muted keywords | -0.8 |

### Adjusting Weights

1. Go to **Settings > Recommendations**
2. Expand a feature category
3. Use the slider to adjust each weight (0.0 to 2.0, or -2.0 to 0.0 for penalties)
4. Changes apply immediately to Inbox ranking

**Tips:**
- Increase a weight to make that signal more important
- Set to 0.0 to ignore a signal entirely
- Negative weights push matching papers down

---

## Presets

Quick configurations for different research styles:

### Focused
Emphasizes author and topic matching. Good for deep dives in a specific area.

**Adjustments:**
- High: Author Match, Topic Match, Keep History
- Low: Recency, Discovery signals

### Balanced
Default settings that work well for most users.

### Exploratory
Emphasizes discovery and serendipity. Good for finding new directions.

**Adjustments:**
- High: Abstract Similarity, Semantic signals
- Low: Author Match, Topic Match

### Research
Optimized for literature review and citation tracking.

**Adjustments:**
- High: Citation Overlap, Citation Count
- Medium: Author Network

To apply a preset, click its button in **Settings > Recommendations > Presets**.

---

## Anti-Filter-Bubble Features

The engine includes safeguards against creating an echo chamber:

### Serendipity Slots

Every N papers, one "wild card" paper is inserted to expose you to new topics.

**Setting:** "Insert one serendipity paper every X papers"
- Default: 1 per 10 papers
- Range: 3 to 50
- Lower = more serendipity, higher = more focused

### Negative Preference Decay

Dismissed papers influence recommendations, but that influence fades over time.

**Setting:** "Forget dismissals after X days"
- Default: 90 days
- Range: 7 to 365 days
- Prevents permanent exclusion of topics you might revisit

---

## Training History

The engine learns from your actions. View and manage this training data:

1. Go to **Settings > Recommendations**
2. Click **View Training History**
3. See recent keep/dismiss/star actions
4. Click **Undo** to remove a training signal

### What Trains the Engine

| Action | Signal | Strength |
|--------|--------|----------|
| Keep paper | Positive | High |
| Star paper | Positive | Very High |
| Dismiss paper | Negative | Medium |
| Delete paper | Negative | Low |
| Time spent reading | Positive | Low |

### Resetting Training

To start fresh:
1. Click **Reset to Defaults** in Recommendation settings
2. This clears learned preferences
3. Weights return to defaults
4. Training history is cleared

---

## How Scores Are Calculated

The final score is a weighted sum:

```
Score = Σ (feature_value × feature_weight)
```

For example:
```
Author Match:    0.8 × 0.8 = 0.64   (author you've kept before)
Topic Match:     0.7 × 0.7 = 0.49   (in your preferred topic)
Recency:         0.5 × 0.9 = 0.45   (published last week)
Dismiss History: -0.7 × 0.3 = -0.21 (similar to a dismissed paper)
────────────────────────────────────
Total Score:     1.37
```

Papers are sorted by total score in descending order.

---

## Viewing Why a Paper Ranked

In the Inbox with "Recommended" sort:

1. Hover over a paper (macOS) or long-press (iOS)
2. Select **Show Recommendation Details**
3. See the breakdown of scores by feature
4. Understand exactly why this paper ranked where it did

---

## Performance Tips

### Large Libraries

If you have thousands of papers:
- Building the semantic index may be slow initially
- Use Weighted mode for faster performance
- Consider excluding old papers from indexing

### Battery Usage

- Weighted mode uses minimal resources
- Semantic mode uses more CPU/memory when indexing
- Once indexed, all modes are efficient

### Sync Across Devices

- Weights sync via iCloud
- Training history syncs via iCloud
- Semantic index is device-local (rebuild on each device)

---

## Troubleshooting

### Recommendations Seem Off

1. Check your training history for accidental signals
2. Undo any incorrect training events
3. Let the engine learn from more actions
4. Try adjusting weights manually

### Index Building Fails

1. Ensure sufficient storage space
2. Keep app in foreground during indexing
3. Try with a smaller library first
4. Check for corrupted paper records

### No "Recommended" Sort Option

1. Verify recommendations are enabled in Settings
2. Ensure you're in Inbox (not Library)
3. Restart the app

---

## Privacy

All recommendation processing happens on-device:
- No paper data sent to external servers
- Embeddings generated locally
- Training history stored in your iCloud (if enabled)
- No third-party analytics

---

## See Also

- [Inbox Management](inbox-management) - Managing the paper inbox
- [Smart Searches](../smart-searches) - Automated paper discovery
