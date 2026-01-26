//! Integration adapters for the impress suite
//!
//! These adapters provide access to other tools in the impress ecosystem:
//! - **imbib**: Reference and bibliography management
//! - **imprint**: Document creation and editing
//! - **implore**: Data visualization and analysis

pub mod imbib;
pub mod implore;
pub mod imprint;

pub use imbib::ImbibAdapter;
pub use implore::ImploreAdapter;
pub use imprint::ImprintAdapter;
