# im-identifiers

Extract, validate, and resolve academic publication identifiers in Rust.

## Supported Identifiers

| Type | Format | Example |
|------|--------|---------|
| **DOI** | `10.XXXX/suffix` | `10.1038/nature12373` |
| **arXiv** | `YYMM.NNNNN` or `archive/NNNNNNN` | `2301.12345v2`, `hep-th/9901001` |
| **ISBN** | ISBN-10, ISBN-13 (with checksum) | `978-0-321-12521-7` |
| **PMID** | PubMed ID | `12345678` |
| **Bibcode** | NASA ADS bibcode | `2020ApJ...123...45A` |

## Library Usage

```rust
use im_identifiers::{
    extract_dois, extract_arxiv_ids, extract_isbns, extract_all,
    is_valid_doi, is_valid_arxiv_id, is_valid_isbn, normalize_doi,
    generate_cite_key, identifier_url, IdentifierType,
};

// === Extract identifiers from text ===

let dois = extract_dois("See doi:10.1038/nature12373 for details".into());
assert_eq!(dois, vec!["10.1038/nature12373"]);

let arxiv = extract_arxiv_ids("arXiv:2301.12345 and cond-mat/9901001".into());
assert_eq!(arxiv.len(), 2);

let isbns = extract_isbns("ISBN: 978-0-321-12521-7".into());
assert_eq!(isbns, vec!["9780321125217"]);

// Extract all identifier types at once with position info
let all = extract_all("DOI: 10.1038/nature12373, arXiv: 2301.12345".into());
assert_eq!(all.len(), 2);
assert_eq!(all[0].identifier_type, "doi");
assert_eq!(all[1].identifier_type, "arxiv");

// === Validate identifiers ===

assert!(is_valid_doi("10.1038/nature12373".into()));
assert!(!is_valid_doi("not-a-doi".into()));

assert!(is_valid_arxiv_id("2301.12345".into()));
assert!(is_valid_arxiv_id("hep-th/9901001v1".into()));

assert!(is_valid_isbn("978-0-321-12521-7".into()));
assert!(is_valid_isbn("080442957X".into()));  // ISBN-10 with X check digit

// === Normalize ===

assert_eq!(
    normalize_doi("https://doi.org/10.1038/nature12373".into()),
    "10.1038/nature12373"
);

// === Generate citation keys ===

let key = generate_cite_key(
    Some("Einstein, Albert".into()),
    Some("1905".into()),
    Some("On the Electrodynamics of Moving Bodies".into()),
);
assert_eq!(key, "Einstein1905Electrodynamics");

// === Build URLs ===

let url = identifier_url(IdentifierType::Doi, "10.1038/nature12373".into());
assert_eq!(url, Some("https://doi.org/10.1038/nature12373".into()));

let url = identifier_url(IdentifierType::Arxiv, "2301.12345".into());
assert_eq!(url, Some("https://arxiv.org/abs/2301.12345".into()));
```

## CLI

Install with:

```sh
cargo install im-identifiers --features cli
```

### Commands

```sh
# Extract all identifiers from text (outputs JSON)
im-identifiers extract "See 10.1038/nature12373 and arXiv:2301.12345"

# Extract from stdin
cat paper.txt | im-identifiers extract -

# Validate an identifier
im-identifiers validate doi 10.1038/nature12373
im-identifiers validate arxiv 2301.12345
im-identifiers validate isbn 978-0-321-12521-7

# Normalize a DOI (strip URL prefix, trailing punctuation)
im-identifiers normalize "https://doi.org/10.1038/nature12373"

# Generate a citation key
im-identifiers citekey --author "Smith, John" --year 2024 --title "Machine Learning"

# Get the URL for an identifier
im-identifiers url doi 10.1038/nature12373
im-identifiers url arxiv 2301.12345
im-identifiers url bibcode "2020ApJ...123...45A"
```

## Identifier Extraction Details

The extraction engine handles common formats seen in academic text:

- DOIs with URL prefix: `https://doi.org/10.1038/...`
- DOIs with label: `doi:10.1038/...`
- Bare DOIs: `10.1038/...`
- arXiv with URL: `https://arxiv.org/abs/2301.12345`
- arXiv with label: `arXiv:2301.12345`
- Old arXiv format: `hep-th/9901001`
- ISBNs with hyphens: `978-0-321-12521-7`
- ISBNs with label: `ISBN: 0306406152`

Trailing punctuation (`.`, `,`, `;`, `)`, `]`) is automatically stripped from DOIs.

## Citation Key Generation

Keys follow the `AuthorYearWord` pattern:

- First author's last name (diacritics normalized to ASCII)
- 4-digit year
- First significant title word (skipping articles/prepositions)

Collision avoidance: appends `a`, `b`, `c`... then `2`, `3`, `4`... when keys clash with existing entries.

## Enrichment Source Resolution

The `resolver` module maps identifiers to academic database URLs and determines which identifiers can query which sources:

| Source | Accepted identifiers |
|--------|---------------------|
| NASA ADS | bibcode, DOI, arXiv |
| Semantic Scholar | DOI, arXiv, PMID, S2 ID |
| OpenAlex | DOI, OpenAlex ID |
| Crossref | DOI |
| arXiv | arXiv ID |
| PubMed | PMID, PMCID, DOI |
| DBLP | DBLP key, DOI |

## License

MIT
