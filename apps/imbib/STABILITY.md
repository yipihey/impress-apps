# imbib Feature Stability Audit

This document tracks the status of each feature in imbib to ensure we know what works reliably before shipping releases.

**Last Updated:** 2026-02-01
**Target Release:** 1.1.0 (Stability Release)

---

## Test Suite Status

**Last Run:** 2026-02-01

| Test Category | Count | Status |
|--------------|-------|--------|
| PublicationManagerCore Swift Tests | ~1451 test functions | ✅ Passing |
| Rust Bridge Tests | 32 tests in 11 suites | ✅ Passing |
| UI Tests | 32 files | 🔍 Not run in CI |

**Notes:**
- Swift tests run via `swift test` in PublicationManagerCore
- Some compiler warnings for PDFKit sendability (non-blocking)
- UI tests require Xcode project and device/simulator

---

## Status Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Works reliably - tested and verified |
| ⚠️ | Partially working - has known issues |
| ❌ | Broken - do not ship |
| 🔍 | Needs testing - status unknown |
| 🚫 | Disabled - removed from release |

---

## Core Features (Must Work Perfectly)

These are the essential features that every user relies on.

| Feature | macOS | iOS | Status | Notes |
|---------|-------|-----|--------|-------|
| **BibTeX Import** | 🔍 | 🔍 | | Parse and import .bib files |
| **BibTeX Export** | 🔍 | 🔍 | | Export library to .bib format |
| **RIS Import** | 🔍 | 🔍 | | Parse and import .ris files |
| **PDF Management** | 🔍 | 🔍 | | Store, organize, and open PDFs |
| **PDF Viewing** | 🔍 | 🔍 | | Read PDFs with native viewer |
| **Local Search** | 🔍 | 🔍 | | Search within library |
| **Collections** | 🔍 | 🔍 | | Organize papers into collections |
| **Smart Collections** | 🔍 | 🔍 | | Dynamic collections with filters |
| **CloudKit Sync** | 🔍 | 🔍 | | Sync library across devices |
| **Keyboard Navigation** | 🔍 | N/A | | Full keyboard control |

---

## CloudKit Sync Test Matrix

Cross-device sync must work reliably. Test each combination:

| Test | macOS→macOS | macOS→iOS | iOS→macOS | iOS→iOS |
|------|-------------|-----------|-----------|---------|
| Library syncs without duplication | 🔍 | 🔍 | 🔍 | 🔍 |
| Publication syncs | 🔍 | 🔍 | 🔍 | 🔍 |
| PDF attachment syncs | 🔍 | 🔍 | 🔍 | 🔍 |
| Collections sync | 🔍 | 🔍 | 🔍 | 🔍 |
| Smart searches sync | 🔍 | 🔍 | 🔍 | 🔍 |
| Offline edits merge correctly | 🔍 | 🔍 | 🔍 | 🔍 |
| Library deduplication works | 🔍 | 🔍 | 🔍 | 🔍 |
| Fresh install sync works | 🔍 | 🔍 | 🔍 | 🔍 |

### CloudKit Environment Detection

| Check | Status | Notes |
|-------|--------|-------|
| Sandbox detection works | 🔍 | Running from Xcode shows warning |
| Production detection works | 🔍 | App Store/TestFlight shows no warning |
| Environment shown in Settings | 🔍 | |

### Library Deduplication

| Test | Status | Notes |
|------|--------|-------|
| Canonical ID deduplication | 🔍 | Same default library merged |
| Name-based deduplication (24h) | 🔍 | Same name within 24h merged |
| Publications migrated | 🔍 | All papers in merged library |
| Collections migrated | 🔍 | All collections in merged library |
| Smart searches migrated | 🔍 | All searches in merged library |

---

## Search Sources

Each external search source should be tested independently.

| Source | Status | Test Query | Notes |
|--------|--------|------------|-------|
| **arXiv** | 🔍 | `author:Doe cosmology` | |
| **NASA ADS** | 🔍 | `author:Doe year:2023` | Requires API key |
| **SciX (ADS successor)** | 🔍 | | |
| **Crossref** | 🔍 | DOI lookup | |
| **OpenAlex** | 🔍 | | Free, no API key |
| **PubMed** | 🔍 | Medical/bio papers | |
| **Web of Science** | 🔍 | | Requires subscription |

---

## Import/Export Features

| Feature | Status | Notes |
|---------|--------|-------|
| **BibTeX Import** | 🔍 | |
| **BibTeX Export** | 🔍 | |
| **RIS Import** | 🔍 | |
| **Mbox Export** | 🔍 | Full library backup |
| **Mbox Import** | 🔍 | Restore from backup |
| **PDF Auto-Download** | 🔍 | From arXiv, ADS links |
| **Drag & Drop Import** | 🔍 | Drop BibTeX, RIS, PDF |
| **Safari Extension** | 🔍 | Add papers from browser |
| **Share Extension** | 🔍 | iOS share sheet |

---

## PDF Features

| Feature | macOS | iOS | Status | Notes |
|---------|-------|-----|--------|-------|
| **PDF Viewing** | 🔍 | 🔍 | | |
| **Annotations - Highlight** | 🔍 | 🔍 | | |
| **Annotations - Notes** | 🔍 | 🔍 | | |
| **Annotations - Underline** | 🔍 | 🔍 | | |
| **PDF Search** | 🔍 | 🔍 | | Full-text search |
| **PDF Dark Mode** | 🔍 | 🔍 | | Invert colors |
| **PDF Continuous Scroll** | 🔍 | 🔍 | | |
| **PDF Page Thumbnails** | 🔍 | 🔍 | | |
| **PDF Zoom** | 🔍 | 🔍 | | |

---

## Advanced Features (Can Be Disabled If Broken)

These features are nice-to-have but not essential for core functionality.

### E-Ink Device Integration

| Feature | Status | Notes |
|---------|--------|-------|
| **reMarkable Cloud Sync** | 🔍 | Requires reMarkable account |
| **reMarkable Local Sync** | 🔍 | USB connection |
| **reMarkable Annotation Import** | 🔍 | Pull annotations back |
| **Supernote Sync** | 🔍 | If implemented |
| **Kindle Scribe Sync** | 🔍 | If implemented |

### Display Features

| Feature | Status | Notes |
|---------|--------|-------|
| **Display Rotation** | 🔍 | Rotate display for vertical reading |
| **Multi-Monitor Support** | 🔍 | PDF on external display |
| **Detached Windows** | 🔍 | Separate PDF viewer windows |

### AI Features

| Feature | Status | Notes |
|---------|--------|-------|
| **AI Enrichment** | 🔍 | Auto-fetch metadata |
| **AI Search Assistance** | 🔍 | Natural language queries |
| **Recommendations** | 🔍 | Similar paper suggestions |

### Automation

| Feature | Status | Notes |
|---------|--------|-------|
| **URL Scheme Handling** | 🔍 | `imbib://` URLs |
| **Shortcuts Integration** | 🔍 | App Intents |
| **Automation Rules** | 🔍 | Auto-organize on import |

---

## iOS Parity Checklist

Features that should work identically on iOS:

| Feature | macOS | iOS | Notes |
|---------|-------|-----|-------|
| PDF Viewing | 🔍 | 🔍 | |
| Search | 🔍 | 🔍 | |
| Annotations | 🔍 | 🔍 | |
| Sync | 🔍 | 🔍 | |
| Collections | 🔍 | 🔍 | |
| Export | 🔍 | 🔍 | |
| Share Extension | N/A | 🔍 | |

---

## Known Issues

Track specific bugs here with links to GitHub issues.

| Issue | Feature | Severity | GitHub Issue |
|-------|---------|----------|--------------|
| | | | |

---

## Test Commands

```bash
# Run all unit tests
cd apps/imbib/PublicationManagerCore
swift test

# Run specific test file
swift test --filter BibTeXExporterTests

# Run performance tests
swift test --filter Performance
```

---

## Verification Checklist for Release

Before merging `develop` → `main`:

- [ ] All unit tests pass
- [ ] Manual smoke test completed:
  - [ ] Import BibTeX file (5+ entries)
  - [ ] Import RIS file
  - [ ] Search arXiv and import paper
  - [ ] Search ADS and import paper
  - [ ] Open and read PDF
  - [ ] Create highlight annotation
  - [ ] Create collection and add papers
  - [ ] Export selection to BibTeX
  - [ ] Verify CloudKit sync (if enabled)
- [ ] No new compiler warnings
- [ ] macOS build succeeds
- [ ] iOS build succeeds
- [ ] Version number bumped

---

## How to Update This Document

1. Test a feature thoroughly
2. Update its status symbol
3. Add notes if there are caveats
4. If broken, file a GitHub issue and link it
5. Commit changes to this file

---

## Audit Schedule

- **Weekly:** Run test suite, update any newly discovered issues
- **Before release:** Complete full manual verification checklist
- **After user reports:** Update relevant feature status
