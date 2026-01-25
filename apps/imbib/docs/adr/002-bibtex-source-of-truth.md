# ADR-002: BibTeX as Source of Truth

## Status

Accepted

## Date

2026-01-04

## Context

Users have existing `.bib` files they've built over years, often with BibDesk. We need to decide the relationship between our Core Data database and BibTeX files.

Options:
1. **Core Data only** - Import once, manage in database, export on demand
2. **BibTeX only** - Parse `.bib` on every load, no persistent database
3. **Core Data primary** - Database is canonical, BibTeX is export format
4. **BibTeX primary** - `.bib` file is canonical, Core Data is cache/index

## Decision

Use a **hybrid approach** where:
- `.bib` files are the user-owned, portable format
- Core Data is the working database for queries and CloudKit sync
- Import parses `.bib` → Core Data
- Export regenerates `.bib` from Core Data
- Unknown fields are preserved for round-trip fidelity

## Rationale

### User Data Ownership

Researchers often use BibTeX files across multiple tools:
- LaTeX documents (`\bibliography{refs}`)
- Collaborative Overleaf projects
- Pandoc/Markdown workflows
- Other reference managers

A `.bib` file is a plain-text, future-proof format they can always access.

### BibDesk Compatibility

BibDesk users expect to:
- Open their existing `.bib` file
- Edit in our app or BibDesk interchangeably
- Have PDFs linked correctly

This requires full BibTeX round-trip fidelity.

### Query Performance

Core Data enables:
- Fast full-text search
- Smart collections with predicates
- CloudKit sync
- Relationship traversal

Parsing a large `.bib` file on every query would be slow.

## Implementation

### Import

```swift
func importBibTeX(from url: URL) throws {
    let content = try String(contentsOf: url)
    let entries = try BibTeXParser.parse(content)
    
    for entry in entries {
        let publication = Publication(context: viewContext)
        publication.citeKey = entry.citeKey
        publication.entryType = entry.entryType
        publication.rawBibTeX = entry.rawBibTeX  // Preserve original
        publication.rawFields = encodeFields(entry.fields)
        // Map common fields to attributes...
    }
}
```

### Export

```swift
func exportBibTeX(publications: [Publication]) -> String {
    publications.map { pub in
        var fields = decodeFields(pub.rawFields)
        // Add linked file references
        for file in pub.linkedFiles {
            let bdskFile = BibTeXExporter.encodeBdskFile(file)
            fields["Bdsk-File-\(index)"] = bdskFile
        }
        return BibTeXExporter.formatEntry(
            citeKey: pub.citeKey,
            entryType: pub.entryType,
            fields: fields
        )
    }.joined(separator: "\n\n")
}
```

### Field Preservation

Store all fields as JSON:

```swift
// Store
publication.rawFields = """
{"journal": "Nature", "custom-field": "value"}
"""

// On export, merge Core Data attributes with rawFields
// Core Data attributes take precedence for edited fields
```

## Consequences

### Positive

- Users keep their `.bib` files and workflows
- Full BibDesk compatibility
- No data lock-in
- Fast queries via Core Data

### Negative

- Must handle BibTeX parsing edge cases
- Sync conflicts possible if editing in multiple apps
- Storage duplication (Core Data + `.bib`)

### Mitigations

- Comprehensive BibTeX parser tests
- File watching for external changes
- Export only on explicit save or app quit
