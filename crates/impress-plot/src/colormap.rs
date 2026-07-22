//! Colormaps for the 2D-histogram raster path.
//!
//! Each map is an anchor LUT interpolated in sRGB. The anchors are sampled from
//! the canonical matplotlib maps (viridis/magma/plasma/inferno/cividis are
//! perceptually-uniform; turbo and greys included for preference). Fidelity is
//! good at this anchor density; swapping in full 256-entry LUTs later is a
//! drop-in change behind `sample()`.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Colormap {
    Viridis,
    Magma,
    Plasma,
    Inferno,
    Cividis,
    Turbo,
    Greys,
}

impl Colormap {
    pub fn anchors(self) -> &'static [[u8; 3]] {
        match self {
            Colormap::Viridis => VIRIDIS,
            Colormap::Magma => MAGMA,
            Colormap::Plasma => PLASMA,
            Colormap::Inferno => INFERNO,
            Colormap::Cividis => CIVIDIS,
            Colormap::Turbo => TURBO,
            Colormap::Greys => GREYS,
        }
    }

    /// Sample the map at `t ∈ [0,1]` (clamped) → sRGB.
    pub fn sample(self, t: f64) -> [u8; 3] {
        sample_anchors(self.anchors(), t)
    }

    pub fn from_name(name: &str) -> Option<Colormap> {
        Some(match name.to_ascii_lowercase().as_str() {
            "viridis" => Colormap::Viridis,
            "magma" => Colormap::Magma,
            "plasma" => Colormap::Plasma,
            "inferno" => Colormap::Inferno,
            "cividis" => Colormap::Cividis,
            "turbo" => Colormap::Turbo,
            "greys" | "grey" | "gray" | "greyscale" => Colormap::Greys,
            _ => return None,
        })
    }
}

pub(crate) fn sample_anchors(anchors: &[[u8; 3]], t: f64) -> [u8; 3] {
    let t = t.clamp(0.0, 1.0);
    if anchors.len() == 1 {
        return anchors[0];
    }
    let seg = t * (anchors.len() - 1) as f64;
    let i = (seg.floor() as usize).min(anchors.len() - 2);
    let f = seg - i as f64;
    let (a, b) = (anchors[i], anchors[i + 1]);
    [
        (a[0] as f64 + (b[0] as f64 - a[0] as f64) * f).round() as u8,
        (a[1] as f64 + (b[1] as f64 - a[1] as f64) * f).round() as u8,
        (a[2] as f64 + (b[2] as f64 - a[2] as f64) * f).round() as u8,
    ]
}

// 13-stop anchor LUTs (t = 0, 1/12, …, 1).
const VIRIDIS: &[[u8; 3]] = &[
    [68, 1, 84],
    [71, 24, 106],
    [72, 45, 117],
    [69, 63, 125],
    [61, 82, 133],
    [52, 100, 137],
    [44, 117, 138],
    [37, 133, 142],
    [33, 148, 140],
    [40, 174, 128],
    [77, 200, 100],
    [143, 215, 68],
    [253, 231, 37],
];
const MAGMA: &[[u8; 3]] = &[
    [0, 0, 4],
    [15, 9, 45],
    [42, 12, 85],
    [73, 12, 111],
    [102, 21, 123],
    [131, 33, 129],
    [161, 43, 128],
    [190, 55, 121],
    [217, 72, 108],
    [238, 100, 93],
    [251, 137, 97],
    [254, 182, 132],
    [252, 253, 191],
];
const PLASMA: &[[u8; 3]] = &[
    [13, 8, 135],
    [58, 4, 163],
    [92, 1, 166],
    [123, 3, 158],
    [151, 24, 138],
    [175, 49, 117],
    [196, 72, 99],
    [214, 96, 82],
    [230, 122, 65],
    [242, 149, 47],
    [250, 178, 34],
    [251, 208, 34],
    [240, 249, 33],
];
const INFERNO: &[[u8; 3]] = &[
    [0, 0, 4],
    [12, 8, 38],
    [40, 11, 84],
    [75, 12, 107],
    [107, 23, 110],
    [137, 34, 105],
    [168, 46, 95],
    [197, 61, 79],
    [222, 80, 60],
    [240, 106, 37],
    [249, 142, 9],
    [249, 184, 47],
    [252, 255, 164],
];
const CIVIDIS: &[[u8; 3]] = &[
    [0, 34, 78],
    [0, 42, 102],
    [23, 51, 106],
    [55, 61, 104],
    [82, 72, 105],
    [104, 84, 108],
    [124, 96, 108],
    [146, 108, 106],
    [169, 121, 100],
    [192, 135, 91],
    [217, 150, 78],
    [238, 167, 58],
    [255, 234, 70],
];
const TURBO: &[[u8; 3]] = &[
    [48, 18, 59],
    [64, 68, 196],
    [65, 121, 245],
    [39, 173, 220],
    [30, 209, 178],
    [64, 231, 124],
    [130, 246, 71],
    [188, 245, 46],
    [230, 220, 49],
    [253, 176, 39],
    [246, 116, 24],
    [216, 60, 9],
    [122, 4, 3],
];
const GREYS: &[[u8; 3]] = &[
    [255, 255, 255],
    [235, 235, 235],
    [214, 214, 214],
    [189, 189, 189],
    [160, 160, 160],
    [130, 130, 130],
    [99, 99, 99],
    [74, 74, 74],
    [50, 50, 50],
    [30, 30, 30],
    [16, 16, 16],
    [8, 8, 8],
    [0, 0, 0],
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoints_and_selection() {
        assert_eq!(Colormap::Viridis.sample(0.0), [68, 1, 84]);
        assert_eq!(Colormap::Viridis.sample(1.0), [253, 231, 37]);
        assert_eq!(Colormap::from_name("magma"), Some(Colormap::Magma));
        assert_eq!(Colormap::from_name("nope"), None);
        // interpolation returns a real interior color (not an endpoint)
        let m = Colormap::Turbo.sample(0.5);
        assert_ne!(m, Colormap::Turbo.sample(0.0));
        assert_ne!(m, Colormap::Turbo.sample(1.0));
    }
}
