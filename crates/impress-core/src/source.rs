//! Domain-neutral source location and extraction primitives.
//!
//! These types describe *where bytes or derived text came from*. They do not
//! say what a source means in a particular domain. A publication annotation,
//! a repair-manual rule, and a scientific data-quality assertion can all cite
//! the same structures without sharing a domain ontology.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::item::ItemId;

/// A rectangle in page/image coordinates normalized to `[0, 1]`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct NormalizedRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl NormalizedRect {
    /// Construct a non-empty rectangle contained by the normalized unit square.
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Result<Self, SourceError> {
        let rect = Self {
            x,
            y,
            width,
            height,
        };
        rect.validate()?;
        Ok(rect)
    }

    pub fn validate(&self) -> Result<(), SourceError> {
        let values = [self.x, self.y, self.width, self.height];
        if values.iter().any(|v| !v.is_finite()) {
            return Err(SourceError::InvalidRegion(
                "coordinates must be finite".into(),
            ));
        }
        if self.x < 0.0
            || self.y < 0.0
            || self.width <= 0.0
            || self.height <= 0.0
            || self.x + self.width > 1.0
            || self.y + self.height > 1.0
        {
            return Err(SourceError::InvalidRegion(
                "rectangle must be non-empty and contained in [0, 1]".into(),
            ));
        }
        Ok(())
    }
}

/// A stable, renderer-independent location within a source asset.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct SourceLocator {
    /// Zero-based machine page index.
    pub page_index: Option<u32>,
    /// Human-visible page label, which may be roman or non-numeric.
    pub page_label: Option<String>,
    /// Optional normalized region on the selected page/image.
    pub region: Option<NormalizedRect>,
    /// Half-open character range in the extraction identified by the citation.
    pub char_range: Option<(u64, u64)>,
    /// Hierarchical section headings from broadest to narrowest.
    #[serde(default)]
    pub section_path: Vec<String>,
    pub figure_label: Option<String>,
    pub table_label: Option<String>,
}

impl SourceLocator {
    pub fn validate(&self) -> Result<(), SourceError> {
        if let Some(region) = self.region {
            region.validate()?;
            if self.page_index.is_none() {
                return Err(SourceError::InvalidLocator(
                    "a page region requires page_index".into(),
                ));
            }
        }
        if let Some((start, end)) = self.char_range {
            if start >= end {
                return Err(SourceError::InvalidLocator(
                    "char_range must be non-empty and half-open".into(),
                ));
            }
        }
        if self.page_index.is_none()
            && self.page_label.is_none()
            && self.char_range.is_none()
            && self.section_path.is_empty()
            && self.figure_label.is_none()
            && self.table_label.is_none()
        {
            return Err(SourceError::InvalidLocator(
                "a locator must identify at least one source position".into(),
            ));
        }
        Ok(())
    }
}

/// A citation pinned to immutable source bytes and, when relevant, one
/// extraction run.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SourceCitation {
    pub id: Uuid,
    pub source_item_id: ItemId,
    /// Lowercase SHA-256 of the source bytes.
    pub source_content_hash: String,
    pub extraction_run_id: Option<ItemId>,
    pub locator: SourceLocator,
    pub quote: Option<String>,
    /// Lowercase SHA-256 of the normalized quote, when a quote is retained.
    pub quote_hash: Option<String>,
    pub title: Option<String>,
}

impl SourceCitation {
    pub fn validate(&self) -> Result<(), SourceError> {
        validate_sha256("source_content_hash", &self.source_content_hash)?;
        self.locator.validate()?;
        match (&self.quote, &self.quote_hash) {
            (Some(quote), _) if quote.trim().is_empty() => Err(SourceError::InvalidCitation(
                "quote must not be blank".into(),
            )),
            (None, Some(_)) => Err(SourceError::InvalidCitation(
                "quote_hash requires quote".into(),
            )),
            (Some(quote), Some(hash)) => {
                validate_sha256("quote_hash", hash)?;
                let actual = normalized_text_hash(quote);
                if actual != *hash {
                    return Err(SourceError::InvalidCitation(
                        "quote_hash does not match normalized quote".into(),
                    ));
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }
}

/// Identity and reproducibility metadata for one extraction/OCR execution.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExtractionRun {
    pub id: ItemId,
    pub source_item_id: ItemId,
    pub source_content_hash: String,
    pub extractor: String,
    pub extractor_version: String,
    pub profile: String,
    pub started_at: String,
    pub completed_at: Option<String>,
    pub output_content_hash: Option<String>,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub produced_item_ids: Vec<ItemId>,
}

impl ExtractionRun {
    pub fn validate(&self) -> Result<(), SourceError> {
        validate_sha256("source_content_hash", &self.source_content_hash)?;
        if let Some(hash) = &self.output_content_hash {
            validate_sha256("output_content_hash", hash)?;
        }
        for (name, value) in [
            ("extractor", &self.extractor),
            ("extractor_version", &self.extractor_version),
            ("profile", &self.profile),
            ("started_at", &self.started_at),
        ] {
            if value.trim().is_empty() {
                return Err(SourceError::InvalidExtraction(format!(
                    "{name} must not be blank"
                )));
            }
        }
        Ok(())
    }

    /// Stable derivation key used to make unchanged extraction idempotent.
    pub fn derivation_key(&self) -> String {
        format!(
            "{}:{}:{}:{}",
            self.source_content_hash, self.extractor, self.extractor_version, self.profile
        )
    }
}

/// One positioned text observation emitted by an OCR or layout extractor.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExtractedTextRegion {
    pub text: String,
    /// Extractor-defined confidence normalized to `[0, 1]`, when available.
    pub confidence: Option<f64>,
    pub region: NormalizedRect,
}

/// Confidence state for a figure region. Automatic extraction must use
/// `Ambiguous` instead of guessing at a crop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FigureRegionStatus {
    Extracted,
    Curated,
    Ambiguous,
}

/// Provenance for an extracted or manually corrected figure boundary.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FigureRegionProvenance {
    Automatic {
        extractor: String,
        extractor_version: String,
    },
    ManualCorrection {
        curator: String,
        corrected_at: String,
        #[serde(default)]
        supersedes: Option<ItemId>,
    },
}

/// Immutable layout evidence connecting a figure label and caption to page
/// geometry. Coordinates use the same normalized lower-left page space as OCR
/// regions, independent of output DPI.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FigureRegionEvidence {
    pub id: ItemId,
    pub source_item_id: ItemId,
    pub source_content_hash: String,
    pub extraction_run_id: Option<ItemId>,
    pub page_index: u32,
    pub page_label: String,
    pub figure_label: String,
    pub caption_text: Option<String>,
    pub image_region: Option<NormalizedRect>,
    pub caption_region: Option<NormalizedRect>,
    pub status: FigureRegionStatus,
    pub provenance: FigureRegionProvenance,
    #[serde(default)]
    pub warnings: Vec<String>,
}

impl FigureRegionEvidence {
    pub fn validate(&self) -> Result<(), SourceError> {
        validate_sha256("source_content_hash", &self.source_content_hash)?;
        if self.page_label.trim().is_empty() || self.figure_label.trim().is_empty() {
            return Err(SourceError::InvalidFigureRegion(
                "page_label and figure_label must not be blank".into(),
            ));
        }
        if self
            .caption_text
            .as_ref()
            .is_some_and(|value| value.trim().is_empty())
        {
            return Err(SourceError::InvalidFigureRegion(
                "caption_text must be absent rather than blank".into(),
            ));
        }
        if let Some(region) = self.image_region {
            region.validate()?;
        }
        if let Some(region) = self.caption_region {
            region.validate()?;
        }
        match self.status {
            FigureRegionStatus::Extracted | FigureRegionStatus::Curated
                if self.image_region.is_none() =>
            {
                Err(SourceError::InvalidFigureRegion(
                    "an extracted or curated figure requires image_region".into(),
                ))
            }
            FigureRegionStatus::Ambiguous if self.image_region.is_some() => {
                Err(SourceError::InvalidFigureRegion(
                    "an ambiguous figure must not publish a selected image_region".into(),
                ))
            }
            FigureRegionStatus::Curated
                if !matches!(
                    self.provenance,
                    FigureRegionProvenance::ManualCorrection { .. }
                ) =>
            {
                Err(SourceError::InvalidFigureRegion(
                    "curated geometry requires manual-correction provenance".into(),
                ))
            }
            _ => Ok(()),
        }
    }
}

impl ExtractedTextRegion {
    pub fn validate(&self) -> Result<(), SourceError> {
        if self.text.trim().is_empty() {
            return Err(SourceError::InvalidChunk(
                "region text must not be blank".into(),
            ));
        }
        if self
            .confidence
            .is_some_and(|value| !value.is_finite() || !(0.0..=1.0).contains(&value))
        {
            return Err(SourceError::InvalidChunk(
                "region confidence must be finite and contained in [0, 1]".into(),
            ));
        }
        self.region.validate()
    }
}

/// Domain-neutral text derived from an immutable source.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContentChunk {
    pub id: ItemId,
    pub source_item_id: ItemId,
    pub extraction_run_id: ItemId,
    /// Page/region citation created from the same source and extraction run.
    /// Older chunks remain readable when this optional link is absent.
    #[serde(default)]
    pub citation_id: Option<ItemId>,
    pub ordinal: u32,
    pub text: String,
    pub content_hash: String,
    pub locator: SourceLocator,
    /// Optional layout observations retained by OCR/layout-aware extractors.
    #[serde(default)]
    pub regions: Vec<ExtractedTextRegion>,
}

impl ContentChunk {
    pub fn validate(&self) -> Result<(), SourceError> {
        if self.text.trim().is_empty() {
            return Err(SourceError::InvalidChunk("text must not be blank".into()));
        }
        validate_sha256("content_hash", &self.content_hash)?;
        if normalized_text_hash(&self.text) != self.content_hash {
            return Err(SourceError::InvalidChunk(
                "content_hash does not match normalized text".into(),
            ));
        }
        for region in &self.regions {
            region.validate()?;
        }
        self.locator.validate()
    }
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum SourceError {
    #[error("invalid normalized region: {0}")]
    InvalidRegion(String),
    #[error("invalid source locator: {0}")]
    InvalidLocator(String),
    #[error("invalid source citation: {0}")]
    InvalidCitation(String),
    #[error("invalid extraction run: {0}")]
    InvalidExtraction(String),
    #[error("invalid content chunk: {0}")]
    InvalidChunk(String),
    #[error("invalid figure region: {0}")]
    InvalidFigureRegion(String),
    #[error("invalid SHA-256 in {field}: {value}")]
    InvalidHash { field: String, value: String },
}

fn validate_sha256(field: &str, value: &str) -> Result<(), SourceError> {
    if value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        Ok(())
    } else {
        Err(SourceError::InvalidHash {
            field: field.into(),
            value: value.into(),
        })
    }
}

/// Hash text after trimming and collapsing Unicode whitespace. Extractors can
/// therefore reproduce quote/chunk identity without preserving layout-only
/// runs of spaces or line endings.
pub fn normalized_text_hash(text: &str) -> String {
    let normalized = text.split_whitespace().collect::<Vec<_>>().join(" ");
    format!("{:x}", Sha256::digest(normalized.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    #[test]
    fn normalized_rect_rejects_overflow_and_empty_regions() {
        assert!(NormalizedRect::new(0.1, 0.1, 0.8, 0.8).is_ok());
        assert!(NormalizedRect::new(0.5, 0.5, 0.6, 0.1).is_err());
        assert!(NormalizedRect::new(0.0, 0.0, 0.0, 0.5).is_err());
    }

    #[test]
    fn locator_requires_a_position_and_page_for_regions() {
        assert!(SourceLocator::default().validate().is_err());
        let locator = SourceLocator {
            region: Some(NormalizedRect::new(0.0, 0.0, 0.5, 0.5).unwrap()),
            ..Default::default()
        };
        assert!(locator.validate().is_err());
    }

    #[test]
    fn citation_is_pinned_to_a_valid_hash() {
        let citation = SourceCitation {
            id: Uuid::new_v4(),
            source_item_id: Uuid::new_v4(),
            source_content_hash: HASH.into(),
            extraction_run_id: None,
            locator: SourceLocator {
                page_index: Some(3),
                page_label: Some("17".into()),
                ..Default::default()
            },
            quote: Some("A bounded excerpt".into()),
            quote_hash: Some(normalized_text_hash("A bounded excerpt")),
            title: None,
        };
        assert!(citation.validate().is_ok());
        assert_eq!(
            serde_json::from_str::<SourceCitation>(&serde_json::to_string(&citation).unwrap())
                .unwrap(),
            citation
        );
    }

    #[test]
    fn extraction_derivation_key_changes_with_profile() {
        let mut run = ExtractionRun {
            id: Uuid::new_v4(),
            source_item_id: Uuid::new_v4(),
            source_content_hash: HASH.into(),
            extractor: "pdfium".into(),
            extractor_version: "1".into(),
            profile: "text".into(),
            started_at: "2026-08-05T12:00:00Z".into(),
            completed_at: None,
            output_content_hash: None,
            warnings: vec![],
            produced_item_ids: vec![],
        };
        let first = run.derivation_key();
        run.profile = "layout".into();
        assert_ne!(run.derivation_key(), first);
    }

    #[test]
    fn extracted_regions_validate_geometry_and_normalized_confidence() {
        let mut region = ExtractedTextRegion {
            text: "Fuel injection".into(),
            confidence: Some(0.97),
            region: NormalizedRect::new(0.1, 0.2, 0.5, 0.1).unwrap(),
        };
        assert!(region.validate().is_ok());
        region.confidence = Some(1.01);
        assert!(region.validate().is_err());
    }
}
