//! Wrapper types mirroring `im_identifiers` with UniFFI derives.

use serde::{Deserialize, Serialize};

// ── ExtractedIdentifier ──────────────────────────────────────────────────────

/// Extracted identifier with position information
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ExtractedIdentifier {
    pub identifier_type: String,
    pub value: String,
    pub start_index: u32,
    pub end_index: u32,
}

impl From<im_identifiers::ExtractedIdentifier> for ExtractedIdentifier {
    fn from(e: im_identifiers::ExtractedIdentifier) -> Self {
        Self {
            identifier_type: e.identifier_type,
            value: e.value,
            start_index: e.start_index,
            end_index: e.end_index,
        }
    }
}

// ── IdentifierType ───────────────────────────────────────────────────────────

/// Types of publication identifiers across different sources
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum IdentifierType {
    /// Digital Object Identifier
    Doi,
    /// arXiv preprint identifier
    Arxiv,
    /// PubMed identifier
    Pmid,
    /// PubMed Central identifier
    Pmcid,
    /// NASA ADS bibcode
    Bibcode,
    /// Semantic Scholar paper ID
    SemanticScholar,
    /// OpenAlex work ID
    OpenAlex,
    /// DBLP record key
    Dblp,
}

impl IdentifierType {
    /// Get all identifier types
    pub fn all() -> &'static [IdentifierType] {
        &[
            IdentifierType::Doi,
            IdentifierType::Arxiv,
            IdentifierType::Pmid,
            IdentifierType::Pmcid,
            IdentifierType::Bibcode,
            IdentifierType::SemanticScholar,
            IdentifierType::OpenAlex,
            IdentifierType::Dblp,
        ]
    }
}

macro_rules! bidir_enum {
    ($local:ident, $foreign:path, $($variant:ident),+ $(,)?) => {
        impl From<$foreign> for $local {
            fn from(t: $foreign) -> Self {
                match t { $(<$foreign>::$variant => Self::$variant,)+ }
            }
        }
        impl From<$local> for $foreign {
            fn from(t: $local) -> Self {
                match t { $($local::$variant => Self::$variant,)+ }
            }
        }
    };
}

bidir_enum!(
    IdentifierType, im_identifiers::IdentifierType,
    Doi, Arxiv, Pmid, Pmcid, Bibcode, SemanticScholar, OpenAlex, Dblp,
);

// ── EnrichmentSource ─────────────────────────────────────────────────────────

/// Sources that can provide enrichment data
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EnrichmentSource {
    /// NASA Astrophysics Data System
    Ads,
    /// Semantic Scholar
    SemanticScholar,
    /// OpenAlex
    OpenAlex,
    /// Crossref
    Crossref,
    /// arXiv
    Arxiv,
    /// PubMed
    Pubmed,
    /// DBLP
    Dblp,
}

bidir_enum!(
    EnrichmentSource, im_identifiers::EnrichmentSource,
    Ads, SemanticScholar, OpenAlex, Crossref, Arxiv, Pubmed, Dblp,
);

// ── PreferredIdentifier ──────────────────────────────────────────────────────

/// Preferred identifier result containing type and value
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PreferredIdentifier {
    /// The identifier type (as string, e.g., "doi", "arxiv")
    pub id_type: String,
    /// The identifier value
    pub value: String,
}

impl From<im_identifiers::PreferredIdentifier> for PreferredIdentifier {
    fn from(p: im_identifiers::PreferredIdentifier) -> Self {
        Self {
            id_type: p.id_type,
            value: p.value,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_identifier_type_roundtrip() {
        for variant in [
            IdentifierType::Doi,
            IdentifierType::Arxiv,
            IdentifierType::Bibcode,
        ] {
            let inner: im_identifiers::IdentifierType = variant.into();
            let back: IdentifierType = inner.into();
            assert_eq!(variant, back);
        }
    }

    #[test]
    fn test_enrichment_source_roundtrip() {
        for variant in [
            EnrichmentSource::Ads,
            EnrichmentSource::SemanticScholar,
            EnrichmentSource::Crossref,
        ] {
            let inner: im_identifiers::EnrichmentSource = variant.into();
            let back: EnrichmentSource = inner.into();
            assert_eq!(variant, back);
        }
    }
}
