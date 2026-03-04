//! PaperStub — lightweight paper metadata for references and citations.
//!
//! Used by the citation explorer to display paper metadata without importing
//! the full publication. Mapped from `ScixPaper` (via scix-client-ffi) in Swift.

/// Lightweight representation of a paper for references/citations display.
///
/// Produced by ADS/SciX reference and citation queries. Not a full publication —
/// just enough metadata to show in the citation explorer and link to import.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct PaperStub {
    /// ADS bibcode — primary identifier (e.g., "2023ApJ...123..456A")
    pub id: String,
    /// Paper title
    pub title: String,
    /// Author names in "Last, First" format
    pub authors: Vec<String>,
    /// Publication year
    pub year: Option<i32>,
    /// Journal or conference name
    pub venue: Option<String>,
    /// DOI
    pub doi: Option<String>,
    /// arXiv identifier
    pub arxiv_id: Option<String>,
    /// Number of papers citing this one
    pub citation_count: Option<i32>,
    /// Number of references in this paper (if available)
    pub reference_count: Option<i32>,
    /// Whether any open-access version is available
    pub is_open_access: bool,
    /// Abstract text
    pub abstract_text: Option<String>,
}
