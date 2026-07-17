//! File-handling helpers (Phase 1F): pure-logic naming and PDF validation.
//!
//! These mirror Swift's `PDFManager` filename rules and `PDFHealthCheckService`
//! style sanity checks. All FileManager I/O stays in Swift; this module is
//! intentionally side-effect-free so it is reachable from the TUI, CLI, web,
//! and tests without any platform dependencies.
//!
//! The existing `crate::filename` module remains for the Publication-driven
//! `generate_pdf_filename(publication, options)` path used by the UniFFI
//! surface. The functions here expose the lower-level `(author, year, title)`
//! signature requested by the migration plan so the TUI can drive filename
//! generation directly without an entire Publication.

pub mod naming;
pub mod validation;

pub use naming::{generate_filename, sanitize_slug, FilenameOptions};
pub use validation::{validate_pdf, ValidationIssue, ValidationSeverity};
