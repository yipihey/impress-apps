//! Statistical data generators for implore.
//!
//! Provides generators for statistical distributions and random data.

use std::collections::HashMap;

use crate::plugin::{
    BoundingBox, DataGenerator, DataSchema, DataType, FieldDescriptor, GeneratedData,
    GeneratorCategory, GeneratorError, GeneratorMetadata, GeneratorParams, ParameterConstraints,
    ParameterSpec,
};

/// Gaussian cluster generator
pub struct GaussianClusters {
    metadata: GeneratorMetadata,
}

impl GaussianClusters {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "stats-gaussian-clusters".to_string(),
                name: "Gaussian Clusters".to_string(),
                category: GeneratorCategory::Statistical,
                description: "Generate point clouds with multiple Gaussian clusters".to_string(),
                icon: "chart.dots.scatter".to_string(),
                parameters: vec![
                    ParameterSpec::int("num_clusters", "Clusters", 3)
                        .with_constraints(ParameterConstraints::range(1.0, 20.0))
                        .with_description("Number of clusters"),
                    ParameterSpec::int("points_per_cluster", "Points/Cluster", 1000)
                        .with_constraints(ParameterConstraints::range(10.0, 100000.0))
                        .with_description("Points in each cluster"),
                    ParameterSpec::float("cluster_spread", "Cluster Spread", 2.0)
                        .with_constraints(ParameterConstraints::range(0.1, 10.0))
                        .with_description("Maximum distance of cluster centers from origin"),
                    ParameterSpec::float("std_dev", "Std Deviation", 0.3)
                        .with_constraints(ParameterConstraints::range(0.01, 2.0))
                        .with_description("Standard deviation of each cluster"),
                    ParameterSpec::int("dimensions", "Dimensions", 2)
                        .with_constraints(ParameterConstraints::range(2.0, 3.0))
                        .with_description("2D or 3D"),
                    ParameterSpec::int("seed", "Seed", 42),
                ],
                output_dimensions: 3,
                supports_animation: false,
            },
        }
    }
}

impl Default for GaussianClusters {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for GaussianClusters {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64).with_description("X coordinate"),
            FieldDescriptor::new("y", DataType::Float64).with_description("Y coordinate"),
            FieldDescriptor::new("z", DataType::Float64).with_description("Z coordinate (0 for 2D)"),
            FieldDescriptor::new("cluster", DataType::Float64)
                .with_description("Cluster index (0-based)"),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let num_clusters = params.get_int_or("num_clusters", 3) as usize;
        let points_per_cluster = params.get_int_or("points_per_cluster", 1000) as usize;
        let cluster_spread = params.get_float_or("cluster_spread", 2.0);
        let std_dev = params.get_float_or("std_dev", 0.3);
        let dimensions = params.get_int_or("dimensions", 2) as usize;
        let seed = params.get_int_or("seed", 42) as u64;

        let total_points = num_clusters * points_per_cluster;
        let mut x_data = Vec::with_capacity(total_points);
        let mut y_data = Vec::with_capacity(total_points);
        let mut z_data = Vec::with_capacity(total_points);
        let mut cluster_data = Vec::with_capacity(total_points);

        let mut rng = SimpleRng::new(seed);

        // Generate cluster centers
        let mut centers = Vec::with_capacity(num_clusters);
        for _ in 0..num_clusters {
            let cx = (rng.next_f64() * 2.0 - 1.0) * cluster_spread;
            let cy = (rng.next_f64() * 2.0 - 1.0) * cluster_spread;
            let cz = if dimensions == 3 {
                (rng.next_f64() * 2.0 - 1.0) * cluster_spread
            } else {
                0.0
            };
            centers.push((cx, cy, cz));
        }

        // Generate points for each cluster
        for (cluster_idx, (cx, cy, cz)) in centers.iter().enumerate() {
            for _ in 0..points_per_cluster {
                // Box-Muller transform for Gaussian distribution
                let (gx, gy) = box_muller(&mut rng);
                let x = cx + gx * std_dev;
                let y = cy + gy * std_dev;
                let z = if dimensions == 3 {
                    let (gz, _) = box_muller(&mut rng);
                    cz + gz * std_dev
                } else {
                    0.0
                };

                x_data.push(x);
                y_data.push(y);
                z_data.push(z);
                cluster_data.push(cluster_idx as f64);
            }
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("y".to_string(), y_data);
        columns.insert("z".to_string(), z_data);
        columns.insert("cluster".to_string(), cluster_data);

        let extent = cluster_spread + 4.0 * std_dev;
        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new(
                [-extent, -extent, if dimensions == 3 { -extent } else { 0.0 }],
                [extent, extent, if dimensions == 3 { extent } else { 0.0 }],
            ))
            .with_metadata("generator", "gaussian-clusters")
            .with_metadata("num_clusters", num_clusters.to_string()))
    }
}

/// Uniform random point generator
pub struct UniformRandom {
    metadata: GeneratorMetadata,
}

impl UniformRandom {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "stats-uniform".to_string(),
                name: "Uniform Random".to_string(),
                category: GeneratorCategory::Statistical,
                description: "Generate uniformly distributed random points".to_string(),
                icon: "dice".to_string(),
                parameters: vec![
                    ParameterSpec::int("num_points", "Points", 10000)
                        .with_constraints(ParameterConstraints::range(10.0, 1000000.0)),
                    ParameterSpec::float("x_min", "X Min", -1.0),
                    ParameterSpec::float("x_max", "X Max", 1.0),
                    ParameterSpec::float("y_min", "Y Min", -1.0),
                    ParameterSpec::float("y_max", "Y Max", 1.0),
                    ParameterSpec::float("z_min", "Z Min", 0.0),
                    ParameterSpec::float("z_max", "Z Max", 0.0)
                        .with_description("Set equal to Z Min for 2D"),
                    ParameterSpec::int("seed", "Seed", 42),
                ],
                output_dimensions: 3,
                supports_animation: false,
            },
        }
    }
}

impl Default for UniformRandom {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for UniformRandom {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64),
            FieldDescriptor::new("y", DataType::Float64),
            FieldDescriptor::new("z", DataType::Float64),
            FieldDescriptor::new("index", DataType::Float64)
                .with_description("Point index"),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let num_points = params.get_int_or("num_points", 10000) as usize;
        let x_min = params.get_float_or("x_min", -1.0);
        let x_max = params.get_float_or("x_max", 1.0);
        let y_min = params.get_float_or("y_min", -1.0);
        let y_max = params.get_float_or("y_max", 1.0);
        let z_min = params.get_float_or("z_min", 0.0);
        let z_max = params.get_float_or("z_max", 0.0);
        let seed = params.get_int_or("seed", 42) as u64;

        let mut x_data = Vec::with_capacity(num_points);
        let mut y_data = Vec::with_capacity(num_points);
        let mut z_data = Vec::with_capacity(num_points);
        let mut index_data = Vec::with_capacity(num_points);

        let mut rng = SimpleRng::new(seed);

        for i in 0..num_points {
            let x = x_min + rng.next_f64() * (x_max - x_min);
            let y = y_min + rng.next_f64() * (y_max - y_min);
            let z = z_min + rng.next_f64() * (z_max - z_min);

            x_data.push(x);
            y_data.push(y);
            z_data.push(z);
            index_data.push(i as f64);
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("y".to_string(), y_data);
        columns.insert("z".to_string(), z_data);
        columns.insert("index".to_string(), index_data);

        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new([x_min, y_min, z_min], [x_max, y_max, z_max]))
            .with_metadata("generator", "uniform"))
    }
}

// Helper functions

/// Simple RNG for reproducible generation
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

/// Box-Muller transform for generating Gaussian-distributed values
fn box_muller(rng: &mut SimpleRng) -> (f64, f64) {
    let u1 = rng.next_f64().max(1e-10); // Avoid log(0)
    let u2 = rng.next_f64();

    let r = (-2.0 * u1.ln()).sqrt();
    let theta = 2.0 * std::f64::consts::PI * u2;

    (r * theta.cos(), r * theta.sin())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gaussian_clusters() {
        let gen = GaussianClusters::new();
        let mut params = GeneratorParams::new();
        params.set_int("num_clusters", 3);
        params.set_int("points_per_cluster", 100);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 300);

        // Check cluster assignments
        let clusters = data.get_column("cluster").unwrap();
        let unique_clusters: std::collections::HashSet<i64> =
            clusters.iter().map(|&c| c as i64).collect();
        assert_eq!(unique_clusters.len(), 3);
    }

    #[test]
    fn test_uniform_random() {
        let gen = UniformRandom::new();
        let mut params = GeneratorParams::new();
        params.set_int("num_points", 1000);
        params.set_float("x_min", 0.0);
        params.set_float("x_max", 10.0);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 1000);

        // Check all x values are in range
        let x = data.get_column("x").unwrap();
        for &val in x {
            assert!(val >= 0.0 && val <= 10.0);
        }
    }

    #[test]
    fn test_reproducibility() {
        let gen = GaussianClusters::new();
        let mut params = GeneratorParams::new();
        params.set_int("seed", 12345);
        params.set_int("points_per_cluster", 50);

        let data1 = gen.generate(&params).unwrap();
        let data2 = gen.generate(&params).unwrap();

        let x1 = data1.get_column("x").unwrap();
        let x2 = data2.get_column("x").unwrap();

        for (v1, v2) in x1.iter().zip(x2.iter()) {
            assert_eq!(v1, v2, "Reproducibility failed");
        }
    }

    #[test]
    fn test_3d_clusters() {
        let gen = GaussianClusters::new();
        let mut params = GeneratorParams::new();
        params.set_int("dimensions", 3);
        params.set_int("points_per_cluster", 100);

        let data = gen.generate(&params).unwrap();

        // Z values should be non-zero for 3D
        let z = data.get_column("z").unwrap();
        let has_nonzero = z.iter().any(|&v| v != 0.0);
        assert!(has_nonzero, "3D should have non-zero Z values");
    }
}
