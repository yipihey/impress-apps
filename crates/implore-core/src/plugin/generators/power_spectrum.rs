//! Power spectrum noise generator.
//!
//! This generator creates Gaussian noise with a polynomial power spectrum,
//! useful for creating noise with specific frequency characteristics.

use std::collections::HashMap;
use std::f64::consts::PI;

use crate::plugin::{
    BoundingBox, DataGenerator, DataSchema, DataType, FieldDescriptor, GeneratedData,
    GeneratorCategory, GeneratorError, GeneratorMetadata, GeneratorParams, ParameterConstraints,
    ParameterSpec, ParameterType, ParameterValue,
};

/// Gaussian noise generator with polynomial power spectrum.
///
/// The power spectrum is defined as P(k) = k^α where α is determined
/// by evaluating the polynomial coefficients in log-log space.
pub struct PowerSpectrumNoise {
    metadata: GeneratorMetadata,
}

impl PowerSpectrumNoise {
    pub fn new() -> Self {
        let metadata = GeneratorMetadata {
            id: "noise-power-spectrum".to_string(),
            name: "Power Spectrum Noise".to_string(),
            category: GeneratorCategory::Noise,
            description:
                "Gaussian noise with polynomial power spectrum for controlled frequency content"
                    .to_string(),
            icon: "waveform.path.ecg".to_string(),
            parameters: vec![
                ParameterSpec {
                    name: "coefficients".to_string(),
                    label: "Spectrum Coefficients".to_string(),
                    param_type: ParameterType::Polynomial,
                    default_value: ParameterValue::Vec(vec![-2.0, 0.0]), // Pink noise: P(k) ∝ 1/k²
                    constraints: None,
                    description: Some(
                        "Polynomial coefficients [a₀, a₁, ...] for log₁₀(P) = Σ aᵢ·(log₁₀ k)ⁱ"
                            .to_string(),
                    ),
                },
                ParameterSpec::int("resolution", "Resolution", 256)
                    .with_constraints(ParameterConstraints::range(16.0, 2048.0).power_of_two())
                    .with_description("Grid resolution (must be power of 2)"),
                ParameterSpec::int("seed", "Seed", 42)
                    .with_constraints(ParameterConstraints::none())
                    .with_description("Random seed for reproducibility"),
                ParameterSpec::float("scale", "Output Scale", 1.0)
                    .with_constraints(ParameterConstraints::range(0.01, 100.0))
                    .with_description("Scale factor for output values"),
            ],
            output_dimensions: 2,
            supports_animation: true,
        };

        Self { metadata }
    }

    /// Evaluate the polynomial at a given log-k value.
    fn eval_polynomial(coeffs: &[f64], log_k: f64) -> f64 {
        let mut result = 0.0;
        let mut log_k_power = 1.0;
        for coeff in coeffs {
            result += coeff * log_k_power;
            log_k_power *= log_k;
        }
        result
    }
}

impl Default for PowerSpectrumNoise {
    fn default() -> Self {
        Self::new()
    }
}

impl DataGenerator for PowerSpectrumNoise {
    fn metadata(&self) -> &GeneratorMetadata {
        &self.metadata
    }

    fn schema(&self) -> DataSchema {
        DataSchema {
            fields: vec![
                FieldDescriptor::new("x", DataType::Float64)
                    .with_description("X coordinate")
                    .with_range(0.0, 1.0),
                FieldDescriptor::new("y", DataType::Float64)
                    .with_description("Y coordinate")
                    .with_range(0.0, 1.0),
                FieldDescriptor::new("value", DataType::Float64).with_description("Noise value"),
            ],
        }
    }

    fn generate(&self, params: &GeneratorParams) -> Result<GeneratedData, GeneratorError> {
        let coeffs = params
            .get_vec("coefficients")
            .unwrap_or(&[-2.0, 0.0])
            .to_vec();
        let resolution = params.get_int_or("resolution", 256) as usize;
        let seed = params.get_int_or("seed", 42) as u64;
        let scale = params.get_float_or("scale", 1.0);

        let n = resolution;
        let total_points = n * n;

        // Initialize RNG
        let mut rng = SimpleRng::new(seed);

        // Generate white noise in frequency domain (complex numbers)
        // We'll store as [real, imag] pairs for each frequency component
        let mut freq_real = vec![0.0f64; n * n];
        let mut freq_imag = vec![0.0f64; n * n];

        // Generate Gaussian random values for frequency domain
        for ky in 0..n {
            for kx in 0..n {
                let idx = ky * n + kx;

                // Compute frequency magnitude (distance from origin in frequency space)
                let fx = if kx <= n / 2 {
                    kx as f64
                } else {
                    (n - kx) as f64
                };
                let fy = if ky <= n / 2 {
                    ky as f64
                } else {
                    (n - ky) as f64
                };
                let k = (fx * fx + fy * fy).sqrt();

                // Compute amplitude from power spectrum
                // P(k) in log-log space
                let amplitude = if k < 0.5 {
                    // DC and near-DC: use low-k value
                    let log_p = Self::eval_polynomial(&coeffs, 0.0);
                    10.0_f64.powf(log_p / 2.0)
                } else {
                    let log_k = k.log10();
                    let log_p = Self::eval_polynomial(&coeffs, log_k);
                    10.0_f64.powf(log_p / 2.0) // sqrt of power for amplitude
                };

                // Generate Gaussian random phase
                let (g1, g2) = rng.gaussian_pair();
                freq_real[idx] = g1 * amplitude;
                freq_imag[idx] = g2 * amplitude;
            }
        }

        // Perform inverse FFT (simplified 2D FFT)
        let spatial = inverse_fft_2d(&freq_real, &freq_imag, n);

        // Generate output
        let mut xs = Vec::with_capacity(total_points);
        let mut ys = Vec::with_capacity(total_points);
        let mut values = Vec::with_capacity(total_points);

        for iy in 0..n {
            for ix in 0..n {
                let idx = iy * n + ix;
                xs.push(ix as f64 / (n - 1) as f64);
                ys.push(iy as f64 / (n - 1) as f64);
                values.push(spatial[idx] * scale);
            }
        }

        let mut columns = HashMap::new();
        columns.insert("x".to_string(), xs);
        columns.insert("y".to_string(), ys);
        columns.insert("value".to_string(), values);

        Ok(GeneratedData::new(columns)
            .with_bounds(BoundingBox::new([0.0, 0.0, -1.0], [1.0, 1.0, 1.0]))
            .with_metadata("generator", "power-spectrum")
            .with_metadata("resolution", &resolution.to_string()))
    }

    fn generate_frame(
        &self,
        params: &GeneratorParams,
        time: f64,
    ) -> Result<GeneratedData, GeneratorError> {
        // Animate by varying the seed based on time
        let base_seed = params.get_int_or("seed", 42);
        let mut animated_params = params.clone();
        animated_params.set_int("seed", base_seed + (time * 60.0) as i64);
        self.generate(&animated_params)
    }
}

/// Simple RNG for reproducible generation (Xorshift64)
struct SimpleRng {
    state: u64,
}

impl SimpleRng {
    fn new(seed: u64) -> Self {
        Self {
            state: if seed == 0 { 1 } else { seed },
        }
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }

    fn next_f64(&mut self) -> f64 {
        (self.next_u64() as f64) / (u64::MAX as f64)
    }

    /// Generate a pair of Gaussian random numbers using Box-Muller transform
    fn gaussian_pair(&mut self) -> (f64, f64) {
        let u1 = self.next_f64().max(1e-10);
        let u2 = self.next_f64();

        let r = (-2.0 * u1.ln()).sqrt();
        let theta = 2.0 * PI * u2;

        (r * theta.cos(), r * theta.sin())
    }
}

/// Simplified 2D inverse FFT (Cooley-Tukey style)
fn inverse_fft_2d(real: &[f64], imag: &[f64], n: usize) -> Vec<f64> {
    // Allocate working arrays
    let mut work_real = real.to_vec();
    let mut work_imag = imag.to_vec();

    // 1D inverse FFT on each row
    for y in 0..n {
        let offset = y * n;
        inverse_fft_1d(
            &mut work_real[offset..offset + n],
            &mut work_imag[offset..offset + n],
        );
    }

    // 1D inverse FFT on each column
    let mut col_real = vec![0.0; n];
    let mut col_imag = vec![0.0; n];

    for x in 0..n {
        // Extract column
        for y in 0..n {
            col_real[y] = work_real[y * n + x];
            col_imag[y] = work_imag[y * n + x];
        }

        inverse_fft_1d(&mut col_real, &mut col_imag);

        // Write back
        for y in 0..n {
            work_real[y * n + x] = col_real[y];
        }
    }

    work_real
}

/// 1D inverse FFT using Cooley-Tukey algorithm
fn inverse_fft_1d(real: &mut [f64], imag: &mut [f64]) {
    let n = real.len();
    if n <= 1 {
        return;
    }

    // Bit-reversal permutation
    let mut j = 0;
    for i in 0..n {
        if i < j {
            real.swap(i, j);
            imag.swap(i, j);
        }
        let mut m = n >> 1;
        while m >= 1 && j >= m {
            j -= m;
            m >>= 1;
        }
        j += m;
    }

    // Cooley-Tukey iterations
    let mut step = 2;
    while step <= n {
        let half = step / 2;
        let angle = 2.0 * PI / step as f64; // Positive for inverse

        for i in (0..n).step_by(step) {
            for k in 0..half {
                let w_re = (angle * k as f64).cos();
                let w_im = (angle * k as f64).sin();

                let t_re = w_re * real[i + k + half] - w_im * imag[i + k + half];
                let t_im = w_re * imag[i + k + half] + w_im * real[i + k + half];

                real[i + k + half] = real[i + k] - t_re;
                imag[i + k + half] = imag[i + k] - t_im;
                real[i + k] += t_re;
                imag[i + k] += t_im;
            }
        }

        step *= 2;
    }

    // Scale by 1/n for inverse transform
    let scale = 1.0 / n as f64;
    for i in 0..n {
        real[i] *= scale;
        imag[i] *= scale;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_power_spectrum_generation() {
        let generator = PowerSpectrumNoise::new();
        let params = GeneratorParams::new();

        let result = generator.generate(&params);
        assert!(result.is_ok());

        let data = result.unwrap();
        assert!(data.point_count > 0);
        assert!(data.columns.contains_key("x"));
        assert!(data.columns.contains_key("y"));
        assert!(data.columns.contains_key("value"));
    }

    #[test]
    fn test_polynomial_evaluation() {
        // Linear: log P = -2 * log k
        let coeffs = vec![0.0, -2.0];
        let log_k = 1.0; // k = 10
        let log_p = PowerSpectrumNoise::eval_polynomial(&coeffs, log_k);
        assert!((log_p - (-2.0)).abs() < 1e-10);
    }

    #[test]
    fn test_reproducibility() {
        let generator = PowerSpectrumNoise::new();
        let mut params = GeneratorParams::new();
        params.set_int("seed", 12345);
        params.set_int("resolution", 64);

        let result1 = generator.generate(&params).unwrap();
        let result2 = generator.generate(&params).unwrap();

        let values1 = result1.get_column("value").unwrap();
        let values2 = result2.get_column("value").unwrap();

        for (v1, v2) in values1.iter().zip(values2.iter()) {
            assert!((v1 - v2).abs() < 1e-10);
        }
    }

    #[test]
    fn test_fft_roundtrip() {
        // Simple test: FFT of constant should give impulse at DC
        let n = 8;
        let mut real = vec![1.0; n];
        let mut imag = vec![0.0; n];

        inverse_fft_1d(&mut real, &mut imag);

        // After inverse FFT, DC component should be prominent
        assert!(real[0].abs() > 0.5);
    }
}
