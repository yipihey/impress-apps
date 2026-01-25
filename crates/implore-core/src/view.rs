//! View state and rendering modes for visualization
//!
//! This module defines:
//! - ViewState: Current visualization configuration
//! - RenderMode: Science 2D, Box 3D, or Art shader modes
//! - Camera3D: 3D camera with position, target, and projection

use serde::{Deserialize, Serialize};

/// Current state of the visualization view
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ViewState {
    /// Rendering mode (Science2D, Box3D, or ArtShader)
    pub mode: RenderMode,

    /// 3D camera state (used in Box3D and ArtShader modes)
    pub camera: Camera3D,

    /// Color mapping configuration
    pub color_mapping: ColorMapping,

    /// Point size in pixels
    pub point_size: f32,

    /// Current selection bounds (if any)
    pub selection_bounds: Option<SelectionBounds>,

    /// Visible layers (for multi-layer datasets)
    pub visible_layers: Vec<String>,

    /// Whether to show axes
    pub show_axes: bool,

    /// Whether to show grid
    pub show_grid: bool,

    /// Background color (RGB, 0-1)
    pub background_color: [f32; 3],
}

impl Default for ViewState {
    fn default() -> Self {
        Self {
            mode: RenderMode::default(),
            camera: Camera3D::default(),
            color_mapping: ColorMapping::default(),
            point_size: 2.0,
            selection_bounds: None,
            visible_layers: vec!["default".to_string()],
            show_axes: true,
            show_grid: true,
            background_color: [0.1, 0.1, 0.1], // Dark gray
        }
    }
}

impl ViewState {
    /// Cycle to the next render mode
    pub fn cycle_mode(&mut self) {
        self.mode = self.mode.cycle();
    }

    /// Reset to default view
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

/// Rendering mode for the visualization
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum RenderMode {
    /// 2D statistical plots with axes and marginals
    Science2D(Science2DConfig),

    /// 3D point cloud viewer with perspective camera
    Box3D(Box3DConfig),

    /// Custom shader rendering for artistic visualizations
    ArtShader(ArtShaderConfig),
}

impl Default for RenderMode {
    fn default() -> Self {
        RenderMode::Science2D(Science2DConfig::default())
    }
}

impl RenderMode {
    /// Cycle through modes: Science2D -> Box3D -> ArtShader -> Science2D
    pub fn cycle(&self) -> Self {
        match self {
            RenderMode::Science2D(_) => RenderMode::Box3D(Box3DConfig::default()),
            RenderMode::Box3D(_) => RenderMode::ArtShader(ArtShaderConfig::default()),
            RenderMode::ArtShader(_) => RenderMode::Science2D(Science2DConfig::default()),
        }
    }

    /// Check if this is a 2D mode
    pub fn is_2d(&self) -> bool {
        matches!(self, RenderMode::Science2D(_))
    }

    /// Check if this is a 3D mode
    pub fn is_3d(&self) -> bool {
        matches!(self, RenderMode::Box3D(_) | RenderMode::ArtShader(_))
    }

    /// Get the mode name
    pub fn name(&self) -> &'static str {
        match self {
            RenderMode::Science2D(_) => "Science 2D",
            RenderMode::Box3D(_) => "Box 3D",
            RenderMode::ArtShader(_) => "Art Shader",
        }
    }
}

/// Configuration for 2D scientific plots
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Science2DConfig {
    /// Field to map to X axis
    pub x_field: String,

    /// Field to map to Y axis
    pub y_field: String,

    /// Whether to show X marginal (ECDF)
    pub show_x_marginal: bool,

    /// Whether to show Y marginal (ECDF)
    pub show_y_marginal: bool,

    /// Axis scale for X (linear or log)
    pub x_scale: AxisScale,

    /// Axis scale for Y (linear or log)
    pub y_scale: AxisScale,

    /// Whether to show grid lines
    pub show_grid: bool,
}

impl Default for Science2DConfig {
    fn default() -> Self {
        Self {
            x_field: "x".to_string(),
            y_field: "y".to_string(),
            show_x_marginal: true,
            show_y_marginal: true,
            x_scale: AxisScale::Linear,
            y_scale: AxisScale::Linear,
            show_grid: true,
        }
    }
}

/// Configuration for 3D box view
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Box3DConfig {
    /// Field to map to X axis
    pub x_field: String,

    /// Field to map to Y axis
    pub y_field: String,

    /// Field to map to Z axis
    pub z_field: String,

    /// Whether to show wireframe box
    pub show_box: bool,

    /// Whether to enable depth cueing (fog)
    pub depth_cueing: bool,

    /// Depth cueing strength (0-1)
    pub depth_cueing_strength: f32,

    /// Whether to enable depth sorting
    pub depth_sort: bool,
}

impl Default for Box3DConfig {
    fn default() -> Self {
        Self {
            x_field: "x".to_string(),
            y_field: "y".to_string(),
            z_field: "z".to_string(),
            show_box: true,
            depth_cueing: true,
            depth_cueing_strength: 0.5,
            depth_sort: true,
        }
    }
}

/// Configuration for art shader mode
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtShaderConfig {
    /// Shader name or identifier
    pub shader_name: String,

    /// Shader parameters as key-value pairs
    pub parameters: Vec<ShaderParameter>,

    /// Whether to hide all UI chrome
    pub hide_chrome: bool,

    /// Post-processing effects to apply
    pub post_effects: Vec<PostEffect>,
}

impl Default for ArtShaderConfig {
    fn default() -> Self {
        Self {
            shader_name: "default".to_string(),
            parameters: Vec::new(),
            hide_chrome: true,
            post_effects: Vec::new(),
        }
    }
}

/// A shader parameter with name and value
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ShaderParameter {
    pub name: String,
    pub value: ShaderValue,
}

/// Value types for shader parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ShaderValue {
    Float(f32),
    Vec2([f32; 2]),
    Vec3([f32; 3]),
    Vec4([f32; 4]),
    Int(i32),
    Bool(bool),
}

/// Post-processing effects
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum PostEffect {
    /// Bloom effect with intensity
    Bloom { intensity: f32 },

    /// Depth of field with focus distance and blur amount
    DepthOfField { focus_distance: f32, blur: f32 },

    /// Vignette with intensity
    Vignette { intensity: f32 },

    /// Color grading with LUT name
    ColorGrade { lut_name: String },
}

/// Axis scale type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum AxisScale {
    Linear,
    Log10,
    Log2,
    SymLog,
}

impl AxisScale {
    /// Transform a value according to this scale
    pub fn transform(&self, value: f64) -> f64 {
        match self {
            AxisScale::Linear => value,
            AxisScale::Log10 => value.log10(),
            AxisScale::Log2 => value.log2(),
            AxisScale::SymLog => {
                // Symmetric log: sign(x) * log10(1 + |x|)
                value.signum() * (1.0 + value.abs()).log10()
            }
        }
    }

    /// Inverse transform
    pub fn inverse(&self, value: f64) -> f64 {
        match self {
            AxisScale::Linear => value,
            AxisScale::Log10 => 10.0_f64.powf(value),
            AxisScale::Log2 => 2.0_f64.powf(value),
            AxisScale::SymLog => {
                value.signum() * (10.0_f64.powf(value.abs()) - 1.0)
            }
        }
    }
}

/// 3D camera with position, target, and projection
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Camera3D {
    /// Camera position in world space
    pub position: [f32; 3],

    /// Point the camera is looking at
    pub target: [f32; 3],

    /// Up vector
    pub up: [f32; 3],

    /// Field of view in degrees (for perspective)
    pub fov: f32,

    /// Near clipping plane
    pub near: f32,

    /// Far clipping plane
    pub far: f32,

    /// Whether to use orthographic projection
    pub orthographic: bool,

    /// Orthographic scale (only used if orthographic)
    pub ortho_scale: f32,
}

impl Default for Camera3D {
    fn default() -> Self {
        Self {
            position: [3.0, 3.0, 3.0],
            target: [0.0, 0.0, 0.0],
            up: [0.0, 1.0, 0.0],
            fov: 45.0,
            near: 0.1,
            far: 1000.0,
            orthographic: false,
            ortho_scale: 1.0,
        }
    }
}

impl Camera3D {
    /// Create a camera looking at the origin from a given distance
    pub fn look_at_origin(distance: f32) -> Self {
        let angle = std::f32::consts::PI / 4.0;
        Self {
            position: [
                distance * angle.cos(),
                distance * 0.5,
                distance * angle.sin(),
            ],
            target: [0.0, 0.0, 0.0],
            ..Default::default()
        }
    }

    /// Get the view direction (normalized)
    pub fn view_direction(&self) -> [f32; 3] {
        let dx = self.target[0] - self.position[0];
        let dy = self.target[1] - self.position[1];
        let dz = self.target[2] - self.position[2];
        let len = (dx * dx + dy * dy + dz * dz).sqrt();
        [dx / len, dy / len, dz / len]
    }

    /// Orbit around the target by the given angles (radians)
    pub fn orbit(&mut self, delta_phi: f32, delta_theta: f32) {
        let dx = self.position[0] - self.target[0];
        let dy = self.position[1] - self.target[1];
        let dz = self.position[2] - self.target[2];

        let radius = (dx * dx + dy * dy + dz * dz).sqrt();
        let mut theta = (dy / radius).acos();
        let mut phi = dz.atan2(dx);

        phi += delta_phi;
        theta = (theta + delta_theta).clamp(0.01, std::f32::consts::PI - 0.01);

        self.position[0] = self.target[0] + radius * theta.sin() * phi.cos();
        self.position[1] = self.target[1] + radius * theta.cos();
        self.position[2] = self.target[2] + radius * theta.sin() * phi.sin();
    }

    /// Zoom by adjusting distance to target
    pub fn zoom(&mut self, factor: f32) {
        let dx = self.position[0] - self.target[0];
        let dy = self.position[1] - self.target[1];
        let dz = self.position[2] - self.target[2];

        self.position[0] = self.target[0] + dx * factor;
        self.position[1] = self.target[1] + dy * factor;
        self.position[2] = self.target[2] + dz * factor;
    }

    /// Pan the camera and target together
    pub fn pan(&mut self, dx: f32, dy: f32) {
        // Get right and up vectors in view space
        let view = self.view_direction();
        let right = [
            self.up[1] * view[2] - self.up[2] * view[1],
            self.up[2] * view[0] - self.up[0] * view[2],
            self.up[0] * view[1] - self.up[1] * view[0],
        ];

        // Move both position and target
        for i in 0..3 {
            self.position[i] += right[i] * dx + self.up[i] * dy;
            self.target[i] += right[i] * dx + self.up[i] * dy;
        }
    }

    /// Reset to default position
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

/// Color mapping configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ColorMapping {
    /// Field to use for color mapping
    pub field: Option<String>,

    /// Colormap name (e.g., "viridis", "plasma", "inferno")
    pub colormap: String,

    /// Minimum value for colormap (None = auto)
    pub vmin: Option<f64>,

    /// Maximum value for colormap (None = auto)
    pub vmax: Option<f64>,

    /// Whether to apply log scaling before color mapping
    pub log_scale: bool,

    /// Whether to reverse the colormap
    pub reversed: bool,
}

impl Default for ColorMapping {
    fn default() -> Self {
        Self {
            field: None,
            colormap: "viridis".to_string(),
            vmin: None,
            vmax: None,
            log_scale: false,
            reversed: false,
        }
    }
}

impl ColorMapping {
    /// Create a color mapping for a field with a colormap
    pub fn new(field: impl Into<String>, colormap: impl Into<String>) -> Self {
        Self {
            field: Some(field.into()),
            colormap: colormap.into(),
            ..Default::default()
        }
    }

    /// Set the value range
    pub fn with_range(mut self, vmin: f64, vmax: f64) -> Self {
        self.vmin = Some(vmin);
        self.vmax = Some(vmax);
        self
    }

    /// Enable log scaling
    pub fn with_log_scale(mut self) -> Self {
        self.log_scale = true;
        self
    }
}

/// Selection bounds in data coordinates
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SelectionBounds {
    /// Minimum corner
    pub min: [f64; 3],

    /// Maximum corner
    pub max: [f64; 3],
}

impl SelectionBounds {
    /// Create new selection bounds
    pub fn new(min: [f64; 3], max: [f64; 3]) -> Self {
        Self { min, max }
    }

    /// Check if a point is inside the bounds
    pub fn contains(&self, point: &[f64; 3]) -> bool {
        (0..3).all(|i| point[i] >= self.min[i] && point[i] <= self.max[i])
    }

    /// Get the center of the bounds
    pub fn center(&self) -> [f64; 3] {
        [
            (self.min[0] + self.max[0]) / 2.0,
            (self.min[1] + self.max[1]) / 2.0,
            (self.min[2] + self.max[2]) / 2.0,
        ]
    }

    /// Get the size of the bounds
    pub fn size(&self) -> [f64; 3] {
        [
            self.max[0] - self.min[0],
            self.max[1] - self.min[1],
            self.max[2] - self.min[2],
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_mode_cycle() {
        let mode = RenderMode::Science2D(Science2DConfig::default());
        let mode = mode.cycle();
        assert!(matches!(mode, RenderMode::Box3D(_)));

        let mode = mode.cycle();
        assert!(matches!(mode, RenderMode::ArtShader(_)));

        let mode = mode.cycle();
        assert!(matches!(mode, RenderMode::Science2D(_)));
    }

    #[test]
    fn test_camera_orbit() {
        let mut camera = Camera3D::look_at_origin(5.0);
        let initial_distance = {
            let dx = camera.position[0] - camera.target[0];
            let dy = camera.position[1] - camera.target[1];
            let dz = camera.position[2] - camera.target[2];
            (dx * dx + dy * dy + dz * dz).sqrt()
        };

        camera.orbit(0.1, 0.0);

        // Distance should remain the same
        let final_distance = {
            let dx = camera.position[0] - camera.target[0];
            let dy = camera.position[1] - camera.target[1];
            let dz = camera.position[2] - camera.target[2];
            (dx * dx + dy * dy + dz * dz).sqrt()
        };

        assert!((final_distance - initial_distance).abs() < 0.001);
    }

    #[test]
    fn test_axis_scale_transform() {
        assert!((AxisScale::Linear.transform(10.0) - 10.0).abs() < 1e-10);
        assert!((AxisScale::Log10.transform(100.0) - 2.0).abs() < 1e-10);
        assert!((AxisScale::Log2.transform(8.0) - 3.0).abs() < 1e-10);
    }

    #[test]
    fn test_selection_bounds() {
        let bounds = SelectionBounds::new([0.0, 0.0, 0.0], [1.0, 1.0, 1.0]);
        assert!(bounds.contains(&[0.5, 0.5, 0.5]));
        assert!(!bounds.contains(&[1.5, 0.5, 0.5]));
    }
}
