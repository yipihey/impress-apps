//! Fractal generators for implore.
//!
//! Provides classic fractal visualizations like Mandelbrot and Julia sets.

use std::collections::HashMap;

use crate::plugin::{
    BoundingBox, DataGenerator, DataSchema, DataType, FieldDescriptor, GeneratedData,
    GeneratorCategory, GeneratorError, GeneratorMetadata, GeneratorParams, ParameterConstraints,
    ParameterSpec,
};

/// Mandelbrot set generator
pub struct MandelbrotSet {
    metadata: GeneratorMetadata,
}

impl MandelbrotSet {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "fractal-mandelbrot".to_string(),
                name: "Mandelbrot Set".to_string(),
                category: GeneratorCategory::Fractal,
                description: "Explore the Mandelbrot set with infinite zoom capability".to_string(),
                icon: "sparkles".to_string(),
                parameters: vec![
                    ParameterSpec::float("center_x", "Center X", -0.5)
                        .with_constraints(ParameterConstraints::range(-3.0, 3.0))
                        .with_description("X coordinate of the view center"),
                    ParameterSpec::float("center_y", "Center Y", 0.0)
                        .with_constraints(ParameterConstraints::range(-2.0, 2.0))
                        .with_description("Y coordinate of the view center"),
                    ParameterSpec::float("zoom", "Zoom", 1.0)
                        .with_constraints(ParameterConstraints::range(0.1, 1e15))
                        .with_description("Zoom level (higher = deeper zoom)"),
                    ParameterSpec::int("max_iterations", "Max Iterations", 256)
                        .with_constraints(ParameterConstraints::range(10.0, 10000.0))
                        .with_description("Maximum iterations for escape detection"),
                    ParameterSpec::int("resolution", "Resolution", 512)
                        .with_constraints(ParameterConstraints::range(64.0, 4096.0)),
                ],
                output_dimensions: 2,
                supports_animation: true,
            },
        }
    }
}

impl Default for MandelbrotSet {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for MandelbrotSet {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64).with_description("Real component"),
            FieldDescriptor::new("y", DataType::Float64).with_description("Imaginary component"),
            FieldDescriptor::new("iterations", DataType::Float64)
                .with_description("Escape iteration count"),
            FieldDescriptor::new("in_set", DataType::Float64)
                .with_range(0.0, 1.0)
                .with_description("1 if point is in the set, 0 otherwise"),
            FieldDescriptor::new("smooth", DataType::Float64)
                .with_range(0.0, 1.0)
                .with_description("Smooth iteration count for continuous coloring"),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let cx = params.get_float_or("center_x", -0.5);
        let cy = params.get_float_or("center_y", 0.0);
        let zoom = params.get_float_or("zoom", 1.0);
        let max_iter = params.get_int_or("max_iterations", 256) as u32;
        let res = params.get_int_or("resolution", 512) as usize;

        let scale = 4.0 / zoom;

        let capacity = res * res;
        let mut x_data = Vec::with_capacity(capacity);
        let mut y_data = Vec::with_capacity(capacity);
        let mut iterations_data = Vec::with_capacity(capacity);
        let mut in_set_data = Vec::with_capacity(capacity);
        let mut smooth_data = Vec::with_capacity(capacity);

        for iy in 0..res {
            for ix in 0..res {
                let px = cx + (ix as f64 / res as f64 - 0.5) * scale;
                let py = cy + (iy as f64 / res as f64 - 0.5) * scale;

                let (iterations, escaped, smooth) = mandelbrot_iterate(px, py, max_iter);

                x_data.push(px);
                y_data.push(py);
                iterations_data.push(iterations as f64);
                in_set_data.push(if escaped { 0.0 } else { 1.0 });
                smooth_data.push(smooth);
            }
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("y".to_string(), y_data);
        columns.insert("iterations".to_string(), iterations_data);
        columns.insert("in_set".to_string(), in_set_data);
        columns.insert("smooth".to_string(), smooth_data);

        let half_scale = scale / 2.0;
        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new(
                [cx - half_scale, cy - half_scale, 0.0],
                [cx + half_scale, cy + half_scale, max_iter as f64],
            ))
            .with_metadata("generator", "mandelbrot")
            .with_metadata("zoom", zoom.to_string()))
    }

    fn generate_frame(
        &self,
        params: &GeneratorParams,
        time: f64,
    ) -> Result<GeneratedData, GeneratorError> {
        // Animate zoom
        let base_zoom = params.get_float_or("zoom", 1.0);
        let mut animated = params.clone();
        animated.set_float("zoom", base_zoom * (1.0 + time * 0.5).exp());
        self.generate(&animated)
    }
}

/// Julia set generator
pub struct JuliaSet {
    metadata: GeneratorMetadata,
}

impl JuliaSet {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "fractal-julia".to_string(),
                name: "Julia Set".to_string(),
                category: GeneratorCategory::Fractal,
                description: "Julia set fractal with configurable c parameter".to_string(),
                icon: "sparkles".to_string(),
                parameters: vec![
                    ParameterSpec::float("c_real", "C Real", -0.7)
                        .with_constraints(ParameterConstraints::range(-2.0, 2.0))
                        .with_description("Real component of c"),
                    ParameterSpec::float("c_imag", "C Imaginary", 0.27015)
                        .with_constraints(ParameterConstraints::range(-2.0, 2.0))
                        .with_description("Imaginary component of c"),
                    ParameterSpec::float("center_x", "Center X", 0.0)
                        .with_constraints(ParameterConstraints::range(-2.0, 2.0)),
                    ParameterSpec::float("center_y", "Center Y", 0.0)
                        .with_constraints(ParameterConstraints::range(-2.0, 2.0)),
                    ParameterSpec::float("zoom", "Zoom", 1.0)
                        .with_constraints(ParameterConstraints::range(0.1, 1e10)),
                    ParameterSpec::int("max_iterations", "Max Iterations", 256)
                        .with_constraints(ParameterConstraints::range(10.0, 5000.0)),
                    ParameterSpec::int("resolution", "Resolution", 512)
                        .with_constraints(ParameterConstraints::range(64.0, 4096.0)),
                ],
                output_dimensions: 2,
                supports_animation: true,
            },
        }
    }
}

impl Default for JuliaSet {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for JuliaSet {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64).with_description("Real component of z"),
            FieldDescriptor::new("y", DataType::Float64)
                .with_description("Imaginary component of z"),
            FieldDescriptor::new("iterations", DataType::Float64)
                .with_description("Escape iteration count"),
            FieldDescriptor::new("in_set", DataType::Float64)
                .with_range(0.0, 1.0)
                .with_description("1 if point is in the set, 0 otherwise"),
            FieldDescriptor::new("smooth", DataType::Float64)
                .with_range(0.0, 1.0)
                .with_description("Smooth iteration count"),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let c_real = params.get_float_or("c_real", -0.7);
        let c_imag = params.get_float_or("c_imag", 0.27015);
        let cx = params.get_float_or("center_x", 0.0);
        let cy = params.get_float_or("center_y", 0.0);
        let zoom = params.get_float_or("zoom", 1.0);
        let max_iter = params.get_int_or("max_iterations", 256) as u32;
        let res = params.get_int_or("resolution", 512) as usize;

        let scale = 4.0 / zoom;

        let capacity = res * res;
        let mut x_data = Vec::with_capacity(capacity);
        let mut y_data = Vec::with_capacity(capacity);
        let mut iterations_data = Vec::with_capacity(capacity);
        let mut in_set_data = Vec::with_capacity(capacity);
        let mut smooth_data = Vec::with_capacity(capacity);

        for iy in 0..res {
            for ix in 0..res {
                let zx = cx + (ix as f64 / res as f64 - 0.5) * scale;
                let zy = cy + (iy as f64 / res as f64 - 0.5) * scale;

                let (iterations, escaped, smooth) =
                    julia_iterate(zx, zy, c_real, c_imag, max_iter);

                x_data.push(zx);
                y_data.push(zy);
                iterations_data.push(iterations as f64);
                in_set_data.push(if escaped { 0.0 } else { 1.0 });
                smooth_data.push(smooth);
            }
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("y".to_string(), y_data);
        columns.insert("iterations".to_string(), iterations_data);
        columns.insert("in_set".to_string(), in_set_data);
        columns.insert("smooth".to_string(), smooth_data);

        let half_scale = scale / 2.0;
        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new(
                [cx - half_scale, cy - half_scale, 0.0],
                [cx + half_scale, cy + half_scale, max_iter as f64],
            ))
            .with_metadata("generator", "julia")
            .with_metadata("c", format!("({}, {})", c_real, c_imag)))
    }

    fn generate_frame(
        &self,
        params: &GeneratorParams,
        time: f64,
    ) -> Result<GeneratedData, GeneratorError> {
        // Animate c parameter along a circular path
        let base_real = params.get_float_or("c_real", -0.7);
        let base_imag = params.get_float_or("c_imag", 0.27015);

        let angle = time * 0.5;
        let radius = 0.1;
        let c_real = base_real + radius * angle.cos();
        let c_imag = base_imag + radius * angle.sin();

        let mut animated = params.clone();
        animated.set_float("c_real", c_real);
        animated.set_float("c_imag", c_imag);

        self.generate(&animated)
    }
}

// Helper functions

/// Iterate the Mandelbrot function z = z^2 + c
fn mandelbrot_iterate(c_real: f64, c_imag: f64, max_iter: u32) -> (u32, bool, f64) {
    let mut zr = 0.0;
    let mut zi = 0.0;
    let mut iter = 0u32;

    // Escape radius squared (using 256 for smoother coloring)
    const ESCAPE_RADIUS_SQ: f64 = 65536.0;

    while iter < max_iter {
        let zr2 = zr * zr;
        let zi2 = zi * zi;

        if zr2 + zi2 > ESCAPE_RADIUS_SQ {
            // Smooth iteration count
            let log_zn = (zr2 + zi2).ln() / 2.0;
            let nu = (log_zn / 2.0_f64.ln()).ln() / 2.0_f64.ln();
            let smooth = (iter as f64 + 1.0 - nu) / max_iter as f64;
            return (iter, true, smooth.clamp(0.0, 1.0));
        }

        zi = 2.0 * zr * zi + c_imag;
        zr = zr2 - zi2 + c_real;
        iter += 1;
    }

    (max_iter, false, 1.0)
}

/// Iterate the Julia function z = z^2 + c with fixed c
fn julia_iterate(z_real: f64, z_imag: f64, c_real: f64, c_imag: f64, max_iter: u32) -> (u32, bool, f64) {
    let mut zr = z_real;
    let mut zi = z_imag;
    let mut iter = 0u32;

    const ESCAPE_RADIUS_SQ: f64 = 65536.0;

    while iter < max_iter {
        let zr2 = zr * zr;
        let zi2 = zi * zi;

        if zr2 + zi2 > ESCAPE_RADIUS_SQ {
            let log_zn = (zr2 + zi2).ln() / 2.0;
            let nu = (log_zn / 2.0_f64.ln()).ln() / 2.0_f64.ln();
            let smooth = (iter as f64 + 1.0 - nu) / max_iter as f64;
            return (iter, true, smooth.clamp(0.0, 1.0));
        }

        let new_zr = zr2 - zi2 + c_real;
        zi = 2.0 * zr * zi + c_imag;
        zr = new_zr;
        iter += 1;
    }

    (max_iter, false, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mandelbrot_generation() {
        let gen = MandelbrotSet::new();
        let mut params = GeneratorParams::new();
        params.set_int("resolution", 64);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 64 * 64);
        assert!(data.get_column("x").is_some());
        assert!(data.get_column("iterations").is_some());
        assert!(data.get_column("in_set").is_some());
    }

    #[test]
    fn test_mandelbrot_known_points() {
        // Origin is in the set
        let (_, escaped, _) = mandelbrot_iterate(0.0, 0.0, 1000);
        assert!(!escaped, "Origin should be in the set");

        // Point far from origin should escape
        let (_, escaped, _) = mandelbrot_iterate(10.0, 0.0, 1000);
        assert!(escaped, "Point (10, 0) should escape");
    }

    #[test]
    fn test_julia_generation() {
        let gen = JuliaSet::new();
        let mut params = GeneratorParams::new();
        params.set_int("resolution", 64);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 64 * 64);
    }

    #[test]
    fn test_zoom() {
        let gen = MandelbrotSet::new();

        let mut params1 = GeneratorParams::new();
        params1.set_int("resolution", 64);
        params1.set_float("zoom", 1.0);

        let mut params2 = GeneratorParams::new();
        params2.set_int("resolution", 64);
        params2.set_float("zoom", 10.0);

        let data1 = gen.generate(&params1).unwrap();
        let data2 = gen.generate(&params2).unwrap();

        // Higher zoom should have smaller range
        let x1 = data1.get_column("x").unwrap();
        let x2 = data2.get_column("x").unwrap();

        let range1 = x1.iter().cloned().fold(f64::MAX, f64::min)
            - x1.iter().cloned().fold(f64::MIN, f64::max);
        let range2 = x2.iter().cloned().fold(f64::MAX, f64::min)
            - x2.iter().cloned().fold(f64::MIN, f64::max);

        assert!(range2.abs() < range1.abs(), "Zoomed data should have smaller range");
    }
}
