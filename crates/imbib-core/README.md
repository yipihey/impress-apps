# imbib-core

Cross-platform core library for the imbib publication manager, written in Rust with Swift/Kotlin bindings via UniFFI.

## Features

- **BibTeX Parsing & Formatting**: Complete parser with round-trip fidelity
- **RIS Parsing & Formatting**: Full RIS format support with BibTeX conversion
- **Identifier Extraction**: DOI, arXiv ID, and ISBN detection from text
- **Deduplication**: Similarity scoring for detecting duplicate publications

## Building

### Prerequisites

- Rust 1.74 or later
- For iOS: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`

### Commands

```bash
# Build for current platform
cargo build --release

# Build for iOS device
cargo build --release --target aarch64-apple-ios

# Build for iOS simulator (Apple Silicon)
cargo build --release --target aarch64-apple-ios-sim

# Run tests
cargo test

# Generate Swift bindings
cargo run --release --bin uniffi-bindgen generate \
    --library target/release/libimbib_core.dylib \
    --language swift \
    --out-dir generated
```

## Swift Integration

### Using the Generated Bindings

1. Add the static library to your Xcode project
2. Add the generated `imbib_core.swift` to your target
3. Import the module and use:

```swift
import Foundation

// Parse BibTeX
let bibtex = """
@article{Smith2024,
    author = {John Smith},
    title = {A Great Paper},
    year = 2024,
}
"""

do {
    let result = try bibtexParse(input: bibtex)
    for entry in result.entries {
        print("Title: \(entry.fields.first { $0.key == "title" }?.value ?? "")")
    }
} catch {
    print("Parse error: \(error)")
}

// Extract identifiers
let dois = extractDois(text: "Check out doi:10.1038/nature12373")
print("Found DOIs: \(dois)")

// Check similarity
let match = calculateSimilarity(entry1: entry1, entry2: entry2)
if match.score > 0.8 {
    print("Likely duplicates: \(match.reason)")
}
```

## API Reference

### BibTeX Functions

- `bibtexParse(input:)` - Parse BibTeX string into entries
- `bibtexParseEntry(input:)` - Parse a single BibTeX entry
- `bibtexFormatEntry(entry:)` - Format entry to BibTeX string
- `bibtexFormatEntries(entries:)` - Format multiple entries

### RIS Functions

- `risParse(input:)` - Parse RIS string into entries
- `risFormatEntry(entry:)` - Format entry to RIS string
- `risToBibtex(entry:)` - Convert RIS to BibTeX
- `risFromBibtex(entry:)` - Convert BibTeX to RIS

### Identifier Functions

- `extractDois(text:)` - Extract DOIs from text
- `extractArxivIds(text:)` - Extract arXiv IDs from text
- `extractIsbns(text:)` - Extract ISBNs from text
- `extractAll(text:)` - Extract all identifiers with positions
- `isValidDoi(doi:)` - Validate a DOI
- `isValidArxivId(arxivId:)` - Validate an arXiv ID
- `isValidIsbn(isbn:)` - Validate an ISBN
- `normalizeDoi(doi:)` - Normalize a DOI to canonical form
- `generateCiteKey(author:year:title:)` - Generate cite key from metadata

### Deduplication Functions

- `calculateSimilarity(entry1:entry2:)` - Calculate similarity score
- `normalizeTitle(title:)` - Normalize title for comparison
- `normalizeAuthor(author:)` - Normalize author for comparison
- `titlesMatch(title1:title2:threshold:)` - Check if titles match
- `authorsOverlap(authors1:authors2:)` - Check for author overlap

## Project Structure

```
imbib-core/
├── Cargo.toml           # Rust package config
├── build-ios.sh         # iOS build script
├── src/
│   ├── lib.rs           # Library root with FFI exports
│   ├── bibtex/          # BibTeX parsing/formatting
│   ├── ris/             # RIS parsing/formatting
│   ├── identifiers/     # DOI/arXiv/ISBN extraction
│   └── deduplication/   # Similarity algorithms
└── generated/           # Generated Swift bindings
```

## License

MIT
