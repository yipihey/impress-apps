//! Camera system for 3D visualization
//!
//! Provides perspective and orthographic cameras with arcball rotation
//! and keyboard/mouse navigation suitable for scientific data exploration.

use serde::{Deserialize, Serialize};
use std::f32::consts::PI;

/// 3D vector type
pub type Vec3 = [f32; 3];

/// 4x4 matrix type (column-major)
pub type Mat4 = [[f32; 4]; 4];

/// Camera configuration
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Camera {
    /// Camera position in world space
    pub position: Vec3,

    /// Look-at target
    pub target: Vec3,

    /// Up vector (usually [0, 1, 0])
    pub up: Vec3,

    /// Field of view in radians (for perspective)
    pub fov: f32,

    /// Near clipping plane
    pub near: f32,

    /// Far clipping plane
    pub far: f32,

    /// Aspect ratio (width / height)
    pub aspect_ratio: f32,

    /// Projection mode
    pub projection: ProjectionMode,
}

/// Camera projection mode
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProjectionMode {
    Perspective,
    Orthographic,
}

impl Camera {
    /// Create a new perspective camera
    pub fn perspective(position: Vec3, target: Vec3, fov_degrees: f32, aspect: f32) -> Self {
        Self {
            position,
            target,
            up: [0.0, 1.0, 0.0],
            fov: fov_degrees.to_radians(),
            near: 0.1,
            far: 1000.0,
            aspect_ratio: aspect,
            projection: ProjectionMode::Perspective,
        }
    }

    /// Create a new orthographic camera
    pub fn orthographic(position: Vec3, target: Vec3, aspect: f32) -> Self {
        Self {
            position,
            target,
            up: [0.0, 1.0, 0.0],
            fov: 45.0_f32.to_radians(),
            near: 0.1,
            far: 1000.0,
            aspect_ratio: aspect,
            projection: ProjectionMode::Orthographic,
        }
    }

    /// Get the view matrix (world to camera space)
    pub fn view_matrix(&self) -> Mat4 {
        look_at(self.position, self.target, self.up)
    }

    /// Get the projection matrix
    pub fn projection_matrix(&self) -> Mat4 {
        match self.projection {
            ProjectionMode::Perspective => {
                perspective(self.fov, self.aspect_ratio, self.near, self.far)
            }
            ProjectionMode::Orthographic => {
                let distance = vec_length(vec_sub(self.position, self.target));
                let half_height = distance * (self.fov / 2.0).tan();
                let half_width = half_height * self.aspect_ratio;
                orthographic(
                    -half_width,
                    half_width,
                    -half_height,
                    half_height,
                    self.near,
                    self.far,
                )
            }
        }
    }

    /// Get combined view-projection matrix
    pub fn view_projection_matrix(&self) -> Mat4 {
        mat4_multiply(self.projection_matrix(), self.view_matrix())
    }

    /// Get camera forward direction
    pub fn forward(&self) -> Vec3 {
        vec_normalize(vec_sub(self.target, self.position))
    }

    /// Get camera right direction
    pub fn right(&self) -> Vec3 {
        vec_normalize(vec_cross(self.forward(), self.up))
    }

    /// Get distance from camera to target
    pub fn distance(&self) -> f32 {
        vec_length(vec_sub(self.target, self.position))
    }

    /// Set distance while maintaining direction
    pub fn set_distance(&mut self, distance: f32) {
        let direction = vec_normalize(vec_sub(self.position, self.target));
        self.position = vec_add(self.target, vec_scale(direction, distance));
    }

    /// Pan camera (move target and position together)
    pub fn pan(&mut self, dx: f32, dy: f32) {
        let right = self.right();
        let up = vec_normalize(vec_cross(right, self.forward()));

        let delta = vec_add(vec_scale(right, -dx), vec_scale(up, dy));

        self.position = vec_add(self.position, delta);
        self.target = vec_add(self.target, delta);
    }

    /// Zoom by adjusting distance
    pub fn zoom(&mut self, factor: f32) {
        let distance = self.distance();
        let new_distance = (distance * factor).max(0.1).min(10000.0);
        self.set_distance(new_distance);
    }

    /// Reset to default view of bounding box
    pub fn fit_to_bounds(&mut self, min: Vec3, max: Vec3) {
        let center = [
            (min[0] + max[0]) / 2.0,
            (min[1] + max[1]) / 2.0,
            (min[2] + max[2]) / 2.0,
        ];

        let size = [max[0] - min[0], max[1] - min[1], max[2] - min[2]];

        let max_dim = size[0].max(size[1]).max(size[2]);
        let distance = max_dim / (2.0 * (self.fov / 2.0).tan());

        self.target = center;
        self.position = [center[0], center[1], center[2] + distance * 1.5];
    }
}

impl Default for Camera {
    fn default() -> Self {
        Self::perspective([0.0, 0.0, 5.0], [0.0, 0.0, 0.0], 45.0, 1.0)
    }
}

/// Arcball controller for mouse-based rotation
#[derive(Clone, Debug, Default)]
pub struct ArcballController {
    /// Currently dragging
    is_dragging: bool,

    /// Last mouse position (normalized -1 to 1)
    last_pos: Option<[f32; 2]>,

    /// Rotation sensitivity
    pub sensitivity: f32,
}

impl ArcballController {
    pub fn new() -> Self {
        Self {
            is_dragging: false,
            last_pos: None,
            sensitivity: 1.0,
        }
    }

    /// Start drag operation
    pub fn start_drag(&mut self, x: f32, y: f32) {
        self.is_dragging = true;
        self.last_pos = Some([x, y]);
    }

    /// End drag operation
    pub fn end_drag(&mut self) {
        self.is_dragging = false;
        self.last_pos = None;
    }

    /// Update with new mouse position, returns rotation to apply
    pub fn update(&mut self, x: f32, y: f32, camera: &mut Camera) {
        if !self.is_dragging {
            return;
        }

        if let Some([last_x, last_y]) = self.last_pos {
            let dx = (x - last_x) * self.sensitivity;
            let dy = (y - last_y) * self.sensitivity;

            // Horizontal rotation (around world Y)
            let theta = -dx * PI;
            self.rotate_around_target(camera, [0.0, 1.0, 0.0], theta);

            // Vertical rotation (around camera right)
            let phi = -dy * PI;
            let right = camera.right();
            self.rotate_around_target(camera, right, phi);
        }

        self.last_pos = Some([x, y]);
    }

    fn rotate_around_target(&self, camera: &mut Camera, axis: Vec3, angle: f32) {
        let offset = vec_sub(camera.position, camera.target);
        let rotated = rotate_vector(offset, axis, angle);
        camera.position = vec_add(camera.target, rotated);

        // Also rotate up vector for vertical rotation
        if axis[1].abs() < 0.5 {
            camera.up = rotate_vector(camera.up, axis, angle);
        }
    }
}

/// Keyboard camera controller
#[derive(Clone, Debug)]
pub struct KeyboardController {
    /// Movement speed (units per second)
    pub move_speed: f32,

    /// Rotation speed (radians per second)
    pub rotate_speed: f32,
}

impl Default for KeyboardController {
    fn default() -> Self {
        Self {
            move_speed: 5.0,
            rotate_speed: PI / 2.0,
        }
    }
}

impl KeyboardController {
    /// Process keyboard input and update camera
    pub fn update(&self, camera: &mut Camera, input: &CameraInput, dt: f32) {
        let forward = camera.forward();
        let right = camera.right();
        let up = [0.0, 1.0, 0.0];

        let mut move_delta = [0.0, 0.0, 0.0];

        // WASD / hjkl movement
        if input.forward {
            move_delta = vec_add(move_delta, forward);
        }
        if input.backward {
            move_delta = vec_sub(move_delta, forward);
        }
        if input.left {
            move_delta = vec_sub(move_delta, right);
        }
        if input.right {
            move_delta = vec_add(move_delta, right);
        }
        if input.up {
            move_delta = vec_add(move_delta, up);
        }
        if input.down {
            move_delta = vec_sub(move_delta, up);
        }

        // Normalize and apply speed
        if vec_length(move_delta) > 0.001 {
            move_delta = vec_scale(vec_normalize(move_delta), self.move_speed * dt);
            camera.position = vec_add(camera.position, move_delta);
            camera.target = vec_add(camera.target, move_delta);
        }

        // Rotation via arrow keys
        if input.rotate_left {
            let angle = self.rotate_speed * dt;
            let offset = vec_sub(camera.target, camera.position);
            let rotated = rotate_vector(offset, up, angle);
            camera.target = vec_add(camera.position, rotated);
        }
        if input.rotate_right {
            let angle = -self.rotate_speed * dt;
            let offset = vec_sub(camera.target, camera.position);
            let rotated = rotate_vector(offset, up, angle);
            camera.target = vec_add(camera.position, rotated);
        }
    }
}

/// Camera input state
#[derive(Clone, Debug, Default)]
pub struct CameraInput {
    pub forward: bool,  // W or K
    pub backward: bool, // S or J
    pub left: bool,     // A or H
    pub right: bool,    // D or L
    pub up: bool,       // Space or E
    pub down: bool,     // Shift or Q
    pub rotate_left: bool,
    pub rotate_right: bool,
}

// MARK: - Math utilities

fn vec_add(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn vec_sub(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn vec_scale(v: Vec3, s: f32) -> Vec3 {
    [v[0] * s, v[1] * s, v[2] * s]
}

fn vec_dot(a: Vec3, b: Vec3) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn vec_cross(a: Vec3, b: Vec3) -> Vec3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

fn vec_length(v: Vec3) -> f32 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

fn vec_normalize(v: Vec3) -> Vec3 {
    let len = vec_length(v);
    if len > 0.0001 {
        vec_scale(v, 1.0 / len)
    } else {
        v
    }
}

fn rotate_vector(v: Vec3, axis: Vec3, angle: f32) -> Vec3 {
    let axis = vec_normalize(axis);
    let cos_a = angle.cos();
    let sin_a = angle.sin();

    // Rodrigues' rotation formula
    let term1 = vec_scale(v, cos_a);
    let term2 = vec_scale(vec_cross(axis, v), sin_a);
    let term3 = vec_scale(axis, vec_dot(axis, v) * (1.0 - cos_a));

    vec_add(vec_add(term1, term2), term3)
}

fn look_at(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
    let f = vec_normalize(vec_sub(target, eye));
    let s = vec_normalize(vec_cross(f, up));
    let u = vec_cross(s, f);

    [
        [s[0], u[0], -f[0], 0.0],
        [s[1], u[1], -f[1], 0.0],
        [s[2], u[2], -f[2], 0.0],
        [-vec_dot(s, eye), -vec_dot(u, eye), vec_dot(f, eye), 1.0],
    ]
}

fn perspective(fov: f32, aspect: f32, near: f32, far: f32) -> Mat4 {
    let tan_half_fov = (fov / 2.0).tan();

    let mut m = [[0.0; 4]; 4];
    m[0][0] = 1.0 / (aspect * tan_half_fov);
    m[1][1] = 1.0 / tan_half_fov;
    m[2][2] = -(far + near) / (far - near);
    m[2][3] = -1.0;
    m[3][2] = -(2.0 * far * near) / (far - near);

    m
}

fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) -> Mat4 {
    let mut m = [[0.0; 4]; 4];
    m[0][0] = 2.0 / (right - left);
    m[1][1] = 2.0 / (top - bottom);
    m[2][2] = -2.0 / (far - near);
    m[3][0] = -(right + left) / (right - left);
    m[3][1] = -(top + bottom) / (top - bottom);
    m[3][2] = -(far + near) / (far - near);
    m[3][3] = 1.0;

    m
}

fn mat4_multiply(a: Mat4, b: Mat4) -> Mat4 {
    let mut result = [[0.0; 4]; 4];

    for i in 0..4 {
        for j in 0..4 {
            for k in 0..4 {
                result[i][j] += a[k][j] * b[i][k];
            }
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_camera_default() {
        let camera = Camera::default();
        assert_eq!(camera.position, [0.0, 0.0, 5.0]);
        assert_eq!(camera.target, [0.0, 0.0, 0.0]);
    }

    #[test]
    fn test_camera_distance() {
        let camera = Camera::default();
        assert!((camera.distance() - 5.0).abs() < 0.001);
    }

    #[test]
    fn test_camera_forward() {
        let camera = Camera::default();
        let forward = camera.forward();
        // Looking from (0,0,5) to (0,0,0) = forward is (0,0,-1)
        assert!(forward[2] < 0.0);
    }

    #[test]
    fn test_camera_zoom() {
        let mut camera = Camera::default();
        let original_distance = camera.distance();
        camera.zoom(0.5);
        assert!((camera.distance() - original_distance * 0.5).abs() < 0.001);
    }

    #[test]
    fn test_camera_pan() {
        let mut camera = Camera::default();
        let original_target = camera.target;
        camera.pan(1.0, 0.0);
        // Target should have moved
        assert!((camera.target[0] - original_target[0]).abs() > 0.5);
    }

    #[test]
    fn test_arcball_controller() {
        let mut controller = ArcballController::new();
        let mut camera = Camera::default();
        let original_pos = camera.position;

        controller.start_drag(0.0, 0.0);
        controller.update(0.1, 0.0, &mut camera);
        controller.end_drag();

        // Camera should have rotated
        assert!(
            (camera.position[0] - original_pos[0]).abs() > 0.01
                || (camera.position[2] - original_pos[2]).abs() > 0.01
        );
    }

    #[test]
    fn test_fit_to_bounds() {
        let mut camera = Camera::default();
        camera.fit_to_bounds([0.0, 0.0, 0.0], [10.0, 10.0, 10.0]);

        // Camera should be looking at center
        assert!((camera.target[0] - 5.0).abs() < 0.001);
        assert!((camera.target[1] - 5.0).abs() < 0.001);
        assert!((camera.target[2] - 5.0).abs() < 0.001);
    }

    #[test]
    fn test_vec_operations() {
        let a = [1.0, 2.0, 3.0];
        let b = [4.0, 5.0, 6.0];

        let sum = vec_add(a, b);
        assert_eq!(sum, [5.0, 7.0, 9.0]);

        let diff = vec_sub(b, a);
        assert_eq!(diff, [3.0, 3.0, 3.0]);

        let dot = vec_dot(a, b);
        assert!((dot - 32.0).abs() < 0.001);
    }

    #[test]
    fn test_view_projection_matrix() {
        let camera = Camera::default();
        let vp = camera.view_projection_matrix();

        // Matrix should be valid (not all zeros)
        let sum: f32 = vp.iter().flat_map(|row| row.iter()).map(|x| x.abs()).sum();
        assert!(sum > 1.0);
    }
}
