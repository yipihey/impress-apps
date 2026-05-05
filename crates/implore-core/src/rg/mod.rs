//! RG (Renormalization Group) turbulence data model and visualization.
//!
//! Provides types and computation for visualizing 3D velocity fields and
//! gain factor tensors from RG turbulence simulations. Data is loaded from
//! `.npz` files and rendered as 2D slices through the volume.

pub mod compute;
pub mod slice;
pub mod types;

#[cfg(feature = "uniffi")]
pub mod ffi;
