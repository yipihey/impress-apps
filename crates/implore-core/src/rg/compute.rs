//! Derived quantity computation for RG turbulence fields.
//!
//! Computes scalar fields from velocity and gain tensor data:
//! velocity magnitude, vorticity, strain rate, Q-criterion, etc.

use super::types::{DerivedQuantity, RgLevel};
use implore_io::IoError;
use ndarray::{Array3, Array4, Ix3};

/// Compute a derived quantity for a given RG level.
pub fn compute_quantity(level: &RgLevel, quantity: DerivedQuantity) -> Result<Array3<f32>, IoError> {
    match quantity {
        DerivedQuantity::GainFactor => {
            level.gain_factor.clone().ok_or_else(|| {
                IoError::DatasetNotFound("No gain_factor field in dataset".to_string())
            })
        }
        DerivedQuantity::LogGainFactor => {
            let gf = level.gain_factor.as_ref().ok_or_else(|| {
                IoError::DatasetNotFound("No gain_factor field in dataset".to_string())
            })?;
            Ok(gf.mapv(|v| if v > 0.0 { v.log10() } else { f32::NEG_INFINITY }))
        }
        DerivedQuantity::VelocityMagnitude => Ok(velocity_magnitude(&level.u)),
        DerivedQuantity::VelocityX => Ok(level.u.index_axis(ndarray::Axis(0), 0).to_owned()),
        DerivedQuantity::VelocityY => Ok(level.u.index_axis(ndarray::Axis(0), 1).to_owned()),
        DerivedQuantity::VelocityZ => Ok(level.u.index_axis(ndarray::Axis(0), 2).to_owned()),
        DerivedQuantity::VorticityMagnitude => {
            let a = velocity_gradient(&level.u, level.h);
            Ok(vorticity_magnitude(&a))
        }
        DerivedQuantity::StrainMagnitude => {
            let a = velocity_gradient(&level.u, level.h);
            Ok(strain_magnitude(&a))
        }
        DerivedQuantity::QCriterion => {
            let a = velocity_gradient(&level.u, level.h);
            Ok(q_criterion(&a))
        }
        // Stubs for quantities requiring more complex computation
        DerivedQuantity::I2 => {
            let a = velocity_gradient(&level.u, level.h);
            Ok(invariant_i2(&a))
        }
        DerivedQuantity::I3 => {
            let a = velocity_gradient(&level.u, level.h);
            Ok(invariant_i3(&a))
        }
        DerivedQuantity::DetG => {
            let g = level.g.as_ref().ok_or_else(|| {
                IoError::DatasetNotFound("No gain tensor in dataset".to_string())
            })?;
            Ok(det_g(g))
        }
        DerivedQuantity::LambdaMax => {
            let g = level.g.as_ref().ok_or_else(|| {
                IoError::DatasetNotFound("No gain tensor in dataset".to_string())
            })?;
            Ok(cauchy_green_lambda_max(g))
        }
    }
}

/// Compute velocity magnitude |u| at each grid point.
fn velocity_magnitude(u: &Array4<f32>) -> Array3<f32> {
    let n = u.shape()[1];
    let mut result = Array3::<f32>::zeros(Ix3(n, n, n));

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                let ux = u[[0, iz, iy, ix]];
                let uy = u[[1, iz, iy, ix]];
                let uz = u[[2, iz, iy, ix]];
                result[[iz, iy, ix]] = (ux * ux + uy * uy + uz * uz).sqrt();
            }
        }
    }

    result
}

/// Compute the velocity gradient tensor A[i][j] = du_i/dx_j using
/// centered finite differences with periodic boundary conditions.
/// Returns shape (3, 3, n, n, n) flattened as Array4 (9, n, n, n)
/// where index [i*3+j, z, y, x] = A_ij at point (x,y,z).
fn velocity_gradient(u: &Array4<f32>, h: f32) -> Array4<f32> {
    let n = u.shape()[1];
    let inv_2h = 1.0 / (2.0 * h);

    // A[idx, z, y, x] where idx = i*3+j for A_ij = du_i / dx_j
    let mut a = Array4::<f32>::zeros([9, n, n, n]);

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                // Periodic neighbors
                let ixp = (ix + 1) % n;
                let ixm = (ix + n - 1) % n;
                let iyp = (iy + 1) % n;
                let iym = (iy + n - 1) % n;
                let izp = (iz + 1) % n;
                let izm = (iz + n - 1) % n;

                for i in 0..3usize {
                    // du_i/dx (j=0)
                    a[[i * 3 + 0, iz, iy, ix]] =
                        (u[[i, iz, iy, ixp]] - u[[i, iz, iy, ixm]]) * inv_2h;
                    // du_i/dy (j=1)
                    a[[i * 3 + 1, iz, iy, ix]] =
                        (u[[i, iz, iyp, ix]] - u[[i, iz, iym, ix]]) * inv_2h;
                    // du_i/dz (j=2)
                    a[[i * 3 + 2, iz, iy, ix]] =
                        (u[[i, izp, iy, ix]] - u[[i, izm, iy, ix]]) * inv_2h;
                }
            }
        }
    }

    a
}

/// Vorticity magnitude: |omega| = sqrt(sum of omega_k^2)
/// omega_k = epsilon_{ijk} A_{ji} (curl components)
fn vorticity_magnitude(a: &Array4<f32>) -> Array3<f32> {
    let n = a.shape()[1];
    let mut result = Array3::<f32>::zeros(Ix3(n, n, n));

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                // omega_x = du_z/dy - du_y/dz = A[2*3+1] - A[1*3+2]
                let wx = a[[7, iz, iy, ix]] - a[[5, iz, iy, ix]];
                // omega_y = du_x/dz - du_z/dx = A[0*3+2] - A[2*3+0]
                let wy = a[[2, iz, iy, ix]] - a[[6, iz, iy, ix]];
                // omega_z = du_y/dx - du_x/dy = A[1*3+0] - A[0*3+1]
                let wz = a[[3, iz, iy, ix]] - a[[1, iz, iy, ix]];

                result[[iz, iy, ix]] = (wx * wx + wy * wy + wz * wz).sqrt();
            }
        }
    }

    result
}

/// Strain rate magnitude: |S| = sqrt(2 * S_ij * S_ij)
/// S_ij = (A_ij + A_ji) / 2
fn strain_magnitude(a: &Array4<f32>) -> Array3<f32> {
    let n = a.shape()[1];
    let mut result = Array3::<f32>::zeros(Ix3(n, n, n));

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                let mut s2 = 0.0f32;
                for i in 0..3usize {
                    for j in 0..3usize {
                        let s_ij = 0.5 * (a[[i * 3 + j, iz, iy, ix]] + a[[j * 3 + i, iz, iy, ix]]);
                        s2 += s_ij * s_ij;
                    }
                }
                result[[iz, iy, ix]] = (2.0 * s2).sqrt();
            }
        }
    }

    result
}

/// Q-criterion: Q = (|Omega|^2 - |S|^2) / 2
/// where |Omega|^2 = Omega_ij * Omega_ij (antisymmetric part)
fn q_criterion(a: &Array4<f32>) -> Array3<f32> {
    let n = a.shape()[1];
    let mut result = Array3::<f32>::zeros(Ix3(n, n, n));

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                let mut s2 = 0.0f32; // S_ij S_ij
                let mut o2 = 0.0f32; // Omega_ij Omega_ij
                for i in 0..3usize {
                    for j in 0..3usize {
                        let aij = a[[i * 3 + j, iz, iy, ix]];
                        let aji = a[[j * 3 + i, iz, iy, ix]];
                        let s = 0.5 * (aij + aji);
                        let o = 0.5 * (aij - aji);
                        s2 += s * s;
                        o2 += o * o;
                    }
                }
                result[[iz, iy, ix]] = 0.5 * (o2 - s2);
            }
        }
    }

    result
}

/// Invariant I2 = tr(A^2) = A_ij * A_ji
fn invariant_i2(a: &Array4<f32>) -> Array3<f32> {
    let n = a.shape()[1];
    let mut result = Array3::<f32>::zeros(Ix3(n, n, n));

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                let mut tr = 0.0f32;
                for i in 0..3usize {
                    for j in 0..3usize {
                        tr += a[[i * 3 + j, iz, iy, ix]] * a[[j * 3 + i, iz, iy, ix]];
                    }
                }
                result[[iz, iy, ix]] = tr;
            }
        }
    }

    result
}

/// Invariant I3 = tr(A^3) = A_ij * A_jk * A_ki
fn invariant_i3(a: &Array4<f32>) -> Array3<f32> {
    let n = a.shape()[1];
    let mut result = Array3::<f32>::zeros(Ix3(n, n, n));

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                let mut tr = 0.0f32;
                for i in 0..3usize {
                    for j in 0..3usize {
                        for k in 0..3usize {
                            tr += a[[i * 3 + j, iz, iy, ix]]
                                * a[[j * 3 + k, iz, iy, ix]]
                                * a[[k * 3 + i, iz, iy, ix]];
                        }
                    }
                }
                result[[iz, iy, ix]] = tr;
            }
        }
    }

    result
}

/// Determinant of the 3x3 gain tensor at each grid point.
/// G has shape (3, 3, n, n, n).
fn det_g(g: &ndarray::Array5<f32>) -> Array3<f32> {
    let n = g.shape()[2];
    let mut result = Array3::<f32>::zeros(Ix3(n, n, n));

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                let m = nalgebra::Matrix3::new(
                    g[[0, 0, iz, iy, ix]], g[[0, 1, iz, iy, ix]], g[[0, 2, iz, iy, ix]],
                    g[[1, 0, iz, iy, ix]], g[[1, 1, iz, iy, ix]], g[[1, 2, iz, iy, ix]],
                    g[[2, 0, iz, iy, ix]], g[[2, 1, iz, iy, ix]], g[[2, 2, iz, iy, ix]],
                );
                result[[iz, iy, ix]] = m.determinant();
            }
        }
    }

    result
}

/// Max eigenvalue of the Cauchy-Green tensor F^T F where F = G^{-1}.
/// Uses nalgebra for 3x3 symmetric eigenvalue decomposition.
fn cauchy_green_lambda_max(g: &ndarray::Array5<f32>) -> Array3<f32> {
    let n = g.shape()[2];
    let mut result = Array3::<f32>::zeros(Ix3(n, n, n));

    for iz in 0..n {
        for iy in 0..n {
            for ix in 0..n {
                let m = nalgebra::Matrix3::new(
                    g[[0, 0, iz, iy, ix]], g[[0, 1, iz, iy, ix]], g[[0, 2, iz, iy, ix]],
                    g[[1, 0, iz, iy, ix]], g[[1, 1, iz, iy, ix]], g[[1, 2, iz, iy, ix]],
                    g[[2, 0, iz, iy, ix]], g[[2, 1, iz, iy, ix]], g[[2, 2, iz, iy, ix]],
                );

                if let Some(f) = m.try_inverse() {
                    // Cauchy-Green: C = F^T * F
                    let c = f.transpose() * f;
                    // Symmetric eigenvalues
                    let eig = c.symmetric_eigenvalues();
                    result[[iz, iy, ix]] = eig.max();
                }
                // If singular, result stays 0.0
            }
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use ndarray::Array4;

    /// Create a simple test velocity field: uniform flow u = (1, 0, 0).
    fn uniform_flow(n: usize) -> Array4<f32> {
        let mut u = Array4::<f32>::zeros([3, n, n, n]);
        u.index_axis_mut(ndarray::Axis(0), 0).fill(1.0);
        u
    }

    #[test]
    fn test_velocity_magnitude_uniform() {
        let u = uniform_flow(4);
        let mag = velocity_magnitude(&u);
        for v in mag.iter() {
            assert!((v - 1.0).abs() < 1e-6);
        }
    }

    #[test]
    fn test_vorticity_uniform_is_zero() {
        let u = uniform_flow(8);
        let h = 1.0 / 8.0;
        let a = velocity_gradient(&u, h);
        let vort = vorticity_magnitude(&a);
        for v in vort.iter() {
            assert!(v.abs() < 1e-6, "Expected zero vorticity for uniform flow, got {}", v);
        }
    }

    #[test]
    fn test_strain_uniform_is_zero() {
        let u = uniform_flow(8);
        let h = 1.0 / 8.0;
        let a = velocity_gradient(&u, h);
        let s = strain_magnitude(&a);
        for v in s.iter() {
            assert!(v.abs() < 1e-6, "Expected zero strain for uniform flow, got {}", v);
        }
    }
}
