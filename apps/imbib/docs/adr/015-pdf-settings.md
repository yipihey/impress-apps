# ADR-015: PDF Settings and URL Resolution

## Status

Accepted

## Date

2026-01-04

## Context

When viewing online papers (from Smart Search or ADS search), users cannot view PDFs because:

1. **ADSSource does not populate pdfURL** - Papers found via ADS have no PDF URL set, even though:
   - arXiv versions exist (free PDFs available)
   - Publisher PDFs exist via ADS link gateway

2. **No user preference for PDF sources** - Different users have different needs:
   - Some want arXiv preprints (free, always accessible)
   - Some want publisher versions (may require institutional access)

3. **No library proxy support** - Many publisher PDFs are paywalled, requiring institutional proxy access:
   - Stanford: `https://stanford.idm.oclc.org/login?url=`
   - Harvard: `https://ezp-prod1.hul.harvard.edu/login?url=`
   - MIT: `https://libproxy.mit.edu/login?url=`

### Requirements

1. Fix ADSSource to generate PDF URLs (arXiv when available, ADS gateway otherwise)
2. Add settings for PDF source priority (preprint vs publisher)
3. Add library proxy URL configuration
4. Apply settings when resolving PDF URLs for viewing
5. Add debug logging for troubleshooting PDF issues

## Decision

Implement a PDF settings system with:

1. **PDFSettingsStore** - Actor-based settings storage (similar to EnrichmentSettingsStore)
2. **PDFURLResolver** - Static helper to resolve the best PDF URL based on settings
3. **ADSSource fix** - Populate pdfURL in search results
4. **Settings UI** - New PDF tab in Settings with source priority and proxy configuration

### Design Choices

**Preprint as Default**: Preprint sources (arXiv) are preferred by default because:
- Always accessible without authentication
- Freely available to everyone
- Consistent availability across institutions

**Simple Proxy Model**: We use a URL prefix approach (not full proxy configuration) because:
- Most institutional proxies work as simple URL prefixes
- Easy for users to configure (just paste the proxy URL)
- No complex authentication flow needed in the app

**Session-based PDF Caching**: PDFs are cached in SessionCache (not persisted) because:
- Online papers are transient search results
- Persistent storage would require cleanup policies
- SessionCache already handles temporary files

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     PaperPDFTabView                         │
│                          │                                  │
│                          ▼                                  │
│            ┌──────────────────────────┐                    │
│            │    PDFURLResolver        │                    │
│            │  resolve(paper, settings) │                    │
│            └──────────┬───────────────┘                    │
│                       │                                     │
│         ┌─────────────┼─────────────┐                      │
│         ▼             ▼             ▼                      │
│    ┌─────────┐  ┌──────────┐  ┌──────────┐                │
│    │ arXiv   │  │ ADS      │  │ Library  │                │
│    │ PDF URL │  │ Gateway  │  │ Proxy    │                │
│    └─────────┘  └──────────┘  └──────────┘                │
│                                                             │
│                   ┌──────────────────┐                     │
│                   │ PDFSettingsStore │                     │
│                   │    (Actor)       │                     │
│                   └──────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

## Implementation

### PDFSettings Types

```swift
public enum PDFSourcePriority: String, Codable, CaseIterable, Sendable {
    case preprint   // Prefer arXiv, bioRxiv, preprint servers
    case publisher  // Prefer publisher PDFs (via proxy if configured)

    public var displayName: String {
        switch self {
        case .preprint: return "Preprint (arXiv, etc.)"
        case .publisher: return "Publisher"
        }
    }

    public var description: String {
        switch self {
        case .preprint: return "Free and always accessible"
        case .publisher: return "Original version, may require proxy"
        }
    }
}

public struct PDFSettings: Codable, Equatable, Sendable {
    public var sourcePriority: PDFSourcePriority = .preprint
    public var libraryProxyURL: String = ""
    public var proxyEnabled: Bool = false

    public static let `default` = PDFSettings()

    public static let commonProxies: [(name: String, url: String)] = [
        ("Stanford", "https://stanford.idm.oclc.org/login?url="),
        ("Harvard", "https://ezp-prod1.hul.harvard.edu/login?url="),
        ("MIT", "https://libproxy.mit.edu/login?url="),
        ("Berkeley", "https://libproxy.berkeley.edu/login?url=")
    ]
}
```

### PDFSettingsStore

Actor-based settings storage using UserDefaults with caching. See `PublicationManagerCore/Sources/PublicationManagerCore/Files/PDFSettingsStore.swift`.

### PDFURLResolver

Static helper for resolving PDF URLs based on user settings. See `PublicationManagerCore/Sources/PublicationManagerCore/Files/PDFURLResolver.swift`.

### ADSSource Fix

Modified `parseDoc()` to generate PDF URLs:
- Papers with arXiv ID get arXiv PDF URL
- Papers without arXiv ID get ADS gateway URL

## Test Strategy

### Unit Tests

| Test File | Tests | Coverage |
|-----------|-------|----------|
| `PDFSettingsStoreTests.swift` | 18 | Settings persistence, defaults, updates, codable |
| `PDFURLResolverTests.swift` | 25 | URL resolution with all priority/proxy combinations |
| `ADSSourceTests.swift` | 10 | PDF URL generation, arXiv ID extraction, error handling |

**Total: 53 tests**

## Files Created/Modified

| File | Action |
|------|--------|
| `PublicationManagerCore/.../Files/PDFSettingsStore.swift` | CREATE |
| `PublicationManagerCore/.../Files/PDFURLResolver.swift` | CREATE |
| `PublicationManagerCore/.../Sources/BuiltIn/ADSSource.swift` | MODIFY |
| `imbib/imbib/Views/Settings/SettingsView.swift` | MODIFY |
| `imbib/imbib/Views/Settings/PDFSettingsTab.swift` | CREATE |
| `imbib/imbib/Views/Detail/PaperDetailView.swift` | MODIFY |
| `PublicationManagerCoreTests/PDFSettingsStoreTests.swift` | CREATE |
| `PublicationManagerCoreTests/PDFURLResolverTests.swift` | CREATE |
| `PublicationManagerCoreTests/Sources/ADSSourceTests.swift` | CREATE |

## Consequences

### Positive

- Users can view PDFs from ADS search results
- Flexibility to choose preprint vs publisher versions
- Institutional access via library proxy
- Debug logging for troubleshooting
- Clean separation of concerns (settings, resolution, viewing)

### Negative

- Additional settings complexity
- Proxy may not work for all institutions (some use different auth methods)
- ADS gateway URLs may require ADS login for some publishers

### Mitigations

- Clear documentation with common proxy examples
- Graceful fallback (try preprint if publisher fails)
- Debug logging to help diagnose issues

## Alternatives Considered

### Auto-detect Proxy

Automatically detect institutional proxy from network.

**Rejected** because:
- Complex to implement reliably
- Privacy concerns with network probing
- User preference is clearer

### Per-Source PDF Settings

Configure PDF source per search source (ADS, arXiv, etc.).

**Rejected** because:
- Too complex for users
- Global preference is simpler and sufficient
- Can always override manually

## References

- [ADS Link Gateway](https://ui.adsabs.harvard.edu/help/linking/)
- [arXiv PDF Access](https://info.arxiv.org/help/bulk_data_s3.html)
- [EZproxy URL Rewriting](https://help.oclc.org/Library_Management/EZproxy)
