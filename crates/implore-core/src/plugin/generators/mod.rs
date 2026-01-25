//! Built-in data generators for implore.
//!
//! This module contains the standard set of data generators available in implore:
//!
//! - **Noise**: Perlin, Simplex, Worley noise
//! - **Fractals**: Mandelbrot, Julia sets
//! - **Statistical**: Gaussian clusters, uniform random
//! - **Functions**: 2D function plotter, sine/cosine

mod fractal;
mod function;
mod noise;
mod statistical;

pub use fractal::{JuliaSet, MandelbrotSet};
pub use function::{FunctionPlotter2D, SineCosine};
pub use noise::{PerlinNoise2D, SimplexNoise2D, WorleyNoise2D};
pub use statistical::{GaussianClusters, UniformRandom};
