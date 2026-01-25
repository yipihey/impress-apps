//! Spatial indexing for efficient point queries
//!
//! Provides R*-tree and octree implementations for:
//! - Fast spatial selection queries
//! - Nearest neighbor search
//! - Range queries

pub mod rtree;

pub use rtree::{RTree, RTreeConfig};
