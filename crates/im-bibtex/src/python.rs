//! Python bindings for im-bibtex via PyO3
//!
//! Provides a `im_bibtex` Python module with BibTeX parsing, formatting,
//! LaTeX decoding, and journal macro expansion.

use pyo3::prelude::*;
use pyo3::types::PyDict;
use std::collections::HashMap;

use crate::entry::{BibTeXEntry, BibTeXEntryType, BibTeXField};
use crate::parser::{BibTeXParseError, BibTeXParseResult};

// -- Python wrapper types --

/// A single BibTeX field (key-value pair)
#[pyclass(name = "BibTeXField")]
#[derive(Clone)]
pub struct PyBibTeXField {
    #[pyo3(get)]
    pub key: String,
    #[pyo3(get)]
    pub value: String,
}

#[pymethods]
impl PyBibTeXField {
    fn __repr__(&self) -> String {
        format!("BibTeXField(key={:?}, value={:?})", self.key, self.value)
    }
}

impl From<&BibTeXField> for PyBibTeXField {
    fn from(f: &BibTeXField) -> Self {
        Self {
            key: f.key.clone(),
            value: f.value.clone(),
        }
    }
}

/// A parsed BibTeX entry
#[pyclass(name = "BibTeXEntry")]
#[derive(Clone)]
pub struct PyBibTeXEntry {
    #[pyo3(get)]
    pub cite_key: String,
    #[pyo3(get)]
    pub entry_type: String,
    #[pyo3(get)]
    pub fields: Vec<PyBibTeXField>,
    #[pyo3(get)]
    pub raw_bibtex: Option<String>,
}

#[pymethods]
impl PyBibTeXEntry {
    /// Get a field value by key (case-insensitive)
    fn get_field(&self, key: &str) -> Option<String> {
        let key_lower = key.to_lowercase();
        self.fields
            .iter()
            .find(|f| f.key.to_lowercase() == key_lower)
            .map(|f| f.value.clone())
    }

    /// Get all fields as a dictionary
    fn fields_dict<'py>(&self, py: Python<'py>) -> PyResult<Bound<'py, PyDict>> {
        let dict = PyDict::new(py);
        for f in &self.fields {
            dict.set_item(&f.key, &f.value)?;
        }
        Ok(dict)
    }

    #[getter]
    fn title(&self) -> Option<String> {
        self.get_field("title")
    }

    #[getter]
    fn author(&self) -> Option<String> {
        self.get_field("author")
    }

    #[getter]
    fn year(&self) -> Option<String> {
        self.get_field("year")
    }

    #[getter]
    fn doi(&self) -> Option<String> {
        self.get_field("doi")
    }

    #[getter]
    fn journal(&self) -> Option<String> {
        self.get_field("journal")
    }

    fn __repr__(&self) -> String {
        format!(
            "BibTeXEntry(cite_key={:?}, entry_type={:?}, fields={})",
            self.cite_key,
            self.entry_type,
            self.fields.len()
        )
    }
}

impl From<&BibTeXEntry> for PyBibTeXEntry {
    fn from(e: &BibTeXEntry) -> Self {
        Self {
            cite_key: e.cite_key.clone(),
            entry_type: e.entry_type.as_str().to_string(),
            fields: e.fields.iter().map(PyBibTeXField::from).collect(),
            raw_bibtex: e.raw_bibtex.clone(),
        }
    }
}

fn to_rust_entry(py_entry: &PyBibTeXEntry) -> BibTeXEntry {
    let mut entry = BibTeXEntry::new(
        py_entry.cite_key.clone(),
        BibTeXEntryType::from_str(&py_entry.entry_type),
    );
    for f in &py_entry.fields {
        entry.add_field(&f.key, &f.value);
    }
    entry.raw_bibtex = py_entry.raw_bibtex.clone();
    entry
}

/// A parse error with location information
#[pyclass(name = "BibTeXParseError")]
#[derive(Clone)]
pub struct PyBibTeXParseError {
    #[pyo3(get)]
    pub line: u32,
    #[pyo3(get)]
    pub column: u32,
    #[pyo3(get)]
    pub message: String,
}

impl From<&BibTeXParseError> for PyBibTeXParseError {
    fn from(e: &BibTeXParseError) -> Self {
        Self {
            line: e.line,
            column: e.column,
            message: e.message.clone(),
        }
    }
}

#[pymethods]
impl PyBibTeXParseError {
    fn __repr__(&self) -> String {
        format!(
            "BibTeXParseError(line={}, column={}, message={:?})",
            self.line, self.column, self.message
        )
    }
}

/// Result of parsing a BibTeX string
#[pyclass(name = "BibTeXParseResult")]
#[derive(Clone)]
pub struct PyBibTeXParseResult {
    #[pyo3(get)]
    pub entries: Vec<PyBibTeXEntry>,
    #[pyo3(get)]
    pub preambles: Vec<String>,
    #[pyo3(get)]
    pub errors: Vec<PyBibTeXParseError>,
    strings_map: HashMap<String, String>,
}

#[pymethods]
impl PyBibTeXParseResult {
    /// Get string definitions as a dictionary
    fn strings<'py>(&self, py: Python<'py>) -> PyResult<Bound<'py, PyDict>> {
        let dict = PyDict::new(py);
        for (k, v) in &self.strings_map {
            dict.set_item(k, v)?;
        }
        Ok(dict)
    }

    fn __repr__(&self) -> String {
        format!(
            "BibTeXParseResult(entries={}, preambles={}, errors={})",
            self.entries.len(),
            self.preambles.len(),
            self.errors.len()
        )
    }
}

impl From<&BibTeXParseResult> for PyBibTeXParseResult {
    fn from(r: &BibTeXParseResult) -> Self {
        Self {
            entries: r.entries.iter().map(PyBibTeXEntry::from).collect(),
            preambles: r.preambles.clone(),
            errors: r.errors.iter().map(PyBibTeXParseError::from).collect(),
            strings_map: r.strings.clone(),
        }
    }
}

// -- Module functions --

#[pyfunction]
fn parse(input: String) -> PyResult<PyBibTeXParseResult> {
    crate::parse(input)
        .map(|r| PyBibTeXParseResult::from(&r))
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

#[pyfunction]
fn parse_entry(input: String) -> PyResult<PyBibTeXEntry> {
    crate::parse_entry(input)
        .map(|e| PyBibTeXEntry::from(&e))
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))
}

#[pyfunction]
fn format_entry(entry: PyBibTeXEntry) -> String {
    let rust_entry = to_rust_entry(&entry);
    crate::format_entry(rust_entry)
}

#[pyfunction]
fn format_entries(entries: Vec<PyBibTeXEntry>) -> String {
    let rust_entries: Vec<BibTeXEntry> = entries.iter().map(to_rust_entry).collect();
    crate::format_entries(rust_entries)
}

#[pyfunction]
fn decode_latex(input: String) -> String {
    crate::decode_latex(input)
}

#[pyfunction]
fn expand_journal_macro(name: String) -> String {
    crate::expand_journal_macro(name)
}

#[pyfunction]
fn is_journal_macro(name: String) -> bool {
    crate::is_journal_macro(name)
}

#[pyfunction]
fn get_all_journal_macro_names() -> Vec<String> {
    crate::get_all_journal_macro_names()
}

/// Python module: im_bibtex
#[pymodule]
pub fn im_bibtex(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyBibTeXField>()?;
    m.add_class::<PyBibTeXEntry>()?;
    m.add_class::<PyBibTeXParseError>()?;
    m.add_class::<PyBibTeXParseResult>()?;
    m.add_function(wrap_pyfunction!(parse, m)?)?;
    m.add_function(wrap_pyfunction!(parse_entry, m)?)?;
    m.add_function(wrap_pyfunction!(format_entry, m)?)?;
    m.add_function(wrap_pyfunction!(format_entries, m)?)?;
    m.add_function(wrap_pyfunction!(decode_latex, m)?)?;
    m.add_function(wrap_pyfunction!(expand_journal_macro, m)?)?;
    m.add_function(wrap_pyfunction!(is_journal_macro, m)?)?;
    m.add_function(wrap_pyfunction!(get_all_journal_macro_names, m)?)?;
    Ok(())
}
