//! Built-in data generators for implore.
//!
//! This module contains the standard set of data generators available in implore:
//!
//! - **Noise**: Perlin, Simplex, Worley, Power Spectrum noise
//! - **Fractals**: Mandelbrot, Julia sets
//! - **Statistical**: Gaussian clusters, uniform random
//! - **Functions**: 2D function plotter, sine/cosine, dual function plotter

mod dual_function;
mod fractal;
mod function;
mod noise;
mod power_spectrum;
mod statistical;

pub use dual_function::DualFunction;
pub use fractal::{JuliaSet, MandelbrotSet};
pub use function::{FunctionPlotter2D, SineCosine};
pub use noise::{PerlinNoise2D, SimplexNoise2D, WorleyNoise2D};
pub use power_spectrum::PowerSpectrumNoise;
pub use statistical::{GaussianClusters, UniformRandom};
