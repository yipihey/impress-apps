//! Common types for implore-core
//!
//! This module provides UniFFI-compatible vector types that can be used
//! across the FFI boundary. Fixed-size arrays like `[f32; 3]` are not
//! supported by UniFFI, so we use these wrapper types instead.

use serde::{Deserialize, Serialize};

/// A 2D vector of f32 values
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Vec2f {
    pub x: f32,
    pub y: f32,
}

impl Vec2f {
    pub fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    pub fn to_array(&self) -> [f32; 2] {
        [self.x, self.y]
    }
}

impl From<[f32; 2]> for Vec2f {
    fn from(arr: [f32; 2]) -> Self {
        Self { x: arr[0], y: arr[1] }
    }
}

impl From<Vec2f> for [f32; 2] {
    fn from(v: Vec2f) -> Self {
        [v.x, v.y]
    }
}

/// A 3D vector of f32 values
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Vec3f {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vec3f {
    pub fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    pub fn to_array(&self) -> [f32; 3] {
        [self.x, self.y, self.z]
    }

    /// Get the length of the vector
    pub fn length(&self) -> f32 {
        (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
    }

    /// Normalize the vector
    pub fn normalize(&self) -> Self {
        let len = self.length();
        if len > 0.0 {
            Self {
                x: self.x / len,
                y: self.y / len,
                z: self.z / len,
            }
        } else {
            *self
        }
    }

    /// Cross product with another vector
    pub fn cross(&self, other: &Vec3f) -> Vec3f {
        Vec3f {
            x: self.y * other.z - self.z * other.y,
            y: self.z * other.x - self.x * other.z,
            z: self.x * other.y - self.y * other.x,
        }
    }
}

impl From<[f32; 3]> for Vec3f {
    fn from(arr: [f32; 3]) -> Self {
        Self { x: arr[0], y: arr[1], z: arr[2] }
    }
}

impl From<Vec3f> for [f32; 3] {
    fn from(v: Vec3f) -> Self {
        [v.x, v.y, v.z]
    }
}

/// A 4D vector of f32 values
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Vec4f {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

impl Vec4f {
    pub fn new(x: f32, y: f32, z: f32, w: f32) -> Self {
        Self { x, y, z, w }
    }

    pub fn to_array(&self) -> [f32; 4] {
        [self.x, self.y, self.z, self.w]
    }
}

impl From<[f32; 4]> for Vec4f {
    fn from(arr: [f32; 4]) -> Self {
        Self { x: arr[0], y: arr[1], z: arr[2], w: arr[3] }
    }
}

impl From<Vec4f> for [f32; 4] {
    fn from(v: Vec4f) -> Self {
        [v.x, v.y, v.z, v.w]
    }
}

/// A 3D vector of f64 values (for double-precision coordinates)
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Vec3d {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Vec3d {
    pub fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }

    pub fn to_array(&self) -> [f64; 3] {
        [self.x, self.y, self.z]
    }

    /// Get the length of the vector
    pub fn length(&self) -> f64 {
        (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
    }
}

impl From<[f64; 3]> for Vec3d {
    fn from(arr: [f64; 3]) -> Self {
        Self { x: arr[0], y: arr[1], z: arr[2] }
    }
}

impl From<Vec3d> for [f64; 3] {
    fn from(v: Vec3d) -> Self {
        [v.x, v.y, v.z]
    }
}

/// An RGB color represented as three f32 values (0.0-1.0)
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ColorRgb {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

impl ColorRgb {
    pub fn new(r: f32, g: f32, b: f32) -> Self {
        Self { r, g, b }
    }

    pub fn to_array(&self) -> [f32; 3] {
        [self.r, self.g, self.b]
    }

    /// Create from hex color (e.g., 0x1a1a1a)
    pub fn from_hex(hex: u32) -> Self {
        Self {
            r: ((hex >> 16) & 0xFF) as f32 / 255.0,
            g: ((hex >> 8) & 0xFF) as f32 / 255.0,
            b: (hex & 0xFF) as f32 / 255.0,
        }
    }

    /// Common colors
    pub fn black() -> Self { Self { r: 0.0, g: 0.0, b: 0.0 } }
    pub fn white() -> Self { Self { r: 1.0, g: 1.0, b: 1.0 } }
    pub fn dark_gray() -> Self { Self { r: 0.1, g: 0.1, b: 0.1 } }
}

impl Default for ColorRgb {
    fn default() -> Self {
        Self::dark_gray()
    }
}

impl From<[f32; 3]> for ColorRgb {
    fn from(arr: [f32; 3]) -> Self {
        Self { r: arr[0], g: arr[1], b: arr[2] }
    }
}

impl From<ColorRgb> for [f32; 3] {
    fn from(c: ColorRgb) -> Self {
        [c.r, c.g, c.b]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vec3f_operations() {
        let v = Vec3f::new(1.0, 0.0, 0.0);
        assert!((v.length() - 1.0).abs() < 1e-6);

        let v2 = Vec3f::new(0.0, 1.0, 0.0);
        let cross = v.cross(&v2);
        assert!((cross.z - 1.0).abs() < 1e-6);
    }

    #[test]
    fn test_color_from_hex() {
        let color = ColorRgb::from_hex(0xFF0000);
        assert!((color.r - 1.0).abs() < 1e-6);
        assert!(color.g.abs() < 1e-6);
        assert!(color.b.abs() < 1e-6);
    }
}
