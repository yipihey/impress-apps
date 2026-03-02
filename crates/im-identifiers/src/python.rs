//! Python bindings for im-identifiers via PyO3
//!
//! Provides a `im_identifiers` Python module with identifier extraction,
//! validation, normalization, cite key generation, and resolution.

use pyo3::prelude::*;
use std::collections::HashMap;

use crate::extractors::ExtractedIdentifier;
use crate::resolver::{EnrichmentSource, IdentifierType, PreferredIdentifier};

// -- Python wrapper types --

/// An extracted identifier with position information
#[pyclass(name = "ExtractedIdentifier")]
#[derive(Clone)]
pub struct PyExtractedIdentifier {
    #[pyo3(get)]
    pub identifier_type: String,
    #[pyo3(get)]
    pub value: String,
    #[pyo3(get)]
    pub start_index: u32,
    #[pyo3(get)]
    pub end_index: u32,
}

#[pymethods]
impl PyExtractedIdentifier {
    fn __repr__(&self) -> String {
        format!(
            "ExtractedIdentifier(type={:?}, value={:?}, start={}, end={})",
            self.identifier_type, self.value, self.start_index, self.end_index
        )
    }
}

impl From<&ExtractedIdentifier> for PyExtractedIdentifier {
    fn from(e: &ExtractedIdentifier) -> Self {
        Self {
            identifier_type: e.identifier_type.clone(),
            value: e.value.clone(),
            start_index: e.start_index,
            end_index: e.end_index,
        }
    }
}

/// Preferred identifier for a source
#[pyclass(name = "PreferredIdentifier")]
#[derive(Clone)]
pub struct PyPreferredIdentifier {
    #[pyo3(get)]
    pub id_type: String,
    #[pyo3(get)]
    pub value: String,
}

#[pymethods]
impl PyPreferredIdentifier {
    fn __repr__(&self) -> String {
        format!(
            "PreferredIdentifier(type={:?}, value={:?})",
            self.id_type, self.value
        )
    }
}

impl From<&PreferredIdentifier> for PyPreferredIdentifier {
    fn from(p: &PreferredIdentifier) -> Self {
        Self {
            id_type: p.id_type.clone(),
            value: p.value.clone(),
        }
    }
}

// -- Helper functions --

fn parse_identifier_type(s: &str) -> PyResult<IdentifierType> {
    match s.to_lowercase().as_str() {
        "doi" => Ok(IdentifierType::Doi),
        "arxiv" => Ok(IdentifierType::Arxiv),
        "pmid" => Ok(IdentifierType::Pmid),
        "pmcid" => Ok(IdentifierType::Pmcid),
        "bibcode" => Ok(IdentifierType::Bibcode),
        "semanticscholar" | "s2" => Ok(IdentifierType::SemanticScholar),
        "openalex" => Ok(IdentifierType::OpenAlex),
        "dblp" => Ok(IdentifierType::Dblp),
        other => Err(pyo3::exceptions::PyValueError::new_err(format!(
            "Unknown identifier type: {other}"
        ))),
    }
}

fn parse_enrichment_source(s: &str) -> PyResult<EnrichmentSource> {
    match s.to_lowercase().as_str() {
        "ads" => Ok(EnrichmentSource::Ads),
        "semanticscholar" | "s2" => Ok(EnrichmentSource::SemanticScholar),
        "openalex" => Ok(EnrichmentSource::OpenAlex),
        "crossref" => Ok(EnrichmentSource::Crossref),
        "arxiv" => Ok(EnrichmentSource::Arxiv),
        "pubmed" => Ok(EnrichmentSource::Pubmed),
        "dblp" => Ok(EnrichmentSource::Dblp),
        other => Err(pyo3::exceptions::PyValueError::new_err(format!(
            "Unknown enrichment source: {other}"
        ))),
    }
}

// -- Module functions --

#[pyfunction]
fn extract_all(text: String) -> Vec<PyExtractedIdentifier> {
    crate::extract_all(text)
        .iter()
        .map(PyExtractedIdentifier::from)
        .collect()
}

#[pyfunction]
fn extract_dois(text: String) -> Vec<String> {
    crate::extract_dois(text)
}

#[pyfunction]
fn extract_arxiv_ids(text: String) -> Vec<String> {
    crate::extract_arxiv_ids(text)
}

#[pyfunction]
fn extract_isbns(text: String) -> Vec<String> {
    crate::extract_isbns(text)
}

#[pyfunction]
fn is_valid_doi(doi: String) -> bool {
    crate::is_valid_doi(doi)
}

#[pyfunction]
fn is_valid_arxiv_id(arxiv_id: String) -> bool {
    crate::is_valid_arxiv_id(arxiv_id)
}

#[pyfunction]
fn is_valid_isbn(isbn: String) -> bool {
    crate::is_valid_isbn(isbn)
}

#[pyfunction]
fn normalize_doi(doi: String) -> String {
    crate::normalize_doi(doi)
}

#[pyfunction]
#[pyo3(signature = (author=None, year=None, title=None))]
fn generate_cite_key(author: Option<String>, year: Option<String>, title: Option<String>) -> String {
    crate::generate_cite_key(author, year, title)
}

#[pyfunction]
#[pyo3(signature = (author=None, year=None, title=None, existing_keys=vec![]))]
fn generate_unique_cite_key(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
    existing_keys: Vec<String>,
) -> String {
    crate::generate_unique_cite_key(author, year, title, existing_keys)
}

#[pyfunction]
fn make_cite_key_unique(base: String, existing_keys: Vec<String>) -> String {
    crate::make_cite_key_unique(base, existing_keys)
}

#[pyfunction]
fn sanitize_cite_key(key: String) -> String {
    crate::sanitize_cite_key(key)
}

#[pyfunction]
fn identifier_url(id_type: &str, value: String) -> PyResult<Option<String>> {
    let t = parse_identifier_type(id_type)?;
    Ok(crate::identifier_url(t, value))
}

#[pyfunction]
fn identifier_url_prefix(id_type: &str) -> PyResult<Option<String>> {
    let t = parse_identifier_type(id_type)?;
    Ok(crate::identifier_url_prefix(t))
}

#[pyfunction]
fn identifier_display_name(id_type: &str) -> PyResult<String> {
    let t = parse_identifier_type(id_type)?;
    Ok(crate::identifier_display_name(t))
}

#[pyfunction]
fn enrichment_source_display_name(source: &str) -> PyResult<String> {
    let s = parse_enrichment_source(source)?;
    Ok(crate::enrichment_source_display_name(s))
}

#[pyfunction]
fn can_resolve_to_source(identifiers: HashMap<String, String>, source: &str) -> PyResult<bool> {
    let s = parse_enrichment_source(source)?;
    Ok(crate::can_resolve_to_source(identifiers, s))
}

#[pyfunction]
fn preferred_identifier_for_source(
    identifiers: HashMap<String, String>,
    source: &str,
) -> PyResult<Option<PyPreferredIdentifier>> {
    let s = parse_enrichment_source(source)?;
    Ok(crate::preferred_identifier_for_source(identifiers, s).map(|p| PyPreferredIdentifier::from(&p)))
}

#[pyfunction]
fn supported_identifiers_for_source(source: &str) -> PyResult<Vec<String>> {
    let s = parse_enrichment_source(source)?;
    Ok(crate::supported_identifiers_for_source(s))
}

/// Python module: im_identifiers
#[pymodule]
pub fn im_identifiers(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyExtractedIdentifier>()?;
    m.add_class::<PyPreferredIdentifier>()?;
    m.add_function(wrap_pyfunction!(extract_all, m)?)?;
    m.add_function(wrap_pyfunction!(extract_dois, m)?)?;
    m.add_function(wrap_pyfunction!(extract_arxiv_ids, m)?)?;
    m.add_function(wrap_pyfunction!(extract_isbns, m)?)?;
    m.add_function(wrap_pyfunction!(is_valid_doi, m)?)?;
    m.add_function(wrap_pyfunction!(is_valid_arxiv_id, m)?)?;
    m.add_function(wrap_pyfunction!(is_valid_isbn, m)?)?;
    m.add_function(wrap_pyfunction!(normalize_doi, m)?)?;
    m.add_function(wrap_pyfunction!(generate_cite_key, m)?)?;
    m.add_function(wrap_pyfunction!(generate_unique_cite_key, m)?)?;
    m.add_function(wrap_pyfunction!(make_cite_key_unique, m)?)?;
    m.add_function(wrap_pyfunction!(sanitize_cite_key, m)?)?;
    m.add_function(wrap_pyfunction!(identifier_url, m)?)?;
    m.add_function(wrap_pyfunction!(identifier_url_prefix, m)?)?;
    m.add_function(wrap_pyfunction!(identifier_display_name, m)?)?;
    m.add_function(wrap_pyfunction!(enrichment_source_display_name, m)?)?;
    m.add_function(wrap_pyfunction!(can_resolve_to_source, m)?)?;
    m.add_function(wrap_pyfunction!(preferred_identifier_for_source, m)?)?;
    m.add_function(wrap_pyfunction!(supported_identifiers_for_source, m)?)?;
    Ok(())
}
