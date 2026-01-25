# ADR-003: Hybrid Plugin Architecture

## Status

Accepted

## Date

2026-01-04

## Context

We need to support multiple publication databases (arXiv, PubMed, Crossref, etc.), each with different:
- Search APIs (REST, Atom feeds, scraping)
- Response formats (JSON, XML, HTML)
- BibTeX export mechanisms
- Rate limits
- Authentication requirements

We need an architecture that:
- Ships with common sources built-in
- Allows adding new sources without app updates
- Works within iOS code signing constraints
- Is maintainable with Claude Code

## Decision

Use a **hybrid approach**:

1. **Built-in sources**: Swift implementations compiled into the app
2. **JSON config bundles**: Declarative definitions for simple sources (Phase 2)
3. **JavaScriptCore**: For complex user transformations (Phase 4)

## Rationale

### Built-in Swift Plugins

Advantages:
- Type-safe, testable
- Full access to Foundation networking
- Claude Code generates reliable implementations
- Best performance

Implementation:
```swift
public protocol SourcePlugin: Sendable {
    var metadata: SourceMetadata { get }
    func search(query: String) async throws -> [SearchResult]
    func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry
    func normalize(_ entry: BibTeXEntry) -> BibTeXEntry
}

public actor ArXivSource: SourcePlugin { ... }
public actor CrossrefSource: SourcePlugin { ... }
```

### JSON Config Bundles (Phase 2)

For sources with straightforward REST APIs:

```json
{
  "id": "semantic-scholar",
  "name": "Semantic Scholar",
  "searchURL": "https://api.semanticscholar.org/graph/v1/paper/search",
  "queryParam": "query",
  "resultMapping": {
    "id": "$.paperId",
    "title": "$.title",
    "authors": "$.authors[*].name"
  }
}
```

Advantages:
- No app update required
- Users can contribute sources
- Easy to iterate

Limitations:
- Only works for APIs matching the config schema
- No complex response transformations

### JavaScriptCore (Phase 4)

For complex user-defined sources:

```javascript
export default {
  id: "custom-source",
  
  async search(query) {
    const response = await fetch(...);
    const data = await response.json();
    return transformResults(data);  // Custom logic
  }
}
```

Advantages:
- Full flexibility
- Familiar language
- Apple-approved (no dynamic code signing issues)

Limitations:
- Security sandboxing required
- Performance overhead
- More complex to implement

## Phase Plan

| Phase | Approach | Timeline |
|-------|----------|----------|
| 1 | Built-in Swift plugins (arXiv, Crossref, PubMed) | v1.0 |
| 2 | JSON config bundles for simple sources | v1.2 |
| 3 | Additional built-in sources (ADS, DBLP, Scholar) | v1.5 |
| 4 | JavaScriptCore for complex user sources | v2.0 |

## Consequences

### Positive

- Reliable core sources ship immediately
- Extensibility path doesn't block v1.0
- iOS App Store compatible throughout
- Each approach fits its use case

### Negative

- Three different plugin mechanisms to maintain
- JSON schema design requires care
- JavaScript sandboxing adds complexity

### Mitigations

- `ConfigurableSource` wraps JSON bundles in same protocol
- `JavaScriptSource` wraps JS in same protocol
- All sources registered through `SourceManager` uniformly
- Clear documentation for each approach

## Alternatives Considered

### JavaScript Only

Could use JavaScriptCore for all plugins, but:
- More complex to implement
- Performance overhead for built-in sources
- Claude Code generates less reliable JS

### Dynamic Libraries

iOS prohibits loading dynamic code at runtime (code signing). Not viable.

### Server-Side Plugins

Could route searches through our server with plugins there, but:
- Privacy concerns (user queries visible to us)
- Server costs
- Offline doesn't work
- Against design goals
