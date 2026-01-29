---
layout: default
title: Cite Key Formatting
---

# Cite Key Formatting

Cite keys are unique identifiers for papers in your BibTeX library. imbib provides flexible cite key generation with multiple presets and full customization support.

---

## Quick Start

1. Go to **Settings > Import & Export**
2. Select a **Cite Key Format** preset
3. Preview shows what your format produces
4. Toggle **Lowercase** if preferred

New papers will use your chosen format. Existing cite keys are preserved unless you explicitly regenerate them.

---

## Format Presets

imbib includes five built-in presets:

| Preset | Format | Example |
|--------|--------|---------|
| **Classic** | `%a%Y%t` | `Einstein1905Electrodynamics` |
| **Authors+Year** | `%a2_%Y` | `Einstein_Podolsky_1935` |
| **Short** | `%a:%y` | `Einstein:05` |
| **Full Authors** | `%A%Y` | `EinsteinPodolskyRosen1935` |
| **Custom** | (your format) | (varies) |

### Classic (Default)

The traditional format: first author's last name + full year + first significant title word.

```
Hawking1974Black
Witten1995String
Maldacena1999Large
```

### Authors+Year

First two author last names separated by underscore, plus year. Good for multi-author papers.

```
Einstein_Podolsky_1935
Bardeen_Cooper_1957
Freedman_Madore_2001
```

### Short

Compact format: last name + colon + two-digit year. Useful for quick typing.

```
Hawking:74
Witten:95
Maldacena:99
```

### Full Authors

Up to 3 author names concatenated (EtAl if more), plus year. Maximally descriptive.

```
EinsteinPodolskyRosen1935
BardeenCooperSchrieffer1957
PerlmutterEtAl1999
```

---

## Custom Formats

Create your own format using specifiers:

### Author Specifiers

| Specifier | Description | Example |
|-----------|-------------|---------|
| `%a` | First author last name | `Einstein` |
| `%a2` | First two authors | `EinsteinPodolsky` |
| `%a3` | First three authors | `EinsteinPodolskyRosen` |
| `%A` | All authors (max 3, then EtAl) | `EinsteinPodolskyRosen` or `PerlmutterEtAl` |

### Year Specifiers

| Specifier | Description | Example |
|-----------|-------------|---------|
| `%y` | Two-digit year | `05` |
| `%Y` | Four-digit year | `2005` |

### Title Specifiers

| Specifier | Description | Example |
|-----------|-------------|---------|
| `%t` | First significant title word | `Electrodynamics` |
| `%T2` | First 2 significant words | `ElectrodynamicsMoving` |
| `%T3` | First 3 significant words | `ElectrodynamicsMovingBodies` |

**Note:** "Significant" words exclude common words like "the", "a", "an", "on", "of", etc.

### Uniqueness Specifiers

| Specifier | Description | Example |
|-----------|-------------|---------|
| `%u` | Lowercase letter suffix (a-z) | `Einstein1905a` |
| `%n` | Numeric suffix (1, 2, 3...) | `Einstein19051` |

These are appended automatically when needed to avoid duplicates.

### Field Specifiers

| Specifier | Description | Example |
|-----------|-------------|---------|
| `%f{journal}` | Journal name | `PhysRev` |
| `%f{volume}` | Volume number | `47` |
| `%f{arxiv}` | arXiv ID | `2401.12345` |

Access any BibTeX field with `%f{fieldname}`.

### Literal Characters

Any characters not part of a specifier are included literally:

| Format | Result |
|--------|--------|
| `%a_%Y` | `Einstein_1905` |
| `%a:%y` | `Einstein:05` |
| `%a-%t-%Y` | `Einstein-Electrodynamics-1905` |

---

## Examples

### Journal-Style

Format: `%a%Y%f{journal}`
```
Hawking1974Nature
Einstein1905AnnalenPhys
```

### arXiv-Style

Format: `%a%y_%f{arxiv}`
```
Vaswani17_1706.03762
Raffel19_1910.10683
```

### Compact with Uniqueness

Format: `%a%y%u`
```
Einstein05a
Einstein05b
Einstein35a
```

### Verbose

Format: `%A_%Y_%T2`
```
EinsteinPodolskyRosen_1935_CanQuantum
BardeenCooperSchrieffer_1957_TheorySuperconductivity
```

---

## Options

### Lowercase

When enabled, the entire cite key is converted to lowercase:

| Format | Normal | Lowercase |
|--------|--------|-----------|
| `%a%Y%t` | `Einstein1905Electrodynamics` | `einstein1905electrodynamics` |
| `%a:%y` | `Einstein:05` | `einstein:05` |

### Auto-Generate on Import

When enabled, imbib automatically generates cite keys for:
- Papers imported without cite keys
- Papers with ADS-style bibcodes (e.g., `2024ApJ...123..456A`)
- RIS imports (RIS format doesn't have cite keys)

When disabled, original cite keys are preserved and only missing keys are generated.

---

## Collision Handling

When a generated cite key would duplicate an existing one:

1. **Letter suffix**: Adds a, b, c... (if `%u` in format or as fallback)
2. **Number suffix**: Adds 1, 2, 3... (if `%n` in format)
3. **Auto-increment**: Falls back to letter suffix if neither specified

Example with multiple Einstein papers from 1905:
```
Einstein1905a  (first paper)
Einstein1905b  (second paper)
Einstein1905c  (third paper)
```

---

## Format Validation

imbib validates your custom format and warns about:

| Issue | Warning |
|-------|---------|
| Missing author specifier | "Format should include an author specifier (%a, %a2, etc.)" |
| Missing year specifier | "Format should include a year specifier (%y or %Y)" |
| Unknown field in `%f{}` | "Unknown field: xyz" |
| Invalid specifier | "Unknown specifier: %x" |

Validation happens in real-time as you type.

---

## Regenerating Cite Keys

To apply a new format to existing papers:

### Single Paper
1. Select the paper
2. Go to the **BibTeX** tab
3. Edit the cite key field manually

### Multiple Papers
1. Select papers in the list
2. Right-click > **Regenerate Cite Keys**
3. Confirm the operation

**Caution:** Regenerating cite keys may break citations in your manuscripts. Export your manuscript's `.aux` file first to track which cite keys are in use.

---

## BibTeX Compatibility

imbib's cite key formats are compatible with:

- **LaTeX**: Works with `\cite{key}`, `\citep{key}`, `\citet{key}`
- **BibDesk**: Full round-trip compatibility
- **Zotero**: Import/export preserves cite keys
- **Mendeley**: Import/export preserves cite keys
- **JabRef**: Full compatibility

### Character Restrictions

Cite keys should only contain:
- Letters (A-Z, a-z)
- Numbers (0-9)
- Selected punctuation: `_`, `-`, `:`

imbib automatically sanitizes cite keys to remove invalid characters.

---

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Copy Cite Key | Right-click > Copy Cite Key |
| Paste Citation | (in editor) `\cite{` + paste |

---

## Syncing

Cite key format settings sync across devices via iCloud:
- Preset selection
- Custom format string
- Lowercase toggle

This ensures consistent cite key generation across Mac, iPhone, and iPad.

---

## Tips

### For Solo Authors
Use `%a%Y%t` (Classic) - clear and unambiguous.

### For Collaborations
Use `%a2_%Y` (Authors+Year) - captures authorship better.

### For High-Volume Reading
Use `%a:%y` (Short) - quick to type and reference.

### For Literature Reviews
Use `%A%Y` (Full Authors) - maximally descriptive.

### For arXiv-Heavy Fields
Consider `%a%y_%f{arxiv}` - includes the arXiv ID for quick lookup.

---

## Troubleshooting

### Cite Key Not Generated

**Check:**
1. Is "Auto-generate cite keys" enabled in Settings?
2. Does the paper have author and year metadata?
3. Is the cite key field already filled?

### Wrong Format Applied

**Check:**
1. Verify your preset selection in Settings
2. If using Custom, check for typos in the format string
3. Preview should show expected output

### Duplicate Cite Keys

imbib handles this automatically with letter/number suffixes. If you see duplicates:
1. They may be from before imbib (imported from another tool)
2. Run "Regenerate Cite Keys" on affected papers

---

## See Also

- [BibTeX Export](features#bibtex-export) - Export settings
- [Import Settings](features#importing-papers) - Import behavior
- [Settings Reference](reference/settings-reference) - All settings
