//! Contour extraction: marching squares over a grid, with segment chaining
//! into smooth polylines.
//!
//! Input is a row-major grid of samples (same layout as [`crate::Hist2D`]:
//! `v[iy*nx + ix]`, `iy = 0` the LOW-y row), values taken at cell centers.
//! Output polylines are in **normalized [0,1]² space** (cell-center convention:
//! grid point `ix` sits at `(ix + 0.5)/nx`), ready to map through the plot
//! rect exactly like the raster path — so per-axis lin/log + min/max apply to
//! contours for free when the grid was binned in normalized-axis space.

/// How contour levels are chosen between the grid's (positive) min and max.
#[derive(Clone, Debug, PartialEq)]
pub enum ContourLevels {
    /// `n` levels linearly spaced strictly inside (vmin, vmax).
    Linear(usize),
    /// `n` levels log-spaced strictly inside (vmin, vmax) — the right choice
    /// for densities spanning orders of magnitude.
    Log(usize),
    /// Explicit level values (used as given; out-of-range ones yield nothing).
    Explicit(Vec<f64>),
}

impl ContourLevels {
    /// Resolve to concrete level values for a grid with positive value range
    /// `(vmin, vmax)`.
    pub fn resolve(&self, vmin: f64, vmax: f64) -> Vec<f64> {
        match self {
            ContourLevels::Explicit(levels) => levels.clone(),
            ContourLevels::Linear(n) => {
                let n = (*n).max(1);
                (0..n)
                    .map(|i| vmin + (i as f64 + 1.0) / (n as f64 + 1.0) * (vmax - vmin))
                    .collect()
            }
            ContourLevels::Log(n) => {
                let n = (*n).max(1);
                let (lo, hi) = (vmin.max(f64::MIN_POSITIVE).ln(), vmax.ln());
                if !(hi - lo).is_finite() || hi <= lo {
                    return vec![vmin];
                }
                (0..n)
                    .map(|i| (lo + (i as f64 + 1.0) / (n as f64 + 1.0) * (hi - lo)).exp())
                    .collect()
            }
        }
    }
}

/// Extract the `level` iso-lines of `grid` (`nx × ny`, row-major, iy=0 low).
/// Returns chained polylines in normalized [0,1]² (see module docs).
pub fn contour_lines(grid: &[f64], nx: usize, ny: usize, level: f64) -> Vec<Vec<(f64, f64)>> {
    assert_eq!(grid.len(), nx * ny, "grid size mismatch");
    if nx < 2 || ny < 2 {
        return Vec::new();
    }

    let v = |ix: usize, iy: usize| grid[iy * nx + ix];
    let mut segments: Vec<((f64, f64), (f64, f64))> = Vec::new();

    // March each square between four adjacent grid points (cell centers).
    for iy in 0..ny - 1 {
        for ix in 0..nx - 1 {
            let (bl, br) = (v(ix, iy), v(ix + 1, iy));
            let (tl, tr) = (v(ix, iy + 1), v(ix + 1, iy + 1));
            let mask = (bl >= level) as u8
                | (((br >= level) as u8) << 1)
                | (((tr >= level) as u8) << 2)
                | (((tl >= level) as u8) << 3);
            if mask == 0 || mask == 15 {
                continue;
            }

            // Interpolated crossing points on the square's four edges, in
            // grid-point coordinates (gx ∈ [0, nx-1], gy ∈ [0, ny-1]).
            let t = |a: f64, b: f64| ((level - a) / (b - a)).clamp(0.0, 1.0);
            let bottom = || (ix as f64 + t(bl, br), iy as f64);
            let top = || (ix as f64 + t(tl, tr), iy as f64 + 1.0);
            let left = || (ix as f64, iy as f64 + t(bl, tl));
            let right = || (ix as f64 + 1.0, iy as f64 + t(br, tr));

            match mask {
                1 => segments.push((left(), bottom())),
                2 => segments.push((bottom(), right())),
                3 => segments.push((left(), right())),
                4 => segments.push((right(), top())),
                6 => segments.push((bottom(), top())),
                7 => segments.push((left(), top())),
                8 => segments.push((top(), left())),
                9 => segments.push((bottom(), top())),
                11 => segments.push((right(), top())),
                12 => segments.push((right(), left())),
                13 => segments.push((bottom(), right())),
                14 => segments.push((left(), bottom())),
                5 | 10 => {
                    // Saddle: disambiguate with the cell-center average.
                    let center_high = (bl + br + tl + tr) / 4.0 >= level;
                    let diag_bl_tr_high = mask == 5;
                    if diag_bl_tr_high == center_high {
                        // High region connects diagonally.
                        segments.push((left(), top()));
                        segments.push((bottom(), right()));
                    } else {
                        segments.push((left(), bottom()));
                        segments.push((top(), right()));
                    }
                }
                _ => unreachable!(),
            }
        }
    }

    // Normalize to [0,1]² (cell-center convention) and chain into polylines.
    let norm = |(gx, gy): (f64, f64)| ((gx + 0.5) / nx as f64, (gy + 0.5) / ny as f64);
    chain_segments(
        segments
            .into_iter()
            .map(|(a, b)| (norm(a), norm(b)))
            .collect(),
    )
}

/// Join segments that share endpoints into continuous polylines. Closed loops
/// come back with first == last point.
fn chain_segments(segments: Vec<((f64, f64), (f64, f64))>) -> Vec<Vec<(f64, f64)>> {
    use std::collections::HashMap;

    // Quantize endpoints so float jitter doesn't break adjacency.
    let key = |(x, y): (f64, f64)| ((x * 1e9).round() as i64, (y * 1e9).round() as i64);

    let mut adjacency: HashMap<(i64, i64), Vec<usize>> = HashMap::new();
    for (i, (a, b)) in segments.iter().enumerate() {
        adjacency.entry(key(*a)).or_default().push(i);
        adjacency.entry(key(*b)).or_default().push(i);
    }

    let mut used = vec![false; segments.len()];
    let mut polylines = Vec::new();

    for start in 0..segments.len() {
        if used[start] {
            continue;
        }
        used[start] = true;
        let (a, b) = segments[start];
        let mut line = vec![a, b];

        // Extend forward from the tail, then backward from the head.
        for _direction in 0..2 {
            loop {
                let tail = *line.last().unwrap();
                let Some(candidates) = adjacency.get(&key(tail)) else {
                    break;
                };
                let Some(&next) = candidates.iter().find(|&&i| !used[i]) else {
                    break;
                };
                used[next] = true;
                let (na, nb) = segments[next];
                line.push(if key(na) == key(tail) { nb } else { na });
            }
            line.reverse();
        }
        polylines.push(line);
    }
    polylines
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A Gaussian bump sampled on a grid: the `level` contour of
    /// exp(-r²/2σ²) is a circle of radius σ·√(2·ln(1/level)).
    fn gaussian_grid(n: usize, sigma: f64) -> Vec<f64> {
        let mut g = vec![0.0; n * n];
        for iy in 0..n {
            for ix in 0..n {
                let x = (ix as f64 + 0.5) / n as f64 - 0.5;
                let y = (iy as f64 + 0.5) / n as f64 - 0.5;
                g[iy * n + ix] = (-(x * x + y * y) / (2.0 * sigma * sigma)).exp();
            }
        }
        g
    }

    #[test]
    fn gaussian_contour_is_a_circle_of_the_right_radius() {
        let n = 200;
        let sigma = 0.12;
        let grid = gaussian_grid(n, sigma);
        let level: f64 = 0.5;
        let expected_r = sigma * (2.0_f64 * (1.0 / level).ln()).sqrt();

        let lines = contour_lines(&grid, n, n, level);
        assert!(!lines.is_empty(), "expected a contour");

        // All points on all polylines sit at radius expected_r (± a cell).
        let cell = 1.0 / n as f64;
        let mut checked = 0;
        for line in &lines {
            for &(x, y) in line {
                let r = ((x - 0.5).powi(2) + (y - 0.5).powi(2)).sqrt();
                assert!(
                    (r - expected_r).abs() < 2.0 * cell,
                    "point radius {r:.4} vs expected {expected_r:.4}"
                );
                checked += 1;
            }
        }
        assert!(
            checked > 50,
            "contour should have many points, got {checked}"
        );

        // The main contour is one closed loop.
        let longest = lines.iter().max_by_key(|l| l.len()).unwrap();
        let (first, last) = (longest.first().unwrap(), longest.last().unwrap());
        let gap = ((first.0 - last.0).powi(2) + (first.1 - last.1).powi(2)).sqrt();
        assert!(gap < 3.0 * cell, "expected a closed loop, gap {gap:.5}");
    }

    #[test]
    fn levels_resolve_linear_log_explicit() {
        let lin = ContourLevels::Linear(3).resolve(0.0, 4.0);
        assert_eq!(lin, vec![1.0, 2.0, 3.0]);

        let log = ContourLevels::Log(2).resolve(1.0, 1000.0);
        assert!((log[0] - 10.0).abs() < 1e-9 && (log[1] - 100.0).abs() < 1e-9);

        let exp = ContourLevels::Explicit(vec![0.5]).resolve(0.0, 1.0);
        assert_eq!(exp, vec![0.5]);
    }

    #[test]
    fn flat_grid_has_no_contours() {
        let grid = vec![1.0; 100];
        assert!(contour_lines(&grid, 10, 10, 0.5).is_empty());
        assert!(contour_lines(&grid, 10, 10, 2.0).is_empty());
    }
}
