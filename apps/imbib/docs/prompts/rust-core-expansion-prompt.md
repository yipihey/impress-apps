# Rust Core Expansion Implementation Prompt

You are implementing a major architectural refactoring of the imbib publication manager to enable a future web app with complete feature parity. Your goal is to expand the Rust core (`imbib-core`) to contain all platform-agnostic business logic, enabling code sharing across native iOS/macOS apps, a future web app (via WASM), and potentially a backend server.

## Project Context

**imbib** is a cross-platform (macOS/iOS) scientific publication manager. BibTeX/BibDesk-compatible, multi-source search (arXiv, ADS, Crossref, etc.), CloudKit sync.

**Current Architecture:**
```
┌─────────────────────────────────────────────────────────────┐
│  macOS App              │           iOS App                 │
├─────────────────────────┴───────────────────────────────────┤
│                    Shared SwiftUI Views                     │
├─────────────────────────────────────────────────────────────┤
│                 PublicationManagerCore (Swift Package)      │
│    Models │ Repositories │ Services │ Plugins │ ViewModels │
├─────────────────────────────────────────────────────────────┤
│                    Core Data + CloudKit                     │
├─────────────────────────────────────────────────────────────┤
│                 imbib-core (Rust, ~4K lines)                │
│    BibTeX Parser │ RIS Parser │ Deduplication │ Text        │
└─────────────────────────────────────────────────────────────┘
```

**Target Architecture:**
```
┌─────────────────────────────────────────────────────────────────────┐
│                           Client Layer                               │
├──────────────────┬──────────────────────┬───────────────────────────┤
│   macOS/iOS      │      Web App         │     Backend (optional)    │
│   (SwiftUI)      │   (React/Vue)        │     (Axum/Actix)          │
├──────────────────┴──────────────────────┴───────────────────────────┤
│                 Thin Swift Layer (PublicationManagerCore)           │
│         Storage Adapters │ Platform Services │ View Models          │
├─────────────────────────────────────────────────────────────────────┤
│                    imbib-core (Expanded Rust Core)                  │
│  Domain Models │ Business Logic │ Source Plugins │ Sync Logic       │
│  Import/Export │ Validation │ Deduplication │ Parsing               │
└─────────────────────────────────────────────────────────────────────┘
```

## Current Rust Core (imbib-core)

Location: `/Users/tabel/Projects/imbib/imbib-core/`

**Already Implemented (~4K lines):**
- `src/bibtex/` - Parser (nom), formatter, LaTeX decoder, journal macros
- `src/ris/` - Parser, formatter, bidirectional BibTeX↔RIS conversion
- `src/identifiers/` - DOI, arXiv ID, ISBN extraction; cite key generation
- `src/deduplication/` - Similarity scoring (Jaro-Winkler, Levenshtein)
- `src/text/` - MathML parser, author parser, scientific text processing
- `src/search/` - ADS and arXiv query builders

**FFI Bridge:**
- Uses UniFFI 0.28 with proc macros (no .udl files)
- Functions marked with `#[uniffi::export]`
- Types marked with `#[uniffi::Record]`, `#[uniffi::Enum]`, `#[uniffi::Error]`
- Swift bindings generated to `ImbibRustCore/Sources/ImbibRustCore/imbib_core.swift`
- XCFramework at `imbib-core/frameworks/ImbibCore.xcframework`

**Current Dependencies (Cargo.toml):**
```toml
[dependencies]
uniffi = "0.28"
nom = "7.1"
regex = "1.10"
lazy_static = "1.4"
thiserror = "1.0"
unicode-normalization = "0.1"
strsim = "0.11"
```

## Implementation Phases

Execute these phases in order. After each phase, ensure the project builds and existing tests pass before proceeding.

---

### Phase 1: Domain Models in Rust

**Goal:** Create platform-agnostic domain models that will be the single source of truth.

**Create new file:** `imbib-core/src/domain/mod.rs`

```rust
//! Domain models for imbib
//!
//! These are the canonical representations of all entities, shared across
//! native apps (via UniFFI), web (via WASM), and server (native Rust).

use serde::{Deserialize, Serialize};

pub mod publication;
pub mod author;
pub mod library;
pub mod identifiers;
pub mod search_result;
pub mod linked_file;
pub mod tag;
pub mod collection;
pub mod validation;

pub use publication::*;
pub use author::*;
pub use library::*;
pub use identifiers::*;
pub use search_result::*;
pub use linked_file::*;
pub use tag::*;
pub use collection::*;
pub use validation::*;
```

**Create:** `imbib-core/src/domain/identifiers.rs`
```rust
use serde::{Deserialize, Serialize};

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Identifiers {
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub pmid: Option<String>,
    pub pmcid: Option<String>,
    pub bibcode: Option<String>,
    pub isbn: Option<String>,
    pub issn: Option<String>,
    pub orcid: Option<String>,
}

impl Identifiers {
    pub fn is_empty(&self) -> bool {
        self.doi.is_none()
            && self.arxiv_id.is_none()
            && self.pmid.is_none()
            && self.pmcid.is_none()
            && self.bibcode.is_none()
            && self.isbn.is_none()
            && self.issn.is_none()
    }

    /// Returns the best identifier for deduplication (priority order)
    pub fn primary(&self) -> Option<(&'static str, &str)> {
        if let Some(ref doi) = self.doi {
            return Some(("doi", doi));
        }
        if let Some(ref arxiv) = self.arxiv_id {
            return Some(("arxiv", arxiv));
        }
        if let Some(ref bibcode) = self.bibcode {
            return Some(("bibcode", bibcode));
        }
        if let Some(ref pmid) = self.pmid {
            return Some(("pmid", pmid));
        }
        None
    }
}
```

**Create:** `imbib-core/src/domain/author.rs`
```rust
use serde::{Deserialize, Serialize};

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Author {
    pub id: String,
    pub given_name: Option<String>,
    pub family_name: String,
    pub suffix: Option<String>,
    pub orcid: Option<String>,
    pub affiliation: Option<String>,
}

impl Author {
    pub fn new(family_name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            given_name: None,
            family_name,
            suffix: None,
            orcid: None,
            affiliation: None,
        }
    }

    pub fn with_given_name(mut self, given: impl Into<String>) -> Self {
        self.given_name = Some(given.into());
        self
    }

    /// Format as "Family, Given" for BibTeX
    pub fn to_bibtex_format(&self) -> String {
        match &self.given_name {
            Some(given) => format!("{}, {}", self.family_name, given),
            None => self.family_name.clone(),
        }
    }

    /// Format as "Given Family" for display
    pub fn display_name(&self) -> String {
        match &self.given_name {
            Some(given) => format!("{} {}", given, self.family_name),
            None => self.family_name.clone(),
        }
    }
}

/// Parse author string in various formats
#[uniffi::export]
pub fn parse_author_string(input: &str) -> Vec<Author> {
    // Reuse existing text::author_parser logic
    crate::text::parse_authors(input)
        .into_iter()
        .map(|parsed| Author {
            id: uuid::Uuid::new_v4().to_string(),
            family_name: parsed.surname,
            given_name: parsed.given_names,
            suffix: None,
            orcid: None,
            affiliation: None,
        })
        .collect()
}
```

**Create:** `imbib-core/src/domain/publication.rs`
```rust
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use crate::bibtex::{BibTeXEntry, BibTeXEntryType};
use crate::ris::RISEntry;
use super::{Author, Identifiers, LinkedFile, ValidationError};

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct Publication {
    pub id: String,
    pub cite_key: String,
    pub entry_type: String,
    pub title: String,
    pub year: Option<i32>,
    pub month: Option<String>,
    pub authors: Vec<Author>,
    pub editors: Vec<Author>,

    // Standard BibTeX fields
    pub journal: Option<String>,
    pub booktitle: Option<String>,
    pub publisher: Option<String>,
    pub volume: Option<String>,
    pub number: Option<String>,
    pub pages: Option<String>,
    pub edition: Option<String>,
    pub series: Option<String>,
    pub address: Option<String>,
    pub chapter: Option<String>,
    pub howpublished: Option<String>,
    pub institution: Option<String>,
    pub organization: Option<String>,
    pub school: Option<String>,
    pub note: Option<String>,

    // Extended fields
    pub abstract_text: Option<String>,
    pub keywords: Vec<String>,
    pub url: Option<String>,
    pub eprint: Option<String>,
    pub primary_class: Option<String>,
    pub archive_prefix: Option<String>,

    // Identifiers
    pub identifiers: Identifiers,

    // Additional fields (catch-all for non-standard BibTeX fields)
    pub extra_fields: HashMap<String, String>,

    // Linked files
    pub linked_files: Vec<LinkedFile>,

    // Organization
    pub tags: Vec<String>,
    pub collections: Vec<String>,
    pub library_id: Option<String>,

    // Metadata
    pub created_at: Option<String>,  // ISO 8601
    pub modified_at: Option<String>, // ISO 8601
    pub source_id: Option<String>,   // Original source (arxiv, crossref, etc.)

    // Enrichment data
    pub citation_count: Option<i32>,
    pub reference_count: Option<i32>,
    pub enrichment_source: Option<String>,
    pub enrichment_date: Option<String>,

    // Original format preservation
    pub raw_bibtex: Option<String>,
    pub raw_ris: Option<String>,
}

impl Publication {
    pub fn new(cite_key: String, entry_type: String, title: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            cite_key,
            entry_type,
            title,
            year: None,
            month: None,
            authors: Vec::new(),
            editors: Vec::new(),
            journal: None,
            booktitle: None,
            publisher: None,
            volume: None,
            number: None,
            pages: None,
            edition: None,
            series: None,
            address: None,
            chapter: None,
            howpublished: None,
            institution: None,
            organization: None,
            school: None,
            note: None,
            abstract_text: None,
            keywords: Vec::new(),
            url: None,
            eprint: None,
            primary_class: None,
            archive_prefix: None,
            identifiers: Identifiers::default(),
            extra_fields: HashMap::new(),
            linked_files: Vec::new(),
            tags: Vec::new(),
            collections: Vec::new(),
            library_id: None,
            created_at: None,
            modified_at: None,
            source_id: None,
            citation_count: None,
            reference_count: None,
            enrichment_source: None,
            enrichment_date: None,
            raw_bibtex: None,
            raw_ris: None,
        }
    }
}

// Conversion from BibTeXEntry
impl From<BibTeXEntry> for Publication {
    fn from(entry: BibTeXEntry) -> Self {
        let mut pub_ = Publication::new(
            entry.cite_key.clone(),
            entry.entry_type.to_string(),
            entry.fields.iter()
                .find(|f| f.key.to_lowercase() == "title")
                .map(|f| f.value.clone())
                .unwrap_or_default(),
        );

        // Map all standard fields
        for field in &entry.fields {
            let key = field.key.to_lowercase();
            let value = field.value.clone();

            match key.as_str() {
                "title" => pub_.title = value,
                "year" => pub_.year = value.parse().ok(),
                "month" => pub_.month = Some(value),
                "author" => pub_.authors = parse_author_string(&value),
                "editor" => pub_.editors = parse_author_string(&value),
                "journal" => pub_.journal = Some(value),
                "booktitle" => pub_.booktitle = Some(value),
                "publisher" => pub_.publisher = Some(value),
                "volume" => pub_.volume = Some(value),
                "number" => pub_.number = Some(value),
                "pages" => pub_.pages = Some(value),
                "edition" => pub_.edition = Some(value),
                "series" => pub_.series = Some(value),
                "address" => pub_.address = Some(value),
                "chapter" => pub_.chapter = Some(value),
                "howpublished" => pub_.howpublished = Some(value),
                "institution" => pub_.institution = Some(value),
                "organization" => pub_.organization = Some(value),
                "school" => pub_.school = Some(value),
                "note" => pub_.note = Some(value),
                "abstract" => pub_.abstract_text = Some(value),
                "keywords" => pub_.keywords = value.split(',').map(|s| s.trim().to_string()).collect(),
                "url" => pub_.url = Some(value),
                "doi" => pub_.identifiers.doi = Some(value),
                "eprint" => {
                    pub_.eprint = Some(value.clone());
                    // Also set as arxiv_id if it looks like one
                    if value.contains('.') || value.contains('/') {
                        pub_.identifiers.arxiv_id = Some(value);
                    }
                },
                "primaryclass" => pub_.primary_class = Some(value),
                "archiveprefix" => pub_.archive_prefix = Some(value),
                "pmid" => pub_.identifiers.pmid = Some(value),
                "bibcode" | "adsurl" => {
                    if key == "bibcode" {
                        pub_.identifiers.bibcode = Some(value);
                    }
                },
                "isbn" => pub_.identifiers.isbn = Some(value),
                "issn" => pub_.identifiers.issn = Some(value),
                _ => {
                    pub_.extra_fields.insert(field.key.clone(), value);
                }
            }
        }

        pub_.raw_bibtex = entry.raw_bibtex;
        pub_
    }
}

// Conversion to BibTeXEntry
impl From<&Publication> for BibTeXEntry {
    fn from(pub_: &Publication) -> Self {
        use crate::bibtex::BibTeXField;

        let mut fields = Vec::new();

        // Helper to add non-empty fields
        let mut add_field = |key: &str, value: &Option<String>| {
            if let Some(v) = value {
                if !v.is_empty() {
                    fields.push(BibTeXField { key: key.to_string(), value: v.clone() });
                }
            }
        };

        fields.push(BibTeXField { key: "title".to_string(), value: pub_.title.clone() });

        if let Some(year) = pub_.year {
            fields.push(BibTeXField { key: "year".to_string(), value: year.to_string() });
        }

        if !pub_.authors.is_empty() {
            let author_str = pub_.authors.iter()
                .map(|a| a.to_bibtex_format())
                .collect::<Vec<_>>()
                .join(" and ");
            fields.push(BibTeXField { key: "author".to_string(), value: author_str });
        }

        if !pub_.editors.is_empty() {
            let editor_str = pub_.editors.iter()
                .map(|a| a.to_bibtex_format())
                .collect::<Vec<_>>()
                .join(" and ");
            fields.push(BibTeXField { key: "editor".to_string(), value: editor_str });
        }

        add_field("month", &pub_.month);
        add_field("journal", &pub_.journal);
        add_field("booktitle", &pub_.booktitle);
        add_field("publisher", &pub_.publisher);
        add_field("volume", &pub_.volume);
        add_field("number", &pub_.number);
        add_field("pages", &pub_.pages);
        add_field("edition", &pub_.edition);
        add_field("series", &pub_.series);
        add_field("address", &pub_.address);
        add_field("chapter", &pub_.chapter);
        add_field("howpublished", &pub_.howpublished);
        add_field("institution", &pub_.institution);
        add_field("organization", &pub_.organization);
        add_field("school", &pub_.school);
        add_field("note", &pub_.note);
        add_field("abstract", &pub_.abstract_text);
        add_field("url", &pub_.url);
        add_field("eprint", &pub_.eprint);
        add_field("primaryclass", &pub_.primary_class);
        add_field("archiveprefix", &pub_.archive_prefix);
        add_field("doi", &pub_.identifiers.doi);
        add_field("pmid", &pub_.identifiers.pmid);
        add_field("bibcode", &pub_.identifiers.bibcode);
        add_field("isbn", &pub_.identifiers.isbn);
        add_field("issn", &pub_.identifiers.issn);

        if !pub_.keywords.is_empty() {
            fields.push(BibTeXField {
                key: "keywords".to_string(),
                value: pub_.keywords.join(", ")
            });
        }

        // Add extra fields
        for (key, value) in &pub_.extra_fields {
            fields.push(BibTeXField { key: key.clone(), value: value.clone() });
        }

        BibTeXEntry {
            cite_key: pub_.cite_key.clone(),
            entry_type: BibTeXEntryType::from_str(&pub_.entry_type),
            fields,
            raw_bibtex: pub_.raw_bibtex.clone(),
        }
    }
}

// UniFFI exports
#[uniffi::export]
pub fn publication_from_bibtex(entry: BibTeXEntry) -> Publication {
    Publication::from(entry)
}

#[uniffi::export]
pub fn publication_to_bibtex(publication: &Publication) -> BibTeXEntry {
    BibTeXEntry::from(publication)
}

#[uniffi::export]
pub fn publication_to_bibtex_string(publication: &Publication) -> String {
    let entry = BibTeXEntry::from(publication);
    crate::bibtex::bibtex_format_entry(entry)
}

use super::parse_author_string;
```

**Create:** `imbib-core/src/domain/linked_file.rs`
```rust
use serde::{Deserialize, Serialize};

#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum FileStorageType {
    Local,
    ICloud,
    WebDAV,
    S3,
    Url,
}

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct LinkedFile {
    pub id: String,
    pub filename: String,
    pub relative_path: Option<String>,
    pub absolute_url: Option<String>,
    pub storage_type: FileStorageType,
    pub mime_type: Option<String>,
    pub file_size: Option<i64>,
    pub checksum: Option<String>,
    pub added_at: Option<String>,
}

impl LinkedFile {
    pub fn new_local(filename: String, relative_path: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            filename,
            relative_path: Some(relative_path),
            absolute_url: None,
            storage_type: FileStorageType::Local,
            mime_type: Some("application/pdf".to_string()),
            file_size: None,
            checksum: None,
            added_at: None,
        }
    }

    pub fn new_url(filename: String, url: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            filename,
            relative_path: None,
            absolute_url: Some(url),
            storage_type: FileStorageType::Url,
            mime_type: Some("application/pdf".to_string()),
            file_size: None,
            checksum: None,
            added_at: None,
        }
    }
}
```

**Create:** `imbib-core/src/domain/library.rs`
```rust
use serde::{Deserialize, Serialize};

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct Library {
    pub id: String,
    pub name: String,
    pub file_path: Option<String>,
    pub is_default: bool,
    pub created_at: Option<String>,
    pub modified_at: Option<String>,
}

impl Library {
    pub fn new(name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            file_path: None,
            is_default: false,
            created_at: None,
            modified_at: None,
        }
    }
}
```

**Create:** `imbib-core/src/domain/tag.rs`
```rust
use serde::{Deserialize, Serialize};

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Tag {
    pub id: String,
    pub name: String,
    pub color: Option<String>,  // Hex color code
}

impl Tag {
    pub fn new(name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            color: None,
        }
    }

    pub fn with_color(mut self, color: String) -> Self {
        self.color = Some(color);
        self
    }
}
```

**Create:** `imbib-core/src/domain/collection.rs`
```rust
use serde::{Deserialize, Serialize};

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct Collection {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub is_smart: bool,
    pub smart_query: Option<String>,
    pub created_at: Option<String>,
}

impl Collection {
    pub fn new(name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            parent_id: None,
            is_smart: false,
            smart_query: None,
            created_at: None,
        }
    }

    pub fn new_smart(name: String, query: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            parent_id: None,
            is_smart: true,
            smart_query: Some(query),
            created_at: None,
        }
    }
}
```

**Create:** `imbib-core/src/domain/search_result.rs`
```rust
use serde::{Deserialize, Serialize};
use super::{Author, Identifiers};

#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum Source {
    ArXiv,
    Crossref,
    ADS,
    PubMed,
    OpenAlex,
    DBLP,
    SemanticScholar,
    SciX,
    Local,
    Manual,
}

impl Source {
    pub fn as_str(&self) -> &'static str {
        match self {
            Source::ArXiv => "arxiv",
            Source::Crossref => "crossref",
            Source::ADS => "ads",
            Source::PubMed => "pubmed",
            Source::OpenAlex => "openalex",
            Source::DBLP => "dblp",
            Source::SemanticScholar => "semanticscholar",
            Source::SciX => "scix",
            Source::Local => "local",
            Source::Manual => "manual",
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct PdfLink {
    pub url: String,
    pub link_type: PdfLinkType,
    pub description: Option<String>,
}

#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum PdfLinkType {
    Direct,
    Landing,
    ArXiv,
    Publisher,
    OpenAccess,
}

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct SearchResult {
    pub source_id: String,
    pub source: Source,
    pub title: String,
    pub authors: Vec<Author>,
    pub year: Option<i32>,
    pub identifiers: Identifiers,
    pub abstract_text: Option<String>,
    pub journal: Option<String>,
    pub volume: Option<String>,
    pub pages: Option<String>,
    pub pdf_links: Vec<PdfLink>,
    pub bibtex: Option<String>,
    pub url: Option<String>,
    pub citation_count: Option<i32>,
}

impl SearchResult {
    /// Convert to a Publication for import
    pub fn to_publication(&self) -> super::Publication {
        let mut pub_ = super::Publication::new(
            self.generate_cite_key(),
            "article".to_string(),
            self.title.clone(),
        );

        pub_.year = self.year;
        pub_.authors = self.authors.clone();
        pub_.identifiers = self.identifiers.clone();
        pub_.abstract_text = self.abstract_text.clone();
        pub_.journal = self.journal.clone();
        pub_.volume = self.volume.clone();
        pub_.pages = self.pages.clone();
        pub_.url = self.url.clone();
        pub_.source_id = Some(format!("{}:{}", self.source.as_str(), self.source_id));
        pub_.citation_count = self.citation_count;
        pub_.raw_bibtex = self.bibtex.clone();

        pub_
    }

    fn generate_cite_key(&self) -> String {
        let author = self.authors.first()
            .map(|a| a.family_name.clone())
            .unwrap_or_else(|| "Unknown".to_string());
        let year = self.year.map(|y| y.to_string()).unwrap_or_default();
        let title_word = self.title.split_whitespace()
            .find(|w| w.len() > 3)
            .unwrap_or("paper")
            .to_string();

        crate::identifiers::generate_cite_key(
            Some(author),
            if year.is_empty() { None } else { Some(year) },
            Some(title_word),
        )
    }
}
```

**Create:** `imbib-core/src/domain/validation.rs`
```rust
use serde::{Deserialize, Serialize};
use super::Publication;

#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize)]
pub enum ValidationSeverity {
    Error,
    Warning,
    Info,
}

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct ValidationError {
    pub field: String,
    pub message: String,
    pub severity: ValidationSeverity,
}

#[uniffi::export]
pub fn validate_publication(publication: &Publication) -> Vec<ValidationError> {
    let mut errors = Vec::new();

    // Required fields
    if publication.cite_key.is_empty() {
        errors.push(ValidationError {
            field: "cite_key".to_string(),
            message: "Citation key is required".to_string(),
            severity: ValidationSeverity::Error,
        });
    }

    if publication.title.is_empty() {
        errors.push(ValidationError {
            field: "title".to_string(),
            message: "Title is required".to_string(),
            severity: ValidationSeverity::Error,
        });
    }

    if publication.entry_type.is_empty() {
        errors.push(ValidationError {
            field: "entry_type".to_string(),
            message: "Entry type is required".to_string(),
            severity: ValidationSeverity::Error,
        });
    }

    // Warnings for recommended fields
    if publication.authors.is_empty() {
        errors.push(ValidationError {
            field: "authors".to_string(),
            message: "Authors are recommended".to_string(),
            severity: ValidationSeverity::Warning,
        });
    }

    if publication.year.is_none() {
        errors.push(ValidationError {
            field: "year".to_string(),
            message: "Year is recommended".to_string(),
            severity: ValidationSeverity::Warning,
        });
    }

    // Entry-type specific validation
    let entry_type = publication.entry_type.to_lowercase();
    match entry_type.as_str() {
        "article" => {
            if publication.journal.is_none() {
                errors.push(ValidationError {
                    field: "journal".to_string(),
                    message: "Journal is required for article entries".to_string(),
                    severity: ValidationSeverity::Warning,
                });
            }
        }
        "inproceedings" | "conference" => {
            if publication.booktitle.is_none() {
                errors.push(ValidationError {
                    field: "booktitle".to_string(),
                    message: "Booktitle is required for conference entries".to_string(),
                    severity: ValidationSeverity::Warning,
                });
            }
        }
        "book" | "inbook" => {
            if publication.publisher.is_none() {
                errors.push(ValidationError {
                    field: "publisher".to_string(),
                    message: "Publisher is recommended for book entries".to_string(),
                    severity: ValidationSeverity::Warning,
                });
            }
        }
        "phdthesis" | "mastersthesis" => {
            if publication.school.is_none() {
                errors.push(ValidationError {
                    field: "school".to_string(),
                    message: "School is required for thesis entries".to_string(),
                    severity: ValidationSeverity::Warning,
                });
            }
        }
        _ => {}
    }

    // Identifier validation
    if let Some(ref doi) = publication.identifiers.doi {
        if !doi.starts_with("10.") {
            errors.push(ValidationError {
                field: "doi".to_string(),
                message: "DOI should start with '10.'".to_string(),
                severity: ValidationSeverity::Warning,
            });
        }
    }

    errors
}

#[uniffi::export]
pub fn is_valid(publication: &Publication) -> bool {
    validate_publication(publication)
        .iter()
        .all(|e| !matches!(e.severity, ValidationSeverity::Error))
}
```

**Update Cargo.toml** - add dependencies:
```toml
[dependencies]
# ... existing deps ...
serde = { version = "1", features = ["derive"] }
serde_json = "1"
uuid = { version = "1", features = ["v4"] }
```

**Update `src/lib.rs`** - add module:
```rust
pub mod domain;

// Re-export domain types
pub use domain::*;
```

**Checkpoint:** Run `cargo build` and `cargo test`. All existing tests must pass.

---

### Phase 2: Import/Export Pipelines

**Goal:** Unified import/export that works with domain models.

**Create:** `imbib-core/src/import/mod.rs`
```rust
//! Import pipelines for various formats

use crate::domain::Publication;
use crate::bibtex::{bibtex_parse, BibTeXEntry};
use crate::ris::{ris_parse, RISEntry};
use thiserror::Error;

#[derive(uniffi::Error, Error, Debug)]
pub enum ImportError {
    #[error("Parse error: {message}")]
    ParseError { message: String },
    #[error("Invalid format: {message}")]
    InvalidFormat { message: String },
    #[error("Empty input")]
    EmptyInput,
}

#[derive(uniffi::Enum, Clone, Debug)]
pub enum ImportFormat {
    BibTeX,
    RIS,
    Auto,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ImportResult {
    pub publications: Vec<Publication>,
    pub warnings: Vec<String>,
    pub errors: Vec<String>,
}

/// Detect format from content
#[uniffi::export]
pub fn detect_format(content: &str) -> ImportFormat {
    let trimmed = content.trim();

    // BibTeX starts with @
    if trimmed.starts_with('@') {
        return ImportFormat::BibTeX;
    }

    // RIS starts with TY  -
    if trimmed.starts_with("TY  -") || trimmed.contains("\nTY  -") {
        return ImportFormat::RIS;
    }

    // Try to detect by content patterns
    if trimmed.contains("@article") || trimmed.contains("@book") ||
       trimmed.contains("@inproceedings") || trimmed.contains("@misc") {
        return ImportFormat::BibTeX;
    }

    if trimmed.contains("ER  -") || trimmed.contains("AU  -") {
        return ImportFormat::RIS;
    }

    ImportFormat::Auto
}

/// Import from BibTeX string
#[uniffi::export]
pub fn import_bibtex(content: &str) -> Result<ImportResult, ImportError> {
    if content.trim().is_empty() {
        return Err(ImportError::EmptyInput);
    }

    let parse_result = bibtex_parse(content.to_string())
        .map_err(|e| ImportError::ParseError { message: e.to_string() })?;

    let mut publications = Vec::new();
    let mut warnings = Vec::new();

    for entry in parse_result.entries {
        let pub_ = Publication::from(entry);

        // Collect warnings for incomplete entries
        let validation = crate::domain::validate_publication(&pub_);
        for err in validation {
            if matches!(err.severity, crate::domain::ValidationSeverity::Warning) {
                warnings.push(format!("{}: {} - {}", pub_.cite_key, err.field, err.message));
            }
        }

        publications.push(pub_);
    }

    // Include parse errors as warnings
    let errors: Vec<String> = parse_result.errors
        .iter()
        .map(|e| e.to_string())
        .collect();

    Ok(ImportResult {
        publications,
        warnings,
        errors,
    })
}

/// Import from RIS string
#[uniffi::export]
pub fn import_ris(content: &str) -> Result<ImportResult, ImportError> {
    if content.trim().is_empty() {
        return Err(ImportError::EmptyInput);
    }

    let ris_entries = ris_parse(content.to_string())
        .map_err(|e| ImportError::ParseError { message: e.to_string() })?;

    let mut publications = Vec::new();
    let mut warnings = Vec::new();

    for ris_entry in ris_entries {
        // Convert RIS to BibTeX first, then to Publication
        let bibtex_entry = crate::ris::ris_to_bibtex(ris_entry.clone());
        let mut pub_ = Publication::from(bibtex_entry);
        pub_.raw_ris = ris_entry.raw_ris;

        let validation = crate::domain::validate_publication(&pub_);
        for err in validation {
            if matches!(err.severity, crate::domain::ValidationSeverity::Warning) {
                warnings.push(format!("{}: {} - {}", pub_.cite_key, err.field, err.message));
            }
        }

        publications.push(pub_);
    }

    Ok(ImportResult {
        publications,
        warnings,
        errors: Vec::new(),
    })
}

/// Import with auto-detection
#[uniffi::export]
pub fn import_auto(content: &str) -> Result<ImportResult, ImportError> {
    match detect_format(content) {
        ImportFormat::BibTeX => import_bibtex(content),
        ImportFormat::RIS => import_ris(content),
        ImportFormat::Auto => {
            // Try BibTeX first, then RIS
            import_bibtex(content).or_else(|_| import_ris(content))
        }
    }
}
```

**Create:** `imbib-core/src/export/mod.rs`
```rust
//! Export pipelines for various formats

use crate::domain::Publication;
use crate::bibtex::{bibtex_format_entry, bibtex_format_entries, BibTeXEntry};
use crate::ris::{ris_format_entry, ris_from_bibtex, RISEntry};

#[derive(uniffi::Enum, Clone, Debug)]
pub enum ExportFormat {
    BibTeX,
    RIS,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ExportOptions {
    pub include_abstract: bool,
    pub include_keywords: bool,
    pub include_extra_fields: bool,
    pub sort_fields: bool,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            include_abstract: true,
            include_keywords: true,
            include_extra_fields: true,
            sort_fields: false,
        }
    }
}

#[uniffi::export]
pub fn default_export_options() -> ExportOptions {
    ExportOptions::default()
}

/// Export single publication to BibTeX
#[uniffi::export]
pub fn export_bibtex(publication: &Publication, options: &ExportOptions) -> String {
    let entry = filter_entry(BibTeXEntry::from(publication), options);
    bibtex_format_entry(entry)
}

/// Export multiple publications to BibTeX
#[uniffi::export]
pub fn export_bibtex_multiple(publications: Vec<Publication>, options: &ExportOptions) -> String {
    let entries: Vec<BibTeXEntry> = publications
        .iter()
        .map(|p| filter_entry(BibTeXEntry::from(p), options))
        .collect();
    bibtex_format_entries(entries)
}

/// Export single publication to RIS
#[uniffi::export]
pub fn export_ris(publication: &Publication) -> String {
    let bibtex_entry = BibTeXEntry::from(publication);
    let ris_entry = ris_from_bibtex(bibtex_entry);
    ris_format_entry(ris_entry)
}

/// Export multiple publications to RIS
#[uniffi::export]
pub fn export_ris_multiple(publications: Vec<Publication>) -> String {
    publications
        .iter()
        .map(|p| {
            let bibtex_entry = BibTeXEntry::from(p);
            let ris_entry = ris_from_bibtex(bibtex_entry);
            ris_format_entry(ris_entry)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn filter_entry(mut entry: BibTeXEntry, options: &ExportOptions) -> BibTeXEntry {
    if !options.include_abstract {
        entry.fields.retain(|f| f.key.to_lowercase() != "abstract");
    }
    if !options.include_keywords {
        entry.fields.retain(|f| f.key.to_lowercase() != "keywords");
    }
    if options.sort_fields {
        entry.fields.sort_by(|a, b| a.key.cmp(&b.key));
    }
    entry
}
```

**Update `src/lib.rs`:**
```rust
pub mod import;
pub mod export;

pub use import::*;
pub use export::*;
```

**Checkpoint:** Run `cargo build` and `cargo test`.

---

### Phase 3: PDF Filename Generation

**Create:** `imbib-core/src/filename/mod.rs`
```rust
//! PDF filename generation with human-readable names

use crate::domain::Publication;
use regex::Regex;
use lazy_static::lazy_static;

lazy_static! {
    static ref UNSAFE_CHARS: Regex = Regex::new(r#"[<>:"/\\|?*\x00-\x1f]"#).unwrap();
    static ref MULTIPLE_SPACES: Regex = Regex::new(r"\s+").unwrap();
    static ref MULTIPLE_UNDERSCORES: Regex = Regex::new(r"_+").unwrap();
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FilenameOptions {
    pub max_length: u32,
    pub include_year: bool,
    pub title_words: u32,
    pub separator: String,
}

impl Default for FilenameOptions {
    fn default() -> Self {
        Self {
            max_length: 100,
            include_year: true,
            title_words: 3,
            separator: "_".to_string(),
        }
    }
}

#[uniffi::export]
pub fn default_filename_options() -> FilenameOptions {
    FilenameOptions::default()
}

/// Generate PDF filename from publication
/// Format: Author_Year_Title.pdf
#[uniffi::export]
pub fn generate_pdf_filename(publication: &Publication, options: &FilenameOptions) -> String {
    let mut parts = Vec::new();

    // Author (first author's family name)
    let author = publication.authors.first()
        .map(|a| sanitize_component(&a.family_name))
        .unwrap_or_else(|| "Unknown".to_string());
    parts.push(author);

    // Year
    if options.include_year {
        if let Some(year) = publication.year {
            parts.push(year.to_string());
        }
    }

    // Title (first N significant words)
    let title = extract_title_words(&publication.title, options.title_words as usize);
    if !title.is_empty() {
        parts.push(title);
    }

    let filename = parts.join(&options.separator);
    let truncated = truncate_filename(&filename, options.max_length as usize);

    format!("{}.pdf", truncated)
}

/// Generate filename from search result (before import)
#[uniffi::export]
pub fn generate_pdf_filename_from_search(
    title: &str,
    authors: Vec<String>,
    year: Option<i32>,
    options: &FilenameOptions,
) -> String {
    let mut parts = Vec::new();

    // Author
    let author = authors.first()
        .map(|a| {
            // Extract family name (last word or after comma)
            if let Some(pos) = a.find(',') {
                sanitize_component(&a[..pos])
            } else {
                a.split_whitespace()
                    .last()
                    .map(|s| sanitize_component(s))
                    .unwrap_or_else(|| "Unknown".to_string())
            }
        })
        .unwrap_or_else(|| "Unknown".to_string());
    parts.push(author);

    // Year
    if options.include_year {
        if let Some(y) = year {
            parts.push(y.to_string());
        }
    }

    // Title
    let title_part = extract_title_words(title, options.title_words as usize);
    if !title_part.is_empty() {
        parts.push(title_part);
    }

    let filename = parts.join(&options.separator);
    let truncated = truncate_filename(&filename, options.max_length as usize);

    format!("{}.pdf", truncated)
}

fn sanitize_component(input: &str) -> String {
    let cleaned = UNSAFE_CHARS.replace_all(input, "");
    let normalized = MULTIPLE_SPACES.replace_all(&cleaned, " ");
    let trimmed = normalized.trim();

    // Convert spaces to underscores and capitalize
    let result: String = trimmed
        .chars()
        .map(|c| if c == ' ' { '_' } else { c })
        .collect();

    MULTIPLE_UNDERSCORES.replace_all(&result, "_").to_string()
}

fn extract_title_words(title: &str, max_words: usize) -> String {
    // Skip common articles and prepositions at the start
    let skip_words = ["a", "an", "the", "on", "in", "of", "for", "to", "and", "with"];

    let words: Vec<&str> = title
        .split_whitespace()
        .filter(|w| w.len() > 1)  // Skip single chars
        .filter(|w| !skip_words.contains(&w.to_lowercase().as_str()))
        .take(max_words)
        .collect();

    words
        .iter()
        .map(|w| sanitize_component(w))
        .collect::<Vec<_>>()
        .join("_")
}

fn truncate_filename(filename: &str, max_length: usize) -> String {
    if filename.len() <= max_length {
        filename.to_string()
    } else {
        // Truncate at word boundary if possible
        let truncated = &filename[..max_length];
        if let Some(pos) = truncated.rfind('_') {
            truncated[..pos].to_string()
        } else {
            truncated.to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_filename() {
        let mut pub_ = Publication::new(
            "einstein1905".to_string(),
            "article".to_string(),
            "On the Electrodynamics of Moving Bodies".to_string(),
        );
        pub_.year = Some(1905);
        pub_.authors.push(crate::domain::Author::new("Einstein".to_string()));

        let filename = generate_pdf_filename(&pub_, &default_filename_options());
        assert_eq!(filename, "Einstein_1905_Electrodynamics_Moving_Bodies.pdf");
    }

    #[test]
    fn test_sanitize_unsafe_chars() {
        let result = sanitize_component("Test: A <File> Name?");
        assert_eq!(result, "Test_A_File_Name");
    }
}
```

**Update `src/lib.rs`:**
```rust
pub mod filename;
pub use filename::*;
```

**Checkpoint:** Run `cargo build` and `cargo test`.

---

### Phase 4: Enhanced Deduplication with Domain Models

**Update:** `imbib-core/src/deduplication/mod.rs` to work with `Publication`:

```rust
// Add to existing file

use crate::domain::Publication;

/// Find duplicates in a list of publications
#[uniffi::export]
pub fn find_duplicates(
    publications: Vec<Publication>,
    threshold: f64,
) -> Vec<DuplicateGroup> {
    let mut groups: Vec<DuplicateGroup> = Vec::new();
    let mut processed: std::collections::HashSet<usize> = std::collections::HashSet::new();

    for i in 0..publications.len() {
        if processed.contains(&i) {
            continue;
        }

        let mut group_ids = vec![publications[i].id.clone()];

        for j in (i + 1)..publications.len() {
            if processed.contains(&j) {
                continue;
            }

            let match_result = calculate_publication_similarity(&publications[i], &publications[j]);
            if match_result.score >= threshold {
                group_ids.push(publications[j].id.clone());
                processed.insert(j);
            }
        }

        if group_ids.len() > 1 {
            groups.push(DuplicateGroup {
                publication_ids: group_ids,
                confidence: threshold,
            });
        }

        processed.insert(i);
    }

    groups
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct DuplicateGroup {
    pub publication_ids: Vec<String>,
    pub confidence: f64,
}

/// Calculate similarity between two publications
#[uniffi::export]
pub fn calculate_publication_similarity(a: &Publication, b: &Publication) -> DeduplicationMatch {
    // First check identifiers (highest confidence)
    if let (Some(doi_a), Some(doi_b)) = (&a.identifiers.doi, &b.identifiers.doi) {
        if normalize_doi(doi_a) == normalize_doi(doi_b) {
            return DeduplicationMatch {
                score: 1.0,
                reason: "Matching DOI".to_string(),
            };
        }
    }

    if let (Some(arxiv_a), Some(arxiv_b)) = (&a.identifiers.arxiv_id, &b.identifiers.arxiv_id) {
        if normalize_arxiv_id(arxiv_a) == normalize_arxiv_id(arxiv_b) {
            return DeduplicationMatch {
                score: 1.0,
                reason: "Matching arXiv ID".to_string(),
            };
        }
    }

    if let (Some(bibcode_a), Some(bibcode_b)) = (&a.identifiers.bibcode, &b.identifiers.bibcode) {
        if bibcode_a == bibcode_b {
            return DeduplicationMatch {
                score: 1.0,
                reason: "Matching bibcode".to_string(),
            };
        }
    }

    // Fall back to title + author similarity
    let title_sim = title_similarity(&a.title, &b.title);
    let author_sim = author_similarity(&a.authors, &b.authors);
    let year_match = match (a.year, b.year) {
        (Some(y1), Some(y2)) => if y1 == y2 { 0.2 } else if (y1 - y2).abs() <= 1 { 0.1 } else { 0.0 },
        _ => 0.0,
    };

    let score = (title_sim * 0.5) + (author_sim * 0.3) + year_match;

    DeduplicationMatch {
        score,
        reason: format!("Title: {:.0}%, Authors: {:.0}%", title_sim * 100.0, author_sim * 100.0),
    }
}

fn title_similarity(a: &str, b: &str) -> f64 {
    let norm_a = normalize_title(a);
    let norm_b = normalize_title(b);
    strsim::jaro_winkler(&norm_a, &norm_b)
}

fn normalize_title(title: &str) -> String {
    title
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn author_similarity(a: &[crate::domain::Author], b: &[crate::domain::Author]) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }

    let names_a: Vec<String> = a.iter().map(|auth| auth.family_name.to_lowercase()).collect();
    let names_b: Vec<String> = b.iter().map(|auth| auth.family_name.to_lowercase()).collect();

    let matches = names_a.iter().filter(|n| names_b.contains(n)).count();
    let total = names_a.len().max(names_b.len());

    matches as f64 / total as f64
}

fn normalize_doi(doi: &str) -> String {
    doi.to_lowercase()
        .trim_start_matches("https://doi.org/")
        .trim_start_matches("http://doi.org/")
        .trim_start_matches("doi:")
        .trim()
        .to_string()
}

fn normalize_arxiv_id(id: &str) -> String {
    id.to_lowercase()
        .trim_start_matches("arxiv:")
        .trim()
        .to_string()
}
```

**Checkpoint:** Run `cargo build` and `cargo test`.

---

### Phase 5: Merge and Conflict Resolution

**Create:** `imbib-core/src/merge/mod.rs`
```rust
//! Merge and conflict resolution for sync

use crate::domain::Publication;
use serde::{Deserialize, Serialize};

#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize)]
pub enum MergeStrategy {
    /// Keep local version
    KeepLocal,
    /// Keep remote version
    KeepRemote,
    /// Keep newer (by modified_at)
    KeepNewer,
    /// Merge fields (non-destructive)
    MergeFields,
    /// Manual resolution required
    Manual,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Conflict {
    pub id: String,
    pub local: Publication,
    pub remote: Publication,
    pub base: Option<Publication>,
    pub conflicting_fields: Vec<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct MergeResult {
    pub merged: Publication,
    pub strategy_used: MergeStrategy,
    pub fields_from_local: Vec<String>,
    pub fields_from_remote: Vec<String>,
}

/// Detect conflicts between local and remote publications
#[uniffi::export]
pub fn detect_conflict(
    local: &Publication,
    remote: &Publication,
    base: Option<Publication>,
) -> Option<Conflict> {
    let mut conflicting_fields = Vec::new();

    // Check each field for conflicts
    if local.title != remote.title {
        conflicting_fields.push("title".to_string());
    }
    if local.year != remote.year {
        conflicting_fields.push("year".to_string());
    }
    if local.authors != remote.authors {
        conflicting_fields.push("authors".to_string());
    }
    if local.abstract_text != remote.abstract_text {
        conflicting_fields.push("abstract".to_string());
    }
    if local.journal != remote.journal {
        conflicting_fields.push("journal".to_string());
    }
    if local.identifiers != remote.identifiers {
        conflicting_fields.push("identifiers".to_string());
    }
    if local.tags != remote.tags {
        conflicting_fields.push("tags".to_string());
    }
    if local.note != remote.note {
        conflicting_fields.push("note".to_string());
    }

    if conflicting_fields.is_empty() {
        None
    } else {
        Some(Conflict {
            id: local.id.clone(),
            local: local.clone(),
            remote: remote.clone(),
            base,
            conflicting_fields,
        })
    }
}

/// Merge two publications using the specified strategy
#[uniffi::export]
pub fn merge_publications(
    local: &Publication,
    remote: &Publication,
    strategy: MergeStrategy,
) -> MergeResult {
    match strategy {
        MergeStrategy::KeepLocal => MergeResult {
            merged: local.clone(),
            strategy_used: MergeStrategy::KeepLocal,
            fields_from_local: vec!["all".to_string()],
            fields_from_remote: vec![],
        },
        MergeStrategy::KeepRemote => MergeResult {
            merged: remote.clone(),
            strategy_used: MergeStrategy::KeepRemote,
            fields_from_local: vec![],
            fields_from_remote: vec!["all".to_string()],
        },
        MergeStrategy::KeepNewer => {
            let local_newer = match (&local.modified_at, &remote.modified_at) {
                (Some(l), Some(r)) => l > r,
                (Some(_), None) => true,
                (None, Some(_)) => false,
                (None, None) => true, // Default to local
            };
            if local_newer {
                MergeResult {
                    merged: local.clone(),
                    strategy_used: MergeStrategy::KeepNewer,
                    fields_from_local: vec!["all".to_string()],
                    fields_from_remote: vec![],
                }
            } else {
                MergeResult {
                    merged: remote.clone(),
                    strategy_used: MergeStrategy::KeepNewer,
                    fields_from_local: vec![],
                    fields_from_remote: vec!["all".to_string()],
                }
            }
        }
        MergeStrategy::MergeFields => merge_fields(local, remote),
        MergeStrategy::Manual => MergeResult {
            merged: local.clone(),
            strategy_used: MergeStrategy::Manual,
            fields_from_local: vec!["all".to_string()],
            fields_from_remote: vec![],
        },
    }
}

fn merge_fields(local: &Publication, remote: &Publication) -> MergeResult {
    let mut merged = local.clone();
    let mut fields_from_local = Vec::new();
    let mut fields_from_remote = Vec::new();

    // Strategy: prefer non-empty over empty, prefer more complete

    // Title: prefer longer (more complete)
    if remote.title.len() > local.title.len() {
        merged.title = remote.title.clone();
        fields_from_remote.push("title".to_string());
    } else {
        fields_from_local.push("title".to_string());
    }

    // Year: prefer present over absent
    if merged.year.is_none() && remote.year.is_some() {
        merged.year = remote.year;
        fields_from_remote.push("year".to_string());
    } else {
        fields_from_local.push("year".to_string());
    }

    // Authors: prefer more authors
    if remote.authors.len() > local.authors.len() {
        merged.authors = remote.authors.clone();
        fields_from_remote.push("authors".to_string());
    } else {
        fields_from_local.push("authors".to_string());
    }

    // Abstract: prefer present over absent, then longer
    match (&local.abstract_text, &remote.abstract_text) {
        (None, Some(_)) => {
            merged.abstract_text = remote.abstract_text.clone();
            fields_from_remote.push("abstract".to_string());
        }
        (Some(l), Some(r)) if r.len() > l.len() => {
            merged.abstract_text = remote.abstract_text.clone();
            fields_from_remote.push("abstract".to_string());
        }
        _ => {
            fields_from_local.push("abstract".to_string());
        }
    }

    // Identifiers: merge (union)
    if merged.identifiers.doi.is_none() && remote.identifiers.doi.is_some() {
        merged.identifiers.doi = remote.identifiers.doi.clone();
        fields_from_remote.push("doi".to_string());
    }
    if merged.identifiers.arxiv_id.is_none() && remote.identifiers.arxiv_id.is_some() {
        merged.identifiers.arxiv_id = remote.identifiers.arxiv_id.clone();
        fields_from_remote.push("arxiv_id".to_string());
    }
    if merged.identifiers.pmid.is_none() && remote.identifiers.pmid.is_some() {
        merged.identifiers.pmid = remote.identifiers.pmid.clone();
        fields_from_remote.push("pmid".to_string());
    }
    if merged.identifiers.bibcode.is_none() && remote.identifiers.bibcode.is_some() {
        merged.identifiers.bibcode = remote.identifiers.bibcode.clone();
        fields_from_remote.push("bibcode".to_string());
    }

    // Tags: union
    for tag in &remote.tags {
        if !merged.tags.contains(tag) {
            merged.tags.push(tag.clone());
            if !fields_from_remote.contains(&"tags".to_string()) {
                fields_from_remote.push("tags".to_string());
            }
        }
    }

    // Linked files: union (by id)
    let local_file_ids: std::collections::HashSet<_> =
        local.linked_files.iter().map(|f| &f.id).collect();
    for file in &remote.linked_files {
        if !local_file_ids.contains(&file.id) {
            merged.linked_files.push(file.clone());
            if !fields_from_remote.contains(&"linked_files".to_string()) {
                fields_from_remote.push("linked_files".to_string());
            }
        }
    }

    // Citation count: prefer higher (more recent)
    if let Some(remote_count) = remote.citation_count {
        if merged.citation_count.map(|c| remote_count > c).unwrap_or(true) {
            merged.citation_count = Some(remote_count);
            merged.enrichment_date = remote.enrichment_date.clone();
            fields_from_remote.push("citation_count".to_string());
        }
    }

    MergeResult {
        merged,
        strategy_used: MergeStrategy::MergeFields,
        fields_from_local,
        fields_from_remote,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merge_prefers_complete() {
        let mut local = Publication::new(
            "test2020".to_string(),
            "article".to_string(),
            "Short".to_string(),
        );
        local.year = Some(2020);

        let mut remote = Publication::new(
            "test2020".to_string(),
            "article".to_string(),
            "A Much Longer and More Complete Title".to_string(),
        );
        remote.abstract_text = Some("This is an abstract".to_string());

        let result = merge_publications(&local, &remote, MergeStrategy::MergeFields);

        assert_eq!(result.merged.title, "A Much Longer and More Complete Title");
        assert_eq!(result.merged.year, Some(2020)); // From local
        assert!(result.merged.abstract_text.is_some()); // From remote
    }
}
```

**Update `src/lib.rs`:**
```rust
pub mod merge;
pub use merge::*;
```

**Checkpoint:** Run `cargo build` and `cargo test`.

---

### Phase 6: Async HTTP Client Foundation (for Source Plugins)

**Update `Cargo.toml`:**
```toml
[dependencies]
# ... existing ...
tokio = { version = "1", features = ["rt", "macros"], optional = true }
reqwest = { version = "0.12", features = ["json"], optional = true }
url = "2"

[features]
default = ["native"]
native = ["uniffi", "tokio", "reqwest"]
wasm = []  # Will add wasm-bindgen later

[target.'cfg(not(target_arch = "wasm32"))'.dependencies]
uniffi = { version = "0.28", features = ["tokio"] }
```

**Create:** `imbib-core/src/http/mod.rs`
```rust
//! HTTP client abstraction for source plugins

#[cfg(not(target_arch = "wasm32"))]
pub mod native;

#[cfg(not(target_arch = "wasm32"))]
pub use native::*;

use thiserror::Error;

#[derive(Error, Debug)]
pub enum HttpError {
    #[error("Request failed: {message}")]
    RequestFailed { message: String },
    #[error("Invalid URL: {url}")]
    InvalidUrl { url: String },
    #[error("Timeout")]
    Timeout,
    #[error("Rate limited")]
    RateLimited,
    #[error("Parse error: {message}")]
    ParseError { message: String },
}

#[derive(Clone, Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
    pub headers: std::collections::HashMap<String, String>,
}
```

**Create:** `imbib-core/src/http/native.rs`
```rust
//! Native HTTP client using reqwest

use super::{HttpError, HttpResponse};
use reqwest::Client;
use std::time::Duration;

pub struct HttpClient {
    client: Client,
    user_agent: String,
}

impl HttpClient {
    pub fn new(user_agent: &str) -> Self {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to create HTTP client");

        Self {
            client,
            user_agent: user_agent.to_string(),
        }
    }

    pub async fn get(&self, url: &str) -> Result<HttpResponse, HttpError> {
        let response = self.client
            .get(url)
            .header("User-Agent", &self.user_agent)
            .send()
            .await
            .map_err(|e| HttpError::RequestFailed { message: e.to_string() })?;

        let status = response.status().as_u16();

        if status == 429 {
            return Err(HttpError::RateLimited);
        }

        let headers = response.headers()
            .iter()
            .filter_map(|(k, v)| {
                v.to_str().ok().map(|v| (k.to_string(), v.to_string()))
            })
            .collect();

        let body = response.text().await
            .map_err(|e| HttpError::ParseError { message: e.to_string() })?;

        Ok(HttpResponse {
            status,
            body,
            headers,
        })
    }

    pub async fn get_with_params(
        &self,
        url: &str,
        params: &[(&str, &str)],
    ) -> Result<HttpResponse, HttpError> {
        let url = reqwest::Url::parse_with_params(url, params)
            .map_err(|_| HttpError::InvalidUrl { url: url.to_string() })?;

        self.get(url.as_str()).await
    }
}

impl Default for HttpClient {
    fn default() -> Self {
        Self::new("imbib/1.0")
    }
}
```

**Update `src/lib.rs`:**
```rust
#[cfg(not(target_arch = "wasm32"))]
pub mod http;
```

**Checkpoint:** Run `cargo build` and `cargo test`.

---

### Phase 7: ArXiv Source Plugin in Rust

**Create:** `imbib-core/src/sources/mod.rs`
```rust
//! Source plugins for fetching publications from online databases

pub mod arxiv;
pub mod traits;

pub use arxiv::*;
pub use traits::*;
```

**Create:** `imbib-core/src/sources/traits.rs`
```rust
//! Common traits for source plugins

use crate::domain::SearchResult;
use crate::http::HttpError;

#[derive(Debug)]
pub enum SourceError {
    Http(HttpError),
    Parse(String),
    RateLimit,
    NotFound,
    InvalidQuery(String),
}

impl From<HttpError> for SourceError {
    fn from(e: HttpError) -> Self {
        match e {
            HttpError::RateLimited => SourceError::RateLimit,
            other => SourceError::Http(other),
        }
    }
}

/// Metadata about a source
pub struct SourceMetadata {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub base_url: &'static str,
    pub rate_limit_per_second: f32,
    pub supports_bibtex: bool,
    pub supports_ris: bool,
    pub requires_api_key: bool,
}
```

**Create:** `imbib-core/src/sources/arxiv.rs`
```rust
//! arXiv source plugin

use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use crate::http::HttpClient;
use super::traits::{SourceError, SourceMetadata};
use regex::Regex;
use lazy_static::lazy_static;

lazy_static! {
    static ref ARXIV_ID_PATTERN: Regex = Regex::new(r"(\d{4}\.\d{4,5}|[a-z-]+/\d{7})").unwrap();
}

pub struct ArxivSource {
    client: HttpClient,
    base_url: String,
}

impl ArxivSource {
    pub fn new() -> Self {
        Self {
            client: HttpClient::new("imbib/1.0 (https://imbib.app)"),
            base_url: "http://export.arxiv.org/api/query".to_string(),
        }
    }

    pub fn metadata() -> SourceMetadata {
        SourceMetadata {
            id: "arxiv",
            name: "arXiv",
            description: "Open-access preprint repository",
            base_url: "https://arxiv.org",
            rate_limit_per_second: 0.33, // 3 second delay recommended
            supports_bibtex: true,
            supports_ris: false,
            requires_api_key: false,
        }
    }

    pub async fn search(&self, query: &str, max_results: u32) -> Result<Vec<SearchResult>, SourceError> {
        let params = [
            ("search_query", format!("all:{}", query)),
            ("max_results", max_results.to_string()),
            ("sortBy", "relevance".to_string()),
            ("sortOrder", "descending".to_string()),
        ];

        let url = format!("{}?{}", self.base_url,
            params.iter()
                .map(|(k, v)| format!("{}={}", k, urlencoding::encode(v)))
                .collect::<Vec<_>>()
                .join("&")
        );

        let response = self.client.get(&url).await?;

        if response.status != 200 {
            return Err(SourceError::Http(crate::http::HttpError::RequestFailed {
                message: format!("Status {}", response.status),
            }));
        }

        self.parse_atom_feed(&response.body)
    }

    pub async fn fetch_by_id(&self, arxiv_id: &str) -> Result<SearchResult, SourceError> {
        let clean_id = arxiv_id
            .trim_start_matches("arXiv:")
            .trim_start_matches("arxiv:");

        let url = format!("{}?id_list={}", self.base_url, clean_id);
        let response = self.client.get(&url).await?;

        let results = self.parse_atom_feed(&response.body)?;
        results.into_iter().next().ok_or(SourceError::NotFound)
    }

    fn parse_atom_feed(&self, xml: &str) -> Result<Vec<SearchResult>, SourceError> {
        // Simple XML parsing (in production, use quick-xml or similar)
        let mut results = Vec::new();

        // Split by entry tags
        for entry in xml.split("<entry>").skip(1) {
            if let Some(end) = entry.find("</entry>") {
                let entry_xml = &entry[..end];
                if let Some(result) = self.parse_entry(entry_xml) {
                    results.push(result);
                }
            }
        }

        Ok(results)
    }

    fn parse_entry(&self, xml: &str) -> Option<SearchResult> {
        let title = extract_tag(xml, "title")?.trim().replace('\n', " ");
        let id = extract_tag(xml, "id")?;
        let summary = extract_tag(xml, "summary").map(|s| s.trim().to_string());
        let published = extract_tag(xml, "published");

        // Extract arXiv ID from URL
        let arxiv_id = ARXIV_ID_PATTERN.find(&id)?.as_str().to_string();

        // Parse authors
        let authors = extract_all_tags(xml, "author")
            .into_iter()
            .filter_map(|author_xml| {
                extract_tag(&author_xml, "name").map(|name| {
                    let parts: Vec<&str> = name.trim().split_whitespace().collect();
                    if parts.len() >= 2 {
                        Author {
                            id: uuid::Uuid::new_v4().to_string(),
                            given_name: Some(parts[..parts.len()-1].join(" ")),
                            family_name: parts.last().unwrap().to_string(),
                            suffix: None,
                            orcid: None,
                            affiliation: None,
                        }
                    } else {
                        Author::new(name.trim().to_string())
                    }
                })
            })
            .collect();

        // Extract year from published date
        let year = published.and_then(|p| {
            p.get(..4).and_then(|y| y.parse().ok())
        });

        // Extract categories/primary_class
        let primary_class = extract_attr(xml, "arxiv:primary_category", "term");

        // Build PDF links
        let pdf_url = format!("https://arxiv.org/pdf/{}.pdf", arxiv_id);
        let abs_url = format!("https://arxiv.org/abs/{}", arxiv_id);

        Some(SearchResult {
            source_id: arxiv_id.clone(),
            source: Source::ArXiv,
            title,
            authors,
            year,
            identifiers: Identifiers {
                arxiv_id: Some(arxiv_id),
                doi: extract_doi_from_links(xml),
                ..Default::default()
            },
            abstract_text: summary,
            journal: primary_class.map(|c| format!("arXiv:{}", c)),
            volume: None,
            pages: None,
            pdf_links: vec![
                PdfLink {
                    url: pdf_url,
                    link_type: PdfLinkType::ArXiv,
                    description: Some("arXiv PDF".to_string()),
                },
            ],
            bibtex: None,
            url: Some(abs_url),
            citation_count: None,
        })
    }
}

impl Default for ArxivSource {
    fn default() -> Self {
        Self::new()
    }
}

// Helper functions for XML parsing
fn extract_tag(xml: &str, tag: &str) -> Option<String> {
    let start_tag = format!("<{}", tag);
    let end_tag = format!("</{}>", tag);

    let start = xml.find(&start_tag)?;
    let content_start = xml[start..].find('>')? + start + 1;
    let end = xml[content_start..].find(&end_tag)? + content_start;

    Some(xml[content_start..end].to_string())
}

fn extract_all_tags(xml: &str, tag: &str) -> Vec<String> {
    let start_tag = format!("<{}", tag);
    let end_tag = format!("</{}>", tag);
    let mut results = Vec::new();
    let mut search_start = 0;

    while let Some(start) = xml[search_start..].find(&start_tag) {
        let abs_start = search_start + start;
        if let Some(content_start) = xml[abs_start..].find('>') {
            let abs_content_start = abs_start + content_start + 1;
            if let Some(end) = xml[abs_content_start..].find(&end_tag) {
                let abs_end = abs_content_start + end;
                results.push(xml[abs_content_start..abs_end].to_string());
                search_start = abs_end + end_tag.len();
            } else {
                break;
            }
        } else {
            break;
        }
    }

    results
}

fn extract_attr(xml: &str, tag: &str, attr: &str) -> Option<String> {
    let start_tag = format!("<{}", tag);
    let start = xml.find(&start_tag)?;
    let tag_end = xml[start..].find('>')?;
    let tag_content = &xml[start..start + tag_end];

    let attr_pattern = format!("{}=\"", attr);
    let attr_start = tag_content.find(&attr_pattern)? + attr_pattern.len();
    let attr_end = tag_content[attr_start..].find('"')? + attr_start;

    Some(tag_content[attr_start..attr_end].to_string())
}

fn extract_doi_from_links(xml: &str) -> Option<String> {
    // Look for DOI in links
    for link in extract_all_tags(xml, "link") {
        if link.contains("doi.org") {
            if let Some(href) = extract_attr(&format!("<link {}>", link), "link", "href") {
                if let Some(doi_start) = href.find("10.") {
                    return Some(href[doi_start..].to_string());
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_arxiv_id() {
        assert!(ARXIV_ID_PATTERN.is_match("2301.12345"));
        assert!(ARXIV_ID_PATTERN.is_match("hep-th/9901001"));
    }
}
```

**Add to Cargo.toml:**
```toml
[dependencies]
# ... existing ...
urlencoding = "2"
```

**Update `src/lib.rs`:**
```rust
#[cfg(not(target_arch = "wasm32"))]
pub mod sources;
```

**Checkpoint:** Run `cargo build` and `cargo test`.

---

### Phase 8: Update Swift Bridge

After all Rust changes are complete, regenerate the Swift bindings:

```bash
cd imbib-core
cargo build --release

# Generate Swift bindings
cargo run --bin uniffi-bindgen generate \
    --library target/release/libimbib_core.dylib \
    --language swift \
    --out-dir ../ImbibRustCore/Sources/ImbibRustCore/

# Rebuild XCFramework
./build-xcframework.sh
```

**Update ImbibRustCore exports** if needed in `ImbibRustCore/Sources/ImbibRustCore/Exports.swift`:

```swift
// Re-export all public types from the generated bindings
@_exported import struct ImbibRustCore.Publication
@_exported import struct ImbibRustCore.Author
@_exported import struct ImbibRustCore.Library
@_exported import struct ImbibRustCore.Tag
@_exported import struct ImbibRustCore.Collection
@_exported import struct ImbibRustCore.SearchResult
@_exported import struct ImbibRustCore.LinkedFile
@_exported import struct ImbibRustCore.Identifiers
@_exported import struct ImbibRustCore.ImportResult
@_exported import struct ImbibRustCore.ExportOptions
@_exported import struct ImbibRustCore.MergeResult
@_exported import struct ImbibRustCore.Conflict
@_exported import enum ImbibRustCore.Source
@_exported import enum ImbibRustCore.MergeStrategy
@_exported import enum ImbibRustCore.ImportFormat
@_exported import enum ImbibRustCore.ValidationSeverity
```

---

### Phase 9: Create Swift Protocol Adapters

**Create:** `PublicationManagerCore/Sources/PublicationManagerCore/DataAccess/PublicationStore.swift`

```swift
import Foundation
import ImbibRustCore

/// Protocol for publication storage, enabling different backends
public protocol PublicationStore: Sendable {
    func fetchAll(in library: String?) async throws -> [Publication]
    func fetch(id: String) async throws -> Publication?
    func fetch(byCiteKey: String, in library: String?) async throws -> Publication?
    func search(query: String) async throws -> [Publication]
    func save(_ publication: Publication) async throws
    func delete(id: String) async throws
    func batchImport(_ publications: [Publication]) async throws

    /// Stream of changes for reactive updates
    func changes() -> AsyncStream<StoreChange>
}

public enum StoreChange: Sendable {
    case inserted([String])
    case updated([String])
    case deleted([String])
    case reloaded
}
```

**Create:** `PublicationManagerCore/Sources/PublicationManagerCore/DataAccess/CoreData/CoreDataPublicationStore.swift`

```swift
import Foundation
import CoreData
import ImbibRustCore

/// Core Data implementation of PublicationStore
public actor CoreDataPublicationStore: PublicationStore {
    private let persistenceController: PersistenceController
    private let changeSubject = AsyncStream<StoreChange>.makeStream()

    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    public func fetchAll(in library: String?) async throws -> [Publication] {
        let context = persistenceController.container.viewContext
        let request = CDPublication.fetchRequest()

        if let libraryId = library {
            request.predicate = NSPredicate(format: "ANY libraries.id == %@", libraryId)
        }

        let cdPublications = try context.fetch(request)
        return cdPublications.map { $0.toRustPublication() }
    }

    public func fetch(id: String) async throws -> Publication? {
        let context = persistenceController.container.viewContext
        let request = CDPublication.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1

        return try context.fetch(request).first?.toRustPublication()
    }

    public func fetch(byCiteKey: String, in library: String?) async throws -> Publication? {
        let context = persistenceController.container.viewContext
        let request = CDPublication.fetchRequest()

        if let libraryId = library {
            request.predicate = NSPredicate(
                format: "citeKey == %@ AND ANY libraries.id == %@",
                byCiteKey, libraryId
            )
        } else {
            request.predicate = NSPredicate(format: "citeKey == %@", byCiteKey)
        }
        request.fetchLimit = 1

        return try context.fetch(request).first?.toRustPublication()
    }

    public func search(query: String) async throws -> [Publication] {
        let context = persistenceController.container.viewContext
        let request = CDPublication.fetchRequest()
        request.predicate = NSPredicate(
            format: "title CONTAINS[cd] %@ OR citeKey CONTAINS[cd] %@",
            query, query
        )

        let cdPublications = try context.fetch(request)
        return cdPublications.map { $0.toRustPublication() }
    }

    public func save(_ publication: Publication) async throws {
        let context = persistenceController.container.viewContext

        let cdPublication: CDPublication
        if let existing = try await fetchCDPublication(id: publication.id, in: context) {
            cdPublication = existing
        } else {
            cdPublication = CDPublication(context: context)
            cdPublication.id = UUID(uuidString: publication.id) ?? UUID()
        }

        cdPublication.update(from: publication)
        try context.save()

        changeSubject.continuation.yield(.updated([publication.id]))
    }

    public func delete(id: String) async throws {
        let context = persistenceController.container.viewContext

        if let cdPublication = try await fetchCDPublication(id: id, in: context) {
            context.delete(cdPublication)
            try context.save()
            changeSubject.continuation.yield(.deleted([id]))
        }
    }

    public func batchImport(_ publications: [Publication]) async throws {
        let context = persistenceController.container.viewContext
        var insertedIds: [String] = []

        for publication in publications {
            let cdPublication = CDPublication(context: context)
            cdPublication.id = UUID(uuidString: publication.id) ?? UUID()
            cdPublication.update(from: publication)
            insertedIds.append(publication.id)
        }

        try context.save()
        changeSubject.continuation.yield(.inserted(insertedIds))
    }

    public func changes() -> AsyncStream<StoreChange> {
        changeSubject.stream
    }

    private func fetchCDPublication(id: String, in context: NSManagedObjectContext) async throws -> CDPublication? {
        let request = CDPublication.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

// MARK: - CDPublication Extensions

extension CDPublication {
    func toRustPublication() -> Publication {
        var identifiers = Identifiers(
            doi: self.doi,
            arxivId: self.arxivIDNormalized,
            pmid: nil,
            pmcid: nil,
            bibcode: self.bibcodeNormalized,
            isbn: nil,
            issn: nil,
            orcid: nil
        )

        // Parse extra identifiers from rawFields if needed
        if let rawFields = self.rawFields as? [String: String] {
            if identifiers.pmid == nil {
                identifiers.pmid = rawFields["pmid"]
            }
            if identifiers.isbn == nil {
                identifiers.isbn = rawFields["isbn"]
            }
        }

        let authors: [Author] = (self.publicationAuthors?.allObjects as? [CDPublicationAuthor])?
            .sorted { ($0.order) < ($1.order) }
            .compactMap { pubAuthor -> Author? in
                guard let author = pubAuthor.author else { return nil }
                return Author(
                    id: author.id?.uuidString ?? UUID().uuidString,
                    givenName: author.givenName,
                    familyName: author.familyName ?? "",
                    suffix: nil,
                    orcid: nil,
                    affiliation: nil
                )
            } ?? []

        let linkedFiles: [LinkedFile] = (self.linkedFiles?.allObjects as? [CDLinkedFile])?
            .map { file in
                LinkedFile(
                    id: file.id?.uuidString ?? UUID().uuidString,
                    filename: file.filename ?? "",
                    relativePath: file.relativePath,
                    absoluteUrl: file.absoluteURL,
                    storageType: .local,
                    mimeType: "application/pdf",
                    fileSize: nil,
                    checksum: nil,
                    addedAt: nil
                )
            } ?? []

        let tags: [String] = (self.tags?.allObjects as? [CDTag])?.map { $0.name ?? "" } ?? []
        let collections: [String] = (self.collections?.allObjects as? [CDCollection])?.map { $0.id?.uuidString ?? "" } ?? []

        var extraFields: [String: String] = [:]
        if let rawFields = self.rawFields as? [String: String] {
            extraFields = rawFields
        }

        return Publication(
            id: self.id?.uuidString ?? UUID().uuidString,
            citeKey: self.citeKey ?? "",
            entryType: self.entryType ?? "article",
            title: self.title ?? "",
            year: self.year != 0 ? Int32(self.year) : nil,
            month: extraFields["month"],
            authors: authors,
            editors: [],
            journal: extraFields["journal"],
            booktitle: extraFields["booktitle"],
            publisher: extraFields["publisher"],
            volume: extraFields["volume"],
            number: extraFields["number"],
            pages: extraFields["pages"],
            edition: extraFields["edition"],
            series: extraFields["series"],
            address: extraFields["address"],
            chapter: extraFields["chapter"],
            howpublished: extraFields["howpublished"],
            institution: extraFields["institution"],
            organization: extraFields["organization"],
            school: extraFields["school"],
            note: extraFields["note"],
            abstractText: self.abstract,
            keywords: (extraFields["keywords"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
            url: self.url,
            eprint: extraFields["eprint"],
            primaryClass: extraFields["primaryclass"],
            archivePrefix: extraFields["archiveprefix"],
            identifiers: identifiers,
            extraFields: extraFields,
            linkedFiles: linkedFiles,
            tags: tags,
            collections: collections,
            libraryId: (self.libraries?.anyObject() as? CDLibrary)?.id?.uuidString,
            createdAt: self.createdAt?.ISO8601Format(),
            modifiedAt: self.modifiedAt?.ISO8601Format(),
            sourceId: self.originalSourceID,
            citationCount: self.citationCount != 0 ? Int32(self.citationCount) : nil,
            referenceCount: self.referenceCount != 0 ? Int32(self.referenceCount) : nil,
            enrichmentSource: self.enrichmentSource,
            enrichmentDate: self.enrichmentDate?.ISO8601Format(),
            rawBibtex: self.rawBibTeX,
            rawRis: nil
        )
    }

    func update(from publication: Publication) {
        self.citeKey = publication.citeKey
        self.entryType = publication.entryType
        self.title = publication.title
        self.year = Int16(publication.year ?? 0)
        self.doi = publication.identifiers.doi
        self.arxivIDNormalized = publication.identifiers.arxivId
        self.bibcodeNormalized = publication.identifiers.bibcode
        self.abstract = publication.abstractText
        self.url = publication.url
        self.rawBibTeX = publication.rawBibtex
        self.originalSourceID = publication.sourceId
        self.citationCount = Int32(publication.citationCount ?? 0)
        self.referenceCount = Int32(publication.referenceCount ?? 0)
        self.enrichmentSource = publication.enrichmentSource
        self.modifiedAt = Date()

        // Store extra fields as rawFields
        var rawFields = publication.extraFields
        if let journal = publication.journal { rawFields["journal"] = journal }
        if let volume = publication.volume { rawFields["volume"] = volume }
        if let pages = publication.pages { rawFields["pages"] = pages }
        if let publisher = publication.publisher { rawFields["publisher"] = publisher }
        // ... add other fields as needed
        self.rawFields = rawFields as NSDictionary
    }
}
```

---

### Phase 10: Update View Models to Use Rust Types

**Update existing view models** to use `Publication` from Rust instead of `CDPublication` directly. This is a gradual migration - you can keep both working during transition.

Example update for `LibraryViewModel`:

```swift
import Foundation
import ImbibRustCore

@MainActor
@Observable
public final class LibraryViewModel {
    private let store: any PublicationStore

    public private(set) var publications: [Publication] = []
    public private(set) var isLoading = false
    public private(set) var error: Error?

    public init(store: any PublicationStore) {
        self.store = store
    }

    public func loadPublications(in library: String? = nil) async {
        isLoading = true
        defer { isLoading = false }

        do {
            publications = try await store.fetchAll(in: library)
            error = nil
        } catch {
            self.error = error
        }
    }

    public func search(query: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            publications = try await store.search(query: query)
            error = nil
        } catch {
            self.error = error
        }
    }

    public func importPublications(from content: String) async throws {
        let result = try importAuto(content: content)

        if !result.errors.isEmpty {
            // Log errors but continue with successful imports
            for error in result.errors {
                print("Import error: \(error)")
            }
        }

        try await store.batchImport(result.publications)
        await loadPublications()
    }

    public func exportBibtex() -> String {
        let options = defaultExportOptions()
        return exportBibtexMultiple(publications: publications, options: options)
    }
}
```

---

## Final Verification

After completing all phases:

1. **Build Rust:**
   ```bash
   cd imbib-core
   cargo build --release
   cargo test
   ```

2. **Regenerate Swift bindings:**
   ```bash
   ./build-xcframework.sh
   ```

3. **Build Swift package:**
   ```bash
   cd PublicationManagerCore
   swift build
   swift test
   ```

4. **Build apps:**
   ```bash
   xcodebuild -scheme imbib -configuration Debug build
   xcodebuild -scheme imbib-iOS -configuration Debug build
   ```

5. **Run all tests and verify no regressions.**

---

## Summary of New Files

### Rust (imbib-core/src/)
- `domain/mod.rs` - Domain module root
- `domain/publication.rs` - Publication model
- `domain/author.rs` - Author model
- `domain/identifiers.rs` - Identifiers model
- `domain/library.rs` - Library model
- `domain/tag.rs` - Tag model
- `domain/collection.rs` - Collection model
- `domain/linked_file.rs` - LinkedFile model
- `domain/search_result.rs` - SearchResult model
- `domain/validation.rs` - Validation logic
- `import/mod.rs` - Import pipelines
- `export/mod.rs` - Export pipelines
- `filename/mod.rs` - PDF filename generation
- `merge/mod.rs` - Merge and conflict resolution
- `http/mod.rs` - HTTP client abstraction
- `http/native.rs` - Native HTTP client
- `sources/mod.rs` - Source plugins module
- `sources/traits.rs` - Source plugin traits
- `sources/arxiv.rs` - ArXiv source plugin

### Swift (PublicationManagerCore/Sources/)
- `DataAccess/PublicationStore.swift` - Storage protocol
- `DataAccess/CoreData/CoreDataPublicationStore.swift` - Core Data adapter

---

## Code Sharing After Implementation

| Component | Native (Swift) | Web (WASM) | Server (Rust) | Shared |
|-----------|---------------|------------|---------------|--------|
| Domain models | ✓ (via FFI) | ✓ | ✓ | **100%** |
| BibTeX/RIS parsing | ✓ (via FFI) | ✓ | ✓ | **100%** |
| Import/export | ✓ (via FFI) | ✓ | ✓ | **100%** |
| Validation | ✓ (via FFI) | ✓ | ✓ | **100%** |
| Deduplication | ✓ (via FFI) | ✓ | ✓ | **100%** |
| Merge/conflict | ✓ (via FFI) | ✓ | ✓ | **100%** |
| Source plugins | ✓ (via FFI) | ✓ | ✓ | **100%** |
| Filename gen | ✓ (via FFI) | ✓ | ✓ | **100%** |
| Storage adapter | Core Data | IndexedDB | SQLite | 0% |
| UI | SwiftUI | React/Vue | N/A | 0% |
