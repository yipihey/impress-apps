//! Dual function plotter generator.
//!
//! This generator creates data for two functions simultaneously:
//! - f1: A height field (z values)
//! - f2: A scalar field for colormap testing
//!
//! This is useful for testing visualization systems that render
//! height-mapped surfaces with independent color channels.

use std::collections::HashMap;

use crate::plugin::{
    BoundingBox, DataGenerator, DataSchema, DataType, FieldDescriptor, GeneratedData,
    GeneratorCategory, GeneratorError, GeneratorMetadata, GeneratorParams, ParameterConstraints,
    ParameterSpec, ParameterType, ParameterValue,
};

/// Dual function plotter for height-field and color visualization.
pub struct DualFunction {
    metadata: GeneratorMetadata,
}

impl DualFunction {
    pub fn new() -> Self {
        let f1_options = vec![
            "sin(x)*cos(y)".to_string(),
            "sin(sqrt(x²+y²))".to_string(),
            "x²+y²".to_string(),
            "exp(-(x²+y²))".to_string(),
            "sin(x)*sin(y)".to_string(),
            "x*y".to_string(),
            "cos(x+y)".to_string(),
            "sin(x²-y²)".to_string(),
            "atan2(y,x)".to_string(),
            "ripple".to_string(),
        ];

        let f2_options = vec![
            "gradient_x".to_string(),
            "gradient_y".to_string(),
            "gradient_mag".to_string(),
            "laplacian".to_string(),
            "angle".to_string(),
            "distance".to_string(),
            "checkerboard".to_string(),
            "value".to_string(),
            "x".to_string(),
            "y".to_string(),
        ];

        let metadata = GeneratorMetadata {
            id: "function-dual".to_string(),
            name: "Dual Function Plotter".to_string(),
            category: GeneratorCategory::Function,
            description:
                "Generate height-field (f1) with independent color channel (f2) for colorbar testing"
                    .to_string(),
            icon: "chart.xyaxis.line".to_string(),
            parameters: vec![
                ParameterSpec::choice("f1", "Height Function", f1_options, "sin(x)*cos(y)")
                    .with_description("Function for z-coordinate (height field)"),
                ParameterSpec::choice("f2", "Color Function", f2_options, "gradient_mag")
                    .with_description("Function for color mapping"),
                ParameterSpec {
                    name: "x_range".to_string(),
                    label: "X Range".to_string(),
                    param_type: ParameterType::Vec2,
                    default_value: ParameterValue::Vec(vec![-std::f64::consts::PI, std::f64::consts::PI]),
                    constraints: None,
                    description: Some("Range of x values [min, max]".to_string()),
                },
                ParameterSpec {
                    name: "y_range".to_string(),
                    label: "Y Range".to_string(),
                    param_type: ParameterType::Vec2,
                    default_value: ParameterValue::Vec(vec![-std::f64::consts::PI, std::f64::consts::PI]),
                    constraints: None,
                    description: Some("Range of y values [min, max]".to_string()),
                },
                ParameterSpec::int("resolution", "Resolution", 128)
                    .with_constraints(ParameterConstraints::range(10.0, 1000.0))
                    .with_description("Grid resolution"),
                ParameterSpec::float("z_scale", "Z Scale", 1.0)
                    .with_constraints(ParameterConstraints::range(0.01, 100.0))
                    .with_description("Scale factor for z values"),
            ],
            output_dimensions: 3,
            supports_animation: true,
        };

        Self { metadata }
    }

    /// Evaluate f1 (height function) at (x, y)
    fn eval_f1(name: &str, x: f64, y: f64) -> f64 {
        match name {
            "sin(x)*cos(y)" => x.sin() * y.cos(),
            "sin(sqrt(x²+y²))" => {
                let r = (x * x + y * y).sqrt();
                if r < 1e-10 {
                    1.0
                } else {
                    r.sin() / r.max(0.01)
                }
            }
            "x²+y²" => x * x + y * y,
            "exp(-(x²+y²))" => (-(x * x + y * y)).exp(),
            "sin(x)*sin(y)" => x.sin() * y.sin(),
            "x*y" => x * y,
            "cos(x+y)" => (x + y).cos(),
            "sin(x²-y²)" => (x * x - y * y).sin(),
            "atan2(y,x)" => y.atan2(x),
            "ripple" => {
                let r = (x * x + y * y).sqrt();
                (r * 3.0).sin() * (-(r * 0.5)).exp()
            }
            _ => x.sin() * y.cos(),
        }
    }

    /// Evaluate f2 (color function) at (x, y) given z and gradients
    fn eval_f2(name: &str, x: f64, y: f64, z: f64, grad_x: f64, grad_y: f64) -> f64 {
        match name {
            "gradient_x" => grad_x,
            "gradient_y" => grad_y,
            "gradient_mag" => (grad_x * grad_x + grad_y * grad_y).sqrt(),
            "laplacian" => {
                // Approximate Laplacian (would need actual second derivatives)
                // Using gradient magnitude as proxy
                (grad_x * grad_x + grad_y * grad_y).sqrt()
            }
            "angle" => grad_y.atan2(grad_x),
            "distance" => (x * x + y * y).sqrt(),
            "checkerboard" => {
                let cx = (x * 2.0).floor() as i32;
                let cy = (y * 2.0).floor() as i32;
                if (cx + cy) % 2 == 0 {
                    1.0
                } else {
                    0.0
                }
            }
            "value" => z,
            "x" => x,
            "y" => y,
            _ => z,
        }
    }
}

impl Default for DualFunction {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for DualFunction {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema {
            fields: vec![
                FieldDescriptor::new("x", DataType::Float64).with_description("X coordinate"),
                FieldDescriptor::new("y", DataType::Float64).with_description("Y coordinate"),
                FieldDescriptor::new("z", DataType::Float64)
                    .with_description("Height value from f1"),
                FieldDescriptor::new("color", DataType::Float64)
                    .with_description("Color value from f2"),
                FieldDescriptor::new("grad_x", DataType::Float64)
                    .with_description("Gradient in x direction"),
                FieldDescriptor::new("grad_y", DataType::Float64)
                    .with_description("Gradient in y direction"),
            ],
        }
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let f1_name = params.get_string_or("f1", "sin(x)*cos(y)");
        let f2_name = params.get_string_or("f2", "gradient_mag");
        let x_range = params
            .get_vec("x_range")
            .map(|v| (v[0], v[1]))
            .unwrap_or((-std::f64::consts::PI, std::f64::consts::PI));
        let y_range = params
            .get_vec("y_range")
            .map(|v| (v[0], v[1]))
            .unwrap_or((-std::f64::consts::PI, std::f64::consts::PI));
        let resolution = params.get_int_or("resolution", 128) as usize;
        let z_scale = params.get_float_or("z_scale", 1.0);

        let (x_min, x_max) = x_range;
        let (y_min, y_max) = y_range;

        let total_points = resolution * resolution;

        let mut xs = Vec::with_capacity(total_points);
        let mut ys = Vec::with_capacity(total_points);
        let mut zs = Vec::with_capacity(total_points);
        let mut colors = Vec::with_capacity(total_points);
        let mut grad_xs = Vec::with_capacity(total_points);
        let mut grad_ys = Vec::with_capacity(total_points);

        // First pass: compute z values
        let mut z_grid = vec![0.0; total_points];
        for iy in 0..resolution {
            for ix in 0..resolution {
                let x = x_min + (x_max - x_min) * (ix as f64 / (resolution - 1) as f64);
                let y = y_min + (y_max - y_min) * (iy as f64 / (resolution - 1) as f64);
                z_grid[iy * resolution + ix] = Self::eval_f1(f1_name, x, y);
            }
        }

        // Second pass: compute gradients and output
        let dx = (x_max - x_min) / (resolution - 1) as f64;
        let dy = (y_max - y_min) / (resolution - 1) as f64;

        for iy in 0..resolution {
            for ix in 0..resolution {
                let x = x_min + (x_max - x_min) * (ix as f64 / (resolution - 1) as f64);
                let y = y_min + (y_max - y_min) * (iy as f64 / (resolution - 1) as f64);
                let idx = iy * resolution + ix;
                let z = z_grid[idx] * z_scale;

                // Compute gradients using central differences
                let grad_x = if ix > 0 && ix < resolution - 1 {
                    (z_grid[idx + 1] - z_grid[idx - 1]) / (2.0 * dx)
                } else if ix == 0 {
                    (z_grid[idx + 1] - z_grid[idx]) / dx
                } else {
                    (z_grid[idx] - z_grid[idx - 1]) / dx
                };

                let grad_y = if iy > 0 && iy < resolution - 1 {
                    (z_grid[(iy + 1) * resolution + ix] - z_grid[(iy - 1) * resolution + ix])
                        / (2.0 * dy)
                } else if iy == 0 {
                    (z_grid[(iy + 1) * resolution + ix] - z_grid[idx]) / dy
                } else {
                    (z_grid[idx] - z_grid[(iy - 1) * resolution + ix]) / dy
                };

                let color = Self::eval_f2(f2_name, x, y, z, grad_x, grad_y);

                xs.push(x);
                ys.push(y);
                zs.push(z);
                colors.push(color);
                grad_xs.push(grad_x);
                grad_ys.push(grad_y);
            }
        }

        // Compute bounds
        let z_min = zs.iter().cloned().fold(f64::INFINITY, f64::min);
        let z_max = zs.iter().cloned().fold(f64::NEG_INFINITY, f64::max);

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), xs);
        columns.insert("y".to_string(), ys);
        columns.insert("z".to_string(), zs);
        columns.insert("color".to_string(), colors);
        columns.insert("grad_x".to_string(), grad_xs);
        columns.insert("grad_y".to_string(), grad_ys);

        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new(
                [x_min, y_min, z_min],
                [x_max, y_max, z_max],
            ))
            .with_metadata("generator", "dual-function")
            .with_metadata("f1", f1_name)
            .with_metadata("f2", f2_name))
    }

    fn generate_frame(
        &self,
        params: &GeneratorParams,
        time: f64,
    ) -> Result<GeneratedData, GeneratorError> {
        // For animation, we could animate the view range or add time-dependent functions
        // For now, just shift the x range over time
        let x_range = params
            .get_vec("x_range")
            .map(|v| (v[0], v[1]))
            .unwrap_or((-std::f64::consts::PI, std::f64::consts::PI));

        let offset = time * 0.5;
        let mut animated_params = params.clone();
        animated_params.set_vec("x_range", vec![x_range.0 + offset, x_range.1 + offset]);

        self.generate(&animated_params)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dual_function_generation() {
        let generator = DualFunction::new();
        let params = GeneratorParams::new();

        let result = generator.generate(&params);
        assert!(result.is_ok());

        let data = result.unwrap();
        assert!(data.point_count > 0);
        assert!(data.columns.contains_key("x"));
        assert!(data.columns.contains_key("y"));
        assert!(data.columns.contains_key("z"));
        assert!(data.columns.contains_key("color"));
        assert!(data.columns.contains_key("grad_x"));
        assert!(data.columns.contains_key("grad_y"));
    }

    #[test]
    fn test_all_f1_functions() {
        let functions = [
            "sin(x)*cos(y)",
            "sin(sqrt(x²+y²))",
            "x²+y²",
            "exp(-(x²+y²))",
            "sin(x)*sin(y)",
            "x*y",
            "cos(x+y)",
            "sin(x²-y²)",
            "atan2(y,x)",
            "ripple",
        ];

        for f in functions {
            let result = DualFunction::eval_f1(f, 1.0, 1.0);
            assert!(
                result.is_finite(),
                "Function {} produced non-finite result",
                f
            );
        }
    }

    #[test]
    fn test_all_f2_functions() {
        let functions = [
            "gradient_x",
            "gradient_y",
            "gradient_mag",
            "laplacian",
            "angle",
            "distance",
            "checkerboard",
            "value",
            "x",
            "y",
        ];

        for f in functions {
            let result = DualFunction::eval_f2(f, 1.0, 1.0, 0.5, 0.1, 0.2);
            assert!(
                result.is_finite(),
                "Function {} produced non-finite result",
                f
            );
        }
    }

    #[test]
    fn test_custom_range() {
        let generator = DualFunction::new();
        let mut params = GeneratorParams::new();
        params.set_vec("x_range", vec![0.0, 10.0]);
        params.set_vec("y_range", vec![-5.0, 5.0]);
        params.set_int("resolution", 32);

        let result = generator.generate(&params).unwrap();

        let xs = result.get_column("x").unwrap();
        let ys = result.get_column("y").unwrap();

        // Check that x values are in [0, 10]
        for &x in xs {
            assert!((0.0..=10.0).contains(&x));
        }

        // Check that y values are in [-5, 5]
        for &y in ys {
            assert!((-5.0..=5.0).contains(&y));
        }
    }
}
