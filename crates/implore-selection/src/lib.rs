//! implore-selection - Keyboard-driven selection grammar
//!
//! This crate provides a grammar for expressing data selections using
//! keyboard-driven commands inspired by Helix/vim:
//!
//! # Expression Syntax
//!
//! - **Field predicates**: `x > 0 && y < 10`
//! - **Geometric primitives**: `sphere([0,0,0], 1.0)`, `box([0,0,0], [1,1,1])`
//! - **Statistical filters**: `zscore(density) < 3`
//! - **Set operations**: `(A || B) && !C`
//! - **Named registers**: `"a` to store, `@a` to recall
//!
//! # Examples
//!
//! ```ignore
//! use implore_selection::parse_selection;
//!
//! let expr = parse_selection("x > 0 && y < 10")?;
//! let expr = parse_selection("zscore(density) < 3 || inlier == 1")?;
//! let expr = parse_selection("sphere([0,0,0], 5) && mass > 1e10")?;
//! ```

pub mod ast;
pub mod eval;
pub mod parser;

pub use ast::*;
pub use eval::*;
pub use parser::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();
