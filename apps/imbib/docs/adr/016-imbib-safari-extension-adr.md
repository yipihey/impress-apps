# ADR-001: Safari Extension Architecture for Web Import

**Status:** Proposed  
**Date:** 2026-01-11  
**Author:** Tom / Claude  

---

## Context

imbib requires a mechanism to import bibliographic metadata from web pages (publisher sites, ADS, arXiv, DOI landing pages, library catalogs) into the application. The solution must work across macOS and iOS/iPadOS Safari, integrate cleanly with the native Swift/SwiftUI application, and provide a good user experience for academic researchers.

Zotero's Connector extension demonstrates that browser-based metadata extraction is viable, with ~500 site-specific "translators" plus fallback to embedded metadata standards.

## Decision Drivers

1. **Cross-platform consistency** — Single extension codebase for macOS and iOS Safari
2. **Offline-first architecture** — Should not require a running server for core functionality
3. **Core source quality** — ADS, arXiv, DOI/CrossRef, and PubMed are primary; general sites are secondary
4. **Maintainability** — Minimize dependency on third-party translator ecosystems
5. **User experience** — One-click import with visual feedback
6. **Integration depth** — Leverage imbib's existing ADS/arXiv API integrations

## Options Considered

### Option A: Reuse Zotero Translators via Translation Server

Run Zotero's [translation-server](https://github.com/zotero/translation-server) as a local service. The Safari extension sends URLs to the server, receives Zotero JSON, and converts to BibTeX/imbib format.

**Pros:**
- Access to ~500 site-specific translators
- Well-tested extraction logic
- Covers long tail of publisher sites

**Cons:**
- Requires Node.js runtime (not native)
- Additional process to manage (Docker or standalone)
- iOS: Cannot run local servers; would need hosted service
- Dependency on Zotero project's maintenance
- Overkill for astrophysics-focused workflow

### Option B: Intercept Zotero Connector Output

Let users install Zotero + Connector. Monitor Zotero's database or use Quick Copy to transfer items to imbib.

**Pros:**
- Zero scraping work
- Full Zotero translator coverage

**Cons:**
- Requires Zotero installation (heavyweight dependency)
- Poor UX (multiple apps, manual steps)
- No iOS support
- imbib becomes secondary to Zotero

### Option C: Native Scrapers + Embedded Metadata Fallback (Recommended)

Build native Swift scrapers for core sources (ADS, arXiv, DOI/CrossRef, PubMed). Fall back to parsing standard embedded metadata (Highwire Press, Dublin Core, OpenGraph, COinS) for other sites. Optionally support translation-server as a power-user feature.

**Pros:**
- Native Swift/JavaScriptCore — no external dependencies
- Tight integration with imbib's existing API clients
- Works identically on macOS and iOS
- Full control over core astrophysics sources
- Embedded metadata covers 80%+ of academic sites
- Optional translation-server for power users

**Cons:**
- Initial development effort for scrapers
- Long-tail sites may have incomplete metadata
- Maintenance burden for site-specific scrapers (mitigated by API stability of core sources)

### Option D: Hybrid — Native Core + Bundled Translators

Embed Zotero translator JavaScript files in the app. Run them via JavaScriptCore with a minimal Zotero API shim. Use native scrapers for core sources.

**Pros:**
- Combines native quality with translator breadth
- No external server required

**Cons:**
- Significant implementation complexity
- Must maintain Zotero API compatibility layer
- Translator updates require app updates
- JavaScriptCore sandboxing complicates network access

## Decision

**Option C: Native Scrapers + Embedded Metadata Fallback**

This approach aligns with imbib's design philosophy of native-first, offline-capable operation. The core astrophysics sources (ADS, arXiv, DOI, PubMed) have stable APIs and structured metadata, making native scrapers reliable and maintainable. The embedded metadata fallback handles the majority of academic publisher sites without site-specific code.

Translation-server support can be added later as an optional feature for users who need broader coverage.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Safari Extension                             │
├─────────────────────────────────────────────────────────────────┤
│  Content Script (injected per page)                             │
│  ├── Detect page type (ADS, arXiv, DOI, publisher, etc.)        │
│  ├── Extract metadata via DOM/meta tags                         │
│  └── Send to background script                                  │
├─────────────────────────────────────────────────────────────────┤
│  Background Script                                               │
│  ├── Coordinate extraction                                       │
│  ├── Normalize to imbib schema                                  │
│  └── Send to native app via App Groups / NSUserActivity         │
├─────────────────────────────────────────────────────────────────┤
│  Popup UI                                                        │
│  ├── Show detected item(s)                                      │
│  ├── Collection picker                                          │
│  └── Import button                                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     imbib Native App                            │
├─────────────────────────────────────────────────────────────────┤
│  Extension Handler (Swift)                                       │
│  ├── Receive metadata from extension                            │
│  ├── Enrich via API (ADS, CrossRef) if needed                   │
│  ├── Fetch PDF if available                                     │
│  └── Insert into Core Data / SwiftData                          │
└─────────────────────────────────────────────────────────────────┘
```

### Communication Mechanism

**macOS:** App Groups shared UserDefaults or direct XPC (if same app bundle)

**iOS:** App Groups with background processing. Extension writes to shared container; app processes on launch or via background task.

**Universal:** `NSUserActivity` handoff for immediate processing when app is running.

## Consequences

### Positive
- Native performance and reliability
- No external dependencies for core workflow
- Identical behavior on macOS and iOS
- Deep integration with imbib's data model
- Can leverage existing ADS/arXiv API code

### Negative
- Limited coverage of niche publisher sites initially
- Must maintain scraper code (though core sources are stable)
- Users expecting Zotero-level breadth may be disappointed

### Mitigations
- Provide "Copy BibTeX" detection for sites that offer export buttons
- Document how to use imbib's BibTeX import for unsupported sites
- Consider translation-server integration in future release

---

# Implementation Plan

## Phase 1: Foundation (Weeks 1–2)

### 1.1 Safari Extension Scaffold
- Create Safari Web Extension target in Xcode (shared macOS/iOS)
- Configure App Groups for data sharing
- Implement basic popup UI (SwiftUI or HTML/JS)
- Test extension ↔ app communication via shared UserDefaults

**Deliverables:**
- [ ] Extension target building for both platforms
- [ ] Popup displays "Hello from imbib"
- [ ] Round-trip data from extension to app

### 1.2 Metadata Schema
- Define `ImportedItem` Swift struct matching imbib's data model
- JSON-serializable for extension ↔ app transfer
- Fields: title, authors, year, journal, volume, pages, DOI, arXiv ID, ADS bibcode, abstract, URLs, PDF URL

**Deliverables:**
- [ ] `ImportedItem.swift` with Codable conformance
- [ ] Unit tests for serialization

## Phase 2: Core Source Scrapers (Weeks 3–5)

### 2.1 ADS (NASA Astrophysics Data System)
- Detect: URL pattern `ui.adsabs.harvard.edu/abs/*`
- Extract: bibcode from URL, fetch via ADS API (already in imbib)
- Handle: abstract pages, search results (multiple items)

**Deliverables:**
- [ ] `ADSScraper.js` content script
- [ ] Detection returns `single` or `multiple` item type
- [ ] Integration tests against live ADS pages

### 2.2 arXiv
- Detect: `arxiv.org/abs/*`, `arxiv.org/pdf/*`
- Extract: arXiv ID from URL, parse page meta tags or fetch via arXiv API
- Handle: abstract pages, PDF pages (redirect to abstract), search/list pages

**Deliverables:**
- [ ] `ArXivScraper.js` content script
- [ ] PDF URL extraction
- [ ] Integration tests

### 2.3 DOI / CrossRef
- Detect: `doi.org/*`, or DOI pattern in page content
- Extract: DOI, fetch metadata via CrossRef API (content negotiation)
- Handle: DOI landing pages, embedded DOIs on publisher pages

**Deliverables:**
- [ ] `DOIScraper.js` content script
- [ ] CrossRef API integration in native app
- [ ] Integration tests

### 2.4 PubMed / PMC
- Detect: `pubmed.ncbi.nlm.nih.gov/*`, `ncbi.nlm.nih.gov/pmc/*`
- Extract: PMID/PMCID, fetch via NCBI E-utilities or parse page
- Handle: abstract pages, search results

**Deliverables:**
- [ ] `PubMedScraper.js` content script
- [ ] Integration tests

## Phase 3: Generic Metadata Fallback (Weeks 6–7)

### 3.1 Embedded Metadata Parser
- Parse in priority order:
  1. Highwire Press meta tags (`citation_title`, `citation_author`, etc.)
  2. Dublin Core (`DC.title`, `DC.creator`, etc.)
  3. PRISM (`prism.title`, etc.)
  4. OpenGraph (`og:title`, etc.) — limited utility
  5. Schema.org JSON-LD (`@type: ScholarlyArticle`)
- Combine best available data from multiple sources

**Deliverables:**
- [ ] `EmbeddedMetadataScraper.js`
- [ ] Priority merging logic
- [ ] Test suite with sample publisher pages

### 3.2 COinS (Context Objects in Spans)
- Detect `<span class="Z3988">` elements
- Parse OpenURL key-value pairs
- Support multiple items per page

**Deliverables:**
- [ ] COinS parser in `EmbeddedMetadataScraper.js`
- [ ] Integration tests

## Phase 4: Extension UI & UX (Weeks 8–9)

### 4.1 Popup Interface
- Show detected item(s) with editable fields
- Collection/folder picker (fetch from app via App Groups)
- "Import" button with progress indicator
- "Import All" for multi-item pages
- Error states and retry logic

**Deliverables:**
- [ ] Popup HTML/CSS/JS (or SwiftUI for native popup on macOS)
- [ ] Collection list sync from app
- [ ] User feedback on import success/failure

### 4.2 Toolbar Icon States
- Dynamic icon reflecting page state:
  - Gray: No detectable content
  - Single item icon (document): One item detected
  - Multiple item icon (folder): Multiple items detected
  - Checkmark: Already in library (requires lookup)

**Deliverables:**
- [ ] Icon assets for all states
- [ ] Badge/overlay for item count
- [ ] "Already saved" detection (DOI/bibcode lookup)

### 4.3 Context Menu
- Right-click on DOI/arXiv ID text → "Import to imbib"
- Right-click on page → "Save page reference to imbib"

**Deliverables:**
- [ ] Context menu registration
- [ ] Text selection DOI/arXiv detection regex

## Phase 5: Native App Integration (Weeks 10–11)

### 5.1 Import Handler
- Watch App Group container for new items
- Background processing on iOS (BGTaskScheduler)
- Enrich metadata via APIs (fill missing fields)
- Fetch PDFs when available and permitted
- Insert into database with duplicate detection

**Deliverables:**
- [ ] `ExtensionImportHandler.swift`
- [ ] Duplicate detection (DOI, arXiv ID, bibcode, title fuzzy match)
- [ ] PDF download queue

### 5.2 Notification & Handoff
- `NSUserActivity` for immediate import when app is open
- Local notification on successful background import
- Deep link to imported item

**Deliverables:**
- [ ] UserActivity handling
- [ ] Notification configuration
- [ ] Deep link URL scheme

## Phase 6: Testing & Polish (Weeks 12–13)

### 6.1 Integration Testing
- Test matrix: macOS Safari, iOS Safari, iPadOS Safari
- Core sources: ADS, arXiv, DOI, PubMed
- Publisher sites: Nature, Science, ApJ, MNRAS, A&A, PRL, etc.
- Edge cases: paywalls, preprints, conference proceedings

**Deliverables:**
- [ ] Test plan document
- [ ] Automated UI tests where possible
- [ ] Manual test checklist

### 6.2 Performance
- Extension load time < 100ms
- Metadata extraction < 500ms
- No UI blocking during network requests

**Deliverables:**
- [ ] Performance benchmarks
- [ ] Optimization pass

### 6.3 Error Handling
- Graceful degradation when APIs unavailable
- Clear error messages for users
- Telemetry for failed extractions (opt-in)

**Deliverables:**
- [ ] Error UI states
- [ ] Logging infrastructure

## Phase 7: Optional — Translation Server Support (Future)

### 7.1 Translation Server Integration
- Settings option to enable translation-server backend
- URL input for server address (localhost:1969 default)
- Fallback chain: native scraper → embedded metadata → translation-server

**Deliverables:**
- [ ] Settings UI
- [ ] Translation-server client
- [ ] Response parsing (Zotero JSON → ImportedItem)

### 7.2 Docker Distribution
- Provide docker-compose.yml for easy translation-server setup
- Documentation for self-hosting

**Deliverables:**
- [ ] Docker configuration
- [ ] Setup documentation

---

## File Structure

```
imbib/
├── imbib.xcodeproj
├── imbib/                          # Main app target
│   ├── Import/
│   │   ├── ExtensionImportHandler.swift
│   │   └── ImportedItem.swift
│   └── ...
├── imbibSafariExtension/           # Extension target
│   ├── Resources/
│   │   ├── manifest.json
│   │   ├── popup.html
│   │   ├── popup.js
│   │   ├── background.js
│   │   └── content/
│   │       ├── main.js             # Orchestrator
│   │       ├── scrapers/
│   │       │   ├── ads.js
│   │       │   ├── arxiv.js
│   │       │   ├── doi.js
│   │       │   ├── pubmed.js
│   │       │   └── embedded.js     # Generic fallback
│   │       └── utils/
│   │           ├── metadata.js
│   │           └── normalize.js
│   ├── SafariWebExtensionHandler.swift
│   └── Info.plist
└── Shared/
    └── AppGroupConstants.swift
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Publisher site changes break scrapers | Medium | Low | Rely on APIs (ADS, CrossRef) over DOM scraping; embedded metadata is standardized |
| Apple rejects extension | Low | High | Follow App Store guidelines strictly; no remote code execution |
| iOS background processing limits | Medium | Medium | Use App Groups for reliable data transfer; import on app launch if background fails |
| User expects Zotero-level coverage | Medium | Low | Clear documentation; BibTeX import as fallback; translation-server as power-user option |
| ADS/arXiv API rate limits | Low | Medium | Respect rate limits; cache responses; batch requests |

---

## Success Metrics

- **Adoption:** >50% of imbib users enable extension within 3 months
- **Coverage:** >95% successful import rate for ADS/arXiv/DOI URLs
- **Performance:** <1s end-to-end import time for single items
- **Reliability:** <1% error rate on supported sites

---

## References

- [Zotero Connectors GitHub](https://github.com/zotero/zotero-connectors)
- [Zotero Translation Server](https://github.com/zotero/translation-server)
- [Zotero Translators](https://github.com/zotero/translators)
- [Safari Web Extensions Documentation](https://developer.apple.com/documentation/safariservices/safari_web_extensions)
- [App Groups Documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_application-groups)
- [Highwire Press Meta Tags](https://scholar.google.com/intl/en/scholar/inclusion.html#indexing)
- [Dublin Core Metadata](https://www.dublincore.org/specifications/dublin-core/)
- [CrossRef Content Negotiation](https://citation.crosscite.org/docs.html)
