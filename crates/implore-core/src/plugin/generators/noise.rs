//! Noise generators for implore.
//!
//! Provides various noise algorithms for generating natural-looking patterns.
//!
//! # Parallel Processing
//!
//! When the `parallel` feature is enabled, noise generation uses rayon for
//! parallel computation, significantly improving performance on multi-core
//! systems for large resolutions (512x512 and above).

use std::collections::HashMap;

#[cfg(feature = "parallel")]
use rayon::prelude::*;

use crate::plugin::{
    BoundingBox, DataGenerator, DataSchema, DataType, FieldDescriptor, GeneratedData,
    GeneratorCategory, GeneratorError, GeneratorMetadata, GeneratorParams, ParameterConstraints,
    ParameterSpec,
};

/// 2D Perlin noise generator
pub struct PerlinNoise2D {
    metadata: GeneratorMetadata,
}

impl PerlinNoise2D {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "noise-perlin-2d".to_string(),
                name: "Perlin Noise (2D)".to_string(),
                category: GeneratorCategory::Noise,
                description: "Classic gradient noise with controllable frequency and octaves"
                    .to_string(),
                icon: "waveform".to_string(),
                parameters: vec![
                    ParameterSpec::int("resolution", "Resolution", 256)
                        .with_constraints(ParameterConstraints::range(8.0, 2048.0).power_of_two())
                        .with_description("Output grid resolution"),
                    ParameterSpec::float("frequency", "Frequency", 4.0)
                        .with_constraints(ParameterConstraints::range(0.1, 64.0))
                        .with_description("Base noise frequency"),
                    ParameterSpec::int("octaves", "Octaves", 4)
                        .with_constraints(ParameterConstraints::range(1.0, 8.0))
                        .with_description("Number of noise layers"),
                    ParameterSpec::float("persistence", "Persistence", 0.5)
                        .with_constraints(ParameterConstraints::range(0.0, 1.0))
                        .with_description("Amplitude falloff per octave"),
                    ParameterSpec::int("seed", "Seed", 42)
                        .with_description("Random seed for reproducibility"),
                ],
                output_dimensions: 2,
                supports_animation: true,
            },
        }
    }
}

impl Default for PerlinNoise2D {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for PerlinNoise2D {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64)
                .with_range(0.0, 1.0)
                .with_description("X coordinate"),
            FieldDescriptor::new("y", DataType::Float64)
                .with_range(0.0, 1.0)
                .with_description("Y coordinate"),
            FieldDescriptor::new("value", DataType::Float64)
                .with_range(-1.0, 1.0)
                .with_description("Noise amplitude"),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let res = params.get_int_or("resolution", 256) as usize;
        let freq = params.get_float_or("frequency", 4.0);
        let octaves = params.get_int_or("octaves", 4) as usize;
        let persistence = params.get_float_or("persistence", 0.5);
        let seed = params.get_int_or("seed", 42) as u64;

        // Simple hash-based permutation table
        let perm = generate_permutation(seed);

        // Generate data - parallel when feature enabled
        #[cfg(feature = "parallel")]
        let data: Vec<(f64, f64, f64)> = (0..res)
            .into_par_iter()
            .flat_map(|iy| {
                (0..res).into_par_iter().map(move |ix| {
                    let px = ix as f64 / res as f64;
                    let py = iy as f64 / res as f64;
                    let noise_value = fbm_perlin_2d(px, py, freq, octaves, persistence, &perm);
                    (px, py, noise_value)
                })
            })
            .collect();

        #[cfg(not(feature = "parallel"))]
        let data: Vec<(f64, f64, f64)> = (0..res)
            .flat_map(|iy| {
                (0..res).map(move |ix| {
                    let px = ix as f64 / res as f64;
                    let py = iy as f64 / res as f64;
                    let noise_value = fbm_perlin_2d(px, py, freq, octaves, persistence, &perm);
                    (px, py, noise_value)
                })
            })
            .collect();

        let capacity = data.len();
        let mut x_data = Vec::with_capacity(capacity);
        let mut y_data = Vec::with_capacity(capacity);
        let mut value_data = Vec::with_capacity(capacity);

        for (px, py, v) in data {
            x_data.push(px);
            y_data.push(py);
            value_data.push(v);
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("y".to_string(), y_data);
        columns.insert("value".to_string(), value_data);

        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new([0.0, 0.0, -1.0], [1.0, 1.0, 1.0]))
            .with_metadata("generator", "perlin-2d")
            .with_metadata("seed", seed.to_string()))
    }

    fn generate_frame(
        &self,
        params: &GeneratorParams,
        time: f64,
    ) -> Result<GeneratedData, GeneratorError> {
        // Animate by varying the seed based on time
        let base_seed = params.get_int_or("seed", 42);
        let mut animated_params = params.clone();
        animated_params.set_int("seed", base_seed + (time * 1000.0) as i64);
        self.generate(&animated_params)
    }
}

/// 2D Simplex noise generator
pub struct SimplexNoise2D {
    metadata: GeneratorMetadata,
}

impl SimplexNoise2D {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "noise-simplex-2d".to_string(),
                name: "Simplex Noise (2D)".to_string(),
                category: GeneratorCategory::Noise,
                description: "Simplex noise - faster and less directional artifacts than Perlin"
                    .to_string(),
                icon: "waveform".to_string(),
                parameters: vec![
                    ParameterSpec::int("resolution", "Resolution", 256)
                        .with_constraints(ParameterConstraints::range(8.0, 2048.0)),
                    ParameterSpec::float("frequency", "Frequency", 4.0)
                        .with_constraints(ParameterConstraints::range(0.1, 64.0)),
                    ParameterSpec::int("octaves", "Octaves", 4)
                        .with_constraints(ParameterConstraints::range(1.0, 8.0)),
                    ParameterSpec::float("persistence", "Persistence", 0.5)
                        .with_constraints(ParameterConstraints::range(0.0, 1.0)),
                    ParameterSpec::int("seed", "Seed", 42),
                ],
                output_dimensions: 2,
                supports_animation: true,
            },
        }
    }
}

impl Default for SimplexNoise2D {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for SimplexNoise2D {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64).with_range(0.0, 1.0),
            FieldDescriptor::new("y", DataType::Float64).with_range(0.0, 1.0),
            FieldDescriptor::new("value", DataType::Float64).with_range(-1.0, 1.0),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let res = params.get_int_or("resolution", 256) as usize;
        let freq = params.get_float_or("frequency", 4.0);
        let octaves = params.get_int_or("octaves", 4) as usize;
        let persistence = params.get_float_or("persistence", 0.5);
        let seed = params.get_int_or("seed", 42) as u64;

        let perm = generate_permutation(seed);

        // Generate data - parallel when feature enabled
        #[cfg(feature = "parallel")]
        let data: Vec<(f64, f64, f64)> = (0..res)
            .into_par_iter()
            .flat_map(|iy| {
                (0..res).into_par_iter().map(move |ix| {
                    let px = ix as f64 / res as f64;
                    let py = iy as f64 / res as f64;
                    let noise_value = fbm_simplex_2d(px, py, freq, octaves, persistence, &perm);
                    (px, py, noise_value)
                })
            })
            .collect();

        #[cfg(not(feature = "parallel"))]
        let data: Vec<(f64, f64, f64)> = (0..res)
            .flat_map(|iy| {
                (0..res).map(move |ix| {
                    let px = ix as f64 / res as f64;
                    let py = iy as f64 / res as f64;
                    let noise_value = fbm_simplex_2d(px, py, freq, octaves, persistence, &perm);
                    (px, py, noise_value)
                })
            })
            .collect();

        let capacity = data.len();
        let mut x_data = Vec::with_capacity(capacity);
        let mut y_data = Vec::with_capacity(capacity);
        let mut value_data = Vec::with_capacity(capacity);

        for (px, py, v) in data {
            x_data.push(px);
            y_data.push(py);
            value_data.push(v);
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("y".to_string(), y_data);
        columns.insert("value".to_string(), value_data);

        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new([0.0, 0.0, -1.0], [1.0, 1.0, 1.0]))
            .with_metadata("generator", "simplex-2d"))
    }
}

/// 2D Worley (cellular) noise generator
pub struct WorleyNoise2D {
    metadata: GeneratorMetadata,
}

impl WorleyNoise2D {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "noise-worley-2d".to_string(),
                name: "Worley Noise (2D)".to_string(),
                category: GeneratorCategory::Noise,
                description: "Cellular noise based on distance to random feature points".to_string(),
                icon: "circle.hexagongrid".to_string(),
                parameters: vec![
                    ParameterSpec::int("resolution", "Resolution", 256)
                        .with_constraints(ParameterConstraints::range(8.0, 2048.0)),
                    ParameterSpec::float("frequency", "Frequency", 8.0)
                        .with_constraints(ParameterConstraints::range(1.0, 64.0))
                        .with_description("Number of cells"),
                    ParameterSpec::choice(
                        "distance_metric",
                        "Distance Metric",
                        vec!["euclidean".to_string(), "manhattan".to_string(), "chebyshev".to_string()],
                        "euclidean",
                    ),
                    ParameterSpec::int("seed", "Seed", 42),
                ],
                output_dimensions: 2,
                supports_animation: false,
            },
        }
    }
}

impl Default for WorleyNoise2D {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for WorleyNoise2D {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64).with_range(0.0, 1.0),
            FieldDescriptor::new("y", DataType::Float64).with_range(0.0, 1.0),
            FieldDescriptor::new("value", DataType::Float64)
                .with_range(0.0, 1.0)
                .with_description("Distance to nearest feature point"),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let res = params.get_int_or("resolution", 256) as usize;
        let freq = params.get_float_or("frequency", 8.0) as usize;
        let metric = params.get_string_or("distance_metric", "euclidean");
        let seed = params.get_int_or("seed", 42) as u64;

        // Generate random feature points in each cell
        let mut rng = SimpleRng::new(seed);
        let mut feature_points = Vec::new();
        for cy in 0..freq {
            for cx in 0..freq {
                let fx = (cx as f64 + rng.next_f64()) / freq as f64;
                let fy = (cy as f64 + rng.next_f64()) / freq as f64;
                feature_points.push((fx, fy));
            }
        }

        let distance_fn: fn(f64, f64, f64, f64) -> f64 = match metric {
            "manhattan" => |x1, y1, x2, y2| (x2 - x1).abs() + (y2 - y1).abs(),
            "chebyshev" => |x1, y1, x2, y2| (x2 - x1).abs().max((y2 - y1).abs()),
            _ => |x1, y1, x2, y2| ((x2 - x1).powi(2) + (y2 - y1).powi(2)).sqrt(),
        };

        let max_possible = match metric {
            "euclidean" => (2.0_f64).sqrt() / freq as f64,
            _ => 2.0 / freq as f64,
        };

        // Generate data - parallel when feature enabled
        #[cfg(feature = "parallel")]
        let data: Vec<(f64, f64, f64)> = (0..res)
            .into_par_iter()
            .flat_map(|iy| {
                let feature_points = &feature_points;
                (0..res).into_par_iter().map(move |ix| {
                    let px = ix as f64 / res as f64;
                    let py = iy as f64 / res as f64;

                    let mut min_dist = f64::MAX;
                    for &(fx, fy) in feature_points {
                        let dist = distance_fn(px, py, fx, fy);
                        min_dist = min_dist.min(dist);
                    }

                    let value = (min_dist / max_possible).min(1.0);
                    (px, py, value)
                })
            })
            .collect();

        #[cfg(not(feature = "parallel"))]
        let data: Vec<(f64, f64, f64)> = (0..res)
            .flat_map(|iy| {
                let feature_points = &feature_points;
                (0..res).map(move |ix| {
                    let px = ix as f64 / res as f64;
                    let py = iy as f64 / res as f64;

                    let mut min_dist = f64::MAX;
                    for &(fx, fy) in feature_points {
                        let dist = distance_fn(px, py, fx, fy);
                        min_dist = min_dist.min(dist);
                    }

                    let value = (min_dist / max_possible).min(1.0);
                    (px, py, value)
                })
            })
            .collect();

        let capacity = data.len();
        let mut x_data = Vec::with_capacity(capacity);
        let mut y_data = Vec::with_capacity(capacity);
        let mut value_data = Vec::with_capacity(capacity);

        for (px, py, v) in data {
            x_data.push(px);
            y_data.push(py);
            value_data.push(v);
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("y".to_string(), y_data);
        columns.insert("value".to_string(), value_data);

        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new([0.0, 0.0, 0.0], [1.0, 1.0, 1.0]))
            .with_metadata("generator", "worley-2d"))
    }
}

// Helper functions for noise generation

/// Compute fractal Brownian motion using Perlin noise
fn fbm_perlin_2d(
    px: f64,
    py: f64,
    base_freq: f64,
    octaves: usize,
    persistence: f64,
    perm: &[usize; 512],
) -> f64 {
    let mut amplitude = 1.0;
    let mut frequency = base_freq;
    let mut noise_value = 0.0;
    let mut max_amplitude = 0.0;

    for _ in 0..octaves {
        noise_value += amplitude * perlin_2d(px * frequency, py * frequency, perm);
        max_amplitude += amplitude;
        amplitude *= persistence;
        frequency *= 2.0;
    }

    noise_value / max_amplitude
}

/// Compute fractal Brownian motion using Simplex noise
fn fbm_simplex_2d(
    px: f64,
    py: f64,
    base_freq: f64,
    octaves: usize,
    persistence: f64,
    perm: &[usize; 512],
) -> f64 {
    let mut amplitude = 1.0;
    let mut frequency = base_freq;
    let mut noise_value = 0.0;
    let mut max_amplitude = 0.0;

    for _ in 0..octaves {
        noise_value += amplitude * simplex_2d(px * frequency, py * frequency, perm);
        max_amplitude += amplitude;
        amplitude *= persistence;
        frequency *= 2.0;
    }

    noise_value / max_amplitude
}

/// Generate a permutation table from a seed
fn generate_permutation(seed: u64) -> [usize; 512] {
    let mut perm = [0usize; 512];
    let mut rng = SimpleRng::new(seed);

    // Initialize with identity
    for i in 0..256 {
        perm[i] = i;
    }

    // Fisher-Yates shuffle
    for i in (1..256).rev() {
        let j = (rng.next_u64() as usize) % (i + 1);
        perm.swap(i, j);
    }

    // Duplicate for wrapping
    for i in 0..256 {
        perm[256 + i] = perm[i];
    }

    perm
}

/// 2D Perlin noise at a point
fn perlin_2d(x: f64, y: f64, perm: &[usize; 512]) -> f64 {
    let x0 = x.floor() as i32;
    let y0 = y.floor() as i32;
    let x1 = x0 + 1;
    let y1 = y0 + 1;

    let sx = x - x0 as f64;
    let sy = y - y0 as f64;

    let u = fade(sx);
    let v = fade(sy);

    let n00 = grad(hash(perm, x0, y0), sx, sy);
    let n10 = grad(hash(perm, x1, y0), sx - 1.0, sy);
    let n01 = grad(hash(perm, x0, y1), sx, sy - 1.0);
    let n11 = grad(hash(perm, x1, y1), sx - 1.0, sy - 1.0);

    let nx0 = lerp(n00, n10, u);
    let nx1 = lerp(n01, n11, u);

    lerp(nx0, nx1, v)
}

/// 2D Simplex noise at a point
fn simplex_2d(x: f64, y: f64, perm: &[usize; 512]) -> f64 {
    const F2: f64 = 0.5 * (1.732050808 - 1.0); // (sqrt(3) - 1) / 2
    const G2: f64 = (3.0 - 1.732050808) / 6.0; // (3 - sqrt(3)) / 6

    let s = (x + y) * F2;
    let i = (x + s).floor() as i32;
    let j = (y + s).floor() as i32;

    let t = (i + j) as f64 * G2;
    let x0 = x - (i as f64 - t);
    let y0 = y - (j as f64 - t);

    let (i1, j1) = if x0 > y0 { (1, 0) } else { (0, 1) };

    let x1 = x0 - i1 as f64 + G2;
    let y1 = y0 - j1 as f64 + G2;
    let x2 = x0 - 1.0 + 2.0 * G2;
    let y2 = y0 - 1.0 + 2.0 * G2;

    let n0 = simplex_contrib(x0, y0, hash(perm, i, j));
    let n1 = simplex_contrib(x1, y1, hash(perm, i + i1, j + j1));
    let n2 = simplex_contrib(x2, y2, hash(perm, i + 1, j + 1));

    70.0 * (n0 + n1 + n2)
}

fn simplex_contrib(x: f64, y: f64, gi: usize) -> f64 {
    let t = 0.5 - x * x - y * y;
    if t < 0.0 {
        0.0
    } else {
        let t = t * t;
        t * t * grad(gi, x, y)
    }
}

fn fade(t: f64) -> f64 {
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + t * (b - a)
}

fn hash(perm: &[usize; 512], x: i32, y: i32) -> usize {
    let xi = (x & 255) as usize;
    let yi = (y & 255) as usize;
    perm[perm[xi] + yi]
}

fn grad(hash: usize, x: f64, y: f64) -> f64 {
    let h = hash & 7;
    let u = if h < 4 { x } else { y };
    let v = if h < 4 { y } else { x };
    (if (h & 1) != 0 { -u } else { u }) + (if (h & 2) != 0 { -2.0 * v } else { 2.0 * v })
}

/// Simple RNG for reproducible noise generation
struct SimpleRng {
    state: u64,
}

impl SimpleRng {
    fn new(seed: u64) -> Self {
        Self {
            state: seed.wrapping_add(0x9E3779B97F4A7C15),
        }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_mul(6364136223846793005).wrapping_add(1);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    fn next_f64(&mut self) -> f64 {
        (self.next_u64() as f64) / (u64::MAX as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_perlin_generation() {
        let gen = PerlinNoise2D::new();
        let mut params = GeneratorParams::new();
        params.set_int("resolution", 64);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 64 * 64);
        assert!(data.get_column("x").is_some());
        assert!(data.get_column("y").is_some());
        assert!(data.get_column("value").is_some());
    }

    #[test]
    fn test_simplex_generation() {
        let gen = SimplexNoise2D::new();
        let params = GeneratorParams::new();

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 256 * 256);

        // Values should be approximately in [-1, 1] range (with small tolerance for FBM)
        let values = data.get_column("value").unwrap();
        for &v in values {
            assert!(v >= -1.5 && v <= 1.5, "Value {} out of range", v);
        }
    }

    #[test]
    fn test_worley_generation() {
        let gen = WorleyNoise2D::new();
        let mut params = GeneratorParams::new();
        params.set_int("resolution", 64);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 64 * 64);

        // Values should be in [0, 1] range
        let values = data.get_column("value").unwrap();
        for &v in values {
            assert!(v >= 0.0 && v <= 1.0, "Value {} out of range", v);
        }
    }

    #[test]
    fn test_reproducibility() {
        let gen = PerlinNoise2D::new();
        let mut params = GeneratorParams::new();
        params.set_int("seed", 12345);
        params.set_int("resolution", 32);

        let data1 = gen.generate(&params).unwrap();
        let data2 = gen.generate(&params).unwrap();

        let values1 = data1.get_column("value").unwrap();
        let values2 = data2.get_column("value").unwrap();

        for (v1, v2) in values1.iter().zip(values2.iter()) {
            assert_eq!(v1, v2, "Reproducibility failed");
        }
    }
}
