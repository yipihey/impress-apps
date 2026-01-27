//! Function generators for implore.
//!
//! Provides generators for mathematical functions and parametric curves.

use std::collections::HashMap;

use crate::plugin::{
    BoundingBox, DataGenerator, DataSchema, DataType, FieldDescriptor, GeneratedData,
    GeneratorCategory, GeneratorError, GeneratorMetadata, GeneratorParams, ParameterConstraints,
    ParameterSpec,
};

/// 2D function plotter (z = f(x, y))
pub struct FunctionPlotter2D {
    metadata: GeneratorMetadata,
}

impl FunctionPlotter2D {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "function-2d".to_string(),
                name: "2D Function Plotter".to_string(),
                category: GeneratorCategory::Function,
                description: "Plot z = f(x, y) as a height field".to_string(),
                icon: "function".to_string(),
                parameters: vec![
                    ParameterSpec::choice(
                        "function",
                        "Function",
                        vec![
                            "sin(x)*cos(y)".to_string(),
                            "sin(sqrt(x^2+y^2))".to_string(),
                            "x^2 + y^2".to_string(),
                            "exp(-(x^2+y^2))".to_string(),
                            "sin(x)*sin(y)".to_string(),
                            "x*y".to_string(),
                            "cos(x+y)".to_string(),
                            "saddle".to_string(),
                        ],
                        "sin(x)*cos(y)",
                    )
                    .with_description("Predefined function to plot"),
                    ParameterSpec::float("x_min", "X Min", -3.14159)
                        .with_constraints(ParameterConstraints::range(-100.0, 100.0)),
                    ParameterSpec::float("x_max", "X Max", 3.14159)
                        .with_constraints(ParameterConstraints::range(-100.0, 100.0)),
                    ParameterSpec::float("y_min", "Y Min", -3.14159)
                        .with_constraints(ParameterConstraints::range(-100.0, 100.0)),
                    ParameterSpec::float("y_max", "Y Max", 3.14159)
                        .with_constraints(ParameterConstraints::range(-100.0, 100.0)),
                    ParameterSpec::int("resolution", "Resolution", 100)
                        .with_constraints(ParameterConstraints::range(10.0, 1000.0)),
                    ParameterSpec::float("scale", "Z Scale", 1.0)
                        .with_constraints(ParameterConstraints::range(0.01, 100.0))
                        .with_description("Vertical scale factor"),
                ],
                output_dimensions: 2,
                supports_animation: true,
            },
        }
    }

    /// Evaluate the function at a point
    fn evaluate(&self, func_name: &str, x: f64, y: f64) -> f64 {
        match func_name {
            "sin(x)*cos(y)" => x.sin() * y.cos(),
            "sin(sqrt(x^2+y^2))" => (x * x + y * y).sqrt().sin(),
            "x^2 + y^2" => x * x + y * y,
            "exp(-(x^2+y^2))" => (-(x * x + y * y)).exp(),
            "sin(x)*sin(y)" => x.sin() * y.sin(),
            "x*y" => x * y,
            "cos(x+y)" => (x + y).cos(),
            "saddle" => x * x - y * y,
            _ => 0.0,
        }
    }
}

impl Default for FunctionPlotter2D {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for FunctionPlotter2D {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64).with_description("X coordinate"),
            FieldDescriptor::new("y", DataType::Float64).with_description("Y coordinate"),
            FieldDescriptor::new("z", DataType::Float64).with_description("Function value f(x, y)"),
            FieldDescriptor::new("gradient_x", DataType::Float64)
                .with_description("Partial derivative df/dx"),
            FieldDescriptor::new("gradient_y", DataType::Float64)
                .with_description("Partial derivative df/dy"),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let function = params.get_string_or("function", "sin(x)*cos(y)");
        let x_min = params.get_float_or("x_min", -std::f64::consts::PI);
        let x_max = params.get_float_or("x_max", std::f64::consts::PI);
        let y_min = params.get_float_or("y_min", -std::f64::consts::PI);
        let y_max = params.get_float_or("y_max", std::f64::consts::PI);
        let res = params.get_int_or("resolution", 100) as usize;
        let scale = params.get_float_or("scale", 1.0);

        let capacity = res * res;
        let mut x_data = Vec::with_capacity(capacity);
        let mut y_data = Vec::with_capacity(capacity);
        let mut z_data = Vec::with_capacity(capacity);
        let mut grad_x_data = Vec::with_capacity(capacity);
        let mut grad_y_data = Vec::with_capacity(capacity);

        let dx = (x_max - x_min) / (res - 1) as f64;
        let dy = (y_max - y_min) / (res - 1) as f64;
        let h = 1e-6; // For numerical differentiation

        let mut z_min = f64::MAX;
        let mut z_max = f64::MIN;

        for iy in 0..res {
            for ix in 0..res {
                let x = x_min + ix as f64 * dx;
                let y = y_min + iy as f64 * dy;
                let z = self.evaluate(function, x, y) * scale;

                // Numerical gradient
                let grad_x = (self.evaluate(function, x + h, y)
                    - self.evaluate(function, x - h, y))
                    / (2.0 * h)
                    * scale;
                let grad_y = (self.evaluate(function, x, y + h)
                    - self.evaluate(function, x, y - h))
                    / (2.0 * h)
                    * scale;

                x_data.push(x);
                y_data.push(y);
                z_data.push(z);
                grad_x_data.push(grad_x);
                grad_y_data.push(grad_y);

                z_min = z_min.min(z);
                z_max = z_max.max(z);
            }
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("y".to_string(), y_data);
        columns.insert("z".to_string(), z_data);
        columns.insert("gradient_x".to_string(), grad_x_data);
        columns.insert("gradient_y".to_string(), grad_y_data);

        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new(
                [x_min, y_min, z_min],
                [x_max, y_max, z_max],
            ))
            .with_metadata("generator", "function-2d")
            .with_metadata("function", function.to_string()))
    }

    fn generate_frame(
        &self,
        params: &GeneratorParams,
        time: f64,
    ) -> Result<GeneratedData, GeneratorError> {
        // Animate by shifting the domain
        let x_min = params.get_float_or("x_min", -std::f64::consts::PI);
        let x_max = params.get_float_or("x_max", std::f64::consts::PI);

        let shift = time * 0.5;
        let mut animated = params.clone();
        animated.set_float("x_min", x_min + shift);
        animated.set_float("x_max", x_max + shift);

        self.generate(&animated)
    }
}

/// Sine/Cosine wave generator
pub struct SineCosine {
    metadata: GeneratorMetadata,
}

impl SineCosine {
    pub fn new() -> Self {
        Self {
            metadata: GeneratorMetadata {
                id: "function-sincos".to_string(),
                name: "Sine/Cosine Waves".to_string(),
                category: GeneratorCategory::Function,
                description: "Generate sine and cosine waves with interference".to_string(),
                icon: "waveform.path".to_string(),
                parameters: vec![
                    ParameterSpec::int("num_points", "Points", 1000)
                        .with_constraints(ParameterConstraints::range(10.0, 100000.0)),
                    ParameterSpec::float("frequency", "Frequency", 2.0)
                        .with_constraints(ParameterConstraints::range(0.1, 100.0)),
                    ParameterSpec::float("amplitude", "Amplitude", 1.0)
                        .with_constraints(ParameterConstraints::range(0.01, 10.0)),
                    ParameterSpec::float("phase", "Phase", 0.0)
                        .with_constraints(ParameterConstraints::range(0.0, 6.283185)),
                    ParameterSpec::float("x_min", "X Min", 0.0),
                    ParameterSpec::float("x_max", "X Max", 6.283185)
                        .with_description("Default is 2π"),
                    ParameterSpec::bool("add_noise", "Add Noise", false),
                    ParameterSpec::float("noise_level", "Noise Level", 0.1)
                        .with_constraints(ParameterConstraints::range(0.0, 1.0)),
                    ParameterSpec::int("seed", "Seed", 42),
                ],
                output_dimensions: 2,
                supports_animation: true,
            },
        }
    }
}

impl Default for SineCosine {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for SineCosine {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema::new(vec![
            FieldDescriptor::new("x", DataType::Float64).with_description("X coordinate"),
            FieldDescriptor::new("sin", DataType::Float64)
                .with_description("sin(freq * x + phase)"),
            FieldDescriptor::new("cos", DataType::Float64)
                .with_description("cos(freq * x + phase)"),
            FieldDescriptor::new("sum", DataType::Float64)
                .with_description("sin + cos (interference)"),
            FieldDescriptor::new("product", DataType::Float64).with_description("sin * cos"),
        ])
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let num_points = params.get_int_or("num_points", 1000) as usize;
        let frequency = params.get_float_or("frequency", 2.0);
        let amplitude = params.get_float_or("amplitude", 1.0);
        let phase = params.get_float_or("phase", 0.0);
        let x_min = params.get_float_or("x_min", 0.0);
        let x_max = params.get_float_or("x_max", 2.0 * std::f64::consts::PI);
        let add_noise = params.get_bool_or("add_noise", false);
        let noise_level = params.get_float_or("noise_level", 0.1);
        let seed = params.get_int_or("seed", 42) as u64;

        let mut x_data = Vec::with_capacity(num_points);
        let mut sin_data = Vec::with_capacity(num_points);
        let mut cos_data = Vec::with_capacity(num_points);
        let mut sum_data = Vec::with_capacity(num_points);
        let mut product_data = Vec::with_capacity(num_points);

        let mut rng = SimpleRng::new(seed);
        let dx = (x_max - x_min) / (num_points - 1) as f64;

        for i in 0..num_points {
            let x = x_min + i as f64 * dx;
            let theta = frequency * x + phase;

            let mut sin_val = amplitude * theta.sin();
            let mut cos_val = amplitude * theta.cos();

            if add_noise {
                sin_val += (rng.next_f64() * 2.0 - 1.0) * noise_level * amplitude;
                cos_val += (rng.next_f64() * 2.0 - 1.0) * noise_level * amplitude;
            }

            x_data.push(x);
            sin_data.push(sin_val);
            cos_data.push(cos_val);
            sum_data.push(sin_val + cos_val);
            product_data.push(sin_val * cos_val);
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), x_data);
        columns.insert("sin".to_string(), sin_data);
        columns.insert("cos".to_string(), cos_data);
        columns.insert("sum".to_string(), sum_data);
        columns.insert("product".to_string(), product_data);

        let y_extent = amplitude * (1.0 + noise_level);
        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new(
                [x_min, -y_extent * 2.0, -y_extent],
                [x_max, y_extent * 2.0, y_extent],
            ))
            .with_metadata("generator", "sincos")
            .with_metadata("frequency", frequency.to_string()))
    }

    fn generate_frame(
        &self,
        params: &GeneratorParams,
        time: f64,
    ) -> Result<GeneratedData, GeneratorError> {
        // Animate phase
        let base_phase = params.get_float_or("phase", 0.0);
        let mut animated = params.clone();
        animated.set_float("phase", base_phase + time);
        self.generate(&animated)
    }
}

// Simple RNG
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
    fn test_function_plotter() {
        let gen = FunctionPlotter2D::new();
        let mut params = GeneratorParams::new();
        params.set_int("resolution", 50);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 50 * 50);

        // Check all columns present
        assert!(data.get_column("x").is_some());
        assert!(data.get_column("y").is_some());
        assert!(data.get_column("z").is_some());
        assert!(data.get_column("gradient_x").is_some());
    }

    #[test]
    fn test_different_functions() {
        let gen = FunctionPlotter2D::new();
        let functions = ["sin(x)*cos(y)", "x^2 + y^2", "saddle"];

        for func in functions {
            let mut params = GeneratorParams::new();
            params.set_string("function", func);
            params.set_int("resolution", 20);

            let data = gen.generate(&params);
            assert!(data.is_ok(), "Failed for function: {}", func);
        }
    }

    #[test]
    fn test_sincos_generation() {
        let gen = SineCosine::new();
        let mut params = GeneratorParams::new();
        params.set_int("num_points", 100);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 100);

        // Check sin values are in [-amplitude, amplitude] range
        let sin = data.get_column("sin").unwrap();
        let amplitude = 1.0;
        for &v in sin {
            assert!(v.abs() <= amplitude * 1.01, "sin value {} out of range", v);
        }
    }

    #[test]
    fn test_sincos_with_noise() {
        let gen = SineCosine::new();
        let mut params = GeneratorParams::new();
        params.set_int("num_points", 100);
        params.set_bool("add_noise", true);
        params.set_float("noise_level", 0.1);

        let data = gen.generate(&params).unwrap();
        assert_eq!(data.point_count, 100);
    }

    #[test]
    fn test_function_gradient() {
        let gen = FunctionPlotter2D::new();
        let mut params = GeneratorParams::new();
        params.set_string("function", "x^2 + y^2");
        params.set_int("resolution", 10);
        params.set_float("x_min", -1.0);
        params.set_float("x_max", 1.0);
        params.set_float("y_min", -1.0);
        params.set_float("y_max", 1.0);

        let data = gen.generate(&params).unwrap();

        // For f(x,y) = x^2 + y^2, df/dx = 2x at (1, 0) should be ~2
        // Find point near (1, 0)
        let x = data.get_column("x").unwrap();
        let y = data.get_column("y").unwrap();
        let grad_x = data.get_column("gradient_x").unwrap();

        for i in 0..data.point_count {
            if (x[i] - 1.0).abs() < 0.2 && y[i].abs() < 0.2 {
                // Gradient at (1, 0) should be close to 2
                assert!((grad_x[i] - 2.0 * x[i]).abs() < 0.5, "Gradient mismatch");
            }
        }
    }
}
