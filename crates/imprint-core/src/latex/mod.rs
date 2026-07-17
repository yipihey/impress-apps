//! LaTeX-related primitives.
//!
//! - [`convert`]: bidirectional LaTeX ↔ Typst conversion (existing module,
//!   formerly the top-level `latex.rs`).
//! - [`diagnostics`]: parser for LaTeX `.log` output into structured
//!   `LatexDiagnostic` records. Ported from
//!   `apps/imprint/macOS/Services/LaTeXLogParser.swift`.
//! - [`formatter`]: native LaTeX source beautifier. The Swift counterpart
//!   shells out to `latexindent`; we instead implement a sensible built-in
//!   formatter so the substrate has a default that works without an
//!   external TeX distribution. Ported in spirit from
//!   `apps/imprint/macOS/Services/LaTeXFormatterService.swift`.

pub mod convert;
pub mod diagnostics;
pub mod formatter;

pub use convert::*;
pub use diagnostics::*;
pub use formatter::*;
