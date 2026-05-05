//! 2D slice extraction and colormapping for volume data.

use super::types::SliceAxis;
use crate::colormap::{self, Colormap};
use ndarray::{Array2, Array3};

/// Extract a 2D slice from a 3D field along the given axis at the given position.
///
/// - `SliceAxis::Z` at position `p` → field[p, :, :] (an XY plane)
/// - `SliceAxis::Y` at position `p` → field[:, p, :] (an XZ plane)
/// - `SliceAxis::X` at position `p` → field[:, :, p] (a YZ plane)
pub fn extract_slice(field: &Array3<f32>, axis: SliceAxis, position: usize) -> Array2<f32> {
    match axis {
        SliceAxis::Z => field.index_axis(ndarray::Axis(0), position).to_owned(),
        SliceAxis::Y => field.index_axis(ndarray::Axis(1), position).to_owned(),
        SliceAxis::X => field.index_axis(ndarray::Axis(2), position).to_owned(),
    }
}

/// Apply a colormap to a 2D scalar field, producing RGBA bytes.
///
/// Values are linearly mapped from `[vmin, vmax]` to `[0, 1]` before sampling
/// the colormap. Returns a row-major RGBA byte buffer suitable for texture upload.
pub fn apply_colormap(
    slice: &Array2<f32>,
    colormap: &Colormap,
    vmin: f32,
    vmax: f32,
) -> Vec<u8> {
    let (h, w) = (slice.shape()[0], slice.shape()[1]);
    let range = if (vmax - vmin).abs() > f32::EPSILON {
        vmax - vmin
    } else {
        1.0
    };
    let inv_range = 1.0 / range;

    let mut rgba = Vec::with_capacity(h * w * 4);

    for iy in 0..h {
        for ix in 0..w {
            let v = slice[[iy, ix]];
            let t = ((v - vmin) * inv_range).clamp(0.0, 1.0);
            let c = colormap.sample(t);
            rgba.push((c.r * 255.0) as u8);
            rgba.push((c.g * 255.0) as u8);
            rgba.push((c.b * 255.0) as u8);
            rgba.push(255); // full alpha
        }
    }

    rgba
}

/// Compute min and max of a 2D array, skipping NaN/Inf.
pub fn finite_min_max(slice: &Array2<f32>) -> (f32, f32) {
    let mut min = f32::INFINITY;
    let mut max = f32::NEG_INFINITY;

    for &v in slice.iter() {
        if v.is_finite() {
            if v < min {
                min = v;
            }
            if v > max {
                max = v;
            }
        }
    }

    if !min.is_finite() {
        min = 0.0;
    }
    if !max.is_finite() {
        max = 1.0;
    }

    (min, max)
}

/// Get a colormap by name, falling back to coolwarm.
pub fn get_colormap_or_default(name: &str) -> Colormap {
    colormap::get_colormap(name).unwrap_or_else(colormap::coolwarm)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ndarray::{Array3, Ix3};

    #[test]
    fn test_extract_slice_z() {
        let mut field = Array3::<f32>::zeros(Ix3(4, 4, 4));
        // Set z=2 plane to 1.0
        field.index_axis_mut(ndarray::Axis(0), 2).fill(1.0);

        let s = extract_slice(&field, SliceAxis::Z, 2);
        assert_eq!(s.shape(), &[4, 4]);
        assert!((s[[0, 0]] - 1.0).abs() < 1e-6);

        let s0 = extract_slice(&field, SliceAxis::Z, 0);
        assert!((s0[[0, 0]]).abs() < 1e-6);
    }

    #[test]
    fn test_extract_slice_y() {
        let mut field = Array3::<f32>::zeros(Ix3(4, 4, 4));
        field.index_axis_mut(ndarray::Axis(1), 1).fill(2.0);

        let s = extract_slice(&field, SliceAxis::Y, 1);
        assert_eq!(s.shape(), &[4, 4]);
        assert!((s[[0, 0]] - 2.0).abs() < 1e-6);
    }

    #[test]
    fn test_apply_colormap_range() {
        let slice = ndarray::arr2(&[[0.0, 0.5], [0.5, 1.0]]);
        let cmap = crate::colormap::viridis();
        let rgba = apply_colormap(&slice, &cmap, 0.0, 1.0);
        assert_eq!(rgba.len(), 4 * 4); // 2x2 pixels * 4 bytes
        // Alpha should always be 255
        assert_eq!(rgba[3], 255);
        assert_eq!(rgba[7], 255);
    }

    #[test]
    fn test_finite_min_max() {
        let slice = ndarray::arr2(&[[1.0, f32::NAN], [f32::NEG_INFINITY, 3.0]]);
        let (min, max) = finite_min_max(&slice);
        assert!((min - 1.0).abs() < 1e-6);
        assert!((max - 3.0).abs() < 1e-6);
    }
}
