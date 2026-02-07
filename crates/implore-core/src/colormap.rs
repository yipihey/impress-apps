//! Colormap system for scientific visualization
//!
//! Provides a variety of perceptually uniform colormaps suitable for
//! scientific data visualization, including:
//! - Sequential: viridis, plasma, inferno, magma
//! - Diverging: coolwarm, seismic
//! - Categorical: for discrete data
//!
//! All colormaps support interpolation and can be reversed.

use serde::{Deserialize, Serialize};

/// A color in RGBA format (0.0 to 1.0)
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Color {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Color {
    /// Create a new color
    pub fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    /// Create a color from RGB (alpha = 1.0)
    pub fn rgb(r: f32, g: f32, b: f32) -> Self {
        Self { r, g, b, a: 1.0 }
    }

    /// Create a color from hex string (e.g., "#FF5733" or "FF5733")
    pub fn from_hex(hex: &str) -> Option<Self> {
        let hex = hex.trim_start_matches('#');
        if hex.len() != 6 {
            return None;
        }

        let r = u8::from_str_radix(&hex[0..2], 16).ok()? as f32 / 255.0;
        let g = u8::from_str_radix(&hex[2..4], 16).ok()? as f32 / 255.0;
        let b = u8::from_str_radix(&hex[4..6], 16).ok()? as f32 / 255.0;

        Some(Self::rgb(r, g, b))
    }

    /// Convert to hex string
    pub fn to_hex(&self) -> String {
        format!(
            "#{:02X}{:02X}{:02X}",
            (self.r * 255.0) as u8,
            (self.g * 255.0) as u8,
            (self.b * 255.0) as u8
        )
    }

    /// Linear interpolation between two colors
    pub fn lerp(a: &Color, b: &Color, t: f32) -> Color {
        let t = t.clamp(0.0, 1.0);
        Color {
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t,
            a: a.a + (b.a - a.a) * t,
        }
    }

    /// Convert to array [r, g, b, a]
    pub fn to_array(&self) -> [f32; 4] {
        [self.r, self.g, self.b, self.a]
    }
}

impl Default for Color {
    fn default() -> Self {
        Self::rgb(0.5, 0.5, 0.5)
    }
}

/// A colormap for mapping scalar values to colors
#[derive(Clone, Debug)]
pub struct Colormap {
    /// Name of the colormap
    pub name: String,
    /// Color stops (positions from 0.0 to 1.0)
    stops: Vec<(f32, Color)>,
    /// Whether the colormap is reversed
    reversed: bool,
}

impl Colormap {
    /// Create a new colormap from a list of colors (evenly spaced)
    pub fn from_colors(name: impl Into<String>, colors: Vec<Color>) -> Self {
        let n = colors.len();
        let stops: Vec<(f32, Color)> = colors
            .into_iter()
            .enumerate()
            .map(|(i, c)| (i as f32 / (n - 1).max(1) as f32, c))
            .collect();

        Self {
            name: name.into(),
            stops,
            reversed: false,
        }
    }

    /// Create a new colormap from stops (position, color pairs)
    pub fn from_stops(name: impl Into<String>, stops: Vec<(f32, Color)>) -> Self {
        Self {
            name: name.into(),
            stops,
            reversed: false,
        }
    }

    /// Reverse the colormap
    pub fn reversed(mut self) -> Self {
        self.reversed = !self.reversed;
        self
    }

    /// Sample the colormap at a position (0.0 to 1.0)
    pub fn sample(&self, mut t: f32) -> Color {
        t = t.clamp(0.0, 1.0);
        if self.reversed {
            t = 1.0 - t;
        }

        if self.stops.is_empty() {
            return Color::default();
        }

        if self.stops.len() == 1 {
            return self.stops[0].1;
        }

        // Find the two stops to interpolate between
        for i in 0..self.stops.len() - 1 {
            let (t0, c0) = &self.stops[i];
            let (t1, c1) = &self.stops[i + 1];

            if t >= *t0 && t <= *t1 {
                let local_t = (t - t0) / (t1 - t0);
                return Color::lerp(c0, c1, local_t);
            }
        }

        // If t is beyond the last stop, return the last color
        self.stops.last().map(|(_, c)| *c).unwrap_or_default()
    }

    /// Generate a lookup table of the specified size
    pub fn generate_lut(&self, size: usize) -> Vec<Color> {
        (0..size)
            .map(|i| self.sample(i as f32 / (size - 1).max(1) as f32))
            .collect()
    }

    /// Generate RGBA bytes for a texture (4 bytes per entry)
    pub fn generate_texture(&self, size: usize) -> Vec<u8> {
        let lut = self.generate_lut(size);
        let mut bytes = Vec::with_capacity(size * 4);

        for color in lut {
            bytes.push((color.r * 255.0) as u8);
            bytes.push((color.g * 255.0) as u8);
            bytes.push((color.b * 255.0) as u8);
            bytes.push((color.a * 255.0) as u8);
        }

        bytes
    }
}

// MARK: - Built-in Colormaps

/// Get the viridis colormap (perceptually uniform, colorblind-safe)
#[allow(clippy::approx_constant)]
pub fn viridis() -> Colormap {
    Colormap::from_colors(
        "viridis",
        vec![
            Color::rgb(0.267, 0.005, 0.329),
            Color::rgb(0.282, 0.141, 0.458),
            Color::rgb(0.254, 0.265, 0.530),
            Color::rgb(0.207, 0.372, 0.553),
            Color::rgb(0.164, 0.471, 0.558),
            Color::rgb(0.128, 0.567, 0.551),
            Color::rgb(0.135, 0.659, 0.518),
            Color::rgb(0.267, 0.749, 0.441),
            Color::rgb(0.478, 0.821, 0.318),
            Color::rgb(0.741, 0.873, 0.150),
            Color::rgb(0.993, 0.906, 0.144),
        ],
    )
}

/// Get the plasma colormap
pub fn plasma() -> Colormap {
    Colormap::from_colors(
        "plasma",
        vec![
            Color::rgb(0.050, 0.030, 0.528),
            Color::rgb(0.294, 0.012, 0.615),
            Color::rgb(0.494, 0.012, 0.658),
            Color::rgb(0.665, 0.138, 0.614),
            Color::rgb(0.798, 0.280, 0.470),
            Color::rgb(0.898, 0.396, 0.304),
            Color::rgb(0.973, 0.558, 0.154),
            Color::rgb(0.992, 0.748, 0.159),
            Color::rgb(0.940, 0.975, 0.131),
        ],
    )
}

/// Get the inferno colormap
pub fn inferno() -> Colormap {
    Colormap::from_colors(
        "inferno",
        vec![
            Color::rgb(0.001, 0.000, 0.014),
            Color::rgb(0.133, 0.047, 0.263),
            Color::rgb(0.341, 0.063, 0.429),
            Color::rgb(0.550, 0.161, 0.506),
            Color::rgb(0.735, 0.216, 0.330),
            Color::rgb(0.878, 0.392, 0.102),
            Color::rgb(0.978, 0.557, 0.035),
            Color::rgb(0.992, 0.772, 0.247),
            Color::rgb(0.988, 0.998, 0.645),
        ],
    )
}

/// Get the magma colormap
pub fn magma() -> Colormap {
    Colormap::from_colors(
        "magma",
        vec![
            Color::rgb(0.001, 0.000, 0.014),
            Color::rgb(0.116, 0.042, 0.232),
            Color::rgb(0.271, 0.051, 0.404),
            Color::rgb(0.461, 0.098, 0.495),
            Color::rgb(0.665, 0.176, 0.515),
            Color::rgb(0.844, 0.295, 0.461),
            Color::rgb(0.962, 0.507, 0.454),
            Color::rgb(0.992, 0.738, 0.600),
            Color::rgb(0.987, 0.991, 0.750),
        ],
    )
}

/// Get the coolwarm diverging colormap
pub fn coolwarm() -> Colormap {
    Colormap::from_colors(
        "coolwarm",
        vec![
            Color::rgb(0.230, 0.299, 0.754),
            Color::rgb(0.552, 0.691, 0.996),
            Color::rgb(0.865, 0.865, 0.865),
            Color::rgb(0.957, 0.647, 0.510),
            Color::rgb(0.706, 0.016, 0.150),
        ],
    )
}

/// Get a list of all built-in colormap names
pub fn builtin_colormap_names() -> Vec<&'static str> {
    vec!["viridis", "plasma", "inferno", "magma", "coolwarm"]
}

/// Get a built-in colormap by name
pub fn get_colormap(name: &str) -> Option<Colormap> {
    match name.to_lowercase().as_str() {
        "viridis" => Some(viridis()),
        "plasma" => Some(plasma()),
        "inferno" => Some(inferno()),
        "magma" => Some(magma()),
        "coolwarm" => Some(coolwarm()),
        _ => None,
    }
}

/// Colormap configuration for a visualization
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ColormapConfig {
    /// Colormap name
    pub name: String,

    /// Value range for mapping
    pub min_value: f64,
    pub max_value: f64,

    /// Whether to reverse the colormap
    pub reversed: bool,

    /// Whether to use logarithmic scaling
    pub log_scale: bool,

    /// Clip values outside the range (otherwise extend to min/max colors)
    pub clip: bool,
}

impl ColormapConfig {
    /// Create a new colormap configuration
    pub fn new(name: impl Into<String>, min: f64, max: f64) -> Self {
        Self {
            name: name.into(),
            min_value: min,
            max_value: max,
            reversed: false,
            log_scale: false,
            clip: false,
        }
    }

    /// Map a value to a normalized position (0.0 to 1.0)
    pub fn normalize(&self, value: f64) -> f32 {
        let value = if self.log_scale && value > 0.0 {
            value.ln()
        } else {
            value
        };

        let min = if self.log_scale && self.min_value > 0.0 {
            self.min_value.ln()
        } else {
            self.min_value
        };

        let max = if self.log_scale && self.max_value > 0.0 {
            self.max_value.ln()
        } else {
            self.max_value
        };

        let t = if max > min {
            ((value - min) / (max - min)) as f32
        } else {
            0.5
        };

        if self.clip {
            t.clamp(0.0, 1.0)
        } else {
            t
        }
    }
}

impl Default for ColormapConfig {
    fn default() -> Self {
        Self::new("viridis", 0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_color_from_hex() {
        let color = Color::from_hex("#FF5733").unwrap();
        assert!((color.r - 1.0).abs() < 0.01);
        assert!((color.g - 0.341).abs() < 0.01);
        assert!((color.b - 0.2).abs() < 0.01);
    }

    #[test]
    fn test_color_lerp() {
        let a = Color::rgb(0.0, 0.0, 0.0);
        let b = Color::rgb(1.0, 1.0, 1.0);
        let mid = Color::lerp(&a, &b, 0.5);

        assert!((mid.r - 0.5).abs() < 0.001);
        assert!((mid.g - 0.5).abs() < 0.001);
        assert!((mid.b - 0.5).abs() < 0.001);
    }

    #[test]
    fn test_colormap_sample() {
        let cmap = viridis();

        let c0 = cmap.sample(0.0);
        let c1 = cmap.sample(1.0);
        let mid = cmap.sample(0.5);

        // Viridis starts dark purple, ends yellow
        assert!(c0.r < 0.3);
        assert!(c1.r > 0.9);
        assert!(mid.g > 0.4); // Mid is greenish
    }

    #[test]
    fn test_colormap_reversed() {
        let cmap = viridis();
        let cmap_rev = viridis().reversed();

        let c0 = cmap.sample(0.0);
        let c1_rev = cmap_rev.sample(1.0);

        assert!((c0.r - c1_rev.r).abs() < 0.01);
        assert!((c0.g - c1_rev.g).abs() < 0.01);
        assert!((c0.b - c1_rev.b).abs() < 0.01);
    }

    #[test]
    fn test_generate_lut() {
        let cmap = viridis();
        let lut = cmap.generate_lut(256);

        assert_eq!(lut.len(), 256);
    }

    #[test]
    fn test_colormap_config_normalize() {
        let config = ColormapConfig::new("viridis", 0.0, 100.0);

        assert!((config.normalize(0.0) - 0.0).abs() < 0.001);
        assert!((config.normalize(50.0) - 0.5).abs() < 0.001);
        assert!((config.normalize(100.0) - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_colormap_config_log_scale() {
        let mut config = ColormapConfig::new("viridis", 1.0, 1000.0);
        config.log_scale = true;

        let mid_log = config.normalize(31.62); // sqrt(1000) on log scale should be ~0.5
        assert!((mid_log - 0.5).abs() < 0.1);
    }
}
